from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from app.audit import write_audit_entry
from app.auth import require_roles
from app.database import get_db
from app.exception_metrics import count_recent_approved_exceptions
from app.models import (
    ApprovalControlStatus,
    AuditActionType,
    ExceptionRequest,
    ExceptionStatus,
    POStatus,
    PurchaseOrder,
    Role,
    User,
)
from app.risk_engine import _as_naive_utc
from app.schemas import (
    ExceptionDecisionRequest,
    ExceptionRequestCreate,
    ExceptionRequestDetailResponse,
    ExceptionRequestResponse,
)

router = APIRouter(prefix="/api/v1/exception-requests", tags=["exception-requests"])


@router.get("", response_model=list[ExceptionRequestDetailResponse])
def list_exception_requests(
    status_filter: ExceptionStatus | None = Query(default=None, alias="status"),
    db: Session = Depends(get_db),
    caller: User = Depends(require_roles(Role.procurement_lead, Role.auditor)),
) -> list[ExceptionRequest]:
    """Previously did not exist at all — procurement_lead had no way to
    discover a pending exception request except knowing its id out of band.
    Defaults to pending, since that's the actionable queue."""
    query = db.query(ExceptionRequest)
    query = query.filter(ExceptionRequest.status == (status_filter or ExceptionStatus.pending))
    return query.order_by(ExceptionRequest.expiry_at).all()


@router.post("", response_model=ExceptionRequestResponse, status_code=status.HTTP_201_CREATED)
def create_exception_request(
    payload: ExceptionRequestCreate,
    db: Session = Depends(get_db),
    caller: User = Depends(
        require_roles(Role.requester, Role.department_approver, Role.procurement_lead)
    ),
) -> ExceptionRequest:
    po = db.get(PurchaseOrder, payload.purchase_order_id)
    if po is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Purchase order not found")
    if po.approval_control_status != ApprovalControlStatus.blocked:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Exceptions can only be requested for a blocked purchase order",
        )

    exception_request = ExceptionRequest(
        purchase_order_id=po.id,
        requested_by_id=caller.id,
        justification=payload.justification,
        urgency=payload.urgency,
        expiry_at=payload.expiry_at,
        status=ExceptionStatus.pending,
    )
    db.add(exception_request)
    db.flush()

    write_audit_entry(
        db,
        entity_type="exception_request",
        entity_id=exception_request.id,
        action_type=AuditActionType.exception_submitted,
        actor_id=caller.id,
        rationale=(
            f"{caller.email} requested an exception for PO {po.id} "
            f"(urgency={payload.urgency.value})"
        ),
        metadata={"po_id": str(po.id), "urgency": payload.urgency.value},
    )

    db.commit()
    db.refresh(exception_request)

    exception_request.recent_exception_count_for_supplier = count_recent_approved_exceptions(
        db, po.supplier_id
    )
    return exception_request


@router.post("/{exception_id}/decision", response_model=ExceptionRequestResponse)
def decide_exception_request(
    exception_id: int,
    payload: ExceptionDecisionRequest,
    db: Session = Depends(get_db),
    caller: User = Depends(require_roles(Role.procurement_lead)),
) -> ExceptionRequest:
    exception_request = db.get(ExceptionRequest, exception_id)
    if exception_request is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="Exception request not found"
        )

    now = datetime.now(timezone.utc)
    if exception_request.status != ExceptionStatus.pending:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT, detail="Exception request already decided"
        )
    if _as_naive_utc(exception_request.expiry_at) < _as_naive_utc(now):
        exception_request.status = ExceptionStatus.lapsed
        write_audit_entry(
            db,
            entity_type="exception_request",
            entity_id=exception_request.id,
            action_type=AuditActionType.exception_lapsed,
            actor_id=None,
            rationale="Exception request expired before a decision was made",
        )
        db.commit()
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Exception request lapsed")

    # FR-013: self-approval MUST be rejected regardless of role, checked
    # even though the route already requires procurement_lead — a
    # procurement_lead can still be the original requester.
    if caller.id == exception_request.requested_by_id:
        write_audit_entry(
            db,
            entity_type="exception_request",
            entity_id=exception_request.id,
            action_type=AuditActionType.self_approval_blocked,
            actor_id=caller.id,
            rationale=(
                f"{caller.email} attempted to decide their own exception request "
                f"for PO {exception_request.purchase_order_id} — blocked "
                f"(segregation of duties)"
            ),
            metadata={
                "po_id": str(exception_request.purchase_order_id),
                "exception_request_id": str(exception_request.id),
                "actor_email": caller.email,
                "actor_role_at_time": caller.role.value,
            },
        )
        db.commit()
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Cannot approve or reject your own exception request",
        )

    po = db.get(PurchaseOrder, exception_request.purchase_order_id)
    exception_request.decided_by_id = caller.id
    exception_request.decided_at = now

    if payload.decision == "approved":
        exception_request.status = ExceptionStatus.approved
        po.approved_with_exception = True
        po.status = POStatus.approved
        po.decided_at = now

        write_audit_entry(
            db,
            entity_type="exception_request",
            entity_id=exception_request.id,
            action_type=AuditActionType.exception_approved,
            actor_id=caller.id,
            rationale=f"{caller.email} approved exception request for PO {po.id} — {payload.reason}",
            metadata={
                "po_id": str(po.id),
                "actor_email": caller.email,
                "actor_role_at_time": caller.role.value,
                "reason": payload.reason,
            },
        )
        write_audit_entry(
            db,
            entity_type="purchase_order",
            entity_id=po.id,
            action_type=AuditActionType.po_approved_with_exception,
            actor_id=caller.id,
            rationale=(
                f"PO {po.id} approved via exception (exception_request_id="
                f"{exception_request.id}) — {payload.reason}"
            ),
            metadata={
                "po_id": str(po.id),
                "exception_request_id": str(exception_request.id),
                "actor_email": caller.email,
                "actor_role_at_time": caller.role.value,
                "reason": payload.reason,
            },
        )
    else:
        exception_request.status = ExceptionStatus.rejected
        write_audit_entry(
            db,
            entity_type="exception_request",
            entity_id=exception_request.id,
            action_type=AuditActionType.exception_rejected,
            actor_id=caller.id,
            rationale=f"{caller.email} rejected exception request for PO {po.id} — {payload.reason}",
            metadata={
                "po_id": str(po.id),
                "actor_email": caller.email,
                "actor_role_at_time": caller.role.value,
                "reason": payload.reason,
            },
        )

    db.commit()
    db.refresh(exception_request)
    return exception_request
