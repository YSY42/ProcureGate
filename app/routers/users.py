from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from app.audit import write_audit_entry
from app.auth import require_roles
from app.database import get_db
from app.models import AuditActionType, Role, User
from app.schemas import RoleElevationRequest, UserResponse

router = APIRouter(prefix="/api/v1/users", tags=["users"])


@router.patch("/{user_id}/role", response_model=UserResponse)
def elevate_role(
    user_id: int,
    payload: RoleElevationRequest,
    db: Session = Depends(get_db),
    caller: User = Depends(require_roles(Role.access_admin)),
) -> User:
    target = db.get(User, user_id)
    if target is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")

    prior_role = target.role
    target.role = payload.new_role

    write_audit_entry(
        db,
        entity_type="user",
        entity_id=target.id,
        action_type=AuditActionType.role_elevation,
        actor_id=caller.id,
        rationale=(
            f"{caller.email} elevated {target.email} from "
            f"{prior_role.value} to {payload.new_role.value}"
        ),
        metadata={
            "grantor_id": caller.id,
            "grantee_id": target.id,
            "prior_role": prior_role.value,
            "new_role": payload.new_role.value,
        },
    )

    db.commit()
    db.refresh(target)
    return target
