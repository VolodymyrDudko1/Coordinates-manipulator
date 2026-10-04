import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from pydantic import ValidationError
from sqlalchemy.ext.asyncio import (
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)
from src.database import Base, get_db
from src.main import SimulationRequest, app, calculate_secure_coordinates
from src.models import User


@pytest_asyncio.fixture
async def client(tmp_path):
    engine = create_async_engine(f"sqlite+aiosqlite:///{tmp_path}/test.db")
    session_factory = async_sessionmaker(
        engine, class_=AsyncSession, expire_on_commit=False
    )
    async with engine.begin() as connection:
        await connection.run_sync(Base.metadata.create_all)

    async def override_get_db():
        async with session_factory() as session:
            yield session

    app.dependency_overrides[get_db] = override_get_db
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as test_client:
        yield test_client, session_factory
    app.dependency_overrides.clear()
    await engine.dispose()


async def register(client, email: str) -> dict:
    response = await client.post(
        "/auth/register", json={"email": email, "password": "password123"}
    )
    assert response.status_code == 201
    return response.json()


async def login(client, email: str) -> str:
    response = await client.post(
        "/auth/login", json={"email": email, "password": "password123"}
    )
    assert response.status_code == 200
    return response.json()["access_token"]


@pytest.mark.asyncio
async def test_unauthenticated_me(client):
    response = await client[0].get("/users/me")
    assert response.status_code == 401


@pytest.mark.asyncio
async def test_auth_flow(client):
    await register(client[0], "login@example.com")
    assert await login(client[0], "login@example.com")
    response = await client[0].post(
        "/auth/login",
        json={"email": "login@example.com", "password": "wrongpassword"},
    )
    assert response.status_code == 401


@pytest.mark.asyncio
async def test_vertical_rbac(client):
    test_client, session_factory = client
    await register(test_client, "user@example.com")
    token = await login(test_client, "user@example.com")
    headers = {"Authorization": f"Bearer {token}"}
    assert (
        await test_client.get("/admin/dashboard", headers=headers)
    ).status_code == 403

    async with session_factory() as session:
        user = await session.get(User, 1)
        assert user is not None
        user.role = "ADMIN"
        await session.commit()
    admin_token = await login(test_client, "user@example.com")
    assert (
        await test_client.get(
            "/admin/dashboard",
            headers={"Authorization": f"Bearer {admin_token}"},
        )
    ).status_code == 200


@pytest.mark.asyncio
async def test_horizontal_idor_protection(client):
    test_client, _ = client
    await register(test_client, "a@example.com")
    second_user = await register(test_client, "b@example.com")
    token = await login(test_client, "a@example.com")
    response = await test_client.put(
        f"/users/{second_user['id']}",
        headers={"Authorization": f"Bearer {token}"},
        json={"email": "changed@example.com"},
    )
    assert response.status_code == 403


def test_simulation_parameters_reject_non_finite_values():
    with pytest.raises(ValidationError):
        SimulationRequest(initial_speed=float("nan"))
    with pytest.raises(ValidationError):
        SimulationRequest(object_mass=float("inf"))


def test_secure_coordinates_follow_non_linear_geodesic_formula():
    trajectory = calculate_secure_coordinates(
        dimension_id=3,
        complexity=2,
        initial_speed=10,
        object_mass=2,
    )
    assert len(trajectory) == 17
    assert all(len(point) == 3 for point in trajectory)
    assert trajectory[0][0] == 0.0
    assert trajectory[0][1] == 0.0
    assert trajectory[0][2] == 1.6
    assert trajectory[1][0] == 10.0
    assert trajectory[-1][0] == 160.0
    assert trajectory[-1][1] != trajectory[1][1]
    assert trajectory[-1][2] != trajectory[1][2]


def test_secure_coordinates_clamp_extreme_values():
    trajectory = calculate_secure_coordinates(
        dimension_id=1_000_000,
        complexity=100,
        initial_speed=1_000_000,
        object_mass=1_000_000,
    )
    assert all(abs(value) <= 1e12 for point in trajectory for value in point)
