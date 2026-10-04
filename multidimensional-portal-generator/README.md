# Multidimensional Portal Generation

## Лабораторна робота №3 — Option B: Cloud Deployment on Render

**Course:** Development of High Workload Applications using Python
**Domain:** Multidimensional Portal Generation (*Генератор багатовимірних порталів*)
**Application class:** Compute-intensive application (*Обчислювально-місткий застосунок*)

This project demonstrates an asynchronous Python application that generates
non-linear three-dimensional geodesic trajectories and renders them in an
interactive HTML5 Canvas dashboard. Lab 3 is implemented using **Option B:
Cloud Deployment on a Free Server (Render)**, rather than a CI/CD pipeline.

## 1. Project and Architectural Overview

The system is a decoupled three-tier architecture:

```text
Browser
   │
   ▼
Django Web Dashboard (:8080)
   │  server-side httpx.AsyncClient proxy
   ▼
FastAPI Calculation API (:8000)
   │  async SQLAlchemy / asyncpg
   ▼
PostgreSQL (:5432, internal Docker network)
```

### Async API layer — FastAPI

The backend is located in `multidimensional-portal-generator/src/`.

- FastAPI exposes authentication, user, and simulation endpoints.
- The `/simulations/run` endpoint validates the request with Pydantic.
- Non-linear coordinate generation is performed by the pure, top-level
  `calculate_secure_coordinates` worker.
- CPU-intensive spatial calculations are submitted to a
  `ProcessPoolExecutor` with `asyncio.get_running_loop().run_in_executor`.
- The event loop remains available for HTTP and database I/O while the
  physics calculation runs in a separate process.
- Coordinates are returned as JSON triplets:

  ```json
  [[x0, y0, z0], [x1, y1, z1], "..."]
  ```

The geodesic worker combines axial displacement, mass-dependent gravitational
drop, dimensional warp harmonics, and depth oscillation. Numerical values are
validated and clamped before serialization.

### Client proxy layer — Django

The client is located in `portal_client/`.

- Django serves the dashboard, login, registration, and HTML templates.
- Browser requests are sent to Django rather than directly to FastAPI.
- Django uses `httpx.AsyncClient` for server-side proxy requests.
- The JWT remains in the Django session and is attached server-side as:

  ```http
  Authorization: Bearer <token>
  ```

- This design avoids browser-to-backend CORS requirements and prevents the
  access token from being exposed to Canvas JavaScript.
- `canvas_sim.js` receives the generated triplets, performs isometric 3D-to-2D
  projection, calculates a dynamic bounding box, and animates the trajectory
  with `requestAnimationFrame`.

### Database and configuration layer

- PostgreSQL 16 is used for persistent application data.
- SQLAlchemy 2.0 asynchronous sessions use the `asyncpg` driver.
- `pydantic-settings` loads environment-specific configuration.
- PostgreSQL data is stored in the named Docker volume `postgres-data`.
- The database container is not published to the host in Compose; application
  services access it through the internal hostname `db`.

## 2. Configuration Management and Environment Profiles

The project replaces hardcoded deployment credentials with environment
variables (*Змінні оточення*). Real environment files are excluded from Git.
Only safe templates are committed:

- `.env.example` — complete local template, including Compose variables.
- `.env.sandbox.example` — sandbox application settings template.
- `.env.production.example` — production settings template.
- `.env.sandbox` — local file created from the sandbox template.
- `.env.production` — deployment/local production file, never committed.

`src/config.py` selects the profile from `ENVIRONMENT` and loads the matching
file:

```python
env_file=f".env.{environment}"
```

Environment variables supplied directly by Docker, Render, or the shell take
precedence over values in the environment file.

### Configuration variables

| Variable | Sandbox example | Production example | Purpose |
|---|---|---|---|
| `ENVIRONMENT` | `sandbox` | `production` | Selects the configuration profile |
| `DEBUG` | `True` | `False` | Enables development diagnostics or production masking |
| `SECRET_KEY` | Local development secret | Strong secret or Render-generated value | JWT signing and application security |
| `ALGORITHM` | `HS256` | `HS256` | JWT signing algorithm |
| `ACCESS_TOKEN_EXPIRE_MINUTES` | `30` | `30` | JWT lifetime |
| `DATABASE_URL` | Internal/local PostgreSQL URL | Managed PostgreSQL connection string | Async SQLAlchemy database connection |
| `PORT` | `8000` | Render-provided `$PORT` | HTTP port used by Uvicorn |

Never commit real passwords, database URLs, JWT secrets, or Render credentials.

### Production error masking

When `DEBUG=False`, the global FastAPI exception handler logs the full
traceback internally but returns only:

```json
{
  "message": "An internal server error occurred."
}
```

This prevents public exposure of internal Python stack traces (*Стектрейси
викликів*) and implementation details. With `DEBUG=True`, detailed exception
messages are available for sandbox diagnostics.

## 3. Database Isolation

Sandbox and production data must use separate PostgreSQL databases and
credentials. Test actions must never run against live production data.

| Environment | Database | Intended use |
|---|---|---|
| Sandbox | `portal_db_sandbox` | Local feature development, experiments, and tests |
| Production | `portal_db_prod` | Isolated Render-managed production workload |

For local Docker Compose, set `POSTGRES_DB=portal_db_sandbox` and make the
database name in `DATABASE_URL` match it. Render provisions
`portal-db-prod` from `render.yaml`; its database name is `portal_db_prod`.

The Compose database is persistent through `postgres-data`, but it remains a
separate local instance from the managed Render database.

## 4. How to Run the Application Locally

### Prepare the sandbox profile

From the repository root:

```bash
cp .env.sandbox.example .env.sandbox
```

Edit `.env.sandbox` and set a local secret and a sandbox-only
`DATABASE_URL`. For Compose, use the complete `.env.example` as a starting
point because it also contains `POSTGRES_USER`, `POSTGRES_PASSWORD`, and
`POSTGRES_DB`:

```bash
cp .env.example .env.sandbox
```

Use a sandbox database such as `portal_db_sandbox`.

### Local Uvicorn launch

The requested profile-oriented commands are:

```bash
# Sandbox
ENV_FILE=.env.sandbox uvicorn src.main:app --host 0.0.0.0 --port 8000 --reload

# Production
ENV_FILE=.env.production uvicorn src.main:app --host 0.0.0.0 --port 8000
```

In the current implementation, profile selection is controlled by
`ENVIRONMENT`, not by `ENV_FILE`. The directly executable equivalents are:

```bash
# Run from multidimensional-portal-generator/
ENVIRONMENT=sandbox uvicorn src.main:app --host 0.0.0.0 --port 8000 --reload
ENVIRONMENT=production uvicorn src.main:app --host 0.0.0.0 --port 8000
```

Ensure `DATABASE_URL`, `SECRET_KEY`, and the appropriate `.env.<environment>`
file are available before starting the API.

The API documentation is then available at:

```text
http://localhost:8000/docs
```

### Docker Compose multi-container launch

The requested commands are:

```bash
# Sandbox
docker compose --env-file .env.sandbox up --build

# Production
docker compose --env-file .env.production up -d --build
```

The Compose file starts:

| Service | Role | Host port |
|---|---|---:|
| `db` | PostgreSQL 16 | Internal `5432` only |
| `backend` | FastAPI and physics worker | `8000` |
| `client` | Django dashboard and proxy | `8080` |

Open the dashboard at:

```text
http://localhost:8080/
```

The client waits for a healthy backend, and the backend waits for a healthy
database. To inspect runtime status:

```bash
docker compose --env-file .env.sandbox ps
docker compose --env-file .env.sandbox logs -f backend client db
```

## 5. Option B — Cloud Deployment on Render

### Infrastructure as Code

`render.yaml` is the Render Infrastructure-as-Code (*Інфраструктура як код*)
blueprint. It defines both the web service and the managed database:

```yaml
services:
  - type: web
    name: portal-generator-api
    env: docker
    plan: free
    dockerfilePath: ./Dockerfile
    healthCheckPath: /docs

databases:
  - name: portal-db-prod
    plan: free
    databaseName: portal_db_prod
    user: postgres
```

The blueprint configures production values:

- `ENVIRONMENT=production`
- `DEBUG=False`
- Render-generated `SECRET_KEY`
- `DATABASE_URL` linked automatically to the managed PostgreSQL connection
  string
- `/docs` as the health-check endpoint

### Dynamic port binding

Render assigns the listening port through the `$PORT` environment variable.
The production `Dockerfile` supports both Render and local execution:

```dockerfile
CMD ["sh", "-c", "uvicorn src.main:app --host 0.0.0.0 --port ${PORT:-8000}"]
```

The service binds to the Render-provided port in the cloud and falls back to
port `8000` locally.

### Render deployment steps

1. Push this repository to GitHub.
2. In Render, choose **New → Blueprint**.
3. Connect the repository and select `render.yaml`.
4. Confirm the free web service and PostgreSQL plan.
5. Render builds `Dockerfile`, provisions `portal-db-prod`, generates the
   production secret, and injects the managed connection string.
6. Wait for the `/docs` health check to report the web service as healthy.

The managed database is separate from all sandbox databases. Do not point a
local test profile at the Render production connection string.

### Live public API URL

After deployment, the public API documentation is available at:

```text
https://portal-generator-api.onrender.com/docs
```

The exact hostname may differ if the Render service name is changed. The
Render dashboard is the source of truth for the deployed URL.

## 6. Verification and Testing

Run the backend test suite from the repository root:

```bash
cd multidimensional-portal-generator
../.venv/bin/pytest -q
```

Run static checks:

```bash
.venv/bin/ruff check multidimensional-portal-generator/src \
  multidimensional-portal-generator/tests
node --check portal_client/simulator/static/simulator/js/canvas_sim.js
```

Expected checks include:

- Authentication and role-based access control
- Horizontal IDOR protection
- Rejection of non-finite simulation values
- Non-linear geodesic triplet generation
- Coordinate clamping and JSON-safe output
- Canvas script syntax

## 7. Operational Notes

- Use sandbox credentials and `portal_db_sandbox` for development.
- Use Render-managed secrets and `portal_db_prod` for production.
- Keep `DEBUG=False` in production.
- Do not publish PostgreSQL port `5432` unnecessarily.
- Check container health before debugging the Canvas:

  ```bash
  docker compose ps
  curl -f http://localhost:8000/docs
  curl -f http://localhost:8080/
  ```

- The dashboard proxy logs backend status and response information; the
  Canvas renderer logs payload shape, point count, bounding-box values, scale
  factors, and invalid coordinates in the browser console.
