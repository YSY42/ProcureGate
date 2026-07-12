# Quickstart: Layered Risk Model, Role Integrity & Controlled Exception Approval

Validates the feature end-to-end against a running instance. See
[data-model.md](data-model.md) for entity shapes and [contracts/](contracts/)
for full request/response detail — not duplicated here.

## Prerequisites

- Docker + docker-compose
- `docker-compose.yml` brings up `app` (FastAPI/uvicorn) + `postgres`
- `.env` with `DATABASE_URL`, `JWT_SECRET`, and the risk-threshold settings
  from `app/config.py` (staleness window, ESG floor, etc.)

## Setup

```bash
docker compose up -d --build
# Schema is created automatically on app startup via Base.metadata.create_all()
docker compose run --rm app python -m scripts.seed_access_admin \
  --email admin@example.com --password change-me
```

## Scenario 1 — Self-registration cannot self-elevate (User Story 1)

```bash
curl -s -X POST localhost:8000/api/v1/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"email":"eve@example.com","password":"pass1234","role":"access_admin"}'
```
**Expected**: `201`, response `role` is `"requester"` — the submitted `role`
field was ignored (FR-001).

## Scenario 2 — Only access_admin can elevate a role (User Story 1)

```bash
ADMIN_TOKEN=$(curl -s -X POST localhost:8000/api/v1/auth/login \
  -d 'username=admin@example.com&password=change-me' | jq -r .access_token)

curl -s -X PATCH localhost:8000/api/v1/users/2/role \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"new_role":"procurement_lead"}'
```
**Expected**: `200`; `GET /audit-log?action_type=role_elevation` (as
auditor, see Scenario 6) shows one entry with `grantor`, `grantee`,
`prior_role="requester"`, `new_role="procurement_lead"`.

Repeat the same call authenticated as a `requester` token instead of
`ADMIN_TOKEN` → **expected `403`**.

## Scenario 3 — Layered risk drives approval control status (User Story 2)

```bash
# Blocked supplier: creation-time rejection, no risk computed
curl -s -X POST localhost:8000/api/v1/suppliers \
  -H "Authorization: Bearer $LEAD_TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"BlockedCo"}'
curl -s -X PATCH localhost:8000/api/v1/suppliers/1 \
  -H "Authorization: Bearer $LEAD_TOKEN" -d '{"status":"blocked"}'
curl -s -X POST localhost:8000/api/v1/purchase-orders \
  -H "Authorization: Bearer $REQUESTER_TOKEN" \
  -d '{"supplier_id":1,"amount":"100.00","currency":"USD","description":"test"}'
```
**Expected**: `409 supplier_blocked`.

```bash
# Unassessed supplier: never assessed → Blocked at submission
curl -s -X POST localhost:8000/api/v1/suppliers \
  -H "Authorization: Bearer $LEAD_TOKEN" -d '{"name":"NewCo"}'
curl -s -X POST localhost:8000/api/v1/purchase-orders \
  -H "Authorization: Bearer $REQUESTER_TOKEN" \
  -d '{"supplier_id":2,"amount":"100.00","currency":"USD","description":"test"}'
curl -s -X POST localhost:8000/api/v1/purchase-orders/1/transitions \
  -H "Authorization: Bearer $REQUESTER_TOKEN" -d '{"action":"submit"}'
```
**Expected**: `200`; `approval_control_status == "blocked"`.
`GET /audit-log?entity_type=purchase_order&entity_id=1` (as auditor) shows a
`risk_trigger_incomplete_or_unassessed` entry with a rationale mentioning
"never assessed".

## Scenario 4 — Controlled exception process (User Story 3)

```bash
curl -s -X POST localhost:8000/api/v1/exception-requests \
  -H "Authorization: Bearer $REQUESTER_TOKEN" \
  -d '{"purchase_order_id":1,"justification":"Urgent","urgency":"high","expiry_at":"2026-08-01T00:00:00Z"}'

# procurement_lead who IS the requester tries to approve their own request → 403
curl -s -X POST localhost:8000/api/v1/exception-requests/1/decision \
  -H "Authorization: Bearer $SAME_USER_AS_LEAD_TOKEN" -d '{"decision":"approved"}'

# a DIFFERENT procurement_lead approves → 200
curl -s -X POST localhost:8000/api/v1/exception-requests/1/decision \
  -H "Authorization: Bearer $OTHER_LEAD_TOKEN" -d '{"decision":"approved"}'
```
**Expected**: first call `403 self_approval_forbidden`; second call `200`,
and `GET /purchase-orders/1` shows `approved_with_exception: true`,
`status: "approved"`.

```bash
# access_admin attempts the same decision endpoint → 403 (route-level, never reaches handler)
curl -s -X POST localhost:8000/api/v1/exception-requests/1/decision \
  -H "Authorization: Bearer $ACCESS_ADMIN_TOKEN" -d '{"decision":"approved"}'
```

## Scenario 5 — Role-scoped dashboard (User Story 4)

```bash
curl -s localhost:8000/api/v1/dashboard -H "Authorization: Bearer $REQUESTER_TOKEN"
curl -s localhost:8000/api/v1/dashboard -H "Authorization: Bearer $DEPT_APPROVER_TOKEN"
curl -s localhost:8000/api/v1/dashboard -H "Authorization: Bearer $LEAD_TOKEN"
curl -s localhost:8000/api/v1/dashboard -H "Authorization: Bearer $ADMIN_TOKEN"
```
**Expected**: four different response shapes per contracts/dashboard-audit.md
— requester sees only own POs; access_admin sees a role-elevation list with
no business KPIs.

## Scenario 6 — Auditor: read-only everywhere (User Story 5)

```bash
for ep in \
  "POST /purchase-orders" \
  "POST /purchase-orders/1/transitions" \
  "POST /exception-requests" \
  "POST /exception-requests/1/decision" \
  "PATCH /suppliers/1" \
  "PATCH /users/2/role"; do
  echo "== $ep =="
  # issue each with $AUDITOR_TOKEN and confirm 403
done

curl -s localhost:8000/api/v1/dashboard -H "Authorization: Bearer $AUDITOR_TOKEN"
curl -s localhost:8000/api/v1/audit-log -H "Authorization: Bearer $AUDITOR_TOKEN"
```
**Expected**: every mutating call `403`; both read calls `200`.

## Automated equivalent

`pytest` runs all of the above as `tests/test_role_integrity.py`,
`tests/test_purchase_orders.py`, `tests/test_exceptions.py`,
`tests/test_dashboard.py`, plus `tests/test_risk_engine.py` for the pure
risk-computation unit tests (every tier/validity/control-status combination,
per constitution Principle I/V). CI runs the full suite against SQLite on
every PR (constitution Principle V) — see `.github/workflows/ci.yml`.
