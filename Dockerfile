# syntax=docker/dockerfile:1
#
# Backend image for the FastAPI "Multidimensional Portal Generator" API.
#
# Base image: python:3.12-slim
#   * 3.12 - the version the project is developed and tested with (CI uses 3.12);
#   * slim (Debian bookworm) - glibc, so manylinux wheels (asyncpg, bcrypt, pydantic-core)
#     install as-is; ~10x smaller than the full python image. Alpine is avoided because
#     musl has no prebuilt wheels for several deps -> compiling them makes it slower/bigger.
#
# Multi-stage:
#   builder - has gcc, builds a self-contained virtualenv in /opt/venv;
#   runtime - only the venv + application code, no compilers, no pip cache, non-root.

############################ builder ############################
FROM python:3.12-slim AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# gcc is only a safety net for deps without a wheel for this platform (e.g. arm64);
# it never reaches the final image. libpq-dev is not needed: asyncpg talks the
# PostgreSQL protocol itself.
RUN apt-get update \
 && apt-get install -y --no-install-recommends gcc \
 && rm -rf /var/lib/apt/lists/*

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# requirements first: this layer is rebuilt only when dependencies change.
COPY multidimensional-portal-generator/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt \
 && { pip uninstall -y pip setuptools wheel || true; }

############################ runtime ############################
FROM python:3.12-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH" \
    PORT=8000

# Unprivileged system user; the code stays root-owned => read-only for the app.
RUN groupadd --system app && useradd --system --gid app --create-home --home-dir /home/app app

WORKDIR /app

COPY --from=builder /opt/venv /opt/venv
# Code last: editing the app does not invalidate the dependency layers above.
COPY multidimensional-portal-generator/alembic.ini \
     multidimensional-portal-generator/gunicorn.conf.py ./
COPY multidimensional-portal-generator/migrations ./migrations
COPY multidimensional-portal-generator/scripts ./scripts
COPY multidimensional-portal-generator/src ./src
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

USER app

EXPOSE 8000

# entrypoint: wait for DB -> alembic upgrade head -> exec CMD
ENTRYPOINT ["docker-entrypoint.sh"]
# gunicorn as process manager + uvicorn ASGI workers; bind/workers in gunicorn.conf.py
CMD ["gunicorn", "src.main:app", "--config", "gunicorn.conf.py"]
