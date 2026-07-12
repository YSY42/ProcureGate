# Contract: Users & Role Elevation

Base path: `/api/v1/users`. All endpoints require a valid JWT.

## PATCH /users/{user_id}/role

**Permitted roles**: `access_admin` only — `require_roles(["access_admin"])`.

**Request** (`RoleElevationRequest`):
```json
{ "new_role": "procurement_lead" }
```
`new_role` validated against the `Role` enum (400 on invalid value).

**Behavior** (FR-002, FR-003):
1. Load target `User` by `user_id` (404 if missing).
2. Record `prior_role = target.role`; set `target.role = new_role`.
3. Write `AuditLogEntry(entity_type="user", entity_id=user_id,
   action_type="role_elevation", actor_id=caller.id, rationale=f"{caller.email}
   elevated {target.email} from {prior_role} to {new_role}",
   metadata_json={"grantor_id": caller.id, "grantee_id": user_id,
   "prior_role": prior_role, "new_role": new_role})`.

**Response** `200`: `UserResponse` (updated).

**Errors**: `403` if caller role != `access_admin` (enforced by the
dependency itself, before the handler body runs — this is what makes
self-elevation-by-non-access_admin structurally impossible, not just
validated). `404` if target user does not exist.

**Acceptance scenario mapping**: spec US1 AC2 (non-access_admin rejected),
AC3 (access_admin elevates, audit fields present).
