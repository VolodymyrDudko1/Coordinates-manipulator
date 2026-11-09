"""Gunicorn settings for the FastAPI app (ASGI via uvicorn workers).

All knobs come from the environment so the same image runs in compose and on Render.
"""

import os

bind = f"0.0.0.0:{os.getenv('PORT', '8000')}"
worker_class = "uvicorn_worker.UvicornWorker"
# Each worker is a separate process with its own event loop (and its own
# ProcessPoolExecutor), so this is the main horizontal knob inside one container.
workers = int(os.getenv("WEB_CONCURRENCY", "2"))
timeout = int(os.getenv("GUNICORN_TIMEOUT", "60"))
graceful_timeout = 20
keepalive = 5
accesslog = "-"  # stdout -> `docker compose logs web`
errorlog = "-"
loglevel = os.getenv("LOG_LEVEL", "info")
# Trust X-Forwarded-For/-Proto only from these proxies. Behind Nginx (Lab 6) the
# replicas are reachable only on the internal network, so "*" is safe there.
forwarded_allow_ips = os.getenv("FORWARDED_ALLOW_IPS", "127.0.0.1")
