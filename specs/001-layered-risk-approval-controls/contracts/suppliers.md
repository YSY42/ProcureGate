# Contract: Suppliers

Base path: `/api/v1/suppliers`. All endpoints require a valid JWT.

## POST /suppliers

**Permitted roles**: `procurement_lead` only (research.md Decision 7).

**Request** (`SupplierCreateRequest`):
```json
{
  "name": "Acme Corp",
  "country": "US",
  "category": "electronics",
  "delivery_reliability_score": 92.5,
  "defect_rate": 1.2,
  "esg_rating": 71.0,
  "sanctions_flag": false
}
```
All risk-input fields optional at creation (an Unassessed supplier is valid —
FR-006).

**Behavior**: on create/update, if all five risk inputs are present,
`assessed_at = now()` and `computed_risk_tier =
risk_engine.compute_risk_tier(...)` is set; if some but not all are present,
`assessed_at` is left null (supplier reads as `Incomplete`, not `Unassessed`,
per `risk_engine.compute_validity_status`).

**Response** `201`: `SupplierResponse` — includes `computed_risk_tier` but
**not** `assessment_validity_status`/`approval_control_status` (those are PO-
submission-time-only concepts, not supplier-level fields — research.md
Decision 4).

**Errors**: `403` if caller is not `procurement_lead`.

## PATCH /suppliers/{supplier_id}

**Permitted roles**: `procurement_lead` only.

**Request** (`SupplierUpdateRequest`): any subset of the create fields, plus
`status` (`active`/`suspended`/`blocked`). Updating `status` writes
`AuditLogEntry(action_type="supplier_status_change")`. Updating any risk
input recomputes `computed_risk_tier` and refreshes `assessed_at = now()`.

**Response** `200`: `SupplierResponse`.

**Errors**: `403` for any non-`procurement_lead` caller, including
`access_admin` (FR-014 — access_admin has zero write access here, enforced
by `access_admin` simply never appearing in this route's `require_roles`
list, not by a conditional check).

## GET /suppliers, GET /suppliers/{supplier_id}

**Permitted roles**: `requester`, `department_approver`, `procurement_lead`,
`auditor`. `access_admin` is excluded from `require_roles(...)` on these
routes — FR-014 bars access_admin from "any read/write relationship to
Supplier or PurchaseOrder business data of any kind," so this is a read
restriction, not just a write restriction.
