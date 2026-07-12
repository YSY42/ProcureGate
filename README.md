# PO Risk-Based Approval Workflow

A purchase-order approval system where a layered supplier risk model
(inherent / performance / compliance) drives a dynamic approval pathway —
built to demonstrate REST API design, relational modeling, RBAC, and test
discipline on the backend, with a native iOS client to follow.

## Stack

FastAPI + SQLAlchemy + PostgreSQL (SQLite in CI) · JWT auth · pytest ·
Docker · GitHub Actions · SwiftUI client

## Roadmap

- [x] Backend: risk engine, RBAC, exceptions, audit trail — 61 tests
- [ ] SwiftUI client

## Quickstart

```bash
docker compose up -d --build
docker compose run --rm app python -m scripts.seed_access_admin \
  --email admin@example.com --password change-me
```

Full end-to-end scenarios: `specs/001-layered-risk-approval-controls/quickstart.md`.

## Docs

Design artifacts (spec, plan, data model, API contracts, research decisions)
live under `specs/001-layered-risk-approval-controls/`.
