# ProcureGate

> **The core idea:** purchase order approval routing is decided by live supplier risk,
> not just by static value threshold.

Most purchase order approval systems route on order value alone, by
the time anyone realizes the supplier is risky, the order has already
gone through. 

ProcureGate checks supplier risk the moment a PO is
submitted, not after the fact. The same order can go through, get
blocked, or submit exception depending on how risky that supplier looks right now.
Self-approval is blocked at the database level, and every decision
lands in an audit trail that can't be edited after the fact.

---

## Key features

**Dynamic, risk-based approval routing**

  - The same PO can take a different approval path depending on the
supplier's live risk score, which is computed in 3 layers risk (country, performance, compliance); a compliance floor failure blocks the order regardless of the rest.

**Segregation of duties**
  - Nobody can approve their own exception request. Department approvers
only see orders from their own team.

**An audit trail you can trust**
  - Once a decision is logged, it can't be edited. Every risk trigger and
approval carries the actual data behind it.

**A native macOS client**
  - Built in SwiftUI: role-based dashboards, a searchable purchase-order
queue, and a filterable audit trail you can drill into.

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
