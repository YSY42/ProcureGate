<!--
Sync Impact Report
==================
Version change: [TEMPLATE] → 1.0.0 (initial ratification)
Modified principles: N/A (first fill of template placeholders)
Added sections:
  - Core Principles: I. Business Logic Purity, II. Audit Traceability,
    III. Permissions as Code, IV. No Magic Numbers, V. Testing as a Merge
    Threshold, VI. Scope Discipline, VII. Front-End/Back-End Alignment
    (7 principles supplied by user; template's 5-slot default was expanded)
  - Technology & Architecture Constraints
  - Development Workflow & Quality Gates
Removed sections: none (template placeholders only)
Templates requiring updates:
  - .specify/templates/plan-template.md ✅ no changes needed (Constitution Check
    section reads gates generically from this file)
  - .specify/templates/spec-template.md ✅ no changes needed (generic structure)
  - .specify/templates/tasks-template.md ✅ no changes needed (generic structure)
  - .specify/templates/checklist-template.md ✅ no changes needed
Follow-up TODOs:
  - TODO(RATIFICATION_DATE): original adoption date not supplied by user; set to
    today's date (constitution authored and ratified same day for this project).
-->

# PO Risk-Based Approval Workflow Constitution

## Core Principles

### I. Business Logic Purity
Supplier risk-scoring and approval-routing logic in `app/risk_engine.py` MUST be
implemented as pure functions: no direct database session access, no HTTP
request/response objects, no other I/O. Any change to scoring weights,
thresholds, or compliance veto rules MUST be accompanied, in the same PR, by
new or updated unit tests covering every risk-tier threshold and every
compliance-veto scenario, and those tests MUST be added or updated before the
change is merged.
Rationale: a pure risk engine can be exhaustively unit-tested and reasoned
about without a database or web server, and guarantees the routing decision is
deterministic given a supplier's scores.

### II. Audit Traceability
Every operation that changes a purchase order's status (submit, approve,
reject, auto-approve) MUST insert a row into `audit_log`. The `audit_log` table
MUST be insert-only: UPDATE and DELETE on this table MUST be prohibited at the
database level (revoked grants or a trigger), not merely by application-layer
convention. Each `audit_log` row MUST carry a human-readable rationale that
answers "why was this approval path chosen" (e.g., which risk tier, which
threshold, which veto fired) — a bare status code with no rationale is
insufficient.
Rationale: risk-based routing is only defensible if every decision leaves an
immutable, explainable trail.

### III. Permissions as Code
Every endpoint that mutates data MUST declare its permitted roles through a
role-validation dependency (e.g., `require_roles(...)`) at the route
declaration. Hard-coded role checks via `if`/`else` branching inside business
logic or route handler bodies are PROHIBITED.
Rationale: centralizing permission checks in declarative dependencies keeps the
access-control model auditable in one place instead of scattered across
handlers.

### IV. No Magic Numbers
Business-rule values — scoring weights, risk thresholds, compliance minimums —
MUST be defined as named constants or configuration entries following the
`Settings` pattern in `config.py`. Hardcoding such values inline in function
bodies is PROHIBITED.
Rationale: named, centralized configuration is what makes thresholds
changeable and reviewable without hunting through function bodies.

### V. Testing as a Merge Threshold
CI (GitHub Actions) MUST run the full `pytest` suite, and it MUST pass before
any merge into `main`. A PR that changes a business rule (in `risk_engine.py`
or related configuration) without corresponding test coverage MUST be treated
as incomplete and MUST NOT be merged.
Rationale: CI is the enforcement mechanism for Principles I and IV — untested
rule changes are exactly the failure mode this project must avoid.

### VI. Scope Discipline
This is a portfolio project targeted for completion in 2-4 weeks. Any new
feature MUST map clearly to the objective of demonstrating: REST API design,
relational modeling, authentication, testing, CI/CD, and containerization. A
feature that does not serve this objective MUST NOT be implemented. When
trading off scope, depth on the core PO/approval flow MUST be prioritized over
breadth of unrelated features.
Rationale: without an explicit scope gate, portfolio projects tend to expand
indefinitely instead of demonstrating depth on the core flow.

### VII. Front-End/Back-End Alignment
The SwiftUI client's data models and API calls MUST strictly conform to the
response shapes defined in the backend's `schemas.py`. The client MUST NOT
re-derive or guess business rules already computed by the backend (e.g., risk
score calculation or approval-routing decisions). Presentation-only derivations
(e.g., mapping a risk level to a UI color) MAY be done client-side.
Rationale: `schemas.py` and `risk_engine.py` are the single source of truth for
business rules; letting the client re-implement them would silently violate
Principle I's determinism guarantee.

## Technology & Architecture Constraints

The backend is FastAPI + SQLAlchemy + PostgreSQL with JWT-based authentication;
the client is SwiftUI. This stack is a fixed decision for this project (see
Principle VI) and MUST NOT be swapped mid-project without an explicit,
documented amendment to this constitution. `config.py`'s `Settings` pattern is
the single mechanism for environment- and business-rule configuration referenced
by Principle IV.

## Development Workflow & Quality Gates

- Every PR MUST state which Core Principle(s) it touches and confirm the
  relevant tests (Principle I, V) were added or updated.
- CI MUST pass (Principle V) before merge; there is no override.
- Any endpoint mutating data MUST be reviewed for a `require_roles(...)`
  dependency (Principle III) before approval.
- Reviewers MUST reject PRs that introduce inline literals for business-rule
  values (Principle IV) or that add scope not traceable to Principle VI's
  demonstrated-capability list.

## Governance

This constitution supersedes ad-hoc conventions for this project. Amendments
require: (1) a written rationale for the change, (2) an update to this file
following the versioning policy below, and (3) a check of `plan-template.md`,
`spec-template.md`, and `tasks-template.md` for any needed alignment. Versioning
follows semantic rules: MAJOR for backward-incompatible principle removal or
redefinition, MINOR for a new principle or materially expanded guidance, PATCH
for wording/clarification only. All PRs and reviews MUST verify compliance with
the Core Principles above; unjustified complexity or deviation is grounds for
requesting changes.

**Version**: 1.0.0 | **Ratified**: 2026-07-10 | **Last Amended**: 2026-07-10
