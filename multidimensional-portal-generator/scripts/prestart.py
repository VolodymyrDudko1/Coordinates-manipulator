"""Pre-start checks run by docker-entrypoint.sh before migrations.

1. Wait until the database accepts connections (``depends_on: service_healthy``
   covers the first start, this also covers restarts and external databases).
2. Adopt databases created before Alembic was introduced: if the tables exist
   but ``alembic_version`` does not, stamp revision 0001 instead of failing on
   "relation already exists".
"""

import asyncio
import os
import sys
import time

from alembic import command
from alembic.config import Config
from sqlalchemy import inspect, text
from sqlalchemy.ext.asyncio import create_async_engine
from src.config import settings

TIMEOUT = float(os.getenv("DB_WAIT_TIMEOUT", "60"))
BASELINE_REVISION = "0001"


async def wait_for_db() -> set[str]:
    engine = create_async_engine(settings.DATABASE_URL)
    deadline = time.monotonic() + TIMEOUT
    attempt = 0
    try:
        while True:
            attempt += 1
            try:
                async with engine.connect() as conn:
                    await conn.execute(text("SELECT 1"))
                    tables = await conn.run_sync(
                        lambda c: set(inspect(c).get_table_names())
                    )
                print(f"prestart: database is up (attempt {attempt})", flush=True)
                return tables
            except Exception as exc:  # noqa: BLE001
                if time.monotonic() > deadline:
                    print(
                        f"prestart: database unreachable after {TIMEOUT:.0f}s: {exc}",
                        file=sys.stderr,
                        flush=True,
                    )
                    raise SystemExit(1) from exc
                print(
                    f"prestart: waiting for database ({type(exc).__name__})", flush=True
                )
                await asyncio.sleep(1)
    finally:
        await engine.dispose()


def main() -> None:
    tables = asyncio.run(wait_for_db())
    if "users" in tables and "alembic_version" not in tables:
        print(
            f"prestart: legacy schema, no alembic_version -> stamp {BASELINE_REVISION}",
            flush=True,
        )
        command.stamp(Config("alembic.ini"), BASELINE_REVISION)


if __name__ == "__main__":
    main()
