"""Overlays procurement_lead's runtime risk-threshold overrides onto the
static config.py defaults. The DB read happens here, at the call site —
risk_engine.py's functions stay pure (constitution Principle I: no database
session, no I/O) and simply receive whatever Settings value this produces.
"""

from sqlalchemy.orm import Session

from app.config import Settings
from app.config import settings as default_settings
from app.models import RiskThresholdOverride


def get_effective_settings(db: Session) -> Settings:
    override = db.query(RiskThresholdOverride).first()
    if override is None:
        return default_settings

    updates: dict[str, float] = {}
    if override.esg_compliance_floor is not None:
        updates["ESG_COMPLIANCE_FLOOR"] = override.esg_compliance_floor
    if override.esg_elevated_margin is not None:
        updates["ESG_ELEVATED_MARGIN"] = override.esg_elevated_margin

    if not updates:
        return default_settings
    return default_settings.model_copy(update=updates)
