from datetime import datetime, timedelta, timezone

from sqlalchemy import func
from sqlalchemy.orm import Session

from app.models import (
    AuditActionType,
    AuditLogEntry,
    ExceptionRequest,
    ExceptionStatus,
    PurchaseOrder,
    Supplier,
    User,
)


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
