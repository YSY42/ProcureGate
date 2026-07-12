"""Pure supplier-risk and approval-routing functions (constitution Principle
I — Business Logic Purity). No database session, no HTTP request/response
objects, no other I/O is imported or touched anywhere in this module.
"""

from datetime import datetime, timezone

from app.config import Settings
from app.config import settings as default_settings
from app.models import ApprovalControlStatus, Role, RiskTier, Supplier, ValidityStatus


def _as_naive_utc(dt: datetime) -> datetime:
    """SQLite drops timezone info on stored datetimes while Postgres keeps
    it, so a value read back from either backend may be naive or aware.
    Normalizing both operands before subtracting keeps staleness math
    consistent across research.md Decision 2's Postgres/SQLite asymmetry."""
    if dt.tzinfo is not None:
        return dt.astimezone(timezone.utc).replace(tzinfo=None)
    return dt

_TIER_SEVERITY = {RiskTier.low: 0, RiskTier.medium: 1, RiskTier.high: 2}


def compute_inherent_risk(
    country: str | None, category: str | None, settings: Settings = default_settings
) -> RiskTier:
    if country in settings.HIGH_RISK_COUNTRIES or category in settings.HIGH_RISK_CATEGORIES:
        return RiskTier.high
    if (
        country in settings.ELEVATED_RISK_COUNTRIES
        or category in settings.ELEVATED_RISK_CATEGORIES
    ):
        return RiskTier.medium
    return RiskTier.low


def compute_performance_risk(
    delivery_reliability_score: float,
    defect_rate: float,
    settings: Settings = default_settings,
) -> RiskTier:
    if (
        delivery_reliability_score < settings.PERFORMANCE_RISK_DELIVERY_THRESHOLD
        or defect_rate > settings.PERFORMANCE_RISK_DEFECT_THRESHOLD
    ):
        return RiskTier.high
    if (
        delivery_reliability_score < settings.PERFORMANCE_RISK_STRONG_DELIVERY_THRESHOLD
        or defect_rate > settings.PERFORMANCE_RISK_STRONG_DEFECT_THRESHOLD
    ):
        return RiskTier.medium
    return RiskTier.low


def compute_compliance_risk(
    esg_rating: float, sanctions_flag: bool, settings: Settings = default_settings
) -> RiskTier:
    if sanctions_flag or esg_rating < settings.ESG_COMPLIANCE_FLOOR:
        return RiskTier.high
    if esg_rating < settings.ESG_COMPLIANCE_FLOOR + settings.ESG_ELEVATED_MARGIN:
        return RiskTier.medium
    return RiskTier.low


def compute_risk_tier(
    inherent: RiskTier, performance: RiskTier, compliance: RiskTier
) -> RiskTier:
    """Worst-of-three aggregation (research.md Decision 5): a single
    high-severity layer makes the overall tier high, regardless of the other
    two layers."""
    return max((inherent, performance, compliance), key=lambda t: _TIER_SEVERITY[t])


def compliance_floor_failed(
    esg_rating: float | None, sanctions_flag: bool, settings: Settings = default_settings
) -> bool:
    """Hard veto check, independent of the compliance risk *tier* above
    (research.md Decision 4b, rule 2)."""
    if sanctions_flag:
        return True
    if esg_rating is None:
        return False
    return esg_rating < settings.ESG_COMPLIANCE_FLOOR


_REQUIRED_ASSESSMENT_FIELDS = (
    "country",
    "category",
    "delivery_reliability_score",
    "defect_rate",
    "esg_rating",
)


def compute_validity_status(
    supplier: Supplier, now: datetime, settings: Settings = default_settings
) -> ValidityStatus:
    """FR-006: tracked as a concept independent from the computed risk tier,
    computed live from stored inputs (research.md Decision 4) — never
    conflates "poor score" with "untrustworthy/missing data"."""
    values = [getattr(supplier, field) for field in _REQUIRED_ASSESSMENT_FIELDS]
    present_count = sum(1 for v in values if v is not None)

    if present_count == 0:
        return ValidityStatus.unassessed
    if present_count < len(values) or supplier.assessed_at is None:
        return ValidityStatus.incomplete

    age_days = (_as_naive_utc(now) - _as_naive_utc(supplier.assessed_at)).days
    if age_days > settings.ASSESSMENT_STALENESS_DAYS:
        return ValidityStatus.stale
    return ValidityStatus.current


def compute_approval_control_status(
    tier: RiskTier | None,
    validity: ValidityStatus,
    compliance_floor_failed: bool,
) -> ApprovalControlStatus:
    """Branch order per research.md Decision 4b (first match wins). Stale is
    treated the same as Unassessed/Incomplete (Blocked), not Escalated —
    untrustworthy data is a stronger signal than "this data says high risk."
    """
    if validity in (ValidityStatus.unassessed, ValidityStatus.incomplete):
        return ApprovalControlStatus.blocked
    if compliance_floor_failed:
        return ApprovalControlStatus.blocked
    if validity == ValidityStatus.stale:
        return ApprovalControlStatus.blocked

    # validity == current from here on
    if tier == RiskTier.low:
        return ApprovalControlStatus.allowed
    if tier == RiskTier.medium:
        return ApprovalControlStatus.conditional
    return ApprovalControlStatus.escalated


def generate_approval_steps(control_status: ApprovalControlStatus) -> list[Role]:
    """Control status → step-plan mapping (research.md Decision 6)."""
    if control_status == ApprovalControlStatus.blocked:
        return []
    if control_status == ApprovalControlStatus.allowed:
        return [Role.department_approver]
    if control_status == ApprovalControlStatus.conditional:
        return [Role.department_approver, Role.procurement_lead]
    # escalated
    return [Role.procurement_lead]
