from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.audit import write_audit_entry
from app.auth import require_roles
from app.database import get_db
from app.models import AuditActionType, RiskThresholdOverride, Role, User
from app.schemas import RiskThresholdResponse, RiskThresholdUpdateRequest

router = APIRouter(prefix="/api/v1/risk-settings", tags=["risk-settings"])

_READ_ROLES = (Role.procurement_lead, Role.auditor)
_WRITE_ROLES = (Role.procurement_lead,)


def _get_or_create_override(db: Session) -> RiskThresholdOverride:
    override = db.query(RiskThresholdOverride).first()
    if override is None:
        override = RiskThresholdOverride()
        db.add(override)
        db.flush()
    return override


@router.get("", response_model=RiskThresholdResponse)
def get_risk_settings(
    db: Session = Depends(get_db),
    caller: User = Depends(require_roles(*_READ_ROLES)),
) -> RiskThresholdOverride:
    return _get_or_create_override(db)


@router.patch("", response_model=RiskThresholdResponse)
def update_risk_settings(
    payload: RiskThresholdUpdateRequest,
    db: Session = Depends(get_db),
    caller: User = Depends(require_roles(*_WRITE_ROLES)),
) -> RiskThresholdOverride:
    """Self-service calibration of the risk model (research.md's own stated
    fix for trigger-reason concentration: recalibrate the model rather than
    keep approving exceptions against it). Every change is audited — this
    alters what "blocked" means for every future submission system-wide,
    not a single decision."""
    override = _get_or_create_override(db)
    updates = payload.model_dump(exclude_unset=True)

    changes = {}
    for field, value in updates.items():
        old_value = getattr(override, field)
        if old_value != value:
            changes[field] = (old_value, value)
        setattr(override, field, value)
    override.updated_by_id = caller.id

    if changes:
        change_summary = ", ".join(f"{k} {old} -> {new}" for k, (old, new) in changes.items())
        write_audit_entry(
            db,
            entity_type="risk_settings",
            entity_id=override.id,
            action_type=AuditActionType.risk_threshold_overridden,
            actor_id=caller.id,
            rationale=f"{caller.email} recalibrated risk thresholds: {change_summary}",
            metadata={
                **{k: str(new) for k, (old, new) in changes.items()},
                "actor_email": caller.email,
                "actor_role_at_time": caller.role.value,
            },
        )

    db.commit()
    db.refresh(override)
    return override
