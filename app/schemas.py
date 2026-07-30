from datetime import datetime
from decimal import Decimal

from pydantic import BaseModel, ConfigDict, Field, model_validator

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
    country: str | None = Field(default=None, min_length=2, max_length=2)
    category: str | None = None
    delivery_reliability_score: float | None = Field(default=None, ge=0, le=100)
    defect_rate: float | None = Field(default=None, ge=0, le=100)
    esg_rating: float | None = Field(default=None, ge=0, le=100)
    sanctions_flag: bool = False


class SupplierUpdateRequest(BaseModel):
    name: str | None = None
    status: SupplierStatus | None = None
    country: str | None = Field(default=None, min_length=2, max_length=2)
    category: str | None = None
    delivery_reliability_score: float | None = Field(default=None, ge=0, le=100)
    defect_rate: float | None = Field(default=None, ge=0, le=100)
    esg_rating: float | None = Field(default=None, ge=0, le=100)
    sanctions_flag: bool | None = None
    needs_reassessment: bool | None = None
    reassessment_note: str | None = None


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
    inherent_risk_tier: RiskTier
    performance_risk_tier: RiskTier | None
    compliance_risk_tier: RiskTier | None
    needs_reassessment: bool
    reassessment_note: str | None
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
    requester_email: str
    supplier_id: int
    supplier_name: str
    supplier_risk_tier: RiskTier | None
    supplier_inherent_risk_tier: RiskTier
    supplier_performance_risk_tier: RiskTier | None
    supplier_compliance_risk_tier: RiskTier | None
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
    reason: str | None = None

    @model_validator(mode="after")
    def require_reason_for_reject(self) -> "TransitionRequest":
        if self.action == "reject" and not (self.reason and self.reason.strip()):
            raise ValueError("A reason is required to reject a purchase order")
        return self


class EscalateRequest(BaseModel):
    """The middle option between approve/reject: does not decide the step
    (it stays pending, still actionable by anyone with step authority) —
    only records that the decision-maker asked for a second look, and why."""

    note: str = Field(min_length=1)


class RiskThresholdResponse(BaseModel):
    """procurement_lead's self-service view of the risk model's calibration
    — a null field means "using the config.py default", not "unset and
    broken"."""

    model_config = ConfigDict(from_attributes=True)

    esg_compliance_floor: float | None
    esg_elevated_margin: float | None
    updated_by_id: int | None
    updated_at: datetime


class RiskThresholdUpdateRequest(BaseModel):
    esg_compliance_floor: float | None = Field(default=None, ge=0, le=100)
    esg_elevated_margin: float | None = Field(default=None, ge=0, le=100)


# ---------------------------------------------------------------------------
# Exception Requests (User Story 3)
# ---------------------------------------------------------------------------


class ExceptionRequestCreate(BaseModel):
    purchase_order_id: int
    justification: str = Field(min_length=1)
    urgency: ExceptionUrgency
    expiry_at: datetime


class ExceptionDecisionRequest(BaseModel):
    """Approving an exception is one of the most concentrated-risk actions
    in the system (it overrides a block the risk model raised on purpose) —
    a reason is required for both outcomes, not just rejection, so "why we
    overrode the model this time" is always on record."""

    decision: str = Field(pattern="^(approved|rejected)$")
    reason: str = Field(min_length=1)


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
    recent_exception_count_for_supplier: int | None = None


class ExceptionRequestDetailResponse(ExceptionRequestResponse):
    """Enriches the base response with the PO/supplier/requester context a
    decision-maker needs without a second round-trip per row — backs the
    pending-exceptions list, which didn't exist before this: procurement_lead
    previously had no way to discover a pending exception except knowing its
    id out of band."""

    po_description: str
    po_amount: Decimal
    po_currency: str
    supplier_name: str
    requester_email: str


# ---------------------------------------------------------------------------
# Dashboard (User Story 4) & Audit Trail (User Story 5)
# ---------------------------------------------------------------------------


class AgingStats(BaseModel):
    avg_days_pending: float | None
    oldest_pending_days: int | None


class ApprovalTimeDetailResponse(BaseModel):
    po_id: int
    description: str
    amount: Decimal
    currency: str
    supplier_name: str
    days_to_decision: float
    decided_at: datetime


class TriggerReasonDetailResponse(BaseModel):
    po_id: int
    action_type: str
    rationale: str
    at: datetime
    metadata: dict | None = None


class RequesterSupplierHistoryResponse(BaseModel):
    """Backs the approver-facing "has this requester been blocked against
    this same supplier before" check — surfaced at decision time instead of
    only being discoverable later from procurement_lead's aggregate drift
    signals."""

    blocked_count: int
    details: list[TriggerReasonDetailResponse]


class RequesterDashboard(BaseModel):
    my_purchase_orders: list[PurchaseOrderResponse]
    my_control_status_breakdown: dict[str, int]
    my_trigger_reason_breakdown: dict[str, int]
    my_trigger_reason_details: list[TriggerReasonDetailResponse]
    avg_approval_time_by_tier: dict[str, float | None]


class ApproverDashboard(BaseModel):
    team: str | None
    pending_approvals: list[PurchaseOrderResponse]
    pending_approval_aging: AgingStats
    team_control_status_breakdown: dict[str, int]
    team_trigger_reason_breakdown: dict[str, int]
    team_purchase_orders: list[PurchaseOrderResponse]
    team_trigger_reason_details: list[TriggerReasonDetailResponse]


class ExceptionCounts(BaseModel):
    submitted: int
    approved: int
    rejected: int
    lapsed: int


class SupplierExceptionSignal(BaseModel):
    supplier_id: int
    supplier_name: str
    count: int
    total_amount_eur: float


class RequesterExceptionSignal(BaseModel):
    requester_id: int
    requester_email: str
    count: int


class ExceptionDetailResponse(BaseModel):
    po_id: int
    justification: str
    decided_at: datetime | None


class ExceptionDriftSignals(BaseModel):
    window_days: int
    top_suppliers: list[SupplierExceptionSignal]
    top_requesters: list[RequesterExceptionSignal]
    trigger_reason_distribution: dict[str, int]
    trigger_reason_details: list[TriggerReasonDetailResponse]


class BlockedAttemptDetail(BaseModel):
    supplier_id: int
    supplier_name: str
    actor_email: str
    rationale: str
    at: datetime


class EscalatedApprovalDetail(BaseModel):
    """A pending PO an approver flagged for a second look instead of
    approving or rejecting outright — the middle option between the two,
    surfaced to procurement_lead since department_approver has no direct
    audit-trail visibility of their own."""

    po_id: int
    description: str
    requester_email: str
    step_number: int
    note: str
    actor_email: str
    actor_role_at_time: str
    at: datetime


class TeamPendingAging(BaseModel):
    """Pending-approval aging broken down by team rather than by named
    individual — approval steps are authorized by role + team match (any
    department_approver on the requester's team may act), not assigned to
    one specific person, so "team" is the unit that can actually go
    unstaffed/backlogged in this system's authorization model."""

    team: str
    pending_count: int
    avg_days_pending: float | None
    oldest_pending_days: int | None


class ProcurementLeadDashboard(BaseModel):
    blocked_creation_attempts: int
    blocked_creation_attempt_details: list[BlockedAttemptDetail]
    exception_requests: ExceptionCounts
    pos_affected_by_stale_or_unassessed: int
    risk_tier_distribution: dict[str, int]
    risk_tier_amount_distribution: dict[str, float]
    avg_approval_time_by_tier: dict[str, float | None]
    pending_approval_aging: AgingStats
    pending_approval_aging_by_team: list[TeamPendingAging]
    escalated_approvals: list[EscalatedApprovalDetail]
    exception_drift_signals: ExceptionDriftSignals


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
