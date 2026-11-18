import json
import logging

import pytest
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from src.observability import JsonFormatter, install


def make_app(fail_rate: float) -> FastAPI:
    app = FastAPI()
    install(app, fail_rate)

    @app.get("/health")
    async def health():
        return {"status": "ok"}

    @app.get("/items/{item_id}")
    async def item(item_id: int):
        return {"id": item_id}

    return app


async def get(app: FastAPI, path: str):
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://t") as c:
        return await c.get(path)


@pytest.mark.asyncio
async def test_metrics_use_route_template_not_raw_path():
    app = make_app(fail_rate=0.0)
    for item_id in (1, 2, 3):
        assert (await get(app, f"/items/{item_id}")).status_code == 200
    await get(app, "/no-such-page")
    body = (await get(app, "/metrics")).text
    series = 'http_requests_total{method="GET",route="/items/{item_id}",status="200"}'
    assert series in body
    assert 'route="unmatched",status="404"' in body
    assert "http_request_duration_seconds_bucket" in body
    assert 'route="/items/1"' not in body  # low cardinality: no raw ids in labels


@pytest.mark.asyncio
async def test_fail_rate_breaks_requests_but_not_probes():
    app = make_app(fail_rate=1.0)
    assert (await get(app, "/items/7")).status_code == 500
    assert (await get(app, "/health")).status_code == 200
    assert (await get(app, "/metrics")).status_code == 200


def test_json_log_line_has_request_fields():
    record = logging.LogRecord(
        "portal.access", logging.INFO, __file__, 1, "GET %s", ("/x",), None
    )
    record.method, record.route = "GET", "/x"
    record.status, record.duration_ms = 500, 1.5
    entry = json.loads(JsonFormatter().format(record))
    assert entry["level"] == "INFO" and entry["message"] == "GET /x"
    assert {k: entry[k] for k in ("method", "route", "status", "duration_ms")} == {
        "method": "GET",
        "route": "/x",
        "status": 500,
        "duration_ms": 1.5,
    }
    assert entry["time"].endswith("+00:00")
