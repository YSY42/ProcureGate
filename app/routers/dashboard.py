from datetime import datetime, timezone
from statistics import mean

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session, joinedload

from app.auth import require_roles
from app.database import get_db
from app.exception_metrics import (
    approval_time_details_by_tier,
    exception_trigger_reason_breakdown,
    exception_trigger_reason_details,
    po_control_status_breakdown,
    po_trigger_reason_breakdown,
    po_trigger_reason_details,
    requester_exception_detail_list,
    risk_tier_amount_exposure,
    supplier_exception_detail_list,
    top_requesters_by_recent_exceptions,
    top_suppliers_by_recent_exceptions,
)
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
    ApprovalTimeDetailResponse,
    ApproverDashboard,
    AuditLogEntryResponse,
    BlockedAttemptDetail,
    EscalatedApprovalDetail,
    ExceptionCounts,
    ExceptionDetailResponse,
    ExceptionDriftSignals,
    ProcurementLeadDashboard,
    RequesterDashboard,
    RequesterExceptionSignal,
    RoleElevationLogEntry,
    SupplierExceptionSignal,
    TeamPendingAging,
    TriggerReasonDetailResponse,
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


def _avg_approval_time_by_tier(db: Session) -> dict[str, float | None]:
    """Mean days from submitted_at to decided_at for approved POs, grouped by
    the deciding supplier's computed_risk_tier. Shared by the procurement-lead
    dashboard (system-wide control metric) and the requester dashboard (a
    "how long should I expect to wait" benchmark) — same computation, two
    audiences, not two implementations."""
    result: dict[str, float | None] = {tier.value: None for tier in RiskTier}
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
            result[tier_value] = mean(values)
    return result


def _pending_approval_aging_by_team(pending: list[PurchaseOrder], now: datetime) -> list[TeamPendingAging]:
    """Grouped by team, not by named approver: approval steps are
    authorized by role + team match (any department_approver on the
    requester's team may act — see _require_step_authority), so a team is
    the unit that can actually go unstaffed/backlogged here, not an
    individual. Scoped to POs whose *current* step needs department_approver
    specifically, not the whole submitted queue (which also includes
    procurement_lead-owned steps)."""
    approver_pending = [
        po
        for po in pending
        if any(
            s.step_number == po.current_step_number and s.required_role == Role.department_approver
            for s in po.approval_steps
        )
    ]
    by_team: dict[str, list[PurchaseOrder]] = {}
    for po in approver_pending:
        team = po.requester.team or "Unassigned"
        by_team.setdefault(team, []).append(po)

    result = []
    for team, pos in by_team.items():
        stats = _aging_stats(pos, now)
        result.append(
            TeamPendingAging(
                team=team,
                pending_count=len(pos),
                avg_days_pending=stats.avg_days_pending,
                oldest_pending_days=stats.oldest_pending_days,
            )
        )
    return sorted(result, key=lambda t: t.oldest_pending_days or 0, reverse=True)


def _escalated_approvals(db: Session) -> list[EscalatedApprovalDetail]:
    entries = (
        db.query(AuditLogEntry)
        .filter(
            AuditLogEntry.entity_type == "purchase_order",
            AuditLogEntry.action_type == AuditActionType.approval_escalated,
        )
        .order_by(AuditLogEntry.created_at.desc())
        .all()
    )
    details = []
    for entry in entries:
        po = db.get(PurchaseOrder, entry.entity_id)
        if po is None:
            continue
        metadata = entry.metadata_json or {}
        details.append(
            EscalatedApprovalDetail(
                po_id=po.id,
                description=po.description,
                requester_email=po.requester.email,
                step_number=int(metadata.get("step_number", 0)),
                note=metadata.get("note", ""),
                actor_email=metadata.get("actor_email", ""),
                actor_role_at_time=metadata.get("actor_role_at_time", ""),
                at=entry.created_at,
            )
        )
    return details


def _requester_dashboard(db: Session, caller: User) -> RequesterDashboard:
    pos = (
        db.query(PurchaseOrder)
        .options(joinedload(PurchaseOrder.approval_steps))
        .filter(PurchaseOrder.requester_id == caller.id)
        .all()
    )
    po_ids = [po.id for po in pos]
    return RequesterDashboard(
        my_purchase_orders=pos,
        my_control_status_breakdown=po_control_status_breakdown(db, po_ids),
        my_trigger_reason_breakdown=po_trigger_reason_breakdown(db, po_ids),
        my_trigger_reason_details=[
            TriggerReasonDetailResponse(
                po_id=d.po_id,
                action_type=d.action_type,
                rationale=d.rationale,
                at=d.at,
                metadata=d.metadata,
            )
            for d in po_trigger_reason_details(db, po_ids)
        ],
        avg_approval_time_by_tier=_avg_approval_time_by_tier(db),
    )


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
    team_pos = (
        db.query(PurchaseOrder)
        .join(User, PurchaseOrder.requester_id == User.id)
        .options(joinedload(PurchaseOrder.approval_steps))
        .filter(User.team == caller.team)
        .all()
    )
    team_po_ids = [po.id for po in team_pos]

    return ApproverDashboard(
        team=caller.team,
        pending_approvals=pending,
        pending_approval_aging=_aging_stats(pending, now),
        team_control_status_breakdown=po_control_status_breakdown(db, team_po_ids),
        team_trigger_reason_breakdown=po_trigger_reason_breakdown(db, team_po_ids),
        team_purchase_orders=team_pos,
        team_trigger_reason_details=[
            TriggerReasonDetailResponse(
                po_id=d.po_id,
                action_type=d.action_type,
                rationale=d.rationale,
                at=d.at,
                metadata=d.metadata,
            )
            for d in po_trigger_reason_details(db, team_po_ids)
        ],
    )


def _procurement_lead_dashboard(db: Session) -> ProcurementLeadDashboard:
    now = datetime.now(timezone.utc).replace(tzinfo=None)

    blocked_attempt_entries = (
        db.query(AuditLogEntry)
        .filter(AuditLogEntry.action_type == AuditActionType.po_creation_blocked)
        .order_by(AuditLogEntry.created_at.desc())
        .all()
    )
    blocked_creation_attempts = len(blocked_attempt_entries)

    blocked_creation_attempt_details = []
    for entry in blocked_attempt_entries:
        supplier = db.get(Supplier, entry.entity_id)
        actor = db.get(User, entry.actor_id) if entry.actor_id else None
        blocked_creation_attempt_details.append(
            BlockedAttemptDetail(
                supplier_id=entry.entity_id,
                supplier_name=supplier.name if supplier else "Unknown",
                actor_email=actor.email if actor else "Unknown",
                rationale=entry.rationale,
                at=entry.created_at,
            )
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

    avg_approval_time_by_tier = _avg_approval_time_by_tier(db)

    pending = (
        db.query(PurchaseOrder)
        .options(joinedload(PurchaseOrder.approval_steps))
        .filter(PurchaseOrder.status == POStatus.submitted)
        .all()
    )

    drift_window_days = 90
    top_suppliers = [
        SupplierExceptionSignal(supplier_id=sid, supplier_name=name, count=count, total_amount_eur=amount)
        for sid, name, count, amount in top_suppliers_by_recent_exceptions(db, days=drift_window_days)
    ]
    top_requesters = [
        RequesterExceptionSignal(requester_id=uid, requester_email=email, count=count)
        for uid, email, count in top_requesters_by_recent_exceptions(db, days=drift_window_days)
    ]
    trigger_breakdown = exception_trigger_reason_breakdown(db, days=drift_window_days)
    trigger_details_raw = exception_trigger_reason_details(db, days=drift_window_days)
    trigger_details = [
        TriggerReasonDetailResponse(
            po_id=d.po_id,
            action_type=d.action_type,
            rationale=d.rationale,
            at=d.at,
            metadata=d.metadata,
        )
        for d in trigger_details_raw
    ]

    return ProcurementLeadDashboard(
        blocked_creation_attempts=blocked_creation_attempts,
        blocked_creation_attempt_details=blocked_creation_attempt_details,
        exception_requests=exception_counts,
        pos_affected_by_stale_or_unassessed=len(affected_po_ids),
        risk_tier_distribution=risk_tier_distribution,
        risk_tier_amount_distribution=risk_tier_amount_exposure(db),
        avg_approval_time_by_tier=avg_approval_time_by_tier,
        pending_approval_aging=_aging_stats(pending, now),
        pending_approval_aging_by_team=_pending_approval_aging_by_team(pending, now),
        escalated_approvals=_escalated_approvals(db),
        exception_drift_signals=ExceptionDriftSignals(
            window_days=drift_window_days,
            top_suppliers=top_suppliers,
            top_requesters=top_requesters,
            trigger_reason_distribution=trigger_breakdown,
            trigger_reason_details=trigger_details,
        ),
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


@router.get(
    "/dashboard/supplier-exceptions/{supplier_id}",
    response_model=list[ExceptionDetailResponse],
)
def get_supplier_exception_details(
    supplier_id: int,
    db: Session = Depends(get_db),
    caller: User = Depends(require_roles(Role.procurement_lead, Role.auditor)),
) -> list[dict]:
    return supplier_exception_detail_list(db, supplier_id)


@router.get(
    "/dashboard/requester-exceptions/{requester_id}",
    response_model=list[ExceptionDetailResponse],
)
def get_requester_exception_details(
    requester_id: int,
    db: Session = Depends(get_db),
    caller: User = Depends(require_roles(Role.procurement_lead, Role.auditor)),
) -> list[dict]:
    return requester_exception_detail_list(db, requester_id)


@router.get(
    "/dashboard/approval-time-details/{tier}",
    response_model=list[ApprovalTimeDetailResponse],
)
def get_approval_time_details(
    tier: RiskTier,
    db: Session = Depends(get_db),
    caller: User = Depends(require_roles(Role.procurement_lead, Role.auditor)),
) -> list[dict]:
    return approval_time_details_by_tier(db, tier)


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
