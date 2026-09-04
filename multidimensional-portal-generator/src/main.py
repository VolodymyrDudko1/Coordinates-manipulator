from concurrent.futures import ProcessPoolExecutor
from typing import Any, Dict

from fastapi import FastAPI, status

from .database import Base, engine

# from .schemas import PortalRequest, SimulationResponse
# from .generator.portal_math import calculate_secure_coordinates

app = FastAPI(
    title="Multidimensional Portal Generator API",
    description="High-performance batch-calculating engine for spatial coordinates.",
)

# Allocate Process Pool Executor dedicated to CPU-heavy physics calculations
cpu_executor = ProcessPoolExecutor()


@app.on_event("startup")
async def startup_event() -> None:
    # Auto-creates database schemas during initial local testing
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)


@app.post(
    "/simulations/run",
    response_model=Dict[str, Any],
    status_code=status.HTTP_201_CREATED,
)
@app.on_event("shutdown")
def shutdown_event() -> None:
    cpu_executor.shutdown(wait=True)
