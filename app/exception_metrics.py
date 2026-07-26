from datetime import datetime, timedelta, timezone

from sqlalchemy.orm import Session

from app.models import ExceptionRequest, ExceptionStatus, PurchaseOrder


def count_recent_approved_exceptions(db: Session, supplier_id: int, days: int = 90) -> int:
    """Pure counting query — no side effects, no writes. Callable from
    creation-time display, decision-time display, or a future dashboard
    aggregation without duplicating query logic (mirrors the reuse pattern
    already established by risk_engine.py's pure functions).

    Counts approved exceptions for the given supplier within a rolling
    window — this is a passive signal surfaced to the decision-maker, not
    an enforced limit. See research.md / INTERVIEW_NOTES.md for the
    reasoning: a self-declared "does this set precedent" flag is
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
