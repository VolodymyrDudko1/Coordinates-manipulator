#!/bin/sh
# Container entrypoint for the web service:
#   wait for DB -> apply Alembic migrations -> exec the CMD (gunicorn, or uvicorn --reload in dev).
# `exec` replaces the shell, so the server becomes PID 1 and receives SIGTERM from `docker stop`.
set -e

if [ "${RUN_MIGRATIONS:-1}" = "1" ]; then
    python -m scripts.prestart
    echo "entrypoint: applying migrations (alembic upgrade head)"
    alembic upgrade head
    echo "entrypoint: schema at revision $(alembic current 2>/dev/null | tail -n1)"
fi

exec "$@"
