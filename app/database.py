from sqlalchemy import create_engine, text
from sqlalchemy.orm import Session, sessionmaker

from app.config import settings
from app.models import Base

connect_args = (
    {"check_same_thread": False} if settings.DATABASE_URL.startswith("sqlite") else {}
)
engine = create_engine(settings.DATABASE_URL, connect_args=connect_args)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

_AUDIT_LOG_TRIGGER_SQL = """
CREATE OR REPLACE FUNCTION prevent_audit_log_mutation()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'audit_log is insert-only: % is prohibited (constitution Principle II)', TG_OP;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS audit_log_no_update ON audit_log;
CREATE TRIGGER audit_log_no_update
BEFORE UPDATE OR DELETE ON audit_log
FOR EACH ROW EXECUTE FUNCTION prevent_audit_log_mutation();
"""


def init_db() -> None:
    """Create schema (no migration tool — research.md Decision 1) and,
    on Postgres only, install the audit_log insert-only trigger
    (research.md Decision 3)."""
    Base.metadata.create_all(bind=engine)

    if engine.dialect.name == "postgresql":
        with engine.begin() as conn:
            conn.execute(text(_AUDIT_LOG_TRIGGER_SQL))


def get_db() -> Session:
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
