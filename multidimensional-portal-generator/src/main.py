import asyncio
from concurrent.futures import ProcessPoolExecutor
from typing import Annotated, Any

from fastapi import Depends, FastAPI, HTTPException, status
from pydantic import BaseModel, ConfigDict, EmailStr, Field
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from .auth import (
    create_access_token,
    get_current_user,
    hash_password,
    require_role,
    verify_password,
)
from .database import Base, engine, get_db
from .models import PortalSimulation, User

app = FastAPI(title="Multidimensional Portal Generator API")
cpu_executor = ProcessPoolExecutor()


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
    dimension_id: int = Field(default=1, ge=1)
    complexity: int = Field(default=1, ge=1, le=100)
    initial_speed: float = Field(default=0.0, ge=0.0)
    object_mass: float = Field(default=1.0, gt=0.0)


def calculate_coordinates(coordinates: Any) -> Any:
    if isinstance(coordinates, list):
        return [
            value * 2 if isinstance(value, (int, float)) else value
            for value in coordinates
        ]
    return coordinates


def calculate_trajectory(
    dimension_id: int,
    complexity: int,
    initial_speed: float,
    object_mass: float,
) -> list[dict[str, float]]:
    points = max(8, complexity * 8)
    return [
        {
            "x": float(step),
            "y": initial_speed * step / object_mass,
            "z": float(dimension_id) * (step / points) ** 2,
        }
        for step in range(points)
    ]


@app.on_event("startup")
async def startup_event() -> None:
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)


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
    loop = asyncio.get_running_loop()
    if request.coordinates is not None:
        coordinates = await loop.run_in_executor(
            cpu_executor, calculate_coordinates, request.coordinates
        )
    else:
        coordinates = await loop.run_in_executor(
            cpu_executor,
            calculate_trajectory,
            request.dimension_id,
            request.complexity,
            request.initial_speed,
            request.object_mass,
        )
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
