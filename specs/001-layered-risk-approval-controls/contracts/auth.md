# Contract: Auth

Base path: `/api/v1/auth`. Public (no auth required).

## POST /auth/register

**Request** (`UserRegisterRequest`):
```json
{ "email": "alice@example.com", "password": "min-8-chars" }
```
Note (FR-001): the schema has **no `role` field at all** — if a client sends
one, Pydantic v2's default `extra="ignore"` model config drops it silently.
The created account's `role` is hardcoded to `requester` in the service
function, never read from the request.

**Response** `201`: `UserResponse` — `{id, email, role, team, created_at}`
(role is always `"requester"` here).

**Errors**: `409` if email already registered.

**Permitted roles**: none (public).

## POST /auth/login

**Request** (`OAuth2PasswordRequestForm`-compatible, form-encoded):
`username=<email>&password=<password>`

**Response** `200`: `{"access_token": "<jwt>", "token_type": "bearer"}`.
JWT payload: `{"sub": "<user_id>", "exp": ..., "iat": ...}` — no role claim
(research.md Decision 10).

**Errors**: `401` on bad credentials.

**Permitted roles**: none (public).
