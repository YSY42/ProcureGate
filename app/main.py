from contextlib import asynccontextmanager

from fastapi import FastAPI

from app.database import init_db
from app.routers import auth as auth_router
from app.routers import dashboard as dashboard_router
from app.routers import exceptions as exceptions_router
from app.routers import purchase_orders as purchase_orders_router
from app.routers import suppliers as suppliers_router
from app.routers import users as users_router


@asynccontextmanager
async def lifespan(app: FastAPI):
    init_db()
    yield


app = FastAPI(title="PO Risk-Based Approval Workflow", version="1.0.0", lifespan=lifespan)

app.include_router(auth_router.router)
app.include_router(users_router.router)
app.include_router(suppliers_router.router)
app.include_router(purchase_orders_router.router)
app.include_router(exceptions_router.router)
app.include_router(dashboard_router.router)

# User Story 5 (auditor role) additions land in dashboard.py in Phase 7
# (see tasks.md T055-T056).
