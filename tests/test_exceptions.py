from datetime import datetime, timedelta, timezone

from app.models import AuditActionType, AuditLogEntry, ExceptionStatus, Supplier
from tests.conftest import auth_headers


def _create_blocked_po(client, db, requester_token) -> int:
    supplier = Supplier(name="Unassessed Co")
    db.add(supplier)
    db.commit()
    db.refresh(supplier)

    create_resp = client.post(
        "/api/v1/purchase-orders",
        json={
            "supplier_id": supplier.id,
            "amount": "500.00",
            "currency": "USD",
            "description": "urgent replacement part",
        },
        headers=auth_headers(requester_token),
    )
    po_id = create_resp.json()["id"]

    submit_resp = client.post(
        f"/api/v1/purchase-orders/{po_id}/transitions",
        json={"action": "submit"},
        headers=auth_headers(requester_token),
    )
    assert submit_resp.json()["approval_control_status"] == "blocked"
    return po_id


def _future_expiry() -> str:
    return (datetime.now(timezone.utc) + timedelta(days=3)).isoformat()


def test_self_approval_rejected(client, db, requester_token, procurement_lead_token, procurement_lead):
    po_id = _create_blocked_po(client, db, requester_token)

    create_resp = client.post(
        "/api/v1/exception-requests",
        json={
            "purchase_order_id": po_id,
            "justification": "Urgent business need",
            "urgency": "high",
            "expiry_at": _future_expiry(),
        },
        headers=auth_headers(procurement_lead_token),
    )
    assert create_resp.status_code == 201
    exception_id = create_resp.json()["id"]

    decision_resp = client.post(
        f"/api/v1/exception-requests/{exception_id}/decision",
        json={"decision": "approved"},
        headers=auth_headers(procurement_lead_token),
    )
    assert decision_resp.status_code == 403


def test_cross_approver_approval_flags_po_with_distinct_audit_entries(
    client, db, requester_token, department_approver_token, procurement_lead_token
):
    po_id = _create_blocked_po(client, db, requester_token)

    create_resp = client.post(
        "/api/v1/exception-requests",
        json={
            "purchase_order_id": po_id,
            "justification": "Department needs this urgently",
            "urgency": "critical",
            "expiry_at": _future_expiry(),
        },
        headers=auth_headers(department_approver_token),
    )
    exception_id = create_resp.json()["id"]

    decision_resp = client.post(
        f"/api/v1/exception-requests/{exception_id}/decision",
        json={"decision": "approved"},
        headers=auth_headers(procurement_lead_token),
    )
    assert decision_resp.status_code == 200
    assert decision_resp.json()["status"] == "approved"

    po_resp = client.get(f"/api/v1/purchase-orders/{po_id}", headers=auth_headers(procurement_lead_token))
    assert po_resp.json()["approved_with_exception"] is True
    assert po_resp.json()["status"] == "approved"

    exception_entry = (
        db.query(AuditLogEntry)
        .filter(AuditLogEntry.action_type == AuditActionType.exception_approved)
        .one()
    )
    po_entry = (
        db.query(AuditLogEntry)
        .filter(AuditLogEntry.action_type == AuditActionType.po_approved_with_exception)
        .one()
    )
    assert exception_entry.entity_type == "exception_request"
    assert po_entry.entity_type == "purchase_order"
    assert po_entry.entity_id == po_id


def test_access_admin_cannot_approve_po_step_or_exception(
    client, db, requester_token, department_approver_token, access_admin_token
):
    po_id = _create_blocked_po(client, db, requester_token)

    create_resp = client.post(
        "/api/v1/exception-requests",
        json={
            "purchase_order_id": po_id,
            "justification": "test",
            "urgency": "low",
            "expiry_at": _future_expiry(),
        },
        headers=auth_headers(department_approver_token),
    )
    exception_id = create_resp.json()["id"]

    # access_admin cannot submit an exception request at all
    submit_attempt = client.post(
        "/api/v1/exception-requests",
        json={
            "purchase_order_id": po_id,
            "justification": "test",
            "urgency": "low",
            "expiry_at": _future_expiry(),
        },
        headers=auth_headers(access_admin_token),
    )
    assert submit_attempt.status_code == 403

    # access_admin cannot decide an exception request
    decision_resp = client.post(
        f"/api/v1/exception-requests/{exception_id}/decision",
        json={"decision": "approved"},
        headers=auth_headers(access_admin_token),
    )
    assert decision_resp.status_code == 403

    # access_admin cannot act on a PO approval-step transition
    transition_resp = client.post(
        f"/api/v1/purchase-orders/{po_id}/transitions",
        json={"action": "approve"},
        headers=auth_headers(access_admin_token),
    )
    assert transition_resp.status_code == 403


def test_access_admin_cannot_directly_edit_supplier_or_po(client, db, requester_token, access_admin_token):
    supplier = Supplier(name="Test Co")
    db.add(supplier)
    db.commit()
    db.refresh(supplier)

    supplier_resp = client.patch(
        f"/api/v1/suppliers/{supplier.id}",
        json={"status": "suspended"},
        headers=auth_headers(access_admin_token),
    )
    assert supplier_resp.status_code == 403

    create_resp = client.post(
        "/api/v1/purchase-orders",
        json={
            "supplier_id": supplier.id,
            "amount": "10.00",
            "currency": "USD",
            "description": "x",
        },
        headers=auth_headers(requester_token),
    )
    po_id = create_resp.json()["id"]

    po_resp = client.patch(
        f"/api/v1/purchase-orders/{po_id}",
        json={"description": "hacked"},
        headers=auth_headers(access_admin_token),
    )
    assert po_resp.status_code == 403


def test_exception_request_missing_mandatory_fields_rejected(client, db, requester_token):
    po_id = _create_blocked_po(client, db, requester_token)

    resp = client.post(
        "/api/v1/exception-requests",
        json={"purchase_order_id": po_id},
        headers=auth_headers(requester_token),
    )
    assert resp.status_code == 422
