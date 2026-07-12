# Contract: Purchase Orders

Base path: `/api/v1/purchase-orders`. All endpoints require a valid JWT.
`access_admin` is excluded from every route below (FR-014).

## POST /purchase-orders

**Permitted roles**: `requester`.

**Request** (`PurchaseOrderCreateRequest`):
```json
{ "supplier_id": 7, "amount": "1500.00", "currency": "USD", "description": "Q3 hardware" }
```

**Behavior** (FR-009): load `Supplier`; if `status == "blocked"`, reject
`409` **before** calling any `risk_engine` function — no risk score is
computed for a blocked supplier at creation time. Otherwise create the PO as
`status="draft"`.

**Response** `201`: `PurchaseOrderResponse`.

**Errors**: `409 supplier_blocked` if supplier is blocked. `404` if supplier
does not exist.

## GET /purchase-orders, GET /purchase-orders/{id}

**Permitted roles**: `requester` (own POs only — enforced by filtering the
query to `requester_id == caller.id`, not by a 403), `department_approver`,
`procurement_lead`, `auditor`.

## PATCH /purchase-orders/{id}

**Permitted roles**: `requester`, and only while `status == "draft"` and
`requester_id == caller.id`.

**Request**: any subset of `amount`, `currency`, `description`, `supplier_id`.

**Errors**: `403` if not the owning requester or not in `draft`.

## POST /purchase-orders/{id}/transitions

The single dedicated status-transition endpoint (constitution-level pattern
carried into this feature).

**Permitted roles**: varies by `action` (checked in the handler after a
baseline `require_roles(["requester", "department_approver",
"procurement_lead"])` gate — the fine-grained check below is business logic,
not a permissions dependency, because "who" is allowed depends on runtime
state — the specific `ApprovalStep.required_role` and team — not a fixed role
set known at route-declaration time):

**Request** (`TransitionRequest`):
```json
{ "action": "submit" }
```
`action` ∈ `submit`, `approve`, `reject`, `cancel`.

**Behavior by action**:

- **`submit`** (caller must be the owning requester, PO must be `draft`):
  1. Reload `Supplier`; if `status != "active"`, reject `409`
     (FR-010 — re-checked at submission, not just creation).
  2. Compute `tier = risk_engine.compute_risk_tier(supplier)`,
     `validity = risk_engine.compute_validity_status(supplier, now)`,
     `compliance_floor_failed = risk_engine.compliance_floor_failed(supplier)`.
  3. `control_status = risk_engine.compute_approval_control_status(tier,
     validity, compliance_floor_failed)` — snapshot onto
     `PurchaseOrder.approval_control_status`; set `status="submitted"`,
     `submitted_at=now()`.
  4. For each triggered condition (`validity in {stale, unassessed,
     incomplete}`, `compliance_floor_failed`), write one
     `AuditLogEntry` each (FR-011) — e.g. `risk_trigger_stale` and
     `risk_trigger_compliance_floor` can both be written for the same PO in
     the same submission.
  5. Generate `ApprovalStep` rows per research.md Decision 6 (empty list if
     `control_status == "blocked"`); set `current_step_number` to the first
     step or `null` if none.
  6. Write `AuditLogEntry(action_type="po_status_transition", rationale=
     f"Submitted; control_status={control_status} (tier={tier},
     validity={validity})")`.

- **`approve` / `reject`** (caller's `role` must equal
  `ApprovalStep[current_step_number].required_role`; for a
  `department_approver` step, caller's `team` must also equal the requester's
  `team`):
  1. `403` if caller does not match the required role/team for the current
     step.
  2. Update the `ApprovalStep`; on `approve`, advance
     `current_step_number` to the next step or, if none remain, set
     `PurchaseOrder.status="approved"`, `decided_at=now()`. On `reject`, set
     `PurchaseOrder.status="rejected"`, `decided_at=now()`.
  3. Write `AuditLogEntry(action_type="po_status_transition", rationale=
     f"Step {n} {approve|reject} by {caller.email} ({caller.role})")`.

- **`cancel`** (caller must be the owning requester; PO must be `draft` or
  `submitted`): set `status="cancelled"`; write
  `AuditLogEntry(action_type="po_status_transition")`.

**Response** `200`: `PurchaseOrderResponse` (current state after transition).

**Errors**: `409 supplier_blocked` (submit, re-check), `403 wrong_role_or_team`
(approve/reject), `409 invalid_transition` (action not valid for current
status), `404`.

**Note**: the *exception* path (moving a `blocked` PO forward) is **not**
reachable through this endpoint — it only exists via
`POST /exception-requests` and its decision endpoint (see contracts/exceptions.md),
per constitution-level separation of "normal transition" from "exception
override" and spec User Story 3.
