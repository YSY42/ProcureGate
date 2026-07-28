from datetime import datetime, timedelta, timezone

from sqlalchemy import func
from sqlalchemy.orm import Session

from app.config import FX_RATES_TO_EUR
from app.models import (
    AuditActionType,
    AuditLogEntry,
    ExceptionRequest,
    ExceptionStatus,
    POStatus,
    PurchaseOrder,
    RiskTier,
    Supplier,
    User,
)
from app.risk_engine import _as_naive_utc


def count_recent_approved_exceptions(db: Session, supplier_id: int, days: int = 90) -> int:
    """Pure counting query — no side effects, no writes. Callable from
    creation-time display, decision-time display, or dashboard aggregation
    without duplicating query logic (mirrors the reuse pattern already
    established by risk_engine.py's pure functions).

    Counts approved exceptions for the given supplier within a rolling
    window — this is a passive signal surfaced to the decision-maker, not
    an enforced limit. A self-declared "does this set precedent" flag is
    structurally unreliable (the person most motivated to under-report is
    the one deciding), so the system observes frequency instead of relying
    on self-declaration.
    """
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    return (
        db.query(ExceptionRequest)
        .join(PurchaseOrder, ExceptionRequest.purchase_order_id == PurchaseOrder.id)
        .filter(
            PurchaseOrder.supplier_id == supplier_id,
            ExceptionRequest.status == ExceptionStatus.approved,
            ExceptionRequest.decided_at >= cutoff,
        )
        .count()
    )


def top_suppliers_by_recent_exceptions(
    db: Session, days: int = 90, limit: int = 5
) -> list[tuple[int, str, int]]:
    """Signal #1 (highest confidence): a supplier repeatedly appearing in
    the exception log, regardless of how reasonable each individual
    approval looked, is itself the pattern worth surfacing — this is the
    normalization-of-deviance signal, made visible instead of relying on
    anyone noticing it manually across dozens of individually-reasonable
    decisions."""
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    rows = (
        db.query(PurchaseOrder.supplier_id, Supplier.name, func.count(ExceptionRequest.id))
        .join(ExceptionRequest, ExceptionRequest.purchase_order_id == PurchaseOrder.id)
        .join(Supplier, Supplier.id == PurchaseOrder.supplier_id)
        .filter(
            ExceptionRequest.status == ExceptionStatus.approved,
            ExceptionRequest.decided_at >= cutoff,
        )
        .group_by(PurchaseOrder.supplier_id, Supplier.name)
        .order_by(func.count(ExceptionRequest.id).desc())
        .limit(limit)
        .all()
    )
    return [(supplier_id, name, count) for supplier_id, name, count in rows]


class TriggerReasonDetail:
    """Lightweight internal carrier, converted to schema at the router layer."""

    def __init__(
        self,
        po_id: int,
        action_type: str,
        rationale: str,
        at: datetime,
        metadata: dict | None = None,
    ):
        self.po_id = po_id
        self.action_type = action_type
        self.rationale = rationale
        self.at = at
        self.metadata = metadata


def exception_trigger_reason_details(db: Session, days: int = 90) -> list[TriggerReasonDetail]:
    """Same underlying query as exception_trigger_reason_breakdown, but
    returns the individual entries rather than just counts — so the
    dashboard can show "which POs" behind each reason, not just a number."""
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    po_ids = [
        row.purchase_order_id
        for row in db.query(ExceptionRequest.purchase_order_id)
        .filter(
            ExceptionRequest.status == ExceptionStatus.approved,
            ExceptionRequest.decided_at >= cutoff,
        )
        .all()
    ]
    if not po_ids:
        return []

    trigger_types = [
        AuditActionType.risk_trigger_compliance_floor,
        AuditActionType.risk_trigger_stale,
        AuditActionType.risk_trigger_incomplete_or_unassessed,
    ]
    rows = (
        db.query(AuditLogEntry)
        .filter(
            AuditLogEntry.entity_type == "purchase_order",
            AuditLogEntry.entity_id.in_(po_ids),
            AuditLogEntry.action_type.in_(trigger_types),
        )
        .order_by(AuditLogEntry.created_at.desc())
        .all()
    )
    return [
        TriggerReasonDetail(
            row.entity_id, row.action_type.value, row.rationale, row.created_at, row.metadata_json
        )
        for row in rows
    ]


def supplier_exception_detail_list(db: Session, supplier_id: int, days: int = 90) -> list[dict]:
    """Individual approved exception requests for one supplier — backs the
    drill-down when a procurement_lead clicks a supplier in the drift
    signal list."""
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    rows = (
        db.query(ExceptionRequest)
        .join(PurchaseOrder, ExceptionRequest.purchase_order_id == PurchaseOrder.id)
        .filter(
            PurchaseOrder.supplier_id == supplier_id,
            ExceptionRequest.status == ExceptionStatus.approved,
            ExceptionRequest.decided_at >= cutoff,
        )
        .order_by(ExceptionRequest.decided_at.desc())
        .all()
    )
    return [
        {
            "po_id": r.purchase_order_id,
            "justification": r.justification,
            "decided_at": r.decided_at,
        }
        for r in rows
    ]


def requester_exception_detail_list(db: Session, requester_id: int, days: int = 90) -> list[dict]:
    """Same shape, scoped to one requester instead of one supplier."""
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    rows = (
        db.query(ExceptionRequest)
        .filter(
            ExceptionRequest.requested_by_id == requester_id,
            ExceptionRequest.status == ExceptionStatus.approved,
            ExceptionRequest.decided_at >= cutoff,
        )
        .order_by(ExceptionRequest.decided_at.desc())
        .all()
    )
    return [
        {
            "po_id": r.purchase_order_id,
            "justification": r.justification,
            "decided_at": r.decided_at,
        }
        for r in rows
    ]


def exception_trigger_reason_breakdown(db: Session, days: int = 90) -> dict[str, int]:
    """Signal #2: for exceptions approved within the window, look up which
    risk-trigger reason originally blocked the underlying PO, and count by
    reason. Concentration here signals the risk model's threshold may be
    miscalibrated (many suppliers hitting the same wall), not that any one
    supplier is uniquely risky — the fix in that case is recalibrating the
    model, not continuing to approve exceptions against it."""
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    po_ids = [
        row.purchase_order_id
        for row in db.query(ExceptionRequest.purchase_order_id)
        .filter(
            ExceptionRequest.status == ExceptionStatus.approved,
            ExceptionRequest.decided_at >= cutoff,
        )
        .all()
    ]
    if not po_ids:
        return {}

    trigger_types = [
        AuditActionType.risk_trigger_compliance_floor,
        AuditActionType.risk_trigger_stale,
        AuditActionType.risk_trigger_incomplete_or_unassessed,
    ]
    rows = (
        db.query(AuditLogEntry.action_type, func.count(AuditLogEntry.id))
        .filter(
            AuditLogEntry.entity_type == "purchase_order",
            AuditLogEntry.entity_id.in_(po_ids),
            AuditLogEntry.action_type.in_(trigger_types),
        )
        .group_by(AuditLogEntry.action_type)
        .all()
    )
    return {action_type.value: count for action_type, count in rows}


def po_trigger_reason_details(
    db: Session, purchase_order_ids: list[int]
) -> list[TriggerReasonDetail]:
    """Same shape as po_trigger_reason_breakdown, but returns the individual
    entries rather than just counts — backs the drill-down when a
    requester/approver clicks a specific trigger reason on their
    personal/team risk picture (same pattern as exception_trigger_reason_details)."""
    if not purchase_order_ids:
        return []
    trigger_types = [
        AuditActionType.risk_trigger_compliance_floor,
        AuditActionType.risk_trigger_stale,
        AuditActionType.risk_trigger_incomplete_or_unassessed,
    ]
    rows = (
        db.query(AuditLogEntry)
        .filter(
            AuditLogEntry.entity_type == "purchase_order",
            AuditLogEntry.entity_id.in_(purchase_order_ids),
            AuditLogEntry.action_type.in_(trigger_types),
        )
        .order_by(AuditLogEntry.created_at.desc())
        .all()
    )
    return [
        TriggerReasonDetail(
            row.entity_id, row.action_type.value, row.rationale, row.created_at, row.metadata_json
        )
        for row in rows
    ]


def top_requesters_by_recent_exceptions(
    db: Session, days: int = 90, limit: int = 5
) -> list[tuple[int, str, int]]:
    """Signal #3: a requester repeatedly relying on the exception path may
    indicate a habitual workaround, not a series of unrelated urgent
    situations — worth surfacing, not worth blocking on its own."""
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    rows = (
        db.query(ExceptionRequest.requested_by_id, User.email, func.count(ExceptionRequest.id))
        .join(User, User.id == ExceptionRequest.requested_by_id)
        .filter(
            ExceptionRequest.status == ExceptionStatus.approved,
            ExceptionRequest.decided_at >= cutoff,
        )
        .group_by(ExceptionRequest.requested_by_id, User.email)
        .order_by(func.count(ExceptionRequest.id).desc())
        .limit(limit)
        .all()
    )
    return [(uid, email, count) for uid, email, count in rows]


def approval_time_details_by_tier(db: Session, tier: RiskTier) -> list[dict]:
    """Backs the 'Approval Time by Risk Tier' chart drill-down — same
    approved/decided PO population used for the aggregate mean in
    dashboard.py, but returns per-PO records so a procurement_lead can see
    exactly which orders drove an unexpected average (e.g. why 'high' tier
    might look faster than 'medium')."""
    rows = (
        db.query(PurchaseOrder, Supplier.name)
        .join(Supplier, Supplier.id == PurchaseOrder.supplier_id)
        .filter(
            PurchaseOrder.status == POStatus.approved,
            PurchaseOrder.decided_at.isnot(None),
            PurchaseOrder.submitted_at.isnot(None),
            Supplier.computed_risk_tier == tier,
        )
        .all()
    )
    results = []
    for po, supplier_name in rows:
        days = (
            _as_naive_utc(po.decided_at) - _as_naive_utc(po.submitted_at)
        ).total_seconds() / 86400
        results.append(
            {
                "po_id": po.id,
                "description": po.description,
                "amount": po.amount,
                "currency": po.currency,
                "supplier_name": supplier_name,
                "days_to_decision": days,
                "decided_at": po.decided_at,
            }
        )
    return sorted(results, key=lambda r: r["days_to_decision"])


def risk_tier_amount_exposure(db: Session) -> dict[str, float]:
    """Approved-only spend by supplier risk tier, normalized to EUR using a
    static demo rate table (not live FX). Answers "how much money is
    actually sitting at each risk tier", not just "how many suppliers"."""
    rows = (
        db.query(PurchaseOrder.amount, PurchaseOrder.currency, Supplier.computed_risk_tier)
        .join(Supplier, Supplier.id == PurchaseOrder.supplier_id)
        .filter(
            PurchaseOrder.status == POStatus.approved,
            Supplier.computed_risk_tier.isnot(None),
        )
        .all()
    )
    totals: dict[str, float] = {tier.value: 0.0 for tier in RiskTier}
    for amount, currency, tier in rows:
        rate = FX_RATES_TO_EUR.get(currency, 1.0)
        totals[tier.value] += float(amount) * rate
    return totals


def po_control_status_breakdown(db: Session, purchase_order_ids: list[int]) -> dict[str, int]:
    """Personal/team-scoped version of the same idea behind risk_tier_distribution
    on the procurement_lead dashboard — but scoped to a specific set of POs
    (one requester's own orders, or one team's orders) rather than the whole
    system. Reuses the same grouping shape so a requester or approver reads
    the same visual language as the org-wide dashboard, just narrower."""
    if not purchase_order_ids:
        return {}
    rows = (
        db.query(PurchaseOrder.approval_control_status, func.count(PurchaseOrder.id))
        .filter(
            PurchaseOrder.id.in_(purchase_order_ids),
            PurchaseOrder.approval_control_status.isnot(None),
        )
        .group_by(PurchaseOrder.approval_control_status)
        .all()
    )
    return {status.value: count for status, count in rows}


def po_trigger_reason_breakdown(db: Session, purchase_order_ids: list[int]) -> dict[str, int]:
    """Same shape as exception_trigger_reason_breakdown, but scoped to a
    specific requester's or team's own POs directly (not just the ones that
    went through an approved exception) — answers "what do I personally keep
    hitting", not just "what gets exempted"."""
    if not purchase_order_ids:
        return {}
    trigger_types = [
        AuditActionType.risk_trigger_compliance_floor,
        AuditActionType.risk_trigger_stale,
        AuditActionType.risk_trigger_incomplete_or_unassessed,
    ]
    rows = (
        db.query(AuditLogEntry.action_type, func.count(AuditLogEntry.id))
        .filter(
            AuditLogEntry.entity_type == "purchase_order",
            AuditLogEntry.entity_id.in_(purchase_order_ids),
            AuditLogEntry.action_type.in_(trigger_types),
        )
        .group_by(AuditLogEntry.action_type)
        .all()
    )
    return {action_type.value: count for action_type, count in rows}
