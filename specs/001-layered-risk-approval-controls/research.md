# Phase 0 Research: Layered Risk Model, Role Integrity & Controlled Exception Approval

All Technical Context fields were fixed by explicit user direction (FastAPI +
SQLAlchemy + PostgreSQL/SQLite + JWT + pytest + Docker + GitHub Actions), so
there are no technology-choice unknowns to research. What remains are design
decisions where the spec is intentionally silent on mechanism (by design — it
is technology-agnostic) and a concrete choice must be made to reach
SQLAlchemy/Pydantic/endpoint level. Each is recorded below as Decision /
Rationale / Alternatives considered.

## Decision 1: No migration tool — `Base.metadata.create_all()` only

**Decision**: Schema is created by calling `Base.metadata.create_all(engine)`
at application startup (in `app/database.py`). No Alembic, no migration
history table.

**Rationale**: Explicit user/project decision for a portfolio-timeline
project against a disposable dev/demo database. Documented here as the
constitution's Principle VI (Scope Discipline) calls for recording deliberate
simplifications rather than working around their absence silently.

**Alternatives considered**: Alembic — rejected as explicitly out of scope by
the user; would add migration-authoring overhead disproportionate to a
2-4 week portfolio project with no production data to preserve across schema
changes.

**Consequence carried into data-model.md**: Because there is no migration
path, every new column must have an application-level default (not a
DB-generated backfill), so the *first* creation of the schema is also its
only creation — there is no "existing rows" backfill concern in a genuinely
greenfield schema. This is noted explicitly per-field in data-model.md so it
stays true if the schema evolves later.

## Decision 2: PostgreSQL for dev/local, SQLite for CI (asymmetric, intentional)

**Decision**: `docker-compose.yml` runs the app against Postgres for local
development and manual/demo use. GitHub Actions CI runs `pytest` against
SQLite (file-based, created fresh per run) for speed.

**Rationale**: This feature introduces several enum-typed columns (`role`,
supplier `status`, `computed_risk_tier`, PO `status`, `approval_control_status`,
exception `status`/`urgency`, audit `action_type`). SQLAlchemy's `Enum` type
maps to a native Postgres `ENUM` (or `CHECK` constraint) locally, giving real
enum-violation errors; SQLite enforces only a `CHECK` constraint (via
SQLAlchemy's non-native fallback), which is weaker but still present — CI
still catches invalid-value bugs, just not with the same fidelity as a native
Postgres type. This is an explicit user decision, not an oversight.

**Alternatives considered**: SQLite everywhere (rejected — hides enum-fidelity
bugs, explicitly called out by the user); Postgres in CI via a service
container (acknowledged as a valid stretch item, deliberately deferred to
keep CI fast for this timeline; can be added later without changing any
application code, since SQLAlchemy already targets both dialects).

## Decision 3: `audit_log` insert-only enforcement — Postgres trigger + app-level guard

**Decision**: `app/database.py`, after `create_all()`, executes a raw-SQL
block **only when connected to Postgres** (dialect check) that creates a
`BEFORE UPDATE OR DELETE` trigger on `audit_log` which raises an exception,
blocking both operations at the database level. Additionally, a SQLAlchemy
ORM event listener (`before_update`, `before_delete` on `AuditLogEntry`)
raises an application-level exception as defense-in-depth and to give a
useful error message pre-flight.

**Rationale**: Constitution Principle II requires insert-only enforcement "at
the database level ... not merely by application-layer convention." A trigger
satisfies that literally in the Postgres environment that is now this
project's actual dev/deploy target (Decision 2). SQLite (CI) has no
equivalent trigger mechanism, so in CI the guarantee is enforced only at the
ORM event-listener level; this is documented explicitly as an accepted gap in
CI fidelity, consistent with the same Postgres/SQLite asymmetry already
established for enum handling.

**Alternatives considered**: Revoked `UPDATE`/`DELETE` grants — rejected
because the app connects with a single role that also needs `INSERT`, and
Postgres grants are all-or-nothing per statement type per role; a trigger
gives a precise, table-scoped guarantee without a second DB role/credential
to manage (which would be disproportionate infrastructure for this project).

**Resolution (post-`/speckit-analyze`)**: The accepted CI gap above was
flagged CRITICAL by analysis — constitution Principle II requires DB-level
enforcement unconditionally, and CI (SQLite, the actual merge-gating
environment per Principle V) was only meeting that bar at the application
layer. Resolution: promote the Postgres CI job from "stretch item" (Decision
2's Alternatives Considered) to **required**, scoped narrowly. CI now runs
two jobs: (a) the full `pytest` suite against SQLite (fast, unchanged), and
(b) a second job running only `tests/test_audit_log_immutability.py` against
a Postgres service container, specifically to verify the `BEFORE UPDATE OR
DELETE` trigger fires. This keeps most PRs fast while giving Principle II's
DB-level guarantee real CI coverage instead of relying solely on the
SQLite-only app-level guard. See tasks.md T064.

## Decision 4: Risk tier and validity/control status are computed live, not stored as static columns

**Decision**: `Supplier` stores raw risk **inputs** (country, category,
delivery_reliability_score, defect_rate, esg_rating, sanctions_flag,
assessed_at) plus a **cached** `computed_risk_tier`, recomputed by
`risk_engine.compute_risk_tier(...)` and written back to the row whenever
inputs change. `assessment_validity_status` and `approval_control_status` are
**not** stored on `Supplier` — they are pure functions of the stored inputs
plus the current time (`risk_engine.compute_validity_status(supplier, now)`),
computed at the moment a PO is submitted. The result is then snapshotted
(fixed) onto the `PurchaseOrder` row and expanded into one or more
`AuditLogEntry` rows.

**Rationale**: `assessment_validity_status` depends on `now - assessed_at`,
so a stored value would itself go stale the instant it's written, silently
reintroducing the exact "poor score vs. untrustworthy data" conflation
Principle I and FR-006 exist to prevent. Computing it live from stored inputs
keeps it deterministic and testable as a pure function (Principle I), while
still being "tracked... as a field independent from the computed risk tier"
functionally — the independence FR-006 requires is about the two concepts
never being conflated in the decision logic, not about literal column count.
The point-in-time snapshot lives where mutability actually matters: the PO
record (fixed at submission) and the immutable audit trail.

**Alternatives considered**: Storing `assessment_validity_status` as a column,
recomputed by a scheduled job — rejected as unnecessary infrastructure
(cron/scheduler) for a portfolio-scope project, and it would still be stale
between job runs, so it doesn't actually satisfy "current" any better than
computing on read.

## Decision 4b: Approval control status branching rule

**Decision**: `compute_approval_control_status(tier, validity,
compliance_floor_failed)` resolves in this fixed order (first match wins):

1. `validity ∈ {unassessed, incomplete}` → `Blocked`
2. `compliance_floor_failed` → `Blocked`
3. `validity == stale` → `Blocked`
4. `validity == current` and `tier == low` → `Allowed`
5. `validity == current` and `tier == medium` → `Conditional`
6. `validity == current` and `tier == high` → `Escalated`

**Rationale**: Decision 6 below defines the step-plan *for* each control
status, but analysis found that the mapping *into* each status — the actual
branching logic — was never enumerated anywhere, leaving `Escalated` vs.
`Blocked` for a stale assessment ambiguous (spec.md US2 AC5 permits either
wording-wise). This decision makes the rule single-outcome and deterministic:
`Stale` is treated the same as `Unassessed`/`Incomplete` (`Blocked`), not
`Escalated` — untrustworthy data is a stronger signal than "this data says
high risk," so it should never be able to *escalate* past a normal review
path instead of blocking outright. `Escalated` is reserved for the case where
the data **is** trustworthy (`Current`) and still says `High` risk.

**Alternatives considered**: Letting `Stale` produce `Escalated` instead of
`Blocked` — rejected because it would let a supplier whose last known score
happened to be favorable route through a *lighter* touch (single
procurement_lead step, Decision 6) than a merely-conditional supplier, which
inverts the intent of treating staleness as a control failure.

## Decision 5: Risk tier aggregation rule — worst-of-three, not weighted average

**Decision**: `compute_risk_tier(inherent, performance, compliance)` returns
the **highest-severity** of the three per-layer levels (each layer itself
resolves to Low/Medium/High). A single High-severity layer makes the overall
tier High, regardless of the other two layers.

**Rationale**: Spec requires "two suppliers with identical performance-risk
factors but different country or category ... can land in different computed
tiers" — worst-of-three satisfies this directly and deterministically. A
weighted-average scheme would also satisfy that acceptance scenario, but
would let a severe single-layer risk (e.g., sanctions exposure) be diluted by
two clean layers — the opposite of what "compliance risk (ESG rating vs. the
compliance floor)" as a **floor** concept implies. Worst-of-three is also
simpler to unit-test exhaustively (Principle I/V), since every tier-threshold
combination maps to one deterministic branch instead of a continuous score
space.

**Alternatives considered**: Weighted sum with tier cutoffs — rejected per
above; kept available as a config-driven extension point in `Settings` if a
future iteration wants it (not built now — Principle VI, YAGNI).

## Decision 6: Approval control status → step-plan mapping

**Decision**:
- `Blocked` → zero approval steps generated; the PO cannot proceed without a
  successful exception request (User Story 3).
- `Allowed` → one step: `department_approver`.
- `Conditional` → two steps: `department_approver`, then `procurement_lead`.
- `Escalated` → one step, `procurement_lead` only (skips department_approver
  — severity routes directly to the highest independent authority).

**Rationale**: Gives `Conditional` and `Escalated` visibly different
behavior (otherwise they'd be indistinguishable in practice, undermining the
point of a 4-value control status). Routing `Escalated` straight to
`procurement_lead` matches real-world practice of skipping intermediate
review when a case is already known to be high-severity, and keeps the step
model simple (ordered list of required roles) for a portfolio-scope build.

**Alternatives considered**: Same two-step plan for both `Conditional` and
`Escalated`, distinguished only by a flag — rejected because it would make
"Escalated" purely cosmetic in the routing engine, weakening the "dynamic
approval pathway" the whole feature exists to demonstrate.

## Decision 7: Supplier risk-data ownership (mutation rights)

**Decision**: `procurement_lead` is the only role permitted to create/update
`Supplier` records (including risk-layer inputs and `status`). Spec does not
name this role explicitly for supplier mutation, but does explicitly exclude
`access_admin` from any Supplier/PurchaseOrder write access (FR-014), and
positions `procurement_lead` as "the system's highest independent approval
authority" for business risk decisions.

**Rationale**: Reasonable default per spec-writing guidance (no reasonable
alternative interpretation changes scope/security meaningfully) — assigning
supplier data ownership to the role already responsible for the business risk
domain avoids inventing a new role or giving write access to `requester`/
`department_approver`, which would let the party requesting or first-line
approving a PO also control the risk inputs that gate it (a segregation-of-
duties problem the rest of the spec goes out of its way to avoid elsewhere).

**Alternatives considered**: A dedicated `risk_analyst` role — rejected,
out of scope per spec's explicit five-role list.

## Decision 8: Team scoping for `department_approver` dashboard

**Decision**: `User` gets an optional `team` string column. A
`PurchaseOrder`'s effective team is its requester's `team` at creation time.
A `department_approver`'s dashboard query filters POs (and derived KPIs) to
`requester.team == self.team`.

**Rationale**: Spec requires department_approver to see "team/queue-level
KPIs" but does not define what a team is — simplest structure that makes the
requirement testable without inventing an organizational hierarchy the spec
elsewhere explicitly says is out of scope.

**Alternatives considered**: A full `Team` entity with membership rows —
rejected as disproportionate (Principle VI) for a single string-based scoping
need.

## Decision 9: First `access_admin` bootstrap

**Decision**: `scripts/seed_access_admin.py`, run manually (`docker compose
run app python -m scripts.seed_access_admin`) or once in CI setup before
tests that need an access_admin fixture. Not exposed as an HTTP endpoint.

**Rationale**: Matches the spec's own Assumption that first-access_admin
provisioning is out-of-band. Keeping it a script (not an endpoint) means
FR-002's "only access_admin may elevate roles" has no bypass route reachable
over HTTP.

**Alternatives considered**: A one-time "first user becomes access_admin"
rule — rejected; it's an implicit, easy-to-forget special case exactly of the
kind Principle IV/role-integrity design tries to avoid, and it would create
an unintended privilege-escalation race (whoever registers first wins).

## Decision 10: JWT carries identity only; role is re-read from the database every request

**Decision**: The JWT payload contains only `sub` (user id) and standard
claims (`exp`, `iat`). `auth.get_current_user()` decodes the token, then
loads the `User` row fresh from the database on every request. Nothing about
role is trusted from the token.

**Rationale**: Directly satisfies FR-020 ("evaluate a caller's role from
current, authoritative role state on every request, not from a value cached
at authentication time") and the edge case about a just-demoted user's next
request being rejected. A role claim embedded in the JWT would only be
refreshed on next login, reopening exactly the gap FR-020 exists to close.

**Alternatives considered**: Short-lived tokens + role-in-claim (re-login
every few minutes) — rejected as needless UX complexity when a DB read per
request is already required (the app is not at a scale where this is a
performance concern — Principle VI).

## Decision 11: Dynamic per-step authorization is a documented, disclosed exception to Principle III's static dependency-list form

**Decision**: `app/routers/purchase_orders.py`'s `_require_step_authority()`
checks whether the caller's role matches the *current* `ApprovalStep`'s
`required_role` (and, for a `department_approver` step, whether the caller's
`team` matches the requester's `team`). This check is implemented as an
inline role/team comparison inside a single, named function — not as a
`require_roles(...)` dependency at route declaration.

**Rationale**: constitution Principle III requires permitted roles to be
declared "through a role-validation dependency ... at the route
declaration," which by construction requires the permitted-role set to be
knowable statically, at import time. `POST /purchase-orders/{id}/transitions`
serves `submit`, `cancel`, `approve`, and `reject` through one route, and for
`approve`/`reject` specifically, the only role legitimately allowed to
decide *this* PO's *current* step is a value stored on that PO's
`ApprovalStep` row — it varies per request and is unknowable until the
database is read. No static `require_roles(...)` list can express "whichever
role this specific row currently requires." This was found undisclosed
during a `/speckit-analyze`-style audit (see also the analogous, already-
disclosed reasoning in `contracts/purchase-orders.md`'s transitions
contract) and is recorded here explicitly rather than left as a silent gap:
the check is centralized in exactly one named function
(`_require_step_authority`), which is what Principle III's rationale
("auditable in one place instead of scattered across handlers") actually
protects against — scattering, not the literal mechanism.

**Alternatives considered**: Splitting `approve`/`reject` into their own
routes per possible required role (e.g. separate department-approver and
procurement-lead endpoints) so each could carry its own static
`require_roles(...)` — rejected as it would require the client to know in
advance which step-role is current (defeating the point of a single
transitions endpoint) and would multiply endpoints for a distinction that is
actually a data value, not a routing concern.

Similarly, `get_purchase_order`'s ownership narrowing (a `requester` may only
read their own PO) is implemented as `get_visible_purchase_order`, a named
FastAPI dependency — this one **is** expressed as a `Depends(...)` at route
declaration, so it fully satisfies Principle III's literal mechanism as well
as its rationale, unlike Decision 11's step-authority case above.
