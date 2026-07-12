from datetime import datetime, timedelta, timezone

from app.config import settings
from app.models import AuditActionType, AuditLogEntry, Supplier, SupplierStatus
from tests.conftest import auth_headers


def _create_supplier(db, **kwargs) -> Supplier:
    defaults = dict(name="Acme Corp", status=SupplierStatus.active)
    defaults.update(kwargs)
    supplier = Supplier(**defaults)
    db.add(supplier)
    db.commit()
    db.refresh(supplier)
    return supplier


def _fully_assessed_kwargs(**overrides):
    defaults = dict(
        country="US",
        category="widgets",
        delivery_reliability_score=95,
        defect_rate=0.5,
        esg_rating=90,
        sanctions_flag=False,
        assessed_at=datetime.now(timezone.utc),
        computed_risk_tier="low",
    )
    defaults.update(overrides)
    return defaults


def test_create_po_against_blocked_supplier_rejected_before_risk_computed(
    client, requester_token, db
):
    supplier = _create_supplier(db, status=SupplierStatus.blocked)
    resp = client.post(
        "/api/v1/purchase-orders",
        json={
            "supplier_id": supplier.id,
            "amount": "100.00",
            "currency": "USD",
            "description": "test",
        },
        headers=auth_headers(requester_token),
    )
    assert resp.status_code == 409
    # No PO was created, and no risk trigger audit entries exist for it.
    assert (
        db.query(AuditLogEntry)
        .filter(AuditLogEntry.entity_type == "purchase_order")
        .count()
        == 0
    )


def test_submit_po_suspended_supplier_rejected(client, requester_token, db):
    supplier = _create_supplier(db, **_fully_assessed_kwargs())
    create_resp = client.post(
        "/api/v1/purchase-orders",
        json={
            "supplier_id": supplier.id,
            "amount": "100.00",
            "currency": "USD",
            "description": "test",
        },
        headers=auth_headers(requester_token),
    )
    assert create_resp.status_code == 201
    po_id = create_resp.json()["id"]

    supplier.status = SupplierStatus.suspended
    db.commit()

    submit_resp = client.post(
        f"/api/v1/purchase-orders/{po_id}/transitions",
        json={"action": "submit"},
        headers=auth_headers(requester_token),
    )
    assert submit_resp.status_code == 409


def test_submit_po_unassessed_supplier_blocks(client, requester_token, db):
    supplier = _create_supplier(db)  # no risk inputs at all
    create_resp = client.post(
        "/api/v1/purchase-orders",
        json={
            "supplier_id": supplier.id,
            "amount": "100.00",
            "currency": "USD",
            "description": "test",
        },
        headers=auth_headers(requester_token),
    )
    po_id = create_resp.json()["id"]

    submit_resp = client.post(
        f"/api/v1/purchase-orders/{po_id}/transitions",
        json={"action": "submit"},
        headers=auth_headers(requester_token),
    )
    assert submit_resp.status_code == 200
    assert submit_resp.json()["approval_control_status"] == "blocked"
    assert submit_resp.json()["approval_steps"] == []

    entry = (
        db.query(AuditLogEntry)
        .filter(
            AuditLogEntry.entity_type == "purchase_order",
            AuditLogEntry.entity_id == po_id,
            AuditLogEntry.action_type == AuditActionType.risk_trigger_incomplete_or_unassessed,
        )
        .one()
    )
    assert "unassessed" in entry.rationale


def test_submit_po_stale_assessment_blocks_with_distinct_audit_entry(
    client, requester_token, db
):
    stale_date = datetime.now(timezone.utc) - timedelta(
        days=settings.ASSESSMENT_STALENESS_DAYS + 1
    )
    supplier = _create_supplier(db, **_fully_assessed_kwargs(assessed_at=stale_date))
    create_resp = client.post(
        "/api/v1/purchase-orders",
        json={
            "supplier_id": supplier.id,
            "amount": "100.00",
            "currency": "USD",
            "description": "test",
        },
        headers=auth_headers(requester_token),
    )
    po_id = create_resp.json()["id"]

    submit_resp = client.post(
        f"/api/v1/purchase-orders/{po_id}/transitions",
        json={"action": "submit"},
        headers=auth_headers(requester_token),
    )
    assert submit_resp.status_code == 200
    assert submit_resp.json()["approval_control_status"] == "blocked"

    entry = (
        db.query(AuditLogEntry)
        .filter(
            AuditLogEntry.entity_type == "purchase_order",
            AuditLogEntry.entity_id == po_id,
            AuditLogEntry.action_type == AuditActionType.risk_trigger_stale,
        )
        .one()
    )
    assert "stale" in entry.rationale.lower()
    assert "tier" in entry.rationale.lower()


def test_submit_po_multiple_triggers_produce_separate_audit_entries(
    client, requester_token, db
):
    stale_date = datetime.now(timezone.utc) - timedelta(
        days=settings.ASSESSMENT_STALENESS_DAYS + 1
    )
    supplier = _create_supplier(
        db, **_fully_assessed_kwargs(assessed_at=stale_date, esg_rating=10)
    )
    create_resp = client.post(
        "/api/v1/purchase-orders",
        json={
            "supplier_id": supplier.id,
            "amount": "100.00",
            "currency": "USD",
            "description": "test",
        },
        headers=auth_headers(requester_token),
    )
    po_id = create_resp.json()["id"]

    submit_resp = client.post(
        f"/api/v1/purchase-orders/{po_id}/transitions",
        json={"action": "submit"},
        headers=auth_headers(requester_token),
    )
    assert submit_resp.status_code == 200

    entries = (
        db.query(AuditLogEntry)
        .filter(
            AuditLogEntry.entity_type == "purchase_order",
            AuditLogEntry.entity_id == po_id,
            AuditLogEntry.action_type.in_(
                [
                    AuditActionType.risk_trigger_stale,
                    AuditActionType.risk_trigger_compliance_floor,
                ]
            ),
        )
        .all()
    )
    action_types = {e.action_type for e in entries}
    assert AuditActionType.risk_trigger_stale in action_types
    assert AuditActionType.risk_trigger_compliance_floor in action_types
    assert len(entries) == 2


def test_submit_po_allowed_supplier_generates_department_approver_step(
    client, requester_token, db
):
    supplier = _create_supplier(db, **_fully_assessed_kwargs())
    create_resp = client.post(
        "/api/v1/purchase-orders",
        json={
            "supplier_id": supplier.id,
            "amount": "100.00",
            "currency": "USD",
            "description": "test",
        },
        headers=auth_headers(requester_token),
    )
    po_id = create_resp.json()["id"]

    submit_resp = client.post(
        f"/api/v1/purchase-orders/{po_id}/transitions",
        json={"action": "submit"},
        headers=auth_headers(requester_token),
    )
    body = submit_resp.json()
    assert body["approval_control_status"] == "allowed"
    assert len(body["approval_steps"]) == 1
    assert body["approval_steps"][0]["required_role"] == "department_approver"
