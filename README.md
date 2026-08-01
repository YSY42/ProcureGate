# ProcureGate

> **The core idea:** purchase order approval routing is decided by live supplier risk,
> not just by static value threshold.

Most purchase order approval systems route on order value alone, by
the time anyone realizes the supplier is risky, the order has already
gone through. 

ProcureGate checks supplier risk the moment a PO is
submitted, not after the fact. The same order can go through or get
blocked depending on how risky that supplier looks right now.
Self-approval is blocked at the database level, and every decision
lands in an audit trail that can't be edited after the fact.

---

## Key features

- **Dynamic, risk-based approval routing**:
    the same PO takes a different approval path depending on the submitting supplier's live
    risk score, not a static value threshold.
- **Segregation of duties** — self-approval on exception requests is
  blocked at the backend regardless of role; department approvers are
  scoped to their own team.
- **Audit-trail integrity** — the audit log is insert-only at the
  database level (Postgres trigger); risk triggers and approval
  decisions carry structured metadata, not just a free-text note.
- **A native macOS client** — built in SwiftUI, with role-specific
  dashboards (a personal risk picture for requesters and approvers, a
  governance dashboard for procurement leads and auditors), a
  searchable purchase-order queue, and a filterable audit trail with
  drill-down to the underlying entity.

---

## Stack

**Backend:** FastAPI + SQLAlchemy + PostgreSQL (SQLite in CI) · JWT
auth · pytest · Docker · GitHub Actions (dual SQLite/Postgres CI)
**Client:** SwiftUI, native macOS

## Roadmap

- [x] Backend: risk engine, RBAC, exceptions, audit trail
- [x] SwiftUI macOS client — role-based dashboards, PO queue and
      approval workflow, exception requests, filterable audit trail
- [ ] Cross-platform / web front end

---

## Quickstart

```bash
docker compose up -d --build
docker compose run --rm app python -m scripts.seed_access_admin \
  --email admin@example.com --password change-me
```

Then open the SwiftUI client, or explore the API directly at
`http://localhost:8000/docs`.

Full end-to-end scenarios:
`specs/001-layered-risk-approval-controls/quickstart.md`.

## Docs

Design artifacts (spec, plan, data model, API contracts, research
decisions) live under `specs/001-layered-risk-approval-controls/`.
