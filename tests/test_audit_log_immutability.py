import pytest

from app.audit import write_audit_entry
from app.models import AuditActionType


def test_update_audit_log_entry_raises(db):
    entry = write_audit_entry(
        db,
        entity_type="purchase_order",
        entity_id=1,
        action_type=AuditActionType.po_status_transition,
        actor_id=None,
        rationale="initial entry",
    )
    db.commit()

    entry.rationale = "tampered"
    with pytest.raises(Exception):
        db.commit()
    db.rollback()


def test_delete_audit_log_entry_raises(db):
    entry = write_audit_entry(
        db,
        entity_type="purchase_order",
        entity_id=1,
        action_type=AuditActionType.po_status_transition,
        actor_id=None,
        rationale="initial entry",
    )
    db.commit()

    db.delete(entry)
    with pytest.raises(Exception):
        db.commit()
    db.rollback()
