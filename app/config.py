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

# Static FX-to-EUR table for demo purposes only — NOT live rates. Rates
# drift quickly (especially ARS, VES, TRY) and this table will go stale.
# See conversation notes on the tradeoffs of moving to a live-rate feed
# with historical snapshotting before treating this as audit-grade.
FX_RATES_TO_EUR: dict[str, float] = {
    "EUR": 1.0,

    # Major / G10
    "USD": 0.92,
    "GBP": 1.17,
    "JPY": 0.0062,
    "CHF": 1.05,
    "CAD": 0.68,
    "AUD": 0.60,
    "NZD": 0.55,

    # Asia
    "CNY": 0.127,
    "HKD": 0.118,
    "SGD": 0.68,
    "KRW": 0.00068,
    "INR": 0.011,

    # Europe (non-euro)
    "SEK": 0.087,
    "NOK": 0.085,
    "DKK": 0.134,
    "PLN": 0.23,
    "CZK": 0.040,
    "HUF": 0.0025,
    "RON": 0.20,
    "TRY": 0.027,

    # Middle East / Africa
    "AED": 0.25,
    "SAR": 0.245,
    "ILS": 0.25,
    "ZAR": 0.049,

    # Latin America
    "MXN": 0.049,
    "BRL": 0.163,
    "ARS": 0.00075,   # volatile — treat as directional only
    "CLP": 0.00096,
    "COP": 0.00021,
    "PEN": 0.24,
    "UYU": 0.021,
    "BOB": 0.133,
    "PYG": 0.00012,
    "GTQ": 0.118,
    "CRC": 0.0018,
    "DOP": 0.015,
    "HNL": 0.036,
    "NIO": 0.025,
    "PAB": 0.92,      # pegged 1:1 to USD
}
