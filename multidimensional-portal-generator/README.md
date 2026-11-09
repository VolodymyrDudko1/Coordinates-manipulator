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
    healthCheckPath: /health

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

---

## Лабораторна робота 5 — Контейнеризація веб-системи з Docker

**Мета:** запакувати MVP (FastAPI) і базу даних в ізольовані контейнери, оркестрація через
`docker-compose.yml`, персистентні дані БД, запуск усієї системи **однією командою**:

```bash
docker compose up --build
```

### 5.1 Архітектура

```text
                 Host (localhost)
                       │  :8000  (єдиний опублікований порт, WEB_PORT)
┌──────────────────────┼──────────────────────────────────────────────────────────┐
│ docker compose       ▼                     project "portal"                     │
│               ┌──────────────────┐   network: frontend (bridge)                 │
│               │ web              │◄──────────────── client (Django, profile     │
│               │ gunicorn +       │                   "client", :8080, опційно)   │
│               │ uvicorn workers  │                                              │
│               │ user: app (999)  │                                              │
│               └────────┬─────────┘                                              │
│                        │ postgresql+asyncpg://…@db:5432  (DNS-ім'я сервісу "db")  │
│               ┌────────┴─────────┐   network: backend (internal: true —         │
│               │ db               │            без виходу назовні й без портів   │
│               │ postgres:16-alpine│           на хост)                          │
│               └────────┬─────────┘                                              │
│                        │                                                        │
│               volume pgdata ──► /var/lib/postgresql/data                         │
│               (переживає `docker compose down`; видаляється лише `down -v`)      │
└──────────────────────────────────────────────────────────────────────────────────┘
```

Порядок старту: `db` → healthcheck `pg_isready` = healthy → `web` (entrypoint: очікування БД →
`alembic upgrade head` → gunicorn) → healthcheck `GET /health` (виконує `SELECT 1`) = healthy.

### 5.2 Файли та ключові директиви

| Файл | Призначення |
|---|---|
| `Dockerfile` | Multi-stage образ backend |
| `.dockerignore` | Що НЕ потрапляє в build context |
| `docker-compose.yml` | Production-стек: `web` + `db` (+ опційний `client`) |
| `docker-compose.dev.yml` | Dev-оверлей: bind mount коду + `uvicorn --reload` |
| `.env.example` | Шаблон змінних (комітиться); реальний `.env` — у `.gitignore` і `.dockerignore` |
| `docker-entrypoint.sh` | wait-for-db → міграції → `exec` сервера |
| `multidimensional-portal-generator/scripts/prestart.py` | Очікування БД; «усиновлення» старої схеми (stamp) |
| `multidimensional-portal-generator/alembic.ini`, `migrations/` | Alembic, ревізія `0001` — початкова схема |
| `multidimensional-portal-generator/gunicorn.conf.py` | bind `0.0.0.0:$PORT`, `WEB_CONCURRENCY` воркерів `uvicorn_worker.UvicornWorker` |
| `src/main.py` → `GET /health` | 200 `{"status":"ok","database":"ok"}` або 503, якщо БД недоступна |

**Dockerfile**

- `FROM python:3.12-slim` — та сама версія Python, що в розробці й CI; Debian slim (glibc) ставить
  готові manylinux-wheels (`asyncpg`, `bcrypt`, `pydantic-core`) без компіляції; Alpine (musl)
  змусив би компілювати частину залежностей.
- **Stage `builder`**: `gcc` (страховка для платформ без wheels; `libpq-dev` не потрібен — asyncpg
  реалізує протокол PostgreSQL сам), `python -m venv /opt/venv`, `pip install --no-cache-dir`,
  після чого з venv видаляються `pip/setuptools/wheel`.
- **Stage `runtime`**: чистий `python:3.12-slim` + `COPY --from=builder /opt/venv` + код. Компіляторів,
  кешу pip і build-залежностей немає.
- Кешування шарів: спочатку `requirements.txt` → `pip install`, код копіюється останнім — зміна коду
  не перевстановлює залежності.
- `ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1` — без `.pyc`, логи одразу в stdout.
- `USER app` — непривілейований системний користувач (uid 999); код належить root, тобто для
  застосунку лише на читання.
- `EXPOSE 8000`; `ENTRYPOINT ["docker-entrypoint.sh"]`, `CMD ["gunicorn", "src.main:app", "--config", "gunicorn.conf.py"]`
  — gunicorn як менеджер процесів + uvicorn ASGI-воркери, bind `0.0.0.0`.

**docker-compose.yml**

- `name: portal` — фіксоване ім'я проєкту: контейнери `portal-web-1`, `portal-db-1`, том `portal_pgdata`.
- `db`: `postgres:16-alpine`, облікові дані **лише** з `.env` (`env_file`), том `pgdata`, порт **не
  опубліковано** (рядок `ports` закоментовано для налагодження), healthcheck `pg_isready -U … -d …`.
- `web`: `build` з `Dockerfile`; `DATABASE_URL` збирається з тих самих `POSTGRES_*`, хост — ім'я
  сервісу `db`; опубліковано лише `${WEB_PORT:-8000}:8000`; `depends_on: db: condition: service_healthy`;
  healthcheck на `/health` (python urllib — curl у slim-образі немає).
- Мережі: `backend` (`internal: true`) — тільки `web` ↔ `db`, БД не має доступу в інтернет і не
  видна з хоста; `frontend` — опублікований порт `web` і опційний `client`.
- `restart: unless-stopped` для всіх сервісів.
- `client` (Django-дашборд з ЛР 1–3) — під `profiles: ["client"]`, тому `docker compose up` його не
  запускає: `docker compose --profile client up --build`.

**Міграції — entrypoint, а не окремий сервіс `migrate`.** Скрипт виконується в кожному контейнері `web`
перед стартом gunicorn (до форку воркерів, тобто один раз на контейнер): не потрібен окремий
сервіс і `depends_on: service_completed_successfully`, а будь-який запуск образу — compose, Render,
`docker run` — гарантовано отримує актуальну схему. `alembic upgrade head` ідемпотентний: при
повторних стартах він нічого не робить. Обмеження: при кількох репліках `web` міграції краще
винести в one-off сервіс/job, щоб не запускати їх паралельно; вимкнути в контейнері — `RUN_MIGRATIONS=0`.
`prestart.py` додатково чекає БД до 60 с (`DB_WAIT_TIMEOUT`) і, якщо таблиці вже створені старим
`create_all` без `alembic_version`, робить `alembic stamp 0001` замість помилки «relation already exists».

Схемою PostgreSQL тепер керує Alembic; `Base.metadata.create_all` у `startup` залишено лише для
локального запуску на SQLite без Docker. Відповідність міграції моделям перевірено `alembic check`
(`No new upgrade operations detected`).

### 5.3 Запуск і перевірка

```bash
cp .env.example .env        # замініть SECRET_KEY і POSTGRES_PASSWORD (лише URL-безпечні символи)
docker compose up --build   # або з -d --wait, щоб повернути термінал після статусу healthy
```

Очікувано в кінці виводу: `Container portal-db-1 Healthy`, `Container portal-web-1 Started/Healthy`.

```console
$ docker compose ps
NAME           IMAGE                COMMAND                  SERVICE   STATUS                    PORTS
portal-db-1    postgres:16-alpine   "docker-entrypoint.s…"   db        Up 19 seconds (healthy)   5432/tcp
portal-web-1   portal-web:latest    "docker-entrypoint.s…"   web       Up 13 seconds (healthy)   0.0.0.0:8000->8000/tcp
```

`5432/tcp` без `0.0.0.0:` — порт БД не опубліковано на хост.

```console
$ docker compose logs web
web-1  | prestart: database is up (attempt 1)
web-1  | entrypoint: applying migrations (alembic upgrade head)
web-1  | INFO  [alembic.runtime.migration] Context impl PostgresqlImpl.
web-1  | INFO  [alembic.runtime.migration] Will assume transactional DDL.
web-1  | INFO  [alembic.runtime.migration] Running upgrade  -> 0001, Initial schema: users and portal_simulations.
web-1  | entrypoint: schema at revision 0001 (head)
web-1  | [INFO] Starting gunicorn 26.2.0
web-1  | [INFO] Listening at: http://0.0.0.0:8000 (1)
web-1  | [INFO] Using worker: uvicorn_worker.UvicornWorker
web-1  | [INFO] Booting worker with pid: 23
web-1  | [INFO] Booting worker with pid: 24
web-1  | 127.0.0.1:60332 - "GET /health HTTP/1.1" 200
```

На повторних стартах рядка `Running upgrade` немає — схема вже на `0001 (head)`.

**API (створення + читання даних):**

```bash
B=http://localhost:8000; E=lab5@example.com; P='Lab5Password!'
curl -s $B/health
# {"status":"ok","database":"ok"}
curl -s -H 'Content-Type: application/json' -d "{\"email\":\"$E\",\"password\":\"$P\"}" $B/auth/register
# {"id":1,"email":"lab5@example.com","role":"USER","is_active":true}            (HTTP 201)
TOKEN=$(curl -s -H 'Content-Type: application/json' -d "{\"email\":\"$E\",\"password\":\"$P\"}" $B/auth/login \
        | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
curl -s -H "Authorization: Bearer $TOKEN" $B/users/me
# {"id":1,"email":"lab5@example.com","role":"USER","is_active":true}            (HTTP 200)
curl -s -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
     -d '{"dimension_id":7,"complexity":2,"initial_speed":120.5,"object_mass":42}' $B/simulations/run
# {"id":1,"user_id":1,"coordinates":[[0.0,0.0,33.6], …17 точок…],"created_at":"…"}  (HTTP 201)
docker compose exec db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "select id,user_id,json_array_length(coordinates),created_at from portal_simulations;"'
```

**Персистентність:**

```bash
docker compose down                    # контейнери й мережі видалено, том — ні
docker volume ls | grep portal_pgdata  # local  portal_pgdata
docker compose up -d --wait
curl -s -H 'Content-Type: application/json' -d "{\"email\":\"$E\",\"password\":\"$P\"}" $B/auth/login
# {"access_token":"…","token_type":"bearer"}  — користувач, створений до down, на місці
docker compose exec db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "select count(*) from portal_simulations;"'
# 1
```

Повне скидання даних — лише явно: `docker compose down -v`.

**Ізоляція (додаткова перевірка):** з хоста `localhost:5432` недоступний; із контейнера `db`
`wget https://pypi.org` → `bad address` (мережа `internal`); `docker compose exec web id` →
`uid=999(app)`.

**Навантажувальні тести ЛР 4** працюють проти цього стеку без змін у сценарії: `host` у
`load-tests/locust.conf` = `http://localhost:8000`, `monitor.py`/`run_test.sh` за замовчуванням
стежать за `portal-web-1`/`portal-db-1` (див. `load-tests/README.md`). Smoke-прогін 5 VU × 30 с:
74 запити, 0 % помилок.

### 5.4 Multi-stage build: розмір образу

```bash
docker images portal-web
```

| Образ | Опис | Розмір |
|---|---|---:|
| `portal-web:before-lab5` | вихідний одностадійний `Dockerfile` (до ЛР 5: без gunicorn/alembic, без gcc, root) | 309 MB |
| `portal-web:single-stage` | ті самі залежності, що й зараз, але одна стадія з `gcc` (як «наївний» Dockerfile) | 547 MB |
| `portal-web:latest` | **multi-stage** (`builder` → `runtime`) | **304 MB** |

Multi-stage прибирає з фінального образу компілятор і build-шари: −243 MB (−44 %) порівняно з
одностадійною збіркою з тими самими залежностями, і навіть трохи менше за вихідний образ, хоча
додано gunicorn, uvicorn-worker і alembic. Більшу частину 304 MB становить сам `python:3.12-slim`;
venv займає ~95 MB (ще можна зменшити, винісши `pytest`/`httpx`/`aiosqlite` у dev-залежності).

Щоб відтворити порівняння:

```bash
git show d9b4247:Dockerfile > /tmp/Dockerfile.before          # останній коміт до ЛР 5
docker build -t portal-web:before-lab5 -f /tmp/Dockerfile.before .
docker build --target builder -t portal-web:builder .          # стадія builder ≈ одностадійний образ з gcc: 565 MB
docker compose build web && docker images portal-web
```

### 5.5 Dev-режим з hot reload

```bash
docker compose -f docker-compose.yml -f docker-compose.dev.yml up --build
```

`docker-compose.dev.yml` для `web`: bind mount `./multidimensional-portal-generator:/app:ro` і
команда `uvicorn src.main:app --host 0.0.0.0 --port 8000 --reload --reload-dir src --reload-dir migrations`.
Entrypoint (міграції) той самий. Файл навмисно **не** названо `docker-compose.override.yml`: той
автоматично підхоплюється звичайним `docker compose up`, а production-стек має лишатися без bind
mounts і reload.

Демонстрація (перевірено):

1. `curl -s localhost:8000/health` → `{"status":"ok","database":"ok"}`.
2. Змінити відповідь `/health` у `src/main.py` і зберегти файл (образ не перезбирається).
3. У логах (`docker compose logs -f web`):
   ```
   WARNING:  StatReload detected changes in 'src/main.py'. Reloading...
   INFO:     Shutting down
   INFO:     Started server process [39]
   ```
4. Через ~2 с `curl` повертає нову відповідь.

Повернення до production: `docker compose -f docker-compose.yml -f docker-compose.dev.yml down && docker compose up -d --build`.

### 5.6 Скріншоти для звіту

1. `docker compose up --build` — кінець збірки (`builder`/`runtime` стадії) і `portal-db-1 Healthy`, `portal-web-1 Started`.
2. `docker compose ps` — обидва сервіси `(healthy)`, опубліковано лише `8000`.
3. `docker compose logs web` — `prestart: database is up`, `Running upgrade -> 0001`, `Starting gunicorn`, воркери.
4. `curl /health` + `register` (201) + `/users/me` (200) + `/simulations/run` (201).
5. Персистентність: `docker compose down` → `docker volume ls` (том є) → `up` → успішний `login` / `select count(*)`.
6. `docker images portal-web` — порівняння розмірів (before / single-stage / multi-stage).
7. Hot reload: лог `StatReload detected changes … Reloading…` і `curl` до/після зміни.
8. (опційно) `docker compose exec web id` → `uid=999(app)`; `.env` у `git status` відсутній (ignored).
