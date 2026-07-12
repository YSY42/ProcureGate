from tests.conftest import auth_headers


def test_self_registration_ignores_role_payload(client):
    resp = client.post(
        "/api/v1/auth/register",
        json={
            "email": "eve@example.com",
            "password": "pass1234",
            "role": "access_admin",
        },
    )
    assert resp.status_code == 201
    assert resp.json()["role"] == "requester"


def test_non_admin_cannot_elevate(client, requester_token, department_approver):
    resp = client.patch(
        f"/api/v1/users/{department_approver.id}/role",
        json={"new_role": "procurement_lead"},
        headers=auth_headers(requester_token),
    )
    assert resp.status_code == 403


def test_access_admin_elevates_role_and_audit_recorded(
    client, access_admin_token, access_admin, department_approver, db
):
    resp = client.patch(
        f"/api/v1/users/{department_approver.id}/role",
        json={"new_role": "procurement_lead"},
        headers=auth_headers(access_admin_token),
    )
    assert resp.status_code == 200
    assert resp.json()["role"] == "procurement_lead"

    from app.models import AuditActionType, AuditLogEntry

    entry = (
        db.query(AuditLogEntry)
        .filter(AuditLogEntry.action_type == AuditActionType.role_elevation)
        .one()
    )
    assert entry.metadata_json["grantor_id"] == access_admin.id
    assert entry.metadata_json["grantee_id"] == department_approver.id
    assert entry.metadata_json["prior_role"] == "department_approver"
    assert entry.metadata_json["new_role"] == "procurement_lead"


def test_role_change_takes_effect_on_next_request_without_relogin(
    client, access_admin_token, requester, requester_token, department_approver
):
    """Edge case (spec.md) / FR-020: a demoted-or-elevated user's next
    request, under the same still-valid JWT, reflects the new role."""
    elevate_resp = client.patch(
        f"/api/v1/users/{requester.id}/role",
        json={"new_role": "access_admin"},
        headers=auth_headers(access_admin_token),
    )
    assert elevate_resp.status_code == 200

    # requester_token was issued before the elevation; the JWT itself never
    # changes, but the caller's role must be re-read from the DB.
    resp = client.patch(
        f"/api/v1/users/{department_approver.id}/role",
        json={"new_role": "procurement_lead"},
        headers=auth_headers(requester_token),
    )
    assert resp.status_code == 200
