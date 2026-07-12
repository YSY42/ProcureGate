"""One-time out-of-band bootstrap for the first access_admin account
(research.md Decision 9). Not exposed as an HTTP endpoint — the only way to
create an access_admin over HTTP is via an existing access_admin's role
elevation (FR-002), so this script is the sole way to create the first one.

Usage:
    python -m scripts.seed_access_admin --email admin@example.com --password change-me
"""

import argparse

from app.auth import hash_password
from app.database import SessionLocal, init_db
from app.models import Role, User


def seed_access_admin(email: str, password: str) -> User:
    init_db()
    db = SessionLocal()
    try:
        existing = db.query(User).filter(User.email == email).first()
        if existing:
            raise SystemExit(f"User {email} already exists (role={existing.role.value})")
        user = User(
            email=email,
            hashed_password=hash_password(password),
            role=Role.access_admin,
        )
        db.add(user)
        db.commit()
        db.refresh(user)
        return user
    finally:
        db.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--email", required=True)
    parser.add_argument("--password", required=True)
    args = parser.parse_args()
    created = seed_access_admin(args.email, args.password)
    print(f"Created access_admin user id={created.id} email={created.email}")
