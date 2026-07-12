# Implementation Plan: Layered Risk Model, Role Integrity & Controlled Exception Approval

**Branch**: `001-layered-risk-approval-controls` | **Date**: 2026-07-11 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/001-layered-risk-approval-controls/spec.md`

**Note**: This project has no pre-existing `app/` codebase, tests, or `docker-compose.yml`.
Per explicit direction, this plan designs the baseline PO CRUD/models/auth/risk-engine
**and** the layered-risk/role-integrity/exception/dashboard features together, in one
pass — there is no separate prior baseline implementation to preserve or diff against.
Every functional requirement below is therefore mapped to the file that will
**contain** it (not one it "extends" from prior code).

## Summary

Extend a from-scratch FastAPI + SQLAlchemy PO approval service with: (1) role
integrity (server-controlled self-registration and role elevation), (2) a
three-layer supplier risk model (inherent/performance/compliance) that produces
a cached risk tier, (3) live-computed assessment validity and approval control
status that gate PO submission and are snapshotted onto the PO and into an
insert-only audit log at submission time, (4) a controlled exception process
for Blocked POs requiring a non-self procurement_lead approval, and (5) a
role-scoped dashboard (including an access_admin-only role-elevation view and
an auditor-only full audit-trail view). All business-rule computation lives in
pure functions in `app/risk_engine.py`; all mutating endpoints declare
permitted roles via a `require_roles(...)` dependency; all business-rule
constants live in `app/config.py`.

## Technical Context

**Language/Version**: Python 3.11+

**Primary Dependencies**: FastAPI, SQLAlchemy 2.x, Pydantic v2, python-jose
(JWT), passlib[bcrypt] (password hashing), uvicorn, psycopg2-binary (Postgres
driver), pytest, httpx (FastAPI TestClient)

**Storage**: PostgreSQL 15 (local dev and deployed, via `docker-compose.yml`)
for schema fidelity on enum/constraint columns; SQLite (file or in-memory) in
GitHub Actions CI for test speed. This asymmetry is an explicit, documented
project decision (see research.md, Decision 2) — not an oversight.

**Testing**: pytest, run against SQLite in CI; the same suite is runnable
locally against Postgres via docker-compose.

**Target Platform**: Linux container (Docker), deployed as a single backend
service. SwiftUI client is a separate, independently-deployed consumer and is
explicitly out of scope for this plan.

**Project Type**: web-service (backend only)

**Performance Goals**: None specified beyond "responsive for a single-tenant
portfolio demo dataset" (tens of suppliers, hundreds of POs). Per constitution
Principle VI (Scope Discipline), no load/performance engineering is in scope.

**Constraints**:
- No schema migration tool (no Alembic). Schema is created via SQLAlchemy
  `Base.metadata.create_all()` against a disposable dev/demo database — a
  documented simplification (research.md, Decision 1), consistent with
  constitution Principle VI.
- Audit log table (`audit_log`) MUST be insert-only at the database level
  (constitution Principle II) — addressed via a Postgres trigger plus an
  application-level SQLAlchemy event-listener guard (research.md, Decision 3).

**Scale/Scope**: Single small organization, five roles, portfolio-timeline
project (2-4 weeks per constitution Principle VI).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Check | Status |
|---|---|---|
| I. Business Logic Purity | All risk-tier, validity-status, and control-status computation lives in pure functions in `app/risk_engine.py` (no DB session, no HTTP objects passed in). Every new/changed threshold ships with unit tests covering all tiers and veto scenarios (see tasks.md, Phase 3). | PASS |
| II. Audit Traceability | Every PO status change, exception decision, and role elevation writes an `audit_log` row with a human-readable rationale. `audit_log` is insert-only, enforced at the DB level via a Postgres trigger, verified in CI via a dedicated Postgres-service-container job (not just the SQLite suite) — see research.md, Decision 3. | PASS |
| III. Permissions as Code | Every mutating endpoint declares its allowed roles via a `require_roles([...])` FastAPI dependency at route declaration (see contracts/). One documented, disclosed exception: the transitions endpoint's per-step approve/reject authorization is a per-resource dynamic check (the required role is a runtime DB value, not statically knowable), centralized in one named function rather than a dependency-list — see research.md Decision 11. | PASS (one disclosed exception) |
| IV. No Magic Numbers | All thresholds (staleness window, ESG compliance floor, high-risk country/category lists, performance-risk cutoffs) are named constants on the `Settings` object in `app/config.py`. | PASS |
| V. Testing as a Merge Threshold | CI (GitHub Actions) runs the full `pytest` suite against SQLite on every PR; merge is blocked on failure (see tasks.md, CI setup task). | PASS |
| VI. Scope Discipline | Every entity/endpoint below maps to a functional requirement in spec.md, which itself maps to demonstrating REST design, relational modeling, auth, testing, CI/CD, and containerization. No speculative features added. | PASS |
| VII. Front-End/Back-End Alignment | Out of scope for this plan (SwiftUI client excluded), but `app/schemas.py` is designed as the single response-shape source of truth the client will consume later. | PASS (deferred) |
| Tech stack fixed (Constitution "Technology & Architecture Constraints") | FastAPI + SQLAlchemy + PostgreSQL + JWT, as mandated. No alternative stack considered. | PASS |

No violations. Complexity Tracking table below is intentionally empty.

## Project Structure

### Documentation (this feature)

```text
specs/001-layered-risk-approval-controls/
├── plan.md              # This file (/speckit-plan command output)
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
│   ├── auth.md
│   ├── users.md
│   ├── suppliers.md
│   ├── purchase-orders.md
│   ├── exceptions.md
│   └── dashboard-audit.md
└── tasks.md              # Phase 2 output (/speckit-tasks — not created by /speckit-plan)
```

### Source Code (repository root)

```text
app/
├── main.py                 # FastAPI app instantiation, router registration, startup hook (create_all + trigger install)
├── config.py                # Settings: risk weights/thresholds, staleness window, ESG floor, JWT secret/expiry (Principle IV)
├── database.py               # Engine/session factory; Base.metadata.create_all(); Postgres-only audit_log trigger install
├── models.py                  # SQLAlchemy ORM: User, Supplier, PurchaseOrder, ApprovalStep, ExceptionRequest, AuditLogEntry
├── schemas.py                  # Pydantic request/response models — single source of truth for API shapes (Principle VII)
├── auth.py                      # Password hashing, JWT encode/decode, get_current_user, require_roles(...) dependency factory
├── risk_engine.py                 # Pure functions: layer scores, risk tier, validity status, control status, approval-step plan
├── audit.py                        # write_audit_entry(...) helper used by routers/services (still goes through ORM insert)
└── routers/
    ├── auth.py                      # POST /auth/register, POST /auth/login
    ├── users.py                      # PATCH /users/{user_id}/role  (access_admin only)
    ├── suppliers.py                   # POST/GET/PATCH /suppliers, /suppliers/{id}  (procurement_lead owns risk data)
    ├── purchase_orders.py              # POST/GET /purchase-orders, POST /purchase-orders/{id}/transitions
    ├── exceptions.py                    # POST /exception-requests, POST /exception-requests/{id}/decision
    └── dashboard.py                      # GET /dashboard (role-scoped), GET /audit-log (auditor only)

scripts/
└── seed_access_admin.py    # One-time out-of-band bootstrap for the first access_admin (spec Assumption)

tests/
├── test_risk_engine.py      # Pure-function unit tests: all risk tiers, all validity statuses, all control-status combos
├── test_role_integrity.py    # Self-registration role-ignore, elevation authorization, audit entry shape
├── test_purchase_orders.py    # CRUD + transitions + control-status gating (blocked supplier, suspended supplier, etc.)
├── test_exceptions.py          # Self-approval rejection, access_admin rejection, cross-approver success + flag
└── test_dashboard.py            # Per-role visibility scoping, auditor mutating-endpoint rejection (all 7, individually)

docker-compose.yml           # app + postgres services (local/dev target)
Dockerfile
requirements.txt
.github/workflows/ci.yml     # pytest against SQLite
```

**Structure Decision**: Single backend project (Option 1 from the template,
adapted for a FastAPI service — no `src/` nesting since this is the only
deployable unit in this repository). The SwiftUI client lives in a separate
repository/target and is not represented here. Routers are split by resource
to keep `require_roles(...)` declarations easy to audit per constitution
Principle III.

## Complexity Tracking

> No Constitution Check violations. Table intentionally empty — every design
> choice above traces directly to a functional requirement in spec.md or a
> constitution principle.

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| _none_ | | |
