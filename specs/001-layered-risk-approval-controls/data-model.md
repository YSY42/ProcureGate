# Phase 1 Data Model: Layered Risk Model, Role Integrity & Controlled Exception Approval

All entities below live in `app/models.py` as SQLAlchemy 2.x ORM classes
(`Mapped[...]` / `mapped_column(...)` style). All enums are Python `enum.Enum`
subclasses mapped via SQLAlchemy `Enum(...)`, giving a native Postgres `ENUM`
locally and a `CHECK` constraint on SQLite in CI (research.md, Decision 2).
Since there is no migration tool (research.md, Decision 1), every column
either has a server-independent application default or is nullable — there is
no backfill step because the schema is created once, fresh, via
`Base.metadata.create_all()`.

## Enums

- `Role`: `requester`, `department_approver`, `procurement_lead`,
  `access_admin`, `auditor`
- `SupplierStatus`: `active`, `suspended`, `blocked`
- `RiskLevel` (internal, per-layer): `low`, `medium`, `high`
- `RiskTier` (Supplier.computed_risk_tier): `low`, `medium`, `high`
- `POStatus` (baseline lifecycle): `draft`, `submitted`, `approved`,
  `rejected`, `cancelled`
- `ApprovalControlStatus`: `allowed`, `conditional`, `blocked`, `escalated`
- `ApprovalStepStatus`: `pending`, `approved`, `rejected`
- `ExceptionUrgency`: `low`, `medium`, `high`, `critical`
- `ExceptionStatus`: `pending`, `approved`, `rejected`, `lapsed`
- `AuditActionType`: `po_status_transition`, `risk_trigger_stale`,
  `risk_trigger_incomplete_or_unassessed`, `risk_trigger_compliance_floor`,
  `exception_submitted`, `exception_approved`, `exception_rejected`,
  `exception_lapsed`, `po_approved_with_exception`, `po_creation_blocked`,
  `supplier_status_change`, `role_elevation`. `po_creation_blocked` was added
  during implementation (User Story 4): FR-016's "blocked PO-creation
  attempts" procurement_lead KPI needs a persisted event to count, since a
  rejected `POST /purchase-orders` call otherwise leaves no PurchaseOrder row
  to attach a trigger entry to.

## User

Baseline auth entity, extended by this feature's role-integrity rules.

| Field | Type | Notes |
|---|---|---|
| `id` | int, PK | |
| `email` | str, unique, indexed | login identity |
| `hashed_password` | str | passlib[bcrypt] hash |
| `role` | `Role`, default `requester` | **FR-001**: always `requester` at self-registration regardless of request payload; changed only via `PATCH /users/{id}/role` (FR-002) |
| `team` | str, nullable | research.md Decision 8; scopes department_approver dashboard |
| `created_at` | datetime, server default now | |

**Validation rules**: `email` unique (DB constraint + 409 on conflict).
Password hashed before storage, never returned in any response schema.

**State transitions**: `role` changes only through the role-elevation
endpoint (access_admin caller required); every change produces an
`AuditLogEntry` (`role_elevation`) per FR-003.

## Supplier (extended baseline entity)

| Field | Type | Notes |
|---|---|---|
| `id` | int, PK | |
| `name` | str | |
| `status` | `SupplierStatus`, default `active` | gates PO creation/submission (FR-009, FR-010) |
| `country` | str, nullable | inherent-risk input |
| `category` | str, nullable | inherent-risk input |
| `delivery_reliability_score` | float 0-100, nullable | performance-risk input |
| `defect_rate` | float 0-100 (percent), nullable | performance-risk input |
| `esg_rating` | float 0-100, nullable | compliance-risk input |
| `sanctions_flag` | bool, default `false` | compliance-risk input / hard veto |
| `assessed_at` | datetime, nullable | null ⇒ never assessed (FR-006 `Unassessed`) |
| `computed_risk_tier` | `RiskTier`, nullable | cached output of `risk_engine.compute_risk_tier(...)`, recomputed on every write to the fields above (FR-004, FR-005) |
| `created_at` / `updated_at` | datetime | |

**Validation rules**: `delivery_reliability_score`, `defect_rate`,
`esg_rating` constrained 0-100 at the Pydantic schema layer. Writable only by
`procurement_lead` (research.md Decision 7); `access_admin` has zero
read/write access to this table by design (FR-014).

**Derived, not stored** (research.md Decision 4):
- `assessment_validity_status` = `risk_engine.compute_validity_status(supplier, now)`
  → `current` / `stale` / `unassessed` / `incomplete`
- `approval_control_status` = `risk_engine.compute_approval_control_status(...)`
  → `allowed` / `conditional` / `blocked` / `escalated`
  Computed fresh at PO-submission time; never cached on `Supplier` itself.

## PurchaseOrder (extended baseline entity)

| Field | Type | Notes |
|---|---|---|
| `id` | int, PK | |
| `requester_id` | int, FK → User.id | |
| `supplier_id` | int, FK → Supplier.id | |
| `amount` | numeric(12,2) | baseline CRUD field |
| `currency` | str(3) | baseline CRUD field |
| `description` | str | baseline CRUD field |
| `status` | `POStatus`, default `draft` | baseline lifecycle |
| `approval_control_status` | `ApprovalControlStatus`, nullable | **snapshotted** at submission (FR-007, FR-008); fixed thereafter per spec Edge Cases (not recomputed if supplier data changes later) |
| `approved_with_exception` | bool, default `false` | FR-015 |
| `current_step_number` | int, nullable | pointer into `ApprovalStep`; null once no steps remain pending |
| `created_at` / `submitted_at` / `decided_at` | datetime, nullable | |

**Validation rules**: `requester_id` must reference a `requester`-or-higher
account (any authenticated user may request a PO). Only the owning requester
may edit/submit a `draft` PO.

**State transitions** (`status`, baseline + this feature's gating):
- `draft → submitted`: allowed only if `supplier.status == active`
  (re-checked at submission, not just at creation — FR-010). On this
  transition: compute `approval_control_status` live, snapshot it onto the
  row, generate `ApprovalStep` rows per research.md Decision 6, and write one
  `AuditLogEntry` per triggered condition (FR-011).
  - If the resulting status is `blocked`: no steps are created; PO stays
    `submitted` with no path to `approved` except via a successful
    `ExceptionRequest` (User Story 3).
- `submitted → approved`: last `ApprovalStep` reaches `approved`.
- `submitted → rejected`: any `ApprovalStep` reaches `rejected`, or an
  `ExceptionRequest` is rejected while the PO has no other path forward.
- `draft/submitted → cancelled`: by the owning requester only.

## ApprovalStep

| Field | Type | Notes |
|---|---|---|
| `id` | int, PK | |
| `purchase_order_id` | int, FK → PurchaseOrder.id | |
| `step_number` | int | 1-based order |
| `required_role` | `Role` | `department_approver` or `procurement_lead` only (research.md Decision 6) |
| `status` | `ApprovalStepStatus`, default `pending` | |
| `decided_by_id` | int, FK → User.id, nullable | |
| `decided_at` | datetime, nullable | |

**Validation rules**: an approve/reject decision is accepted only from a user
whose `role == required_role` (Principle III, via `require_roles`), and, for
`department_approver` steps, whose `team == PurchaseOrder.requester.team`.

## ExceptionRequest

| Field | Type | Notes |
|---|---|---|
| `id` | int, PK | |
| `purchase_order_id` | int, FK → PurchaseOrder.id | |
| `requested_by_id` | int, FK → User.id | must be the user whose step is blocked (FR-012) |
| `justification` | text, required | FR-012 |
| `urgency` | `ExceptionUrgency`, required | FR-012 |
| `expiry_at` | datetime, required | FR-012 |
| `status` | `ExceptionStatus`, default `pending` | |
| `decided_by_id` | int, FK → User.id, nullable | must be `procurement_lead` and `!= requested_by_id` (FR-013) |
| `decided_at` | datetime, nullable | |

**Validation rules**:
- `decided_by_id != requested_by_id` enforced in the service layer before
  commit — self-approval MUST be rejected regardless of role (FR-013).
- `decided_by` must currently hold `procurement_lead` (checked live, per
  FR-020 — not cached).
- `access_admin` is never a valid `decided_by` (FR-014), enforced by
  `require_roles(["procurement_lead"])` on the decision endpoint — structurally
  impossible, not just validated.
- A `pending` request whose `expiry_at < now()` is treated as `lapsed` on
  next read/decision attempt (Edge Cases).

**State transitions**: `pending → approved` (procurement_lead decision) →
sets `PurchaseOrder.approved_with_exception = true`, generates approval
outcome, writes `AuditLogEntry(exception_approved)` and
`AuditLogEntry(po_approved_with_exception)` (FR-015, two distinct entries:
the exception decision itself and the resulting PO flag, so each is
independently queryable). `pending → rejected` (procurement_lead decision).
`pending → lapsed` (system, on expiry).

## AuditLogEntry

Insert-only (constitution Principle II; research.md Decision 3).

| Field | Type | Notes |
|---|---|---|
| `id` | int, PK | |
| `entity_type` | str | `"purchase_order"` \| `"supplier"` \| `"user"` \| `"exception_request"` |
| `entity_id` | int | |
| `action_type` | `AuditActionType` | |
| `actor_id` | int, FK → User.id, nullable | null only for system-generated entries (e.g., exception auto-lapse) |
| `rationale` | text, required | human-readable "why" (Principle II) — e.g., `"Blocked: assessment stale (last assessed 214 days ago, staleness window 180 days)"` |
| `metadata_json` | JSON, nullable | structured detail, e.g. `{"prior_role": "requester", "new_role": "procurement_lead", "grantee_id": 42}` for `role_elevation` |
| `created_at` | datetime, server default now | |

**Validation rules**: no `UPDATE`/`DELETE` path exists anywhere in the
application (no router, no service function, performs either). DB-level
trigger (Postgres) and ORM event-listener guard (both dialects) are the
enforced backstop, not the primary control (research.md Decision 3).
**Multiple entries per PO per evaluation**: when several triggers fire on the
same submission (e.g., stale **and** compliance-floor failure), each
produces its own row with `entity_type="purchase_order"`,
`entity_id=<po.id>` — none is skipped or merged (FR-011).

## Relationships summary

```text
User 1---* PurchaseOrder (requester_id)
User 1---* ApprovalStep (decided_by_id, nullable)
User 1---* ExceptionRequest (requested_by_id)
User 1---* ExceptionRequest (decided_by_id, nullable)
User 1---* AuditLogEntry (actor_id, nullable)

Supplier 1---* PurchaseOrder (supplier_id)

PurchaseOrder 1---* ApprovalStep (purchase_order_id)
PurchaseOrder 1---* ExceptionRequest (purchase_order_id)
PurchaseOrder 1---* AuditLogEntry (entity_type="purchase_order", entity_id)
```

## Traceability: functional requirement → owning file

| Requirement(s) | Primary file |
|---|---|
| FR-001, FR-002, FR-003, FR-020 | `app/routers/auth.py`, `app/routers/users.py`, `app/auth.py` |
| FR-004 – FR-008 | `app/risk_engine.py` (pure computation), `app/models.py` (Supplier storage) |
| FR-009, FR-010 | `app/routers/purchase_orders.py` |
| FR-011 | `app/audit.py` + `app/routers/purchase_orders.py` (writes triggered by risk_engine output) |
| FR-012, FR-013, FR-014 (exception part) | `app/routers/exceptions.py` |
| FR-014 (Supplier/PO write ban) | enforced by absence of any `access_admin`-permitted route on `suppliers.py`/`purchase_orders.py` (research.md Decision 7) |
| FR-015 | `app/routers/exceptions.py`, `app/models.py` (`approved_with_exception`) |
| FR-016 | `app/routers/dashboard.py` |
| FR-017, FR-018, FR-019 | `app/routers/dashboard.py` (`GET /audit-log`), `require_roles` on every mutating router |
