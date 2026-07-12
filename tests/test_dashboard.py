from datetime import datetime, timedelta, timezone

import pytest

from app.models import Role, Supplier
from tests.conftest import auth_headers, make_user, token_for


def _create_and_submit_po(client, db, requester_token, supplier_kwargs=None) -> int:
    supplier = Supplier(name="Test Co", **(supplier_kwargs or {}))
    db.add(supplier)
    db.commit()
    db.refresh(supplier)

    create_resp = client.post(
        "/api/v1/purchase-orders",
        json={
            "supplier_id": supplier.id,
            "amount": "50.00",
            "currency": "USD",
            "description": "test",
        },
        headers=auth_headers(requester_token),
    )
    po_id = create_resp.json()["id"]
    client.post(
        f"/api/v1/purchase-orders/{po_id}/transitions",
        json={"action": "submit"},
        headers=auth_headers(requester_token),
    )
    return po_id


def test_requester_dashboard_scoped_to_own_pos(client, db, requester_token, requester):
    _create_and_submit_po(client, db, requester_token)

    other = make_user(db, "other-requester@example.com", Role.requester, team="beta")
    other_token = token_for(other)
    _create_and_submit_po(client, db, other_token)

    resp = client.get("/api/v1/dashboard", headers=auth_headers(requester_token))
    assert resp.status_code == 200
    body = resp.json()
    assert len(body["my_purchase_orders"]) == 1
    assert all(po["requester_id"] == requester.id for po in body["my_purchase_orders"])


def test_department_approver_dashboard_scoped_to_team(
    client, db, requester_token, department_approver_token
):
    po_id = _create_and_submit_po(
        client,
        db,
        requester_token,
        supplier_kwargs=dict(
            country="US",
            category="widgets",
            delivery_reliability_score=95,
            defect_rate=0.5,
            esg_rating=90,
            assessed_at=datetime.now(timezone.utc),
            computed_risk_tier="low",
        ),
    )

    resp = client.get("/api/v1/dashboard", headers=auth_headers(department_approver_token))
    assert resp.status_code == 200
    body = resp.json()
    assert body["team"] == "alpha"
    assert any(po["id"] == po_id for po in body["pending_approvals"])
    assert "avg_days_pending" in body["pending_approval_aging"]


def test_procurement_lead_dashboard_returns_full_kpis(client, db, requester_token, procurement_lead_token):
    resp = client.get("/api/v1/dashboard", headers=auth_headers(procurement_lead_token))
    assert resp.status_code == 200
    body = resp.json()
    for key in (
        "blocked_creation_attempts",
        "exception_requests",
        "pos_affected_by_stale_or_unassessed",
        "risk_tier_distribution",
        "avg_approval_time_by_tier",
        "pending_approval_aging",
    ):
        assert key in body


def test_access_admin_dashboard_shows_role_log_not_business_kpis(
    client, db, access_admin_token, access_admin, department_approver
):
    client.patch(
        f"/api/v1/users/{department_approver.id}/role",
        json={"new_role": "procurement_lead"},
        headers=auth_headers(access_admin_token),
    )

    resp = client.get("/api/v1/dashboard", headers=auth_headers(access_admin_token))
    assert resp.status_code == 200
    body = resp.json()
    assert "role_elevations" in body
    assert len(body["role_elevations"]) == 1
    assert body["role_elevations"][0]["grantor_id"] == access_admin.id
    assert "risk_tier_distribution" not in body
    assert "blocked_creation_attempts" not in body


# ---------------------------------------------------------------------------
# User Story 5 - Read-Only Auditor Access
# ---------------------------------------------------------------------------


@pytest.fixture
def blocked_po(client, db, requester_token):
    supplier = Supplier(name="Unassessed Co")
    db.add(supplier)
    db.commit()
    db.refresh(supplier)

    create_resp = client.post(
        "/api/v1/purchase-orders",
        json={
            "supplier_id": supplier.id,
            "amount": "50.00",
            "currency": "USD",
            "description": "test",
        },
        headers=auth_headers(requester_token),
    )
    po_id = create_resp.json()["id"]
    client.post(
        f"/api/v1/purchase-orders/{po_id}/transitions",
        json={"action": "submit"},
        headers=auth_headers(requester_token),
    )
    return po_id, supplier.id


@pytest.fixture
def pending_exception(client, db, blocked_po, requester_token):
    po_id, _ = blocked_po
    resp = client.post(
        "/api/v1/exception-requests",
        json={
            "purchase_order_id": po_id,
            "justification": "test",
            "urgency": "low",
            "expiry_at": (datetime.now(timezone.utc) + timedelta(days=3)).isoformat(),
        },
        headers=auth_headers(requester_token),
    )
    return resp.json()["id"]


@pytest.mark.parametrize(
    "make_request",
    [
        lambda c, po_id, exc_id, supplier_id, h: c.post(
            "/api/v1/purchase-orders",
            json={
                "supplier_id": supplier_id,
                "amount": "1.00",
                "currency": "USD",
                "description": "x",
            },
            headers=h,
        ),
        lambda c, po_id, exc_id, supplier_id, h: c.post(
            f"/api/v1/purchase-orders/{po_id}/transitions",
            json={"action": "submit"},
            headers=h,
        ),
        lambda c, po_id, exc_id, supplier_id, h: c.post(
            f"/api/v1/purchase-orders/{po_id}/transitions",
            json={"action": "approve"},
            headers=h,
        ),
        lambda c, po_id, exc_id, supplier_id, h: c.post(
            "/api/v1/exception-requests",
            json={
                "purchase_order_id": po_id,
                "justification": "x",
                "urgency": "low",
                "expiry_at": (datetime.now(timezone.utc) + timedelta(days=1)).isoformat(),
            },
            headers=h,
        ),
        lambda c, po_id, exc_id, supplier_id, h: c.post(
            f"/api/v1/exception-requests/{exc_id}/decision",
            json={"decision": "approved"},
            headers=h,
        ),
        lambda c, po_id, exc_id, supplier_id, h: c.patch(
            f"/api/v1/suppliers/{supplier_id}", json={"status": "suspended"}, headers=h
        ),
        lambda c, po_id, exc_id, supplier_id, h: c.patch(
            "/api/v1/users/1/role", json={"new_role": "auditor"}, headers=h
        ),
        lambda c, po_id, exc_id, supplier_id, h: c.post(
            "/api/v1/suppliers", json={"name": "AuditorCantCreate"}, headers=h
        ),
        lambda c, po_id, exc_id, supplier_id, h: c.patch(
            f"/api/v1/purchase-orders/{po_id}", json={"description": "hacked"}, headers=h
        ),
    ],
    ids=[
        "po_creation",
        "po_submission",
        "approval_step_decision",
        "exception_request",
        "exception_decision",
        "supplier_status_change",
        "role_elevation",
        "supplier_creation",
        "po_field_update",
    ],
)
def test_auditor_rejected_on_each_mutating_endpoint_individually(
    client, blocked_po, pending_exception, auditor_token, make_request
):
    po_id, supplier_id = blocked_po
    resp = make_request(client, po_id, pending_exception, supplier_id, auth_headers(auditor_token))
    assert resp.status_code == 403


def test_auditor_dashboard_matches_procurement_lead_shape(client, auditor_token):
    resp = client.get("/api/v1/dashboard", headers=auth_headers(auditor_token))
    assert resp.status_code == 200
    body = resp.json()
    for key in (
        "blocked_creation_attempts",
        "exception_requests",
        "risk_tier_distribution",
        "avg_approval_time_by_tier",
        "pending_approval_aging",
    ):
        assert key in body


def test_auditor_can_read_full_audit_log_including_role_elevation(
    client, db, auditor_token, access_admin_token, department_approver
):
    client.patch(
        f"/api/v1/users/{department_approver.id}/role",
        json={"new_role": "procurement_lead"},
        headers=auth_headers(access_admin_token),
    )

    resp = client.get("/api/v1/audit-log", headers=auth_headers(auditor_token))
    assert resp.status_code == 200
    action_types = {e["action_type"] for e in resp.json()}
    assert "role_elevation" in action_types
