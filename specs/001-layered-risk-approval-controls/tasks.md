---
description: "Task list for Layered Risk Model, Role Integrity & Controlled Exception Approval"
---

# Tasks: Layered Risk Model, Role Integrity & Controlled Exception Approval

**Input**: Design documents from `/specs/001-layered-risk-approval-controls/`

**Prerequisites**: plan.md, spec.md, data-model.md, contracts/, research.md, quickstart.md (all present)

**Tests**: Included. Constitution Principles I ("new/updated unit tests covering
every risk-tier threshold and every compliance-veto scenario") and V ("CI ...
MUST pass before any merge") make test tasks mandatory for this project, not
optional.

**Organization**: Tasks are grouped by user story (per spec.md priorities
P1-P4) to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Maps to spec.md user stories (US1-US5)
- File paths are exact, per plan.md's Project Structure

## Path Conventions

Single backend project at repository root: `app/`, `scripts/`, `tests/` (see
plan.md → Project Structure). No frontend in this plan (SwiftUI is a separate,
out-of-scope client).

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization — no application code yet.

- [X] T001 Create project skeleton directories/files: `app/__init__.py`,
      `app/routers/__init__.py`, `scripts/__init__.py`, `tests/__init__.py`
      per plan.md → Project Structure
- [X] T002 Create `requirements.txt` with fastapi, uvicorn[standard],
      sqlalchemy>=2.0, pydantic>=2.0, python-jose[cryptography],
      passlib[bcrypt], psycopg2-binary, pytest, httpx, python-multipart
- [X] T003 [P] Write `Dockerfile` (Python 3.11-slim base, install
      requirements.txt, uvicorn entrypoint)
- [X] T004 [P] Write `docker-compose.yml` with `app` and `postgres` services
      per plan.md Technical Context (Postgres for local/dev — research.md
      Decision 2), environment variables for `DATABASE_URL`, `JWT_SECRET`
- [X] T005 [P] Write `.github/workflows/ci.yml`: install requirements.txt,
      run `pytest` against SQLite (constitution Principle V — blocks merge
      on failure). Combined with T064: also includes a Postgres
      service-container job for `tests/test_audit_log_immutability.py`.
- [X] T006 [P] Write `.env.example` documenting `DATABASE_URL`, `JWT_SECRET`,
      `JWT_EXPIRE_MINUTES`

**Checkpoint**: Repo builds and runs `docker compose up` with an empty app.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core infrastructure every user story depends on — models, auth,
config, DB bootstrap, audit helper, test fixtures.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [X] T007 Define all enums and SQLAlchemy ORM models
      (`Role`, `SupplierStatus`, `RiskTier`, `POStatus`,
      `ApprovalControlStatus`, `ApprovalStepStatus`, `ExceptionUrgency`,
      `ExceptionStatus`, `AuditActionType`, `User`, `Supplier`,
      `PurchaseOrder`, `ApprovalStep`, `ExceptionRequest`, `AuditLogEntry`)
      in `app/models.py` per data-model.md
- [X] T008 [P] Implement `Settings` (pydantic-settings) in `app/config.py`:
      `JWT_SECRET`, `JWT_EXPIRE_MINUTES`, `DATABASE_URL`,
      `ASSESSMENT_STALENESS_DAYS`, `ESG_COMPLIANCE_FLOOR`,
      `HIGH_RISK_COUNTRIES`, `HIGH_RISK_CATEGORIES`,
      `PERFORMANCE_RISK_DELIVERY_THRESHOLD`, `PERFORMANCE_RISK_DEFECT_THRESHOLD`
      per research.md Decisions 4-6 and constitution Principle IV (named
      constants, no inline literals)
- [X] T009 Implement `app/database.py`: SQLAlchemy engine/session factory,
      `init_db()` calling `Base.metadata.create_all()`, and a Postgres-only
      (dialect-checked) raw-SQL `BEFORE UPDATE OR DELETE` trigger on
      `audit_log` per research.md Decision 3
- [X] T010 [P] Implement `app/auth.py`: password hashing (passlib),
      `create_access_token()`/`decode_access_token()` (python-jose, payload =
      `{sub, exp, iat}` only — no role claim, research.md Decision 10),
      `get_current_user()` dependency (reloads `User` from DB every call —
      FR-020), `require_roles(*roles)` dependency factory (constitution
      Principle III)
- [X] T011 [P] Implement `app/audit.py`: `write_audit_entry(db, entity_type,
      entity_id, action_type, actor_id, rationale, metadata=None)` helper,
      plus a SQLAlchemy `before_update`/`before_delete` event listener on
      `AuditLogEntry` that raises (app-level defense-in-depth per research.md
      Decision 3)
- [X] T012 Implement `app/main.py`: FastAPI app instantiation, startup event
      calling `database.init_db()`, router registration (routers added
      incrementally in later phases)
- [X] T013 [P] Implement `scripts/seed_access_admin.py`: CLI script
      (`--email`, `--password`) that creates a `User` with `role=access_admin`
      directly via the ORM, bypassing the registration endpoint (research.md
      Decision 9)
- [X] T014 [P] Implement `tests/conftest.py`: SQLite in-memory test DB
      fixture, FastAPI `TestClient` fixture, and per-role fixtures
      (`requester_token`, `department_approver_token` with a `team`,
      `procurement_lead_token`, `second_procurement_lead_token`,
      `access_admin_token`, `auditor_token`) that create users directly via
      the ORM (not through the role-elevation endpoint, to keep fixtures
      independent of US1's implementation)

**Checkpoint**: `app/main.py` boots, connects to DB, creates schema. No
routes exist yet. `pytest` collects `conftest.py` fixtures successfully.

---

## Phase 3: User Story 1 - Role Integrity and Controlled Elevation (Priority: P1) 🎯 MVP candidate

**Goal**: Self-registration can never grant a privileged role; only
access_admin can elevate roles; every elevation is audited.

**Independent Test**: Register accounts with varying role payloads (always
land as requester); attempt elevation as non-access_admin (rejected) and as
access_admin (succeeds, audited).

### Tests for User Story 1

- [X] T015 [P] [US1] Test: self-registration payload with `role:
      "access_admin"` (or any non-requester value) still creates a
      `requester` account, in `tests/test_role_integrity.py`
- [X] T016 [P] [US1] Test: role-elevation attempt by a non-access_admin
      caller returns `403`, in `tests/test_role_integrity.py`
- [X] T017 [P] [US1] Test: access_admin elevates a user; response reflects
      new role; an `AuditLogEntry(action_type="role_elevation")` exists with
      `grantor_id`, `grantee_id`, `prior_role`, `new_role` in
      `metadata_json`, in `tests/test_role_integrity.py`

### Implementation for User Story 1

- [X] T018 [US1] Add `UserRegisterRequest` (no `role` field, `model_config =
      {"extra": "ignore"}`), `UserResponse`, `RoleElevationRequest` schemas
      to `app/schemas.py`
- [X] T019 [US1] Implement `POST /auth/register` and `POST /auth/login` in
      `app/routers/auth.py` per contracts/auth.md (register always sets
      `role=Role.requester`)
- [X] T020 [US1] Implement `PATCH /users/{user_id}/role` in
      `app/routers/users.py` with `require_roles(["access_admin"])`,
      writing the audit entry via `app/audit.py`, per contracts/users.md
- [X] T021 [US1] Register `auth` and `users` routers in `app/main.py`

**Checkpoint**: Self-registration and role elevation are fully functional
and independently testable — no other story's code is required.

---

## Phase 4: User Story 2 - Layered Risk Assessment Drives Approval Control Status (Priority: P1)

**Goal**: Supplier risk is computed as three distinct layers combining into a
tier; assessment validity and approval control status are derived correctly
and drive PO submission gating, with every trigger independently audited.

**Independent Test**: Create suppliers with varying inputs/assessment ages;
verify computed tier, validity status, and control status; submit POs and
verify blocked-supplier/suspended-supplier rejection and multi-trigger audit
entries — no exception process or dashboard required.

### Tests for User Story 2

- [X] T022 [P] [US2] Unit tests for `compute_risk_tier()` covering every
      inherent/performance/compliance combination, including the "identical
      performance factors, different country/category → different tier"
      case, in `tests/test_risk_engine.py`
- [X] T023 [P] [US2] Unit tests for `compute_validity_status()` covering
      Current/Stale/Unassessed/Incomplete, in `tests/test_risk_engine.py`
- [X] T024 [P] [US2] Unit tests for `compute_approval_control_status()`
      covering Allowed/Conditional/Blocked/Escalated and the compliance-floor
      veto, asserting the exact branch order in research.md Decision 4b
      (Stale → Blocked, not Escalated), in `tests/test_risk_engine.py`
- [X] T025 [P] [US2] Integration test: PO creation against a `blocked`
      supplier returns `409` before any risk function is called (assert via
      mock/spy that `risk_engine` was not invoked), in
      `tests/test_purchase_orders.py`
- [X] T026 [P] [US2] Integration test: draft PO submission is rejected once
      its supplier becomes `suspended` after the PO was created, in
      `tests/test_purchase_orders.py`
- [X] T027 [P] [US2] Integration test: a supplier with a strong last-computed
      tier but an aged assessment blocks submission, and the audit entry's
      rationale names staleness distinctly from the tier, in
      `tests/test_purchase_orders.py`
- [X] T028 [P] [US2] Integration test: a PO whose supplier has both an ESG
      compliance-floor failure and a stale assessment produces two separate,
      non-overwriting `AuditLogEntry` rows on submission, in
      `tests/test_purchase_orders.py`

### Implementation for User Story 2

- [X] T029 [US2] Implement pure functions in `app/risk_engine.py`:
      `compute_inherent_risk`, `compute_performance_risk`,
      `compute_compliance_risk`, `compute_risk_tier` (worst-of-three,
      research.md Decision 5), `compute_validity_status`,
      `compliance_floor_failed`, `compute_approval_control_status`
      (branch order per research.md Decision 4b), `generate_approval_steps`
      (research.md Decision 6) — no DB/HTTP objects (constitution Principle I)
- [X] T030 [US2] Add `SupplierCreateRequest`, `SupplierUpdateRequest`,
      `SupplierResponse` schemas to `app/schemas.py`
- [X] T031 [US2] Implement `POST /suppliers`, `GET /suppliers`,
      `GET /suppliers/{id}`, `PATCH /suppliers/{id}` in
      `app/routers/suppliers.py` with `require_roles(["procurement_lead"])`
      on writes and `require_roles(["requester", "department_approver",
      "procurement_lead", "auditor"])` on reads (access_admin excluded from
      both — FR-014), recomputing `computed_risk_tier` on input changes, per
      contracts/suppliers.md
- [X] T032 [US2] Add `PurchaseOrderCreateRequest`, `PurchaseOrderResponse`,
      `TransitionRequest` schemas to `app/schemas.py`
- [X] T033 [US2] Implement `POST /purchase-orders`, `GET /purchase-orders`,
      `GET /purchase-orders/{id}`, `PATCH /purchase-orders/{id}` in
      `app/routers/purchase_orders.py` with the blocked-supplier
      pre-computation check (FR-009), per contracts/purchase-orders.md
- [X] T034 [US2] Implement the `submit` action of
      `POST /purchase-orders/{id}/transitions` in
      `app/routers/purchase_orders.py`: re-check supplier status (FR-010),
      call `risk_engine` functions, snapshot `approval_control_status` onto
      the PO, generate `ApprovalStep` rows, write one `AuditLogEntry` per
      triggered condition via `app/audit.py` (FR-011), per
      contracts/purchase-orders.md
- [X] T035 [US2] Register `suppliers` and `purchase_orders` routers in
      `app/main.py`

**Checkpoint**: Risk computation and submission-time gating are fully
functional and independently testable.

---

## Phase 5: User Story 3 - Controlled Exception Process for Blocked POs (Priority: P2)

**Goal**: A blocked PO can only proceed via a non-self-approved exception
request decided by a different procurement_lead; access_admin can never
approve anything or write Supplier/PurchaseOrder data.

**Independent Test**: Take a PO already Blocked (via US2), exercise the
exception submit/approve/reject flow — independent of the dashboard (US4).

### Tests for User Story 3

- [X] T036 [P] [US3] Test: a procurement_lead who submitted an exception
      request cannot approve their own request (`403`), in
      `tests/test_exceptions.py`
- [X] T037 [P] [US3] Test: a different procurement_lead approves a
      department_approver's exception request; the PO becomes `approved`
      with `approved_with_exception=true`; both `exception_approved` and
      `po_approved_with_exception` audit entries exist, in
      `tests/test_exceptions.py`
- [X] T038 [P] [US3] Test: access_admin cannot approve a PO, an approval
      step, or an exception request (`403` on each), in
      `tests/test_exceptions.py`
- [X] T039 [P] [US3] Test: access_admin cannot directly edit a Supplier or a
      PurchaseOrder record (`403`), in `tests/test_purchase_orders.py`

### Implementation for User Story 3

- [X] T040 [US3] Implement the `approve`/`reject`/`cancel` actions of
      `POST /purchase-orders/{id}/transitions` in
      `app/routers/purchase_orders.py`: match caller role/team against the
      current `ApprovalStep.required_role`, advance or resolve the PO, per
      contracts/purchase-orders.md
- [X] T041 [US3] Add `ExceptionRequestCreate`, `ExceptionDecisionRequest`,
      `ExceptionRequestResponse` schemas to `app/schemas.py`
- [X] T042 [US3] Implement `POST /exception-requests` in
      `app/routers/exceptions.py` with `require_roles(["requester",
      "department_approver", "procurement_lead"])`, rejecting non-blocked
      POs, per contracts/exceptions.md
- [X] T043 [US3] Implement `POST /exception-requests/{id}/decision` in
      `app/routers/exceptions.py` with `require_roles(["procurement_lead"])`,
      self-approval check, expiry/lapse check, dual audit-entry write on
      approval, per contracts/exceptions.md
- [X] T044 [US3] Register `exceptions` router in `app/main.py`

**Checkpoint**: Blocked POs have a controlled, auditable path forward;
access_admin is structurally barred from all approval and business-data
write paths.

---

## Phase 6: User Story 4 - Role-Scoped Reporting Dashboard (Priority: P3)

**Goal**: Each role sees exactly the visibility spec.md assigns it — no more,
no less.

**Independent Test**: Seed PO/exception/risk/role-elevation data and call
each role's dashboard view — independent of the auditor role (US5).

### Tests for User Story 4

- [X] T045 [P] [US4] Test: requester's `GET /dashboard` returns only their
      own POs, never another user's, in `tests/test_dashboard.py`
- [X] T046 [P] [US4] Test: department_approver's dashboard is scoped to
      their `team` and includes pending-approval aging, in
      `tests/test_dashboard.py`
- [X] T047 [P] [US4] Test: procurement_lead's dashboard returns all
      documented aggregate KPIs (blocked-creation attempts, exception
      counts/reasons, stale/unassessed exposure, tier distribution, avg
      approval time by tier, pending-approval aging), in
      `tests/test_dashboard.py`
- [X] T048 [P] [US4] Test: access_admin's dashboard returns the
      role-elevation log (grantor/grantee/prior/new role/timestamp) and no
      business-risk KPI fields, in `tests/test_dashboard.py`

### Implementation for User Story 4

- [X] T049 [US4] Add `RequesterDashboard`, `ApproverDashboard`,
      `ProcurementLeadDashboard`, `AccessAdminDashboard` response schemas to
      `app/schemas.py`
- [X] T050 [US4] Implement `GET /dashboard` in `app/routers/dashboard.py`
      with `require_roles(["requester", "department_approver",
      "procurement_lead", "access_admin"])` (auditor added in Phase 7),
      dispatching query/response shape by `caller.role`, per
      contracts/dashboard-audit.md
- [X] T051 [US4] Register `dashboard` router in `app/main.py`

**Checkpoint**: All four non-auditor roles see correctly scoped dashboard
data.

---

## Phase 7: User Story 5 - Read-Only Auditor Access (Priority: P4 — first to cut if time-constrained)

**Goal**: Auditor sees everything (dashboard KPIs + full audit trail) but can
mutate nothing, anywhere, provably.

**Independent Test**: Authenticate as auditor; call every mutating endpoint
individually (all rejected) and both read endpoints (both succeed) —
independent of all other stories being "done" in the sense of having real
data (fixtures suffice).

### Tests for User Story 5

- [X] T052 [P] [US5] Parametrized test asserting `403` for an auditor caller
      on each mutating endpoint individually — PO creation, PO submission,
      approval-step decision, exception request, exception decision,
      supplier status change, role elevation — in `tests/test_dashboard.py`
      (per spec US5: verified individually, not as one representative
      example). **Extended** after an independent audit found two more
      mutating endpoints (`POST /suppliers`, `PATCH /purchase-orders/{id}`)
      existed but were untested for this property: now 9 parametrized cases,
      not 7 — see `contracts/dashboard-audit.md`'s updated matrix.
- [X] T053 [P] [US5] Test: auditor's `GET /dashboard` returns the same
      aggregate shape as `ProcurementLeadDashboard`, in
      `tests/test_dashboard.py`
- [X] T054 [P] [US5] Test: auditor's `GET /audit-log` returns full audit
      history including `role_elevation` entries, in
      `tests/test_dashboard.py`

### Implementation for User Story 5

- [X] T055 [US5] Add `"auditor"` to `GET /dashboard`'s `require_roles(...)`
      and dispatch auditor to the same response path as procurement_lead, in
      `app/routers/dashboard.py`
- [X] T056 [US5] Implement `GET /audit-log` in `app/routers/dashboard.py`
      with `require_roles(["auditor"])` and optional `entity_type`/
      `entity_id`/`action_type` query filters, per
      contracts/dashboard-audit.md
- [X] T057 [US5] Audit every mutating router (`purchase_orders.py`,
      `exceptions.py`, `suppliers.py`, `users.py`) to confirm `"auditor"` is
      absent from every `require_roles(...)` call — fix any omission found

**Checkpoint**: Segregation of duties for auditor is structurally provable,
not just asserted.

---

## Phase 8: Polish & Cross-Cutting Concerns

**Purpose**: Constitution-mandated verification passes and final CI wiring.

- [~] T058 [P] Manually walk through every scenario in
      `specs/001-layered-risk-approval-controls/quickstart.md` against a
      running `docker compose` stack. **PARTIAL**: Docker is not available in
      this implementation environment, so the literal `docker compose`
      stack was never exercised. Substitute verification performed instead:
      booted the app with real `uvicorn` (not the test client) against a
      fresh SQLite DB and walked through Scenarios 1-6 via `curl` end-to-end
      (self-registration role-ignore, role elevation + non-admin rejection,
      unassessed-supplier blocking with audit trail, auditor full
      audit-log read + mutating-endpoint rejection, and all four dashboard
      shapes) — all behaved as documented. Docker packaging itself
      (`Dockerfile` build, `docker-compose.yml` networking) is unverified;
      re-run this task for real before treating the container packaging as
      trustworthy.
- [~] T059 [P] Run the full `pytest` suite against Postgres (via
      docker-compose), not just CI's SQLite, to confirm native-enum
      behavior matches SQLite's check-constraint behavior (research.md
      Decision 2). **NOT DONE**: no local Postgres or Docker available in
      this environment. The Postgres-only paths (`app/database.py`'s
      dialect-checked trigger install, native `ENUM` behavior) are
      currently verified only by the CI job added in T064, which has not
      itself been run yet (requires pushing to GitHub Actions). Treat this
      as outstanding until CI has actually run green on Postgres at least
      once.
- [X] T060 Review `app/routers/*.py` to confirm every mutating route
      declares `require_roles(...)` at the route decorator and contains no
      inline `if role == ...` access-control branching (constitution
      Principle III). **Correction**: the first completion pass of this task
      was incomplete — it fixed `list_purchase_orders`/`get_purchase_order`'s
      coarse role gate but missed two 403-raising inline role comparisons
      found later by an independent audit (`purchase_orders.py`'s
      `get_purchase_order` ownership check and `_do_approve_or_reject`'s
      step-role check). Both are now resolved: the ownership check is
      `get_visible_purchase_order`, a named `Depends(...)` dependency
      (fully satisfies Principle III's literal mechanism); the step-role
      check is `_require_step_authority`, a documented, disclosed exception
      (research.md Decision 11) since the required role is a per-resource
      runtime DB value, not a static set. `grep -rn "\.role !=" app/` and
      `grep -rn "caller\.role ==" app/` now resolve to exactly these two,
      accounted-for locations — verified by direct grep, not asserted.
- [X] T061 Review `app/risk_engine.py` and `app/config.py` to confirm no
      business-rule literal (threshold, weight, floor) is hardcoded outside
      `Settings` (constitution Principle IV). Confirmed clean — the only
      inline numeric literals in `risk_engine.py` are `_TIER_SEVERITY`'s
      0/1/2 ordinal ranking (an internal enum-ordering convention, not a
      configurable business threshold) and a `== 0` field-count check, both
      outside Principle IV's scope.
- [X] T062 Confirm `.github/workflows/ci.yml` blocks merge on any `pytest`
      failure and runs on every pull request (constitution Principle V)

### Remediation tasks (added post-`/speckit-analyze`)

- [X] T063 [Foundational] Test: attempting to `UPDATE` or `DELETE` an
      `AuditLogEntry` row raises via the SQLAlchemy event-listener guard, in
      `tests/test_audit_log_immutability.py` (verifies T011; closes analysis
      finding E1)
- [X] T064 [P] Add a Postgres service-container job to
      `.github/workflows/ci.yml` running
      `tests/test_audit_log_immutability.py` against Postgres to verify the
      `BEFORE UPDATE OR DELETE` trigger (verifies T009; closes analysis
      findings C1 and E1; see research.md Decision 3 Resolution)
- [X] T065 [US1] Test: a user's role is elevated mid-session; their next
      request under the same still-valid JWT reflects the new role's
      permissions without re-login, in `tests/test_role_integrity.py`
      (verifies T010/FR-020; closes analysis finding E2)
- [X] T066 [US3] Test: `POST /exception-requests` missing `justification`,
      `urgency`, or `expiry_at` returns `400`, in `tests/test_exceptions.py`
      (verifies FR-012; closes analysis finding E3)

**Placement note**: these were appended after the original numbering to
avoid renumbering T001-T062. Logically, T063 belongs at the end of Phase 2,
T064 belongs in Phase 1/8 (CI config), T065 belongs in Phase 3, and T066
belongs in Phase 5 — run them alongside those phases, not strictly after T062.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies.
- **Foundational (Phase 2)**: Depends on Setup. Blocks all user stories.
- **US1 (Phase 3, P1)**: Depends only on Foundational.
- **US2 (Phase 4, P1)**: Depends only on Foundational. Independent of US1
  (both P1; can be built in either order or in parallel by different
  developers).
- **US3 (Phase 5, P2)**: Depends on Foundational + US2 (needs `Blocked`
  control status and `ApprovalStep` routing to exist to have something to
  submit an exception against).
- **US4 (Phase 6, P3)**: Depends on Foundational. Fully testable with seeded
  fixtures independent of US1-US3's routers; a *populated* dashboard in
  practice requires US1 (role-elevation log), US2 (risk KPIs), and US3
  (exception KPIs) to have produced real data.
- **US5 (Phase 7, P4)**: Depends on Foundational + US4 (extends the same
  `GET /dashboard` dispatch and reuses its response shape for the auditor
  case). First candidate to drop under time pressure — nothing depends on it.
- **Polish (Phase 8)**: Depends on all implemented stories.

### Within Each User Story

- Tests are written first and MUST fail before implementation begins.
- Pure functions (`risk_engine.py`) before routers that call them.
- Schemas before the routers that use them.
- Models (Foundational) before any story-specific code.

### Parallel Opportunities

- All Setup tasks marked [P] (T003-T006) run in parallel.
- Within Foundational, T008, T010, T011, T013, T014 run in parallel once
  T007 (models) is done; T009 depends on T007.
- US1 and US2 can be implemented in parallel by different developers once
  Foundational is complete (no file overlap: US1 touches
  `routers/auth.py`/`routers/users.py`; US2 touches
  `routers/suppliers.py`/`routers/purchase_orders.py`/`risk_engine.py`).
- All test tasks marked [P] within a story run in parallel (same file,
  different test functions — safe as long as fixtures in `conftest.py` don't
  share mutable state across tests).

---

## Parallel Example: User Story 2

```bash
# Tests (after Foundational is complete):
Task: "Unit tests for compute_risk_tier() in tests/test_risk_engine.py"
Task: "Unit tests for compute_validity_status() in tests/test_risk_engine.py"
Task: "Unit tests for compute_approval_control_status() in tests/test_risk_engine.py"
Task: "Integration test: blocked-supplier PO creation rejected in tests/test_purchase_orders.py"
Task: "Integration test: suspended-supplier draft submission rejected in tests/test_purchase_orders.py"
Task: "Integration test: stale assessment blocks with distinct audit entry in tests/test_purchase_orders.py"
Task: "Integration test: multi-trigger PO produces separate audit entries in tests/test_purchase_orders.py"
```

---

## Implementation Strategy

### MVP First (User Stories 1 + 2)

1. Complete Phase 1: Setup.
2. Complete Phase 2: Foundational (blocks everything).
3. Complete Phase 3 (US1) and Phase 4 (US2) — together, these are the
   minimum viable slice: trustworthy roles + real risk-based blocking. A PO
   can already be correctly blocked/allowed at this point, even though
   Blocked POs have no way forward yet (that's US3).
4. **STOP and VALIDATE**: run quickstart.md Scenarios 1-3.

### Incremental Delivery

1. Setup + Foundational → foundation ready.
2. US1 + US2 → role integrity and risk-based gating demonstrable (MVP).
3. US3 → blocked POs have a controlled way forward (exception process).
4. US4 → role-scoped visibility into everything above.
5. US5 → auditor read-only proof of segregation of duties (drop first if
   short on time — no other story depends on it, per spec).

### Suggested Cut Line Under Time Pressure

Per spec.md's own priority ordering: if the 2-4 week timeline is tight, ship
through US4 and drop US5 entirely (spec explicitly calls this out as
"backend-only... first item to drop"). Do not drop US1 or US2 — every other
story's guarantees assume role integrity and real risk-based control status
exist.
