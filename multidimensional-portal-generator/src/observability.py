"""Observability for Lab 7: JSON logs, Prometheus metrics and fault injection.

* Logs: one JSON object per line on stdout (time, level, logger, message and, for
  requests, method / route / status / duration_ms); Loki parses them with ``| json``.
* Metrics: ``http_requests_total{method,route,status}`` and
  ``http_request_duration_seconds{method,route}`` on ``/metrics``. ``route`` is the
  route *template* (``/simulations/{sim_id}``), never the raw path, so label
  cardinality stays small; unknown paths are reported as ``unmatched``.
* ``FAIL_RATE`` (0..1): share of requests answered with HTTP 500 on purpose, to
  simulate a bad release. Probes and ``/metrics`` are never failed, so pods stay
  Ready and only the error rate changes.
"""

import json
import logging
import random
import sys
import time
from datetime import UTC, datetime

from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest
from starlette.routing import Match

REQUESTS = Counter(
    "http_requests_total",
    "HTTP requests processed, by method, route template and status code.",
    ["method", "route", "status"],
)
LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request duration in seconds, by method and route template.",
    ["method", "route"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
)

# Kubernetes probes and the scrape endpoint: never failed on purpose, logged at DEBUG.
QUIET_ROUTES = {"/health", "/ready", "/metrics"}
REQUEST_FIELDS = ("method", "route", "status", "duration_ms")

access_logger = logging.getLogger("portal.access")


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        entry = {
            "time": datetime.fromtimestamp(record.created, UTC).isoformat(
                timespec="milliseconds"
            ),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }
        for field in REQUEST_FIELDS:
            if hasattr(record, field):
                entry[field] = getattr(record, field)
        if record.exc_info:
            entry["exc"] = self.formatException(record.exc_info)
        return json.dumps(entry, ensure_ascii=False)


def setup_logging(level: str) -> None:
    """Route every logger (ours and uvicorn's) to one JSON handler on stdout."""
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(level.upper())
    for name in ("uvicorn", "uvicorn.error", "uvicorn.access"):
        uv = logging.getLogger(name)
        uv.handlers = []
        uv.propagate = True
    # Access lines come from the middleware below (route + duration), not uvicorn.
    logging.getLogger("uvicorn.access").disabled = True


def route_template(request: Request) -> str:
    for route in request.app.router.routes:
        match, _ = route.matches(request.scope)
        if match == Match.FULL:
            return getattr(route, "path", "unmatched")
    return "unmatched"


def install(app: FastAPI, fail_rate: float) -> None:
    @app.middleware("http")
    async def observe(request: Request, call_next) -> Response:
        route = route_template(request)
        start = time.perf_counter()
        if route not in QUIET_ROUTES and fail_rate > 0 and random.random() < fail_rate:
            response: Response = JSONResponse(
                status_code=500, content={"message": "Injected failure (FAIL_RATE)"}
            )
        else:
            response = await call_next(request)
        duration = time.perf_counter() - start

        REQUESTS.labels(request.method, route, str(response.status_code)).inc()
        LATENCY.labels(request.method, route).observe(duration)
        access_logger.log(
            logging.DEBUG if route in QUIET_ROUTES else logging.INFO,
            "%s %s %s",
            request.method,
            route,
            response.status_code,
            extra={
                "method": request.method,
                "route": route,
                "status": response.status_code,
                "duration_ms": round(duration * 1000, 2),
            },
        )
        return response

    @app.get("/metrics", include_in_schema=False)
    async def metrics() -> Response:
        return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
