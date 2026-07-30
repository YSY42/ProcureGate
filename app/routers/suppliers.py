from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from app.audit import write_audit_entry
from app.auth import require_roles
from app.database import get_db
from app.models import AuditActionType, Role, Supplier, User
from app.risk_engine import (
    compute_compliance_risk,
    compute_inherent_risk,
    compute_performance_risk,
    compute_risk_tier,
)
from app.risk_settings import get_effective_settings
from app.schemas import SupplierCreateRequest, SupplierResponse, SupplierUpdateRequest

router = APIRouter(prefix="/api/v1/suppliers", tags=["suppliers"])

_READ_ROLES = (Role.requester, Role.department_approver, Role.procurement_lead, Role.auditor)
_WRITE_ROLES = (Role.procurement_lead,)


def _recompute_risk_tier(supplier: Supplier, db: Session) -> None:
    """Refreshes computed_risk_tier + assessed_at whenever all five risk
    inputs are present (research.md Decision 4). Reads procurement_lead's
    runtime threshold overrides (app/risk_settings.py) rather than the
    static config.py defaults, so a recalibrated compliance floor takes
    effect the next time a supplier record is touched."""
    fields = (
        supplier.country,
        supplier.category,
        supplier.delivery_reliability_score,
        supplier.defect_rate,
        supplier.esg_rating,
    )
    if any(f is None for f in fields):
        supplier.computed_risk_tier = None
        supplier.assessed_at = None
        return

    effective_settings = get_effective_settings(db)
    inherent = compute_inherent_risk(supplier.country, supplier.category, effective_settings)
    performance = compute_performance_risk(
        supplier.delivery_reliability_score, supplier.defect_rate, effective_settings
    )
    compliance = compute_compliance_risk(
        supplier.esg_rating, supplier.sanctions_flag, effective_settings
    )
    supplier.computed_risk_tier = compute_risk_tier(inherent, performance, compliance)
    supplier.assessed_at = datetime.now(timezone.utc)


@router.post("", response_model=SupplierResponse, status_code=status.HTTP_201_CREATED)
def create_supplier(
    payload: SupplierCreateRequest,
    db: Session = Depends(get_db),
    caller: User = Depends(require_roles(*_WRITE_ROLES)),
) -> Supplier:
    supplier = Supplier(**payload.model_dump())
    _recompute_risk_tier(supplier, db)
    db.add(supplier)
    db.commit()
    db.refresh(supplier)
    return supplier


@router.get("", response_model=list[SupplierResponse])
def list_suppliers(
    db: Session = Depends(get_db), caller: User = Depends(require_roles(*_READ_ROLES))
) -> list[Supplier]:
    return db.query(Supplier).all()


@router.get("/{supplier_id}", response_model=SupplierResponse)
def get_supplier(
    supplier_id: int,
    db: Session = Depends(get_db),
    caller: User = Depends(require_roles(*_READ_ROLES)),
) -> Supplier:
    supplier = db.get(Supplier, supplier_id)
    if supplier is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Supplier not found")
    return supplier


@router.patch("/{supplier_id}", response_model=SupplierResponse)
def update_supplier(
    supplier_id: int,
    payload: SupplierUpdateRequest,
    db: Session = Depends(get_db),
    caller: User = Depends(require_roles(*_WRITE_ROLES)),
) -> Supplier:
    supplier = db.get(Supplier, supplier_id)
    if supplier is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Supplier not found")

    updates = payload.model_dump(exclude_unset=True)
    status_change = updates.pop("status", None)
    reassessment_change = "needs_reassessment" in updates

    for field, value in updates.items():
        setattr(supplier, field, value)
    _recompute_risk_tier(supplier, db)

    if status_change is not None and status_change != supplier.status:
        prior_status = supplier.status
        supplier.status = status_change
        write_audit_entry(
            db,
            entity_type="supplier",
            entity_id=supplier.id,
            action_type=AuditActionType.supplier_status_change,
            actor_id=caller.id,
            rationale=(
                f"{caller.email} changed supplier {supplier.name} status from "
                f"{prior_status.value} to {status_change.value}"
            ),
            metadata={"prior_status": prior_status.value, "new_status": status_change.value},
        )

    # A drift signal (e.g. repeated exceptions) gives procurement_lead a
    # reason to distrust this supplier's current data — this is the audit
    # trail for actually acting on that belief, not just noticing it.
    if reassessment_change:
        write_audit_entry(
            db,
            entity_type="supplier",
            entity_id=supplier.id,
            action_type=AuditActionType.supplier_flagged_for_reassessment,
            actor_id=caller.id,
            rationale=(
                f"{caller.email} {'flagged' if supplier.needs_reassessment else 'cleared the flag on'} "
                f"supplier {supplier.name} for reassessment"
                + (f": {supplier.reassessment_note}" if supplier.needs_reassessment and supplier.reassessment_note else "")
            ),
            metadata={
                "needs_reassessment": str(supplier.needs_reassessment),
                "actor_email": caller.email,
                "actor_role_at_time": caller.role.value,
            },
        )

    db.commit()
    db.refresh(supplier)
    return supplier
