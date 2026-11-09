import os

import pytest
from httpx import ASGITransport, AsyncClient
from src.main import INSTANCE_NAME, app


@pytest.mark.asyncio
async def test_whoami_identifies_replica_and_sets_served_by_header():
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as client:
        response = await client.get("/whoami")

    assert response.status_code == 200
    body = response.json()
    assert body["instance_id"] == INSTANCE_NAME
    assert body["pid"] == os.getpid()
    assert body["hostname"]
    assert response.headers["X-Served-By"] == INSTANCE_NAME


@pytest.mark.asyncio
async def test_slow_sleeps_within_requested_bounds():
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as client:
        response = await client.get("/slow", params={"min_ms": 10, "max_ms": 20})
        rejected = await client.get("/slow", params={"max_ms": 10_000})

    assert response.status_code == 200
    assert 10 <= response.json()["slept_ms"] <= 20
    assert response.headers["X-Served-By"] == INSTANCE_NAME
    assert rejected.status_code == 422
