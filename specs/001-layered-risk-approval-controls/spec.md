# Feature Specification: Layered Risk Model, Role Integrity & Controlled Exception Approval

**Feature Branch**: `001-layered-risk-approval-controls`

**Created**: 2026-07-11

**Status**: Version 1

**Input**: User description: "Extend the existing PO approval workflow (reference the
baseline spec for PO CRUD + state transitions) with a layered risk model, explicit
assessment-validity tracking, a controlled exception process, role integrity
enforcement, and role-scoped reporting. Do not redefine entities already established
in the baseline — extend Supplier, PurchaseOrder, and the existing approval routing
behavior."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Role Integrity and Controlled Elevation (Priority: P1)

Every other rule in this system — self-approval prevention, admin approval bans,
auditor read-only enforcement — assumes a caller's role can be trusted. That
assumption only holds if role assignment itself is controlled. Self-registration
must never let a caller choose their own role: every self-registered account is
created as requester, regardless of what the request payload contains. Moving a
user to a more privileged role (department_approver, procurement_lead, auditor,
or access_admin) can only be done by an existing access_admin, and every such
change is recorded with who granted it, who received it, and the before/after
role.

**Why this priority**: This is the foundation every other role-based rule in
this system depends on. If role assignment can be self-selected or performed by
an untrusted actor, every downstream restriction (self-approval bans, auditor
read-only enforcement, access_admin's narrow scope) becomes unenforceable.

**Independent Test**: Can be fully tested by submitting self-registration
requests with various role payloads and verifying the resulting account is
always requester, then testing role-elevation attempts from both access_admin
and non-access_admin callers — independent of risk scoring, exceptions, or
dashboards existing yet.

**Acceptance Scenarios**:

1. **Given** a self-registration request whose payload specifies a role of
   procurement_lead or access_admin, **When** the account is created, **Then**
   the resulting account's role is requester, regardless of the submitted
   payload.
2. **Given** an authenticated user who is not access_admin, **When** they
   attempt to elevate any user's role, **Then** the attempt is rejected.
3. **Given** an access_admin, **When** they elevate a department_approver to
   procurement_lead, **Then** the change succeeds and the audit trail records
   the grantor, the grantee, the prior role, and the new role.

---

### User Story 2 - Layered Risk Assessment Drives Approval Control Status (Priority: P1)

A procurement organization needs a supplier's risk to be visible as separable
components — not one opaque score — so that reviewers can see *why* a PO is
blocked, and so that stale or missing data is never mistaken for "the supplier
scored badly." The system computes a supplier's risk as distinct layers
(inherent risk from country/category, performance risk from delivery/defect
history, compliance risk from ESG rating vs. the compliance floor), combines
them into a computed risk tier, and separately tracks whether that assessment
is trustworthy right now (Current / Stale / Unassessed / Incomplete). Routing
decisions on a PO are driven by a derived approval control status (Allowed /
Conditional / Blocked / Escalated) — the combination of tier, validity, and
compliance-floor outcome — never by the raw tier alone.

**Why this priority**: This is the foundation the exception process and
dashboards below depend on. Without distinct risk layers, an accurate control
status, and validity tracked independently of score, downstream stories would
be reporting on numbers nobody can trust.

**Independent Test**: Can be fully tested by creating suppliers with varying
country/category/performance/ESG inputs and varying assessment ages/
completeness, then verifying the computed tier, assessment validity status,
and derived approval control status each come out correctly and independently
— without needing the exception process or dashboard to exist yet.

**Acceptance Scenarios**:

1. **Given** a supplier whose status is Blocked, **When** a user attempts to
   create a new PO against that supplier, **Then** the request is rejected
   before any risk score is computed.
2. **Given** a supplier whose status changes to Suspended after a PO was
   already saved as a draft, **When** a user attempts to submit that draft PO,
   **Then** the submission is rejected.
3. **Given** two suppliers with identical performance-risk factors (delivery
   reliability, defect rate) but different country or product category,
   **When** their risk tiers are computed, **Then** the two suppliers can land
   in different computed tiers.
4. **Given** a supplier that has never been assessed, **When** its risk data
   is evaluated, **Then** its assessment validity status is Unassessed (never
   silently treated as a computed High-risk score), and any PO against it is
   Blocked.
5. **Given** a supplier whose last computed risk tier was strong (low risk)
   but whose assessment has aged past the validity window, **When** a PO
   against that supplier is evaluated, **Then** the approval control status
   reflects the staleness (Blocked or Escalated), and the audit trail records
   the staleness reason distinctly from the previously computed tier.
6. **Given** a PO where both an ESG compliance-floor failure and an assessment
   staleness condition are true at the same time, **When** the PO's control
   status is evaluated, **Then** both conditions produce their own separate
   audit trail entries, and neither entry suppresses or overwrites the other's
   rationale.

---

### User Story 3 - Controlled Exception Process for Blocked POs (Priority: P2)

When a PO is blocked, the person who hit the block needs a way forward that
doesn't amount to "one person overrides the control." They submit an exception
request with a justification, urgency category, and expiry date. A procurement
lead who is not the requester must approve it before the PO can proceed, and
that approval is visibly flagged as an exception everywhere it appears.
access_admin — whose scope is identity and access management only — has no
part in this process: it cannot approve anything and cannot write to Supplier
or PurchaseOrder records.

**Why this priority**: This is the safety valve that makes User Story 2's
control status usable in practice — without it, a Blocked PO is a dead end. It
depends on User Story 1 (trustworthy roles) and User Story 2 (control status),
so it is next in priority.

**Independent Test**: Can be fully tested by taking a PO already in Blocked
status (from User Story 2) and exercising the exception submission/approval
flow, independent of the dashboard reporting in User Story 4.

**Acceptance Scenarios**:

1. **Given** a blocked PO and a procurement lead who submitted the exception
   request themself, **When** that same procurement lead attempts to approve
   their own exception request, **Then** the approval is rejected regardless
   of role.
2. **Given** a blocked PO and an exception request submitted by a department
   approver, **When** a *different* procurement lead approves the request,
   **Then** the PO proceeds and is flagged as approved-with-exception, and
   that flag is distinguishable from a normal step approval in both the audit
   trail and dashboard counts.
3. **Given** a blocked PO or a pending exception request, **When**
   access_admin attempts to approve the PO, the PO's approval step, or the
   exception request, **Then** the attempt is rejected regardless of the
   underlying block reason.
4. **Given** any Supplier or PurchaseOrder record, **When** access_admin
   attempts to directly edit that record, **Then** the attempt is rejected —
   access_admin has no read/write relationship to Supplier or PurchaseOrder
   business data of any kind.

---

### User Story 4 - Role-Scoped Reporting Dashboard (Priority: P3)

Different roles need different visibility. A requester sees only their own PO
history. A department approver sees team-level queue and aging visibility. A
procurement lead sees the full aggregate business picture (blocked-creation
attempts, exception activity, stale/unassessed exposure, risk tier
distribution, approval timing by tier, pending-approval aging). access_admin,
having no operational role in procurement decisions, sees a role-elevation
audit log instead — who granted which role to whom, and when — not business-
risk KPIs.

**Why this priority**: Reporting is valuable once there is real risk,
exception, and role-elevation activity to report on (User Stories 1-3), but
the system is functionally complete for approving POs without it — it's a
visibility layer, not a control.

**Independent Test**: Can be fully tested by seeding PO/exception/risk/role-
elevation data and calling each role's dashboard view, independently of
whether the auditor role (User Story 5) exists.

**Acceptance Scenarios**:

1. **Given** a requester with POs of their own and POs belonging to other
   users, **When** they open their dashboard, **Then** they see only their own
   PO history and status — never team- or org-wide aggregates.
2. **Given** a department approver, **When** they open their dashboard,
   **Then** they see team/queue-level KPIs including pending-approval aging,
   scoped to their team.
3. **Given** a procurement lead, **When** they open their dashboard, **Then**
   they see full aggregate business KPIs: blocked PO-creation attempts,
   exception request/approval counts and reasons, POs affected by stale or
   unassessed risk data, risk tier distribution, average approval time
   segmented by risk tier, and aging of pending approvals.
4. **Given** access_admin, **When** they open their dashboard, **Then** they
   see the role-elevation audit log (grantor, grantee, prior role, new role,
   timestamp) and no business-risk KPIs.

---

### User Story 5 - Read-Only Auditor Access (Priority: P4 — first candidate to cut under time pressure)

An auditor role can see everything relevant to oversight — the same aggregate
business KPIs as procurement leads, plus the full audit trail including the
role-elevation log — but cannot take any mutating action anywhere in the
system, proving segregation of duties structurally rather than by convention.

**Why this priority**: Valuable for demonstrating segregation-of-duties as a
provable system property, but the approval workflow, exception process, role
integrity controls, and role-scoped dashboards (P1-P3) are fully functional
without it. Backend-only; no client-facing surface required. Drop first if
time is short — no other story depends on it.

**Independent Test**: Can be fully tested by authenticating as an auditor and
individually calling every mutating endpoint (PO creation, submission,
approval-step decision, exception request, exception approval, supplier
status change, role elevation) plus the read endpoints (dashboard KPIs, audit
trail including the role-elevation log), independent of all other stories
being complete.

**Acceptance Scenarios**:

1. **Given** an authenticated auditor, **When** they attempt PO creation,
   **Then** the request is rejected.
2. **Given** an authenticated auditor, **When** they attempt PO submission,
   **Then** the request is rejected.
3. **Given** an authenticated auditor, **When** they attempt an approval-step
   decision (approve or reject), **Then** the request is rejected.
4. **Given** an authenticated auditor, **When** they attempt to submit an
   exception request, **Then** the request is rejected.
5. **Given** an authenticated auditor, **When** they attempt to approve an
   exception request, **Then** the request is rejected.
6. **Given** an authenticated auditor, **When** they attempt to change a
   supplier's status, **Then** the request is rejected.
7. **Given** an authenticated auditor, **When** they attempt to elevate any
   user's role, **Then** the request is rejected.
8. **Given** an authenticated auditor, **When** they request dashboard KPIs or
   the audit trail (including the role-elevation log), **Then** the request
   succeeds and returns the same aggregate business data available to
   procurement leads plus full audit-trail read access.

---

### Edge Cases

- What happens when a supplier's risk layers are only partially entered (e.g.,
  performance data present, ESG rating missing)? → Assessment validity status
  must be Incomplete, and any PO against that supplier must be Blocked until
  the assessment is completed.
- What happens when an exception request's expiry date passes before a
  procurement lead acts on it? → The request lapses and the PO remains
  Blocked; the original block reason still applies and a new exception
  request is required.
- What happens when a supplier's underlying risk layers change (e.g., a new
  ESG rating arrives) while a PO is already in-flight under a previously
  computed control status? → The already-submitted PO's routing/pathway
  already recorded is not silently recomputed; the new assessment applies to
  future POs and future evaluations only (consistent with the baseline rule
  that an in-flight PO's approval pathway is fixed at submission time).
- What happens when more than one independent trigger (staleness, incomplete
  assessment, compliance-floor failure) fires on the same PO at the same
  time? → Every triggered condition is recorded as its own audit entry; none
  is dropped or overwritten by another.
- What happens when an access_admin who was just demoted (had a privileged
  role removed) still holds a valid session/token? → Role checks must be
  re-evaluated on each request using current role state, not a cached role
  from login time, so a demoted user's next privileged action is rejected.
- What happens when a user attempts to elevate their own role while already
  holding access_admin? → Permitted as a normal access_admin role-elevation
  action on another account, but access_admin elevating *itself* to a role it
  does not already implicitly need is still logged like any other elevation
  with grantor and grantee both identifying that same account — the system
  does not special-case self-elevation for access_admin the way it forbids
  self-approval for procurement_lead, since role elevation and approval
  authority are separate concerns.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST ignore any role value supplied in a self-
  registration request and MUST create every self-registered account with the
  requester role.
- **FR-002**: System MUST allow role elevation (to department_approver,
  procurement_lead, auditor, or access_admin) to be performed only by an
  existing access_admin; no other role may perform a role elevation.
- **FR-003**: System MUST record every role elevation in the audit trail with
  the grantor, the grantee, the prior role, and the new role.
- **FR-004**: System MUST store a supplier's risk as three distinct,
  separately-recorded layers: inherent risk (country, product category),
  performance risk (delivery reliability, defect rate), and compliance risk
  (ESG rating vs. the compliance floor).
- **FR-005**: System MUST combine the three risk layers into a single computed
  risk tier per supplier, such that two suppliers with identical performance-
  risk inputs but different country or category can produce different tiers.
- **FR-006**: System MUST track an assessment validity status — Current,
  Stale, Unassessed, or Incomplete — as a concept independent from the
  computed risk tier (computed live from stored assessment inputs at
  evaluation time; a poor computed tier and an unreliable/missing assessment
  MUST never be conflated).
- **FR-007**: System MUST derive an approval control status — Allowed,
  Conditional, Blocked, or Escalated — from the combination of computed risk
  tier, assessment validity status, and compliance-floor outcome.
- **FR-008**: PO routing and approval-step gating MUST be driven by the
  approval control status, not by the raw computed risk tier alone.
- **FR-009**: System MUST reject PO creation against a Blocked supplier before
  computing or referencing any risk score.
- **FR-010**: System MUST reject submission of an existing draft PO if its
  supplier's status has since become Suspended (or otherwise Blocked).
- **FR-011**: System MUST record staleness, missing/incomplete assessment, and
  compliance-floor failure as independent audit-trail triggers; when multiple
  triggers fire on the same PO, each MUST produce its own distinct audit entry
  and none MUST suppress or overwrite another's rationale.
- **FR-012**: System MUST allow a user whose approval step is Blocked to
  submit an exception request containing a mandatory justification, an
  urgency category, and an expiry date.
- **FR-013**: System MUST require an exception request to be approved by a
  procurement lead who is not the user who submitted the request; self-
  approval MUST be rejected regardless of role.
- **FR-014**: System MUST prevent access_admin from approving a PO, a PO
  approval step, or an exception request under any circumstance, and MUST
  prevent access_admin from writing to any Supplier or PurchaseOrder record,
  as hard role restrictions rather than conventions. access_admin's write
  scope is limited to identity and access management (granting/changing user
  roles).
- **FR-015**: System MUST flag a PO approved via the exception process as a
  distinct action type from a normal step approval, in both the audit trail
  and any reporting view.
- **FR-016**: System MUST scope dashboard visibility by role: a requester
  MUST see only their own PO history and status; a department approver MUST
  see team/queue-level KPIs including pending-approval aging; a procurement
  lead MUST see full aggregate business KPIs (blocked PO-creation attempts,
  exception request/approval counts and reasons, POs affected by stale or
  unassessed risk data, risk tier distribution, average approval time by risk
  tier, and aging of pending approvals); access_admin MUST see a role-
  elevation audit log (grantor, grantee, prior role, new role, timestamp) and
  MUST NOT see business-risk KPIs.
- **FR-017**: System MUST support a fifth role, auditor, with read access to
  the same aggregate business dashboard KPIs available to procurement leads,
  plus full read access to the audit trail including the role-elevation log.
- **FR-018**: System MUST reject an auditor caller on every mutating action —
  PO creation, PO submission, approval-step decision, exception request
  submission, exception request approval, supplier status change, and role
  elevation — individually and without exception, regardless of any other
  condition on the request.
- **FR-019**: System MUST NOT provide any client-facing surface for the
  auditor role; auditor access is backend-only.
- **FR-020**: System MUST evaluate a caller's role from current, authoritative
  role state on every request, not from a value cached at authentication
  time, so a role change takes effect on the caller's next request.

### Key Entities

- **Supplier (extended)**: Adds three separately-recorded risk-layer inputs
  (inherent, performance, compliance/ESG), a computed risk tier, and an
  assessment validity status (Current/Stale/Unassessed/Incomplete). Extends
  the baseline Supplier entity; does not replace it.
- **PurchaseOrder (extended)**: Adds a derived approval control status
  (Allowed/Conditional/Blocked/Escalated) evaluated at submission and fixed
  to the PO thereafter, and an approved-with-exception flag distinguishing
  exception-driven approvals from normal ones. Extends the baseline
  PurchaseOrder entity and its existing approval routing/state-transition
  behavior; does not replace it.
- **Exception Request**: Represents a request to proceed past a Blocked
  control status. Has a requester, a required approver (a procurement lead
  other than the requester), a mandatory justification, an urgency category,
  an expiry date, and a status (pending/approved/rejected/lapsed).
- **Role Elevation Entry**: An audit record of a role change — grantor
  (the access_admin who performed it), grantee (the affected user), prior
  role, new role, and timestamp. Distinct from other audit trail entries but
  part of the same overall audit trail for auditor read access.
- **Audit Trail Entry**: An immutable record of a triggering condition or
  decision (e.g., staleness trigger, incomplete-assessment trigger,
  compliance-floor-failure trigger, normal step approval, exception-approved
  action, supplier status change, role elevation). Multiple entries may exist
  for the same PO when multiple independent triggers fire; none overwrite
  another.
- **Role**: One of requester, department_approver, procurement_lead,
  access_admin, or auditor. Every self-registered account starts as
  requester; only access_admin can elevate a role. access_admin's scope is
  identity/access management only (no Supplier/PurchaseOrder read-write, no
  approval authority). Auditor is read-only everywhere with zero mutating
  capability, including role elevation.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of self-registration attempts that supply a non-requester
  role in the payload result in an account created as requester.
- **SC-002**: 100% of role-elevation attempts by non-access_admin callers are
  rejected.
- **SC-003**: 100% of successful role elevations produce an audit entry
  containing grantor, grantee, prior role, and new role.
- **SC-004**: 100% of PO-creation attempts against a Blocked supplier are
  rejected before any risk score is computed, verified across all tested
  scenarios.
- **SC-005**: Suppliers with identical performance-risk inputs but different
  country or category produce different computed risk tiers in 100% of
  tested combinations where the domain rules call for a different tier.
- **SC-006**: When two or more independent risk triggers (staleness,
  incomplete/unassessed data, compliance-floor failure) occur on the same PO,
  100% of tested cases show each trigger recorded as its own separate,
  non-overwritten audit entry.
- **SC-007**: 0% of exception self-approval attempts succeed, across all
  tested role/requester combinations.
- **SC-008**: 100% of access_admin attempts to approve a PO, approval step, or
  exception request, or to write to a Supplier or PurchaseOrder record, are
  rejected, regardless of the underlying reason.
- **SC-009**: Requesters retrieve only their own PO history in 100% of
  dashboard calls tested — zero instances of cross-user or cross-team data
  exposure.
- **SC-010**: Procurement leads can retrieve the full set of aggregate
  business KPIs (blocked-creation attempts, exception activity, stale/
  unassessed exposure, tier distribution, approval timing by tier, pending-
  approval aging) from a single dashboard call, and access_admin's dashboard
  call returns the role-elevation log rather than business KPIs.
- **SC-011**: 100% of auditor attempts on each of the seven mutating actions
  (PO creation, submission, approval-step decision, exception request,
  exception approval, supplier status change, role elevation) are
  individually rejected, while 100% of auditor read requests for dashboard
  KPIs and audit trail (including the role-elevation log) succeed.

## Assumptions

- A baseline PO workflow already exists (PO CRUD, submit/approve/reject/
  cancel state transitions, and a supplier risk/ESG-driven approval pathway)
  per the project constitution; this specification extends that baseline's
  Supplier and PurchaseOrder entities and approval routing rather than
  redefining them.
- Country risk, category risk, and ESG/sanctions data arrive as fields on the
  Supplier record, populated via integration with specialist platforms
  (sanctions screening, ESG questionnaire tools) in a real deployment; sourcing
  that data is out of scope for this specification, which assumes the fields
  are already present and populated (or explicitly absent/incomplete) on the
  Supplier record.
- Five roles (requester, department_approver, procurement_lead, access_admin,
  auditor) are sufficient for this system's scope; a full enterprise
  governance hierarchy with separate Compliance/Legal/Finance/Internal Audit
  operational participants is intentionally out of scope.
- access_admin is a narrower replacement for a general "admin" concept: its
  authority is limited to identity and access management (granting/changing
  roles); it has no read/write access to Supplier or PurchaseOrder business
  data and no approval authority anywhere in the workflow.
- procurement_lead is the system's highest independent approval authority for
  exceptions; it is barred from approving its own submitted exception
  requests to preserve segregation of duties.
- An exception request that passes its expiry date without a decision lapses
  automatically; the underlying block is not lifted and a new exception
  request is required.
- The very first access_admin account (needed to perform the first role
  elevation) is provisioned outside the scope of this specification (e.g., a
  one-time setup/seed step), since no account can elevate itself from
  requester before any access_admin exists.
- The auditor role's capability is backend-only for this specification; no
  client UI is required, and it is the first item to be dropped if
  implementation time is constrained.
- `assessment_validity_status` and `approval_control_status` are computed on
  demand from stored Supplier risk inputs rather than persisted as their own
  database columns — see the implementation plan's research.md Decision 4
  for the rationale (a stored staleness value would itself go stale the
  instant it was written).
