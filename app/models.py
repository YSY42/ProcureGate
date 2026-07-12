import enum
from datetime import datetime, timezone

from sqlalchemy import (
    JSON,
    Boolean,
    DateTime,
    Enum,
    ForeignKey,
    Numeric,
    String,
    Text,
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


class Base(DeclarativeBase):
    pass


class Role(str, enum.Enum):
    requester = "requester"
    department_approver = "department_approver"
    procurement_lead = "procurement_lead"
    access_admin = "access_admin"
    auditor = "auditor"


class SupplierStatus(str, enum.Enum):
    active = "active"
    suspended = "suspended"
    blocked = "blocked"


class RiskTier(str, enum.Enum):
    low = "low"
    medium = "medium"
    high = "high"


class ValidityStatus(str, enum.Enum):
    current = "current"
    stale = "stale"
    unassessed = "unassessed"
    incomplete = "incomplete"


class ApprovalControlStatus(str, enum.Enum):
    allowed = "allowed"
    conditional = "conditional"
    blocked = "blocked"
    escalated = "escalated"


class POStatus(str, enum.Enum):
    draft = "draft"
    submitted = "submitted"
    approved = "approved"
    rejected = "rejected"
    cancelled = "cancelled"


class ApprovalStepStatus(str, enum.Enum):
    pending = "pending"
    approved = "approved"
    rejected = "rejected"


class ExceptionUrgency(str, enum.Enum):
    low = "low"
    medium = "medium"
    high = "high"
    critical = "critical"


class ExceptionStatus(str, enum.Enum):
    pending = "pending"
    approved = "approved"
    rejected = "rejected"
    lapsed = "lapsed"


class AuditActionType(str, enum.Enum):
    po_status_transition = "po_status_transition"
    risk_trigger_stale = "risk_trigger_stale"
    risk_trigger_incomplete_or_unassessed = "risk_trigger_incomplete_or_unassessed"
    risk_trigger_compliance_floor = "risk_trigger_compliance_floor"
    exception_submitted = "exception_submitted"
    exception_approved = "exception_approved"
    exception_rejected = "exception_rejected"
    exception_lapsed = "exception_lapsed"
    po_approved_with_exception = "po_approved_with_exception"
    po_creation_blocked = "po_creation_blocked"
    supplier_status_change = "supplier_status_change"
    role_elevation = "role_elevation"


class User(Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(primary_key=True)
    email: Mapped[str] = mapped_column(String(255), unique=True, index=True)
    hashed_password: Mapped[str] = mapped_column(String(255))
    role: Mapped[Role] = mapped_column(Enum(Role), default=Role.requester)
    team: Mapped[str | None] = mapped_column(String(100), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class Supplier(Base):
    __tablename__ = "suppliers"

    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(255))
    status: Mapped[SupplierStatus] = mapped_column(
        Enum(SupplierStatus), default=SupplierStatus.active
    )

    # Inherent risk inputs
    country: Mapped[str | None] = mapped_column(String(2), nullable=True)
    category: Mapped[str | None] = mapped_column(String(100), nullable=True)

    # Performance risk inputs
    delivery_reliability_score: Mapped[float | None] = mapped_column(nullable=True)
    defect_rate: Mapped[float | None] = mapped_column(nullable=True)

    # Compliance risk inputs
    esg_rating: Mapped[float | None] = mapped_column(nullable=True)
    sanctions_flag: Mapped[bool] = mapped_column(Boolean, default=False)

    assessed_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    computed_risk_tier: Mapped[RiskTier | None] = mapped_column(
        Enum(RiskTier), nullable=True
    )

    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow
    )


class PurchaseOrder(Base):
    __tablename__ = "purchase_orders"

    id: Mapped[int] = mapped_column(primary_key=True)
    requester_id: Mapped[int] = mapped_column(ForeignKey("users.id"))
    supplier_id: Mapped[int] = mapped_column(ForeignKey("suppliers.id"))

    amount: Mapped[float] = mapped_column(Numeric(12, 2))
    currency: Mapped[str] = mapped_column(String(3))
    description: Mapped[str] = mapped_column(Text)

    status: Mapped[POStatus] = mapped_column(Enum(POStatus), default=POStatus.draft)
    approval_control_status: Mapped[ApprovalControlStatus | None] = mapped_column(
        Enum(ApprovalControlStatus), nullable=True
    )
    approved_with_exception: Mapped[bool] = mapped_column(Boolean, default=False)
    current_step_number: Mapped[int | None] = mapped_column(nullable=True)

    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    submitted_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    decided_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )

    requester: Mapped["User"] = relationship(foreign_keys=[requester_id])
    supplier: Mapped["Supplier"] = relationship()
    approval_steps: Mapped[list["ApprovalStep"]] = relationship(
        back_populates="purchase_order", order_by="ApprovalStep.step_number"
    )


class ApprovalStep(Base):
    __tablename__ = "approval_steps"

    id: Mapped[int] = mapped_column(primary_key=True)
    purchase_order_id: Mapped[int] = mapped_column(ForeignKey("purchase_orders.id"))
    step_number: Mapped[int] = mapped_column()
    required_role: Mapped[Role] = mapped_column(Enum(Role))
    status: Mapped[ApprovalStepStatus] = mapped_column(
        Enum(ApprovalStepStatus), default=ApprovalStepStatus.pending
    )
    decided_by_id: Mapped[int | None] = mapped_column(
        ForeignKey("users.id"), nullable=True
    )
    decided_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )

    purchase_order: Mapped["PurchaseOrder"] = relationship(back_populates="approval_steps")


class ExceptionRequest(Base):
    __tablename__ = "exception_requests"

    id: Mapped[int] = mapped_column(primary_key=True)
    purchase_order_id: Mapped[int] = mapped_column(ForeignKey("purchase_orders.id"))
    requested_by_id: Mapped[int] = mapped_column(ForeignKey("users.id"))
    justification: Mapped[str] = mapped_column(Text)
    urgency: Mapped[ExceptionUrgency] = mapped_column(Enum(ExceptionUrgency))
    expiry_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    status: Mapped[ExceptionStatus] = mapped_column(
        Enum(ExceptionStatus), default=ExceptionStatus.pending
    )
    decided_by_id: Mapped[int | None] = mapped_column(
        ForeignKey("users.id"), nullable=True
    )
    decided_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )

    purchase_order: Mapped["PurchaseOrder"] = relationship()


class AuditLogEntry(Base):
    __tablename__ = "audit_log"

    id: Mapped[int] = mapped_column(primary_key=True)
    entity_type: Mapped[str] = mapped_column(String(50))
    entity_id: Mapped[int] = mapped_column()
    action_type: Mapped[AuditActionType] = mapped_column(Enum(AuditActionType))
    actor_id: Mapped[int | None] = mapped_column(ForeignKey("users.id"), nullable=True)
    rationale: Mapped[str] = mapped_column(Text)
    metadata_json: Mapped[dict | None] = mapped_column(JSON, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
