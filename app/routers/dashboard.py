from datetime import datetime, timezone
from statistics import mean

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session, joinedload

from app.auth import require_roles
from app.database import get_db
from app.models import (
    AuditActionType,
    AuditLogEntry,
    ExceptionRequest,
    ExceptionStatus,
    POStatus,
    PurchaseOrder,
    Role,
    RiskTier,
    Supplier,
    User,
)
from app.risk_engine import _as_naive_utc
from app.schemas import (
    AccessAdminDashboard,
    AgingStats,
    ApproverDashboard,
    AuditLogEntryResponse,
    ExceptionCounts,
    ProcurementLeadDashboard,
    RequesterDashboard,
    RoleElevationLogEntry,
)

router = APIRouter(prefix="/api/v1", tags=["dashboard"])


def _aging_stats(pos: list[PurchaseOrder], now: datetime) -> AgingStats:
    if not pos:
        return AgingStats(avg_days_pending=None, oldest_pending_days=None)
    ages = [
        (now - _as_naive_utc(po.submitted_at)).days
        for po in pos
        if po.submitted_at is not None
    ]
    if not ages:
        return AgingStats(avg_days_pending=None, oldest_pending_days=None)
    return AgingStats(avg_days_pending=mean(ages), oldest_pending_days=max(ages))


def _requester_dashboard(db: Session, caller: User) -> RequesterDashboard:
    pos = (
        db.query(PurchaseOrder)
        .options(joinedload(PurchaseOrder.approval_steps))
        .filter(PurchaseOrder.requester_id == caller.id)
        .all()
    )
    return RequesterDashboard(my_purchase_orders=pos)


def _approver_dashboard(db: Session, caller: User) -> ApproverDashboard:
    now = datetime.now(timezone.utc).replace(tzinfo=None)
    pending = (
        db.query(PurchaseOrder)
        .join(User, PurchaseOrder.requester_id == User.id)
        .options(joinedload(PurchaseOrder.approval_steps))
        .filter(
            PurchaseOrder.status == POStatus.submitted,
            User.team == caller.team,
        )
        .all()
    )
    pending = [
        po
        for po in pending
        if any(
            s.step_number == po.current_step_number
            and s.required_role == Role.department_approver
            for s in po.approval_steps
        )
    ]
    return ApproverDashboard(
        team=caller.team,
        pending_approvals=pending,
        pending_approval_aging=_aging_stats(pending, now),
    )


def _procurement_lead_dashboard(db: Session) -> ProcurementLeadDashboard:
    now = datetime.now(timezone.utc).replace(tzinfo=None)

    blocked_creation_attempts = (
        db.query(AuditLogEntry)
        .filter(AuditLogEntry.action_type == AuditActionType.po_creation_blocked)
        .count()
    )

    exception_counts = ExceptionCounts(
        submitted=db.query(ExceptionRequest).count(),
        approved=db.query(ExceptionRequest)
        .filter(ExceptionRequest.status == ExceptionStatus.approved)
        .count(),
        rejected=db.query(ExceptionRequest)
        .filter(ExceptionRequest.status == ExceptionStatus.rejected)
        .count(),
        lapsed=db.query(ExceptionRequest)
        .filter(ExceptionRequest.status == ExceptionStatus.lapsed)
        .count(),
    )

    affected_po_ids = {
        row.entity_id
        for row in db.query(AuditLogEntry.entity_id)
        .filter(
            AuditLogEntry.entity_type == "purchase_order",
            AuditLogEntry.action_type.in_(
                [
                    AuditActionType.risk_trigger_stale,
                    AuditActionType.risk_trigger_incomplete_or_unassessed,
                ]
            ),
        )
        .all()
    }

    risk_tier_distribution = {tier.value: 0 for tier in RiskTier}
    for row in (
        db.query(Supplier.computed_risk_tier)
        .filter(Supplier.computed_risk_tier.isnot(None))
        .all()
    ):
        risk_tier_distribution[row.computed_risk_tier.value] += 1

    avg_approval_time_by_tier: dict[str, float | None] = {tier.value: None for tier in RiskTier}
    decided = (
        db.query(PurchaseOrder)
        .filter(
            PurchaseOrder.status == POStatus.approved,
            PurchaseOrder.decided_at.isnot(None),
            PurchaseOrder.submitted_at.isnot(None),
        )
        .all()
    )
    by_tier: dict[str, list[float]] = {tier.value: [] for tier in RiskTier}
    for po in decided:
        supplier = db.get(Supplier, po.supplier_id)
        if supplier and supplier.computed_risk_tier:
            days = (
                _as_naive_utc(po.decided_at) - _as_naive_utc(po.submitted_at)
            ).total_seconds() / 86400
            by_tier[supplier.computed_risk_tier.value].append(days)
    for tier_value, values in by_tier.items():
        if values:
            avg_approval_time_by_tier[tier_value] = mean(values)

    pending = (
        db.query(PurchaseOrder)
        .filter(PurchaseOrder.status == POStatus.submitted)
        .all()
    )

    return ProcurementLeadDashboard(
        blocked_creation_attempts=blocked_creation_attempts,
        exception_requests=exception_counts,
        pos_affected_by_stale_or_unassessed=len(affected_po_ids),
        risk_tier_distribution=risk_tier_distribution,
        avg_approval_time_by_tier=avg_approval_time_by_tier,
        pending_approval_aging=_aging_stats(pending, now),
    )


def _access_admin_dashboard(db: Session) -> AccessAdminDashboard:
    entries = (
        db.query(AuditLogEntry)
        .filter(AuditLogEntry.action_type == AuditActionType.role_elevation)
        .order_by(AuditLogEntry.created_at)
        .all()
    )
    elevations = [
        RoleElevationLogEntry(
            grantor_id=(e.metadata_json or {}).get("grantor_id"),
            grantee_id=(e.metadata_json or {}).get("grantee_id"),
            prior_role=(e.metadata_json or {}).get("prior_role"),
            new_role=(e.metadata_json or {}).get("new_role"),
            at=e.created_at,
        )
        for e in entries
    ]
    return AccessAdminDashboard(role_elevations=elevations)


@router.get("/dashboard")
def get_dashboard(
    db: Session = Depends(get_db),
    caller: User = Depends(
        require_roles(
            Role.requester,
            Role.department_approver,
            Role.procurement_lead,
            Role.access_admin,
            Role.auditor,
        )
    ),
):
    if caller.role == Role.requester:
        return _requester_dashboard(db, caller)
    if caller.role == Role.department_approver:
        return _approver_dashboard(db, caller)
    if caller.role == Role.access_admin:
        return _access_admin_dashboard(db)
    # procurement_lead and auditor see the same aggregate business view
    # (spec.md US5 AC8) — auditor's read access is otherwise identical.
    return _procurement_lead_dashboard(db)


@router.get("/audit-log", response_model=list[AuditLogEntryResponse])
def get_audit_log(
    entity_type: str | None = None,
    entity_id: int | None = None,
    action_type: str | None = None,
    db: Session = Depends(get_db),
    caller: User = Depends(require_roles(Role.auditor)),
) -> list[AuditLogEntry]:
    query = db.query(AuditLogEntry)
    if entity_type is not None:
        query = query.filter(AuditLogEntry.entity_type == entity_type)
    if entity_id is not None:
        query = query.filter(AuditLogEntry.entity_id == entity_id)
    if action_type is not None:
        query = query.filter(AuditLogEntry.action_type == action_type)
    return query.order_by(AuditLogEntry.created_at).all()
