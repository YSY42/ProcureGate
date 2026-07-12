from sqlalchemy import event
from sqlalchemy.orm import Session

from app.models import AuditActionType, AuditLogEntry


def write_audit_entry(
    db: Session,
    *,
    entity_type: str,
    entity_id: int,
    action_type: AuditActionType,
    actor_id: int | None,
    rationale: str,
    metadata: dict | None = None,
) -> AuditLogEntry:
    entry = AuditLogEntry(
        entity_type=entity_type,
        entity_id=entity_id,
        action_type=action_type,
        actor_id=actor_id,
        rationale=rationale,
        metadata_json=metadata,
    )
    db.add(entry)
    db.flush()
    return entry


@event.listens_for(AuditLogEntry, "before_update")
def _block_audit_log_update(mapper, connection, target):
    raise RuntimeError(
        "audit_log is insert-only: UPDATE is prohibited (constitution Principle II)"
    )


@event.listens_for(AuditLogEntry, "before_delete")
def _block_audit_log_delete(mapper, connection, target):
    raise RuntimeError(
        "audit_log is insert-only: DELETE is prohibited (constitution Principle II)"
    )
