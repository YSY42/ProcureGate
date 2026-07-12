import os

os.environ.setdefault("DATABASE_URL", "sqlite:///./test_po_workflow.db")
os.environ.setdefault("JWT_SECRET", "test-secret")
os.environ.setdefault("JWT_EXPIRE_MINUTES", "60")

import pytest
from fastapi.testclient import TestClient

from app.auth import create_access_token, hash_password
from app.database import SessionLocal, engine
from app.database import init_db as _init_db
from app.main import app
from app.models import Base, Role, User


@pytest.fixture(autouse=True)
def _reset_db():
    Base.metadata.drop_all(bind=engine)
    _init_db()
    yield


@pytest.fixture
def db():
    session = SessionLocal()
    try:
        yield session
    finally:
        session.close()


@pytest.fixture
def client():
    return TestClient(app)


def auth_headers(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def make_user(
    db, email: str, role: Role, team: str | None = None, password: str = "password123"
) -> User:
    user = User(
        email=email, hashed_password=hash_password(password), role=role, team=team
    )
    db.add(user)
    db.commit()
    db.refresh(user)
    return user


def token_for(user: User) -> str:
    return create_access_token(user.id)


@pytest.fixture
def user_factory(db):
    def _factory(email: str, role: Role, team: str | None = None) -> User:
        return make_user(db, email, role, team=team)

    return _factory


@pytest.fixture
def requester(db) -> User:
    return make_user(db, "requester@example.com", Role.requester, team="alpha")


@pytest.fixture
def requester_token(requester) -> str:
    return token_for(requester)


@pytest.fixture
def department_approver(db) -> User:
    return make_user(
        db, "dept-approver@example.com", Role.department_approver, team="alpha"
    )


@pytest.fixture
def department_approver_token(department_approver) -> str:
    return token_for(department_approver)


@pytest.fixture
def procurement_lead(db) -> User:
    return make_user(db, "lead1@example.com", Role.procurement_lead)


@pytest.fixture
def procurement_lead_token(procurement_lead) -> str:
    return token_for(procurement_lead)


@pytest.fixture
def second_procurement_lead(db) -> User:
    return make_user(db, "lead2@example.com", Role.procurement_lead)


@pytest.fixture
def second_procurement_lead_token(second_procurement_lead) -> str:
    return token_for(second_procurement_lead)


@pytest.fixture
def access_admin(db) -> User:
    return make_user(db, "access-admin@example.com", Role.access_admin)


@pytest.fixture
def access_admin_token(access_admin) -> str:
    return token_for(access_admin)


@pytest.fixture
def auditor(db) -> User:
    return make_user(db, "auditor@example.com", Role.auditor)


@pytest.fixture
def auditor_token(auditor) -> str:
    return token_for(auditor)
