from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Single source of truth for environment and business-rule configuration
    (constitution Principle IV — no magic numbers in risk_engine.py)."""

    DATABASE_URL: str = "sqlite:///./dev.db"
    JWT_SECRET: str = "dev-secret-change-me"
    JWT_ALGORITHM: str = "HS256"
    JWT_EXPIRE_MINUTES: int = 60

    # Risk model thresholds (research.md Decisions 4b, 5)
    ASSESSMENT_STALENESS_DAYS: int = 180

    # Inherent risk (country / category) — three-tier via two list memberships
    HIGH_RISK_COUNTRIES: set[str] = {"IR", "KP", "SY", "RU"}
    ELEVATED_RISK_COUNTRIES: set[str] = {"CN", "RU", "VE", "MM"}
    HIGH_RISK_CATEGORIES: set[str] = {"dual_use_goods", "precious_metals", "defense"}
    ELEVATED_RISK_CATEGORIES: set[str] = {"electronics", "chemicals"}

    # Performance risk (delivery reliability / defect rate) — three-tier via
    # a "strong" band and a "poor" band, with everything between as medium
    PERFORMANCE_RISK_STRONG_DELIVERY_THRESHOLD: float = 90.0
    PERFORMANCE_RISK_STRONG_DEFECT_THRESHOLD: float = 1.0
    PERFORMANCE_RISK_DELIVERY_THRESHOLD: float = 70.0
    PERFORMANCE_RISK_DEFECT_THRESHOLD: float = 5.0

    # Compliance risk (ESG rating vs. compliance floor) — sanctions_flag or
    # esg_rating below the floor is a hard veto (compliance_floor_failed);
    # esg_rating within ESG_ELEVATED_MARGIN points above the floor is medium
    ESG_COMPLIANCE_FLOOR: float = 40.0
    ESG_ELEVATED_MARGIN: float = 15.0

    model_config = SettingsConfigDict(env_file=".env")


settings = Settings()
