# Contract: Exception Requests

Base path: `/api/v1/exception-requests`. All endpoints require a valid JWT.
`access_admin` is excluded from every route below (FR-014).

## POST /exception-requests

**Permitted roles**: `requester`, `department_approver`, `procurement_lead`
— any role that can be "the user whose approval step is blocked" (FR-012).
`require_roles(["requester", "department_approver", "procurement_lead"])`;
`auditor` and `access_admin` excluded.

**Request** (`ExceptionRequestCreate`):
```json
{
  "purchase_order_id": 55,
  "justification": "Urgent replacement part, existing PO for this supplier expired mid-shipment.",
  "urgency": "high",
  "expiry_at": "2026-07-18T00:00:00Z"
}
```

**Behavior**:
1. Load `PurchaseOrder`; `409` if its `approval_control_status != "blocked"`
   — exceptions only apply to blocked POs.
2. `justification`, `urgency`, `expiry_at` all required (400 if missing —
   FR-012's "mandatory" fields).
3. Create `ExceptionRequest(status="pending", requested_by_id=caller.id)`.
4. Write `AuditLogEntry(action_type="exception_submitted")`.

**Response** `201`: `ExceptionRequestResponse`.

**Errors**: `409` if PO is not blocked, `404` if PO does not exist.

## POST /exception-requests/{id}/decision

**Permitted roles**: `procurement_lead` only —
`require_roles(["procurement_lead"])`. This alone makes `access_admin`
approval structurally impossible (FR-014), independent of any body-level
check.

**Request** (`ExceptionDecisionRequest`):
```json
{ "decision": "approved" }
```
`decision` ∈ `approved`, `rejected`.

**Behavior** (FR-013):
1. Load `ExceptionRequest`; `409 already_decided` if `status != "pending"`;
   if `expiry_at < now()`, first flip it to `lapsed` and return `409 lapsed`
   instead of processing the decision.
2. **Self-approval check**: if `caller.id == exception.requested_by_id`,
   reject `403 self_approval_forbidden` — checked **before** any state
   change, regardless of the fact the route already requires
   `procurement_lead` (a procurement_lead can still be the requester).
3. On `approved`: set `exception.status="approved"`,
   `exception.decided_by_id=caller.id`, `decided_at=now()`; set
   `PurchaseOrder.approved_with_exception=true`,
   `PurchaseOrder.status="approved"`, `decided_at=now()`. Write **two**
   audit entries (FR-015 — distinct action types, independently queryable):
   `AuditLogEntry(action_type="exception_approved", entity_type=
   "exception_request")` and `AuditLogEntry(action_type=
   "po_approved_with_exception", entity_type="purchase_order")`.
4. On `rejected`: set `exception.status="rejected"`; PO remains blocked (a
   new exception request may be submitted). Write
   `AuditLogEntry(action_type="exception_rejected")`.

**Response** `200`: `ExceptionRequestResponse`.

**Errors**: `403 self_approval_forbidden`, `409 already_decided`,
`409 lapsed`, `404`.

**Acceptance scenario mapping**: spec US3 AC1 (self-approval rejected), AC2
(cross-approver success + `approved_with_exception` flag), AC3
(access_admin rejected — via route-level `require_roles`, never reaches this
handler).
