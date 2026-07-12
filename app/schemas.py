from datetime import datetime
from decimal import Decimal

from pydantic import BaseModel, ConfigDict, Field

from app.models import (
    ApprovalControlStatus,
    ApprovalStepStatus,
    ExceptionStatus,
    ExceptionUrgency,
    POStatus,
    Role,
    RiskTier,
    SupplierStatus,
)

# ---------------------------------------------------------------------------
# Auth / Users (User Story 1)
# ---------------------------------------------------------------------------


class UserRegisterRequest(BaseModel):
    """No `role` field on purpose (FR-001) — any `role` a client sends is
    silently dropped by this model rather than accepted."""

    model_config = ConfigDict(extra="ignore")

    email: str
    password: str = Field(min_length=8)


class UserResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    email: str
    role: Role
    team: str | None
    created_at: datetime


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"


class RoleElevationRequest(BaseModel):
    new_role: Role


# ---------------------------------------------------------------------------
# Suppliers (User Story 2)
# ---------------------------------------------------------------------------


class SupplierCreateRequest(BaseModel):
    name: str
    country: str | None = None
    category: str | None = None
    delivery_reliability_score: float | None = Field(default=None, ge=0, le=100)
    defect_rate: float | None = Field(default=None, ge=0, le=100)
    esg_rating: float | None = Field(default=None, ge=0, le=100)
    sanctions_flag: bool = False


class SupplierUpdateRequest(BaseModel):
    name: str | None = None
    status: SupplierStatus | None = None
    country: str | None = None
    category: str | None = None
    delivery_reliability_score: float | None = Field(default=None, ge=0, le=100)
    defect_rate: float | None = Field(default=None, ge=0, le=100)
    esg_rating: float | None = Field(default=None, ge=0, le=100)
    sanctions_flag: bool | None = None


class SupplierResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    name: str
    status: SupplierStatus
    country: str | None
    category: str | None
    delivery_reliability_score: float | None
    defect_rate: float | None
    esg_rating: float | None
    sanctions_flag: bool
    assessed_at: datetime | None
    computed_risk_tier: RiskTier | None
    created_at: datetime
    updated_at: datetime


# ---------------------------------------------------------------------------
# Purchase Orders (User Story 2)
# ---------------------------------------------------------------------------


class PurchaseOrderCreateRequest(BaseModel):
    supplier_id: int
    amount: Decimal
    currency: str = Field(min_length=3, max_length=3)
    description: str


class PurchaseOrderUpdateRequest(BaseModel):
    supplier_id: int | None = None
    amount: Decimal | None = None
    currency: str | None = Field(default=None, min_length=3, max_length=3)
    description: str | None = None


class ApprovalStepResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    step_number: int
    required_role: Role
    status: ApprovalStepStatus
    decided_by_id: int | None
    decided_at: datetime | None


class PurchaseOrderResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    requester_id: int
    supplier_id: int
    amount: Decimal
    currency: str
    description: str
    status: POStatus
    approval_control_status: ApprovalControlStatus | None
    approved_with_exception: bool
    current_step_number: int | None
    created_at: datetime
    submitted_at: datetime | None
    decided_at: datetime | None
    approval_steps: list[ApprovalStepResponse] = []


class TransitionRequest(BaseModel):
    action: str = Field(pattern="^(submit|approve|reject|cancel)$")


# ---------------------------------------------------------------------------
# Exception Requests (User Story 3)
# ---------------------------------------------------------------------------


class ExceptionRequestCreate(BaseModel):
    purchase_order_id: int
    justification: str = Field(min_length=1)
    urgency: ExceptionUrgency
    expiry_at: datetime


class ExceptionDecisionRequest(BaseModel):
    decision: str = Field(pattern="^(approved|rejected)$")


class ExceptionRequestResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    purchase_order_id: int
    requested_by_id: int
    justification: str
    urgency: ExceptionUrgency
    expiry_at: datetime
    status: ExceptionStatus
    decided_by_id: int | None
    decided_at: datetime | None


# ---------------------------------------------------------------------------
# Dashboard (User Story 4) & Audit Trail (User Story 5)
# ---------------------------------------------------------------------------


class AgingStats(BaseModel):
    avg_days_pending: float | None
    oldest_pending_days: int | None


class RequesterDashboard(BaseModel):
    my_purchase_orders: list[PurchaseOrderResponse]


class ApproverDashboard(BaseModel):
    team: str | None
    pending_approvals: list[PurchaseOrderResponse]
    pending_approval_aging: AgingStats


class ExceptionCounts(BaseModel):
    submitted: int
    approved: int
    rejected: int
    lapsed: int


class ProcurementLeadDashboard(BaseModel):
    blocked_creation_attempts: int
    exception_requests: ExceptionCounts
    pos_affected_by_stale_or_unassessed: int
    risk_tier_distribution: dict[str, int]
    avg_approval_time_by_tier: dict[str, float | None]
    pending_approval_aging: AgingStats


class RoleElevationLogEntry(BaseModel):
    grantor_id: int | None
    grantee_id: int | None
    prior_role: str | None
    new_role: str | None
    at: datetime


class AccessAdminDashboard(BaseModel):
    role_elevations: list[RoleElevationLogEntry]


class AuditLogEntryResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    entity_type: str
    entity_id: int
    action_type: str
    actor_id: int | None
    rationale: str
    metadata_json: dict | None
    created_at: datetime
