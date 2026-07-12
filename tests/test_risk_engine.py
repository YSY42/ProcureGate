from datetime import datetime, timedelta, timezone

import pytest

from app.config import settings
from app.models import ApprovalControlStatus, RiskTier, Supplier, ValidityStatus
from app.risk_engine import (
    compliance_floor_failed,
    compute_approval_control_status,
    compute_compliance_risk,
    compute_inherent_risk,
    compute_performance_risk,
    compute_risk_tier,
    compute_validity_status,
    generate_approval_steps,
)

# ---------------------------------------------------------------------------
# compute_inherent_risk / compute_performance_risk / compute_compliance_risk
# ---------------------------------------------------------------------------


def test_inherent_risk_high_risk_country_or_category():
    assert compute_inherent_risk("IR", "widgets") == RiskTier.high
    assert compute_inherent_risk("US", "defense") == RiskTier.high


def test_inherent_risk_elevated_country_or_category():
    assert compute_inherent_risk("CN", "widgets") == RiskTier.medium
    assert compute_inherent_risk("US", "electronics") == RiskTier.medium


def test_inherent_risk_low():
    assert compute_inherent_risk("US", "widgets") == RiskTier.low


def test_inherent_risk_identical_performance_different_country_gives_different_tier():
    """spec.md US2 AC3: same performance inputs, different country/category
    → can land in different tiers."""
    us = compute_inherent_risk("US", "widgets")
    ir = compute_inherent_risk("IR", "widgets")
    assert us != ir


def test_performance_risk_tiers():
    assert compute_performance_risk(95, 0.5) == RiskTier.low
    assert compute_performance_risk(80, 2) == RiskTier.medium
    assert compute_performance_risk(50, 10) == RiskTier.high


def test_compliance_risk_tiers():
    assert compute_compliance_risk(90, False) == RiskTier.low
    assert compute_compliance_risk(50, False) == RiskTier.medium
    assert compute_compliance_risk(20, False) == RiskTier.high
    assert compute_compliance_risk(90, True) == RiskTier.high


# ---------------------------------------------------------------------------
# compute_risk_tier (worst-of-three)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "inherent,performance,compliance,expected",
    [
        (RiskTier.low, RiskTier.low, RiskTier.low, RiskTier.low),
        (RiskTier.high, RiskTier.low, RiskTier.low, RiskTier.high),
        (RiskTier.low, RiskTier.high, RiskTier.low, RiskTier.high),
        (RiskTier.low, RiskTier.low, RiskTier.high, RiskTier.high),
        (RiskTier.medium, RiskTier.low, RiskTier.low, RiskTier.medium),
        (RiskTier.medium, RiskTier.medium, RiskTier.high, RiskTier.high),
    ],
)
def test_compute_risk_tier_worst_of_three(inherent, performance, compliance, expected):
    assert compute_risk_tier(inherent, performance, compliance) == expected


# ---------------------------------------------------------------------------
# compliance_floor_failed
# ---------------------------------------------------------------------------


def test_compliance_floor_failed_sanctions():
    assert compliance_floor_failed(90, True) is True


def test_compliance_floor_failed_low_esg():
    assert compliance_floor_failed(10, False) is True


def test_compliance_floor_not_failed():
    assert compliance_floor_failed(90, False) is False


# ---------------------------------------------------------------------------
# compute_validity_status
# ---------------------------------------------------------------------------


def _supplier(**kwargs) -> Supplier:
    defaults = dict(
        name="Test Co",
        country=None,
        category=None,
        delivery_reliability_score=None,
        defect_rate=None,
        esg_rating=None,
        sanctions_flag=False,
        assessed_at=None,
    )
    defaults.update(kwargs)
    return Supplier(**defaults)


def test_validity_unassessed():
    supplier = _supplier()
    assert compute_validity_status(supplier, datetime.now(timezone.utc)) == (
        ValidityStatus.unassessed
    )


def test_validity_incomplete():
    supplier = _supplier(country="US", category="widgets")
    assert compute_validity_status(supplier, datetime.now(timezone.utc)) == (
        ValidityStatus.incomplete
    )


def test_validity_current():
    now = datetime.now(timezone.utc)
    supplier = _supplier(
        country="US",
        category="widgets",
        delivery_reliability_score=95,
        defect_rate=0.5,
        esg_rating=90,
        assessed_at=now - timedelta(days=10),
    )
    assert compute_validity_status(supplier, now) == ValidityStatus.current


def test_validity_stale():
    now = datetime.now(timezone.utc)
    supplier = _supplier(
        country="US",
        category="widgets",
        delivery_reliability_score=95,
        defect_rate=0.5,
        esg_rating=90,
        assessed_at=now - timedelta(days=settings.ASSESSMENT_STALENESS_DAYS + 1),
    )
    assert compute_validity_status(supplier, now) == ValidityStatus.stale


# ---------------------------------------------------------------------------
# compute_approval_control_status (research.md Decision 4b)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "tier,validity,floor_failed,expected",
    [
        (None, ValidityStatus.unassessed, False, ApprovalControlStatus.blocked),
        (None, ValidityStatus.incomplete, False, ApprovalControlStatus.blocked),
        (RiskTier.low, ValidityStatus.current, True, ApprovalControlStatus.blocked),
        (RiskTier.low, ValidityStatus.stale, False, ApprovalControlStatus.blocked),
        (RiskTier.high, ValidityStatus.stale, False, ApprovalControlStatus.blocked),
        (RiskTier.low, ValidityStatus.current, False, ApprovalControlStatus.allowed),
        (RiskTier.medium, ValidityStatus.current, False, ApprovalControlStatus.conditional),
        (RiskTier.high, ValidityStatus.current, False, ApprovalControlStatus.escalated),
    ],
)
def test_compute_approval_control_status(tier, validity, floor_failed, expected):
    assert compute_approval_control_status(tier, validity, floor_failed) == expected


def test_stale_blocks_even_when_last_tier_was_strong():
    """spec.md US2 AC5: a strong last-computed tier does not rescue a stale
    assessment — Decision 4b resolves the spec's 'Blocked or Escalated'
    either/or as Blocked."""
    result = compute_approval_control_status(RiskTier.low, ValidityStatus.stale, False)
    assert result == ApprovalControlStatus.blocked


# ---------------------------------------------------------------------------
# generate_approval_steps (research.md Decision 6)
# ---------------------------------------------------------------------------


def test_generate_approval_steps_by_control_status():
    from app.models import Role

    assert generate_approval_steps(ApprovalControlStatus.blocked) == []
    assert generate_approval_steps(ApprovalControlStatus.allowed) == [
        Role.department_approver
    ]
    assert generate_approval_steps(ApprovalControlStatus.conditional) == [
        Role.department_approver,
        Role.procurement_lead,
    ]
    assert generate_approval_steps(ApprovalControlStatus.escalated) == [
        Role.procurement_lead
    ]
