# Contract: Dashboard & Audit Trail

Base path: `/api/v1`. All endpoints require a valid JWT.

## GET /dashboard

**Permitted roles**: all five — `require_roles(["requester",
"department_approver", "procurement_lead", "access_admin", "auditor"])`.
Response **shape** varies by `caller.role` (a visibility-scoping concern
implemented in the service layer, not a permissions-dependency concern —
Principle III governs *who may call a mutating endpoint*; this is a read
endpoint whose content is scoped per caller).

**Response** `200`, one of (discriminated by role, each a distinct Pydantic
model):

- **`requester`** → `RequesterDashboard`: `{"my_purchase_orders":
  [PurchaseOrderSummary, ...]}` — query filtered to
  `requester_id == caller.id`. Never includes another user's POs (FR-016,
  US4 AC1).

- **`department_approver`** → `ApproverDashboard`:
  `{"team": caller.team, "pending_approvals": [...], "pending_approval_aging":
  {"avg_days_pending": ..., "oldest_pending_days": ...}}` — scoped to
  `PurchaseOrder.requester.team == caller.team` (research.md Decision 8).

- **`procurement_lead`** → `ProcurementLeadDashboard`:
  ```json
  {
    "blocked_creation_attempts": 0,
    "exception_requests": {"submitted": 0, "approved": 0, "rejected": 0, "lapsed": 0},
    "pos_affected_by_stale_or_unassessed": 0,
    "risk_tier_distribution": {"low": 0, "medium": 0, "high": 0},
    "avg_approval_time_by_tier": {"low": null, "medium": null, "high": null},
    "pending_approval_aging": {"avg_days_pending": null, "oldest_pending_days": null}
  }
  ```
  Full aggregate business KPIs (FR-016, US4 AC3).

- **`access_admin`** → `AccessAdminDashboard`:
  `{"role_elevations": [{"grantor": ..., "grantee": ..., "prior_role": ...,
  "new_role": ..., "at": ...}, ...]}` — a filtered view of `AuditLogEntry`
  where `action_type == "role_elevation"`. **No business-risk KPIs are
  included** (FR-016 explicitly excludes them for this role).

- **`auditor`** → same shape as `ProcurementLeadDashboard` (US5 AC8: "the
  same aggregate business data available to procurement leads").

## GET /audit-log

**Permitted roles**: `auditor` only — `require_roles(["auditor"])`. FR-017's
"full read access to the audit trail" is a distinct, broader capability than
any other role's dashboard view (including access_admin's role-elevation-only
slice above), so it is intentionally not exposed to any other role.

**Query params**: `entity_type`, `entity_id`, `action_type` (all optional
filters).

**Response** `200`: `list[AuditLogEntryResponse]` — full, unfiltered rows
(including `role_elevation` entries, satisfying "including the role-elevation
log").

## Auditor mutating-endpoint rejection (cross-cutting, not a single route)

Per FR-018/FR-019 and spec US5, `auditor` is deliberately **absent** from the
`require_roles(...)` list on every mutating route in this plan. The first
seven rows are FR-018's explicitly-named actions; the last two
(`Supplier creation`, `PO field update`) are additional mutating endpoints
that exist for CRUD completeness but were not individually named in spec.md
— added here for completeness after an audit found they were implemented,
role-gated correctly, but undocumented and untested for this property:

| Mutating action | Route | `require_roles(...)` (auditor absent from all) |
|---|---|---|
| PO creation | `POST /purchase-orders` | `["requester"]` |
| PO submission | `POST /purchase-orders/{id}/transitions` (`submit`) | `["requester"]` (+ ownership check) |
| Approval-step decision | `POST /purchase-orders/{id}/transitions` (`approve`/`reject`) | `["department_approver", "procurement_lead"]` (+ per-step dynamic check, research.md Decision 11) |
| Exception request | `POST /exception-requests` | `["requester", "department_approver", "procurement_lead"]` |
| Exception approval | `POST /exception-requests/{id}/decision` | `["procurement_lead"]` |
| Supplier status change | `PATCH /suppliers/{id}` | `["procurement_lead"]` |
| Role elevation | `PATCH /users/{id}/role` | `["access_admin"]` |
| Supplier creation | `POST /suppliers` | `["procurement_lead"]` |
| PO field update | `PATCH /purchase-orders/{id}` | `["requester"]` (+ ownership check) |

Because FastAPI's `require_roles(...)` dependency runs before the handler
body and returns `403` for any role not in its list, `auditor` is rejected
structurally on all nine — this is what tasks.md's test plan verifies
individually per spec US5's explicit "not just one representative example"
requirement (applied here to all nine mutating endpoints, not only FR-018's
seven named ones).
