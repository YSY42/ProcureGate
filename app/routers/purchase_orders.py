from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session, joinedload

from app.audit import write_audit_entry
from app.auth import require_roles
from app.database import get_db
from app.exception_metrics import po_trigger_reason_details
from app.models import (
    ApprovalStep,
    ApprovalStepStatus,
    AuditActionType,
    POStatus,
    PurchaseOrder,
    Role,
    Supplier,
    SupplierStatus,
    User,
    ValidityStatus,
)
from app.risk_engine import (
    _as_naive_utc,
    compliance_floor_failed,
    compute_approval_control_status,
    compute_validity_status,
    generate_approval_steps,
)
from app.risk_settings import get_effective_settings
from app.schemas import (
    EscalateRequest,
    PurchaseOrderCreateRequest,
    PurchaseOrderResponse,
    PurchaseOrderUpdateRequest,
    RequesterSupplierHistoryResponse,
    TransitionRequest,
    TriggerReasonDetailResponse,
)

router = APIRouter(prefix="/api/v1/purchase-orders", tags=["purchase-orders"])

_READ_ROLES = (Role.requester, Role.department_approver, Role.procurement_lead, Role.auditor)


def _get_po_or_404(db: Session, po_id: int) -> PurchaseOrder:
    po = db.get(PurchaseOrder, po_id)
    if po is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Purchase order not found")
    return po


@router.post("", response_model=PurchaseOrderResponse, status_code=status.HTTP_201_CREATED)
def create_purchase_order(
    payload: PurchaseOrderCreateRequest,
    db: Session = Depends(get_db),
    caller: User = Depends(require_roles(Role.requester)),
) -> PurchaseOrder:
    supplier = db.get(Supplier, payload.supplier_id)
    if supplier is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Supplier not found")

    # FR-009: reject before any risk score is computed.
    if supplier.status == SupplierStatus.blocked:
        write_audit_entry(
            db,
            entity_type="supplier",
            entity_id=supplier.id,
            action_type=AuditActionType.po_creation_blocked,
            actor_id=caller.id,
            rationale=(
                f"{caller.email} attempted to create a PO against blocked "
                f"supplier {supplier.name}"
            ),
            metadata={"supplier_name": supplier.name},
        )
        db.commit()
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT, detail="Supplier is blocked"
        )

    po = PurchaseOrder(
        requester_id=caller.id,
        supplier_id=supplier.id,
        amount=payload.amount,
        currency=payload.currency,
        description=payload.description,
        status=POStatus.draft,
    )
    db.add(po)
    db.commit()
    db.refresh(po)
    return po


@router.get("", response_model=list[PurchaseOrderResponse])
def list_purchase_orders(
    db: Session = Depends(get_db), caller: User = Depends(require_roles(*_READ_ROLES))
) -> list[PurchaseOrder]:
    # require_roles is the access-control gate (constitution Principle III);
    # the role check below is data scoping (which rows a permitted caller
    # sees), not a permit/deny decision.
    query = db.query(PurchaseOrder).options(
        joinedload(PurchaseOrder.supplier), joinedload(PurchaseOrder.requester)
    )
    if caller.role == Role.requester:
        query = query.filter(PurchaseOrder.requester_id == caller.id)
    return query.all()


def get_visible_purchase_order(
    po_id: int,
    db: Session = Depends(get_db),
    caller: User = Depends(require_roles(*_READ_ROLES)),
) -> PurchaseOrder:
    """Declarative read-access dependency (constitution Principle III):
    require_roles(*_READ_ROLES) is the access-control gate (who may call
    this route at all); the ownership narrowing for requester lives here,
    in one named, reusable dependency function, rather than as inline
    if/else logic inside a route handler body."""
    po = _get_po_or_404(db, po_id)
    if caller.role == Role.requester and po.requester_id != caller.id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Not permitted")
    return po


@router.get("/{po_id}", response_model=PurchaseOrderResponse)
def get_purchase_order(
    po: PurchaseOrder = Depends(get_visible_purchase_order),
) -> PurchaseOrder:
    return po


@router.get("/{po_id}/requester-supplier-history", response_model=RequesterSupplierHistoryResponse)
def get_requester_supplier_history(
    po: PurchaseOrder = Depends(get_visible_purchase_order),
    db: Session = Depends(get_db),
) -> RequesterSupplierHistoryResponse:
    """What an approver deciding this PO can't currently see: has this same
    requester been blocked against this same supplier before, and why. The
    data already exists for procurement_lead's aggregate drift signals —
    this scopes the same underlying query to the one requester/supplier
    pair in front of the decision-maker right now."""
    sibling_po_ids = [
        row.id
        for row in db.query(PurchaseOrder.id)
        .filter(
            PurchaseOrder.requester_id == po.requester_id,
            PurchaseOrder.supplier_id == po.supplier_id,
            PurchaseOrder.id != po.id,
        )
        .all()
    ]
    details = po_trigger_reason_details(db, sibling_po_ids)
    return RequesterSupplierHistoryResponse(
        blocked_count=len(details),
        details=[
            TriggerReasonDetailResponse(
                po_id=d.po_id, action_type=d.action_type, rationale=d.rationale, at=d.at, metadata=d.metadata
            )
            for d in details
        ],
    )


@router.patch("/{po_id}", response_model=PurchaseOrderResponse)
def update_purchase_order(
    po_id: int,
    payload: PurchaseOrderUpdateRequest,
    db: Session = Depends(get_db),
    caller: User = Depends(require_roles(Role.requester)),
) -> PurchaseOrder:
    po = _get_po_or_404(db, po_id)
    if po.requester_id != caller.id or po.status != POStatus.draft:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Not permitted")

    for field, value in payload.model_dump(exclude_unset=True).items():
        setattr(po, field, value)
    db.commit()
    db.refresh(po)
    return po


def _do_submit(db: Session, po: PurchaseOrder, caller: User) -> None:
    if po.requester_id != caller.id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Not permitted")
    if po.status != POStatus.draft:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Invalid transition")

    supplier = db.get(Supplier, po.supplier_id)
    # FR-010: re-checked at submission, not just at creation.
    if supplier.status != SupplierStatus.active:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Supplier is blocked")

    now = datetime.now(timezone.utc)
    effective_settings = get_effective_settings(db)
    # Use the cached, already-computed tier (maintained by suppliers.py on
    # every write) rather than recomputing from raw fields here — it is
    # None exactly when the assessment is Unassessed/Incomplete, which the
    # validity-status check below independently accounts for.
    tier = supplier.computed_risk_tier
    validity = compute_validity_status(supplier, now, effective_settings)
    floor_failed = compliance_floor_failed(
        supplier.esg_rating, supplier.sanctions_flag, effective_settings
    )

    control_status = compute_approval_control_status(tier, validity, floor_failed)

    po.approval_control_status = control_status
    po.status = POStatus.submitted
    po.submitted_at = now

    # FR-011: one distinct audit entry per triggered condition; none
    # suppress or overwrite another's rationale.
    if validity in (ValidityStatus.unassessed, ValidityStatus.incomplete):
        write_audit_entry(
            db,
            entity_type="purchase_order",
            entity_id=po.id,
            action_type=AuditActionType.risk_trigger_incomplete_or_unassessed,
            actor_id=caller.id,
            rationale=(
                f"Blocked: supplier assessment is {validity.value} "
                f"(missing or never-completed risk data)"
            ),
            metadata={"validity": validity.value},
        )
    if floor_failed:
        write_audit_entry(
            db,
            entity_type="purchase_order",
            entity_id=po.id,
            action_type=AuditActionType.risk_trigger_compliance_floor,
            actor_id=caller.id,
            rationale=(
                f"Blocked: supplier compliance floor failed "
                f"(esg_rating={supplier.esg_rating}, sanctions_flag={supplier.sanctions_flag})"
            ),
            metadata={
                "esg_rating": supplier.esg_rating,
                "sanctions_flag": supplier.sanctions_flag,
            },
        )
    if validity == ValidityStatus.stale:
        age_days = (
            (_as_naive_utc(now) - _as_naive_utc(supplier.assessed_at)).days
            if supplier.assessed_at
            else None
        )
        write_audit_entry(
            db,
            entity_type="purchase_order",
            entity_id=po.id,
            action_type=AuditActionType.risk_trigger_stale,
            actor_id=caller.id,
            rationale=(
                f"Blocked: assessment stale (last assessed {age_days} days ago, "
                f"staleness window {effective_settings.ASSESSMENT_STALENESS_DAYS} days); "
                f"last computed tier was "
                f"{supplier.computed_risk_tier.value if supplier.computed_risk_tier else None}"
            ),
            metadata={
                "age_days": str(age_days) if age_days is not None else None,
                "staleness_window_days": str(effective_settings.ASSESSMENT_STALENESS_DAYS),
                "last_computed_tier": (
                    supplier.computed_risk_tier.value if supplier.computed_risk_tier else None
                ),
            },
        )

    steps = generate_approval_steps(control_status)
    for i, role in enumerate(steps, start=1):
        db.add(ApprovalStep(purchase_order_id=po.id, step_number=i, required_role=role))
    po.current_step_number = 1 if steps else None

    write_audit_entry(
        db,
        entity_type="purchase_order",
        entity_id=po.id,
        action_type=AuditActionType.po_status_transition,
        actor_id=caller.id,
        rationale=(
            f"Submitted; control_status={control_status.value} "
            f"(tier={tier.value if tier else None}, validity={validity.value})"
        ),
        metadata={
            "control_status": control_status.value,
            "tier": tier.value if tier else None,
            "validity": validity.value,
        },
    )


@router.post("/{po_id}/transitions", response_model=PurchaseOrderResponse)
def transition_purchase_order(
    po_id: int,
    payload: TransitionRequest,
    db: Session = Depends(get_db),
    caller: User = Depends(
        require_roles(Role.requester, Role.department_approver, Role.procurement_lead)
    ),
) -> PurchaseOrder:
    po = _get_po_or_404(db, po_id)

    if payload.action == "submit":
        _do_submit(db, po, caller)
    elif payload.action == "cancel":
        _do_cancel(db, po, caller)
    elif payload.action in ("approve", "reject"):
        _do_approve_or_reject(db, po, caller, payload.action, payload.reason)
    else:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Invalid transition")

    db.commit()
    db.refresh(po)
    return po


@router.post("/{po_id}/escalate", response_model=PurchaseOrderResponse)
def escalate_purchase_order(
    po_id: int,
    payload: EscalateRequest,
    db: Session = Depends(get_db),
    caller: User = Depends(require_roles(Role.department_approver, Role.procurement_lead)),
) -> PurchaseOrder:
    """The middle option between approve and reject: does not decide the
    step — it stays pending and fully actionable afterward (by this or any
    other authorized approver) — only records that the decision-maker
    asked for a second look, and why, so procurement_lead has visibility
    without the approver having to violate their own judgment call."""
    po = _get_po_or_404(db, po_id)
    if po.status != POStatus.submitted or po.current_step_number is None:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Invalid transition")

    step = next(
        (s for s in po.approval_steps if s.step_number == po.current_step_number), None
    )
    if step is None or step.status != ApprovalStepStatus.pending:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Invalid transition")

    _require_step_authority(caller, po, step)

    write_audit_entry(
        db,
        entity_type="purchase_order",
        entity_id=po.id,
        action_type=AuditActionType.approval_escalated,
        actor_id=caller.id,
        rationale=(
            f"{caller.email} ({caller.role.value}) asked for a second look on "
            f"step {step.step_number} — {payload.note}"
        ),
        metadata={
            "step_number": str(step.step_number),
            "actor_email": caller.email,
            "actor_role_at_time": caller.role.value,
            "note": payload.note,
        },
    )

    db.commit()
    db.refresh(po)
    return po


def _require_step_authority(caller: User, po: PurchaseOrder, step: ApprovalStep) -> None:
    """Per-resource dynamic authorization (research.md Decision 11 —
    documented, disclosed exception to constitution Principle III): the role
    required to decide the current step is a runtime value read from the
    ApprovalStep row itself, not a fixed set known at route-declaration
    time, so it cannot be expressed as a static require_roles(...) list.
    This function is the single, named, centralized place that decision is
    made — satisfying Principle III's rationale (an auditable, non-scattered
    permission check) even though it cannot satisfy the dependency-list
    mechanism literally."""
    if caller.role != step.required_role:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Not permitted")
    if step.required_role == Role.department_approver:
        if caller.team is None or po.requester.team is None or caller.team != po.requester.team:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Not permitted")


def _do_approve_or_reject(
    db: Session, po: PurchaseOrder, caller: User, action: str, reason: str | None = None
) -> None:
    if po.status != POStatus.submitted or po.current_step_number is None:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Invalid transition")

    step = next(
        (s for s in po.approval_steps if s.step_number == po.current_step_number), None
    )
    if step is None or step.status != ApprovalStepStatus.pending:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Invalid transition")

    _require_step_authority(caller, po, step)

    now = datetime.now(timezone.utc)
    step.decided_by_id = caller.id
    step.decided_at = now

    if action == "reject":
        step.status = ApprovalStepStatus.rejected
        po.status = POStatus.rejected
        po.decided_at = now
        po.current_step_number = None
    else:
        step.status = ApprovalStepStatus.approved
        next_step = next(
            (s for s in po.approval_steps if s.step_number == po.current_step_number + 1),
            None,
        )
        if next_step is None:
            po.status = POStatus.approved
            po.decided_at = now
            po.current_step_number = None
        else:
            po.current_step_number = next_step.step_number

    rationale = f"Step {step.step_number} {action} by {caller.email} ({caller.role.value})"
    if action == "reject" and reason:
        rationale += f" — reason: {reason}"

    metadata = {
        "step_number": str(step.step_number),
        "decision": action,
        "actor_email": caller.email,
        "actor_role_at_time": caller.role.value,
    }
    if action == "reject" and reason:
        metadata["reason"] = reason

    write_audit_entry(
        db,
        entity_type="purchase_order",
        entity_id=po.id,
        action_type=AuditActionType.po_status_transition,
        actor_id=caller.id,
        rationale=rationale,
        metadata=metadata,
    )


def _do_cancel(db: Session, po: PurchaseOrder, caller: User) -> None:
    if po.requester_id != caller.id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Not permitted")
    if po.status not in (POStatus.draft, POStatus.submitted):
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Invalid transition")

    po.status = POStatus.cancelled
    write_audit_entry(
        db,
        entity_type="purchase_order",
        entity_id=po.id,
        action_type=AuditActionType.po_status_transition,
        actor_id=caller.id,
        rationale=f"Cancelled by {caller.email}",
    )
