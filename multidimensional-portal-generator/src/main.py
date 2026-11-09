import asyncio
import logging
import os
import random
import socket
import time
from concurrent.futures import ProcessPoolExecutor
from math import cos, isfinite, radians, sin, tan
from typing import Annotated, Any

from fastapi import Depends, FastAPI, HTTPException, Query, Request, status
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, EmailStr, Field, field_validator
from sqlalchemy import select, text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from .auth import (
    create_access_token,
    get_current_user,
    hash_password,
    require_role,
    verify_password,
)
from .config import settings
from .database import Base, engine, get_db
from .models import PortalSimulation, User

logger = logging.getLogger(__name__)
app = FastAPI(title="Multidimensional Portal Generator API", debug=settings.DEBUG)
cpu_executor = ProcessPoolExecutor()
G_CONSTANT = 6.67430e-11
MAX_COORDINATE_MAGNITUDE = 1e12
HOSTNAME = socket.gethostname()
# Replica name for load-balancing demos (web1/web2/web3 in docker-compose.lb.yml);
# falls back to the container hostname when the variable is not set.
INSTANCE_NAME = os.getenv("INSTANCE_NAME") or HOSTNAME


@app.middleware("http")
async def served_by_header(request: Request, call_next):
    """Tag every response with the replica that produced it (X-Served-By)."""
    response = await call_next(request)
    response.headers["X-Served-By"] = INSTANCE_NAME
    return response


@app.exception_handler(Exception)
async def unhandled_exception_handler(request: Request, exc: Exception) -> JSONResponse:
    logger.error(
        "Unhandled exception while processing %s",
        request.url.path,
        exc_info=(type(exc), exc, exc.__traceback__),
    )
    detail = str(exc) if settings.DEBUG else "An internal server error occurred."
    return JSONResponse(status_code=500, content={"message": detail})


class RegisterRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=8)


class LoginRequest(RegisterRequest):
    pass


class UserUpdate(BaseModel):
    email: EmailStr | None = None
    password: str | None = Field(default=None, min_length=8)
    is_active: bool | None = None


class UserResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    email: EmailStr
    role: str
    is_active: bool


class SimulationRequest(BaseModel):
    coordinates: Any | None = None
    dimension_id: int = Field(default=1, ge=1, le=1_000_000)
    complexity: int = Field(default=1, ge=1, le=100)
    initial_speed: float = Field(default=0.0, ge=0.0, le=1_000_000)
    object_mass: float = Field(default=1.0, gt=0.0, le=1_000_000)

    @field_validator("initial_speed", "object_mass")
    @classmethod
    def require_finite_values(cls, value: float) -> float:
        if not isfinite(value):
            raise ValueError("Value must be finite")
        return value


def calculate_coordinates(coordinates: Any) -> Any:
    if isinstance(coordinates, list):
        return [
            value * 2 if isinstance(value, (int, float)) else value
            for value in coordinates
        ]
    return coordinates


def _clamp_coordinate(value: float) -> float:
    if not isfinite(value):
        return 0.0
    return max(-MAX_COORDINATE_MAGNITUDE, min(MAX_COORDINATE_MAGNITUDE, value))


def _has_invalid_coordinates(coordinates: Any) -> bool:
    try:
        return any(
            not isfinite(float(value)) for point in coordinates for value in point
        )
    except (TypeError, ValueError):
        return False


def calculate_secure_coordinates(
    dimension_id: int,
    complexity: int,
    initial_speed: float,
    object_mass: float,
) -> list[list[float]]:
    """Calculate non-linear geodesic coordinates in O(N) time and memory.

    ``N`` is ``max(8, complexity * 8) + 1`` samples. The returned list owns
    three Python float objects per sample; this compact triplet representation
    is serialized by the API as JSON and stored as one JSON database value.
    The function is top-level, synchronous, and free of application state so
    it can be serialized to a ``ProcessPoolExecutor`` worker.
    """
    if not all(
        (
            isfinite(initial_speed),
            isfinite(object_mass),
            object_mass > 0,
        )
    ):
        raise ValueError("Trajectory parameters must be finite and valid")
    logger.info(
        "Generating geodesic coordinates: object_mass=%s initial_speed=%s "
        "complexity=%s dimension_id=%s",
        object_mass,
        initial_speed,
        complexity,
        dimension_id,
    )
    total_steps = max(8, complexity * 8)
    slope = tan(radians(dimension_id * 5))
    coordinates = [
        [
            _clamp_coordinate(initial_speed * t),
            _clamp_coordinate(
                slope * initial_speed * t
                - 0.5 * (G_CONSTANT * object_mass * (t**2)) / (dimension_id**1.5)
                + (object_mass * 1.5) * sin(complexity * 0.2 * t)
            ),
            _clamp_coordinate((object_mass * 0.8) * cos(complexity * 0.15 * t)),
        ]
        for t in range(total_steps + 1)
    ]
    has_invalid_values = _has_invalid_coordinates(coordinates)
    logger.info(
        "Generated %d geodesic points; sample=%s; invalid_values=%s",
        len(coordinates),
        coordinates[:3],
        has_invalid_values,
    )
    return coordinates


@app.on_event("startup")
async def startup_event() -> None:
    # PostgreSQL schema is owned by Alembic (applied by docker-entrypoint.sh before
    # the server starts). create_all is kept only for the zero-setup local SQLite run.
    if engine.url.get_backend_name() == "sqlite":
        async with engine.begin() as conn:
            await conn.run_sync(Base.metadata.create_all)


@app.get("/health", tags=["service"])
async def health(db: Annotated[AsyncSession, Depends(get_db)]) -> JSONResponse:
    """Liveness + readiness: the process answers and the database is reachable."""
    try:
        await db.execute(text("SELECT 1"))
    except Exception as exc:  # noqa: BLE001 - any DB failure means "not ready"
        logger.warning("Health check: database unavailable: %s", exc)
        return JSONResponse(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            content={"status": "error", "database": "unavailable"},
        )
    return JSONResponse(content={"status": "ok", "database": "ok"})


@app.get("/whoami", tags=["service"])
async def whoami(request: Request) -> dict[str, Any]:
    """Which replica answered (load-balancing demos)."""
    return {
        "hostname": HOSTNAME,
        "instance_id": INSTANCE_NAME,
        "pid": os.getpid(),
        "client": request.client.host if request.client else None,
    }


@app.get("/slow", tags=["service"])
async def slow(
    min_ms: Annotated[int, Query(ge=0, le=5000)] = 100,
    max_ms: Annotated[int, Query(ge=0, le=5000)] = 1000,
) -> dict[str, Any]:
    """Uneven-duration request for comparing balancing algorithms.

    The sleep is intentionally *blocking*: like the bcrypt hashing measured in
    Lab 4, it occupies the replica's single worker, so requests queue up per
    replica. That queueing is what least_conn can avoid and round robin cannot.
    """
    delay = random.uniform(min_ms, max(min_ms, max_ms)) / 1000
    time.sleep(delay)  # noqa: ASYNC251 - deliberate, see docstring
    return {"instance_id": INSTANCE_NAME, "slept_ms": round(delay * 1000)}


@app.on_event("shutdown")
async def shutdown_event() -> None:
    cpu_executor.shutdown(wait=True)


@app.post("/auth/register", response_model=UserResponse, status_code=201)
async def register(
    request: RegisterRequest,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> User:
    user = User(email=request.email, hashed_password=hash_password(request.password))
    db.add(user)
    try:
        await db.commit()
    except IntegrityError:
        await db.rollback()
        raise HTTPException(
            status_code=409, detail="Email already registered"
        ) from None
    await db.refresh(user)
    return user


@app.post("/auth/login")
async def login(
    request: LoginRequest,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict[str, str]:
    user = await db.scalar(select(User).where(User.email == request.email))
    if user is None or not verify_password(request.password, user.hashed_password):
        raise HTTPException(status_code=401, detail="Invalid email or password")
    return {
        "access_token": create_access_token({"sub": str(user.id)}),
        "token_type": "bearer",
    }


@app.get("/users/me", response_model=UserResponse)
async def users_me(
    current_user: Annotated[User, Depends(get_current_user)],
) -> User:
    return current_user


@app.put("/users/{user_id}", response_model=UserResponse)
async def update_user(
    user_id: int,
    request: UserUpdate,
    current_user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> User:
    if current_user.id != user_id and current_user.role != "ADMIN":
        raise HTTPException(status_code=403, detail="Cannot edit another user")
    user = await db.get(User, user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")
    if request.email is not None:
        user.email = request.email
    if request.password is not None:
        user.hashed_password = hash_password(request.password)
    if request.is_active is not None:
        user.is_active = request.is_active
    try:
        await db.commit()
    except IntegrityError:
        await db.rollback()
        raise HTTPException(
            status_code=409, detail="Email already registered"
        ) from None
    await db.refresh(user)
    return user


@app.get("/admin/dashboard")
async def admin_dashboard(
    _: Annotated[User, Depends(require_role("ADMIN"))],
) -> dict[str, str]:
    return {"message": "Admin dashboard"}


@app.post("/simulations/run", status_code=status.HTTP_201_CREATED)
async def run_simulation(
    request: SimulationRequest,
    current_user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> dict[str, Any]:
    try:
        loop = asyncio.get_running_loop()
        if request.coordinates is not None:
            coordinates = await loop.run_in_executor(
                cpu_executor, calculate_coordinates, request.coordinates
            )
        else:
            coordinates = await loop.run_in_executor(
                cpu_executor,
                calculate_secure_coordinates,
                request.dimension_id,
                request.complexity,
                request.initial_speed,
                request.object_mass,
            )
        logger.info(
            "Simulation result: points=%d sample=%s invalid_values=%s",
            len(coordinates),
            coordinates[:3],
            _has_invalid_coordinates(coordinates),
        )
    except ValueError as exc:
        logger.exception("Invalid simulation calculation parameters")
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:
        logger.exception("Simulation calculation failed")
        raise HTTPException(
            status_code=500, detail="Simulation calculation failed"
        ) from exc
    simulation = PortalSimulation(user_id=current_user.id, coordinates=coordinates)
    db.add(simulation)
    await db.commit()
    await db.refresh(simulation)
    return {
        "id": simulation.id,
        "user_id": simulation.user_id,
        "coordinates": simulation.coordinates,
        "created_at": simulation.created_at,
    }
