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

## 8. Deployment to Kubernetes

Розгортання FastAPI backend і PostgreSQL у локальний кластер **minikube** (docker driver)
за допомогою читабельних маніфестів з каталогу `k8s/` (один об'єкт — один файл).
Повна шпаргалка команд для звіту з очікуваним результатом кожної: [`docs/commands.md`](../docs/commands.md).

### Архітектура в кластері

```text
Browser ──► http://portal.local
              │  Ingress (nginx)                 40-ingress.yaml
              ▼
           Service portal-api :80 (ClusterIP)    30-service.yaml
              │  балансування між Ready pod-ами
              ▼
           Deployment portal-api ×2 :8000        20-deployment.yaml
              │  DATABASE_URL (ConfigMap + Secret)
              ▼
           Service portal-db :5432 (ClusterIP)   14-postgres-service.yaml
              ▼
           Deployment portal-db ×1 ──► PVC 1Gi   13-postgres-deployment.yaml, 12-postgres-pvc.yaml
```

Namespace — `dudko`. Конфігурація: `portal-config` (ConfigMap), секрети: `portal-secret` (Secret).

### Передумови

| Інструмент | Навіщо | Перевірка |
|---|---|---|
| Docker | збірка образів, драйвер minikube | `docker version` |
| minikube | локальний кластер Kubernetes | `minikube version` |
| kubectl | керування кластером | `kubectl version --client` |
| curl | перевірка балансування і відсутності простою | `curl --version` |

Ресурси: ~2 CPU і ~4 ГБ RAM, доступні для Docker.

### Розгортання з нуля

1. **Запустити кластер і аддони:**
   ```bash
   minikube start --driver=docker
   minikube addons enable metrics-server
   minikube addons enable ingress
   ```
2. **Зібрати образи `portal-api:1.0.0` і `portal-api:1.1.0` та завантажити їх у minikube:**
   ```bash
   ./scripts/build-images.sh
   ```
   Версія (`APP_VERSION`) і примітка до релізу (`APP_RELEASE_NOTE`) вшиваються в образ через
   `--build-arg`, тому 1.1.0 на сторінці візуально відрізняється від 1.0.0. Тег `latest` не
   використовується; у маніфесті `imagePullPolicy: IfNotPresent`, тож образ береться з вузла.
3. **Застосувати маніфести** (файли застосовуються в алфавітному порядку: спершу namespace,
   потім конфігурація, БД, застосунок, Service, Ingress):
   ```bash
   kubectl apply -f k8s/
   kubectl get pods,deploy,rs,svc,ingress,pvc -n dudko
   ```
4. **Налаштувати доступ за іменем `portal.local`:**
   - Linux з нативним Docker Engine: `echo "$(minikube ip) portal.local" | sudo tee -a /etc/hosts`
   - Linux з Docker Desktop, Windows, macOS: IP minikube з хоста недоступний; додати
     `127.0.0.1 portal.local` у hosts і тримати запущеним `minikube tunnel` в окремому терміналі.
   - Без змін у системі: `kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 18080:80`
     і `curl -H 'Host: portal.local' http://127.0.0.1:18080/`.

   Docker Desktop має виділяти VM щонайменше 3–4 ГБ пам'яті (Settings → Resources), інакше
   `minikube start` завершиться з `RSRC_INSUFFICIENT_CONTAINER_MEMORY`.
5. **Відкрити** `http://portal.local/` — сторінка показує версію, hostname pod-а,
   `APP_GREETING`, `LOG_LEVEL` і замаскований `API_KEY` (`de***`).
   JSON-варіант для curl: `http://portal.local/info`.

### Ендпоінти для Kubernetes

| Шлях | Probe | Поведінка |
|---|---|---|
| `GET /health` | liveness | завжди `200 {"status":"ok"}`, поки процес живий (не залежить від БД) |
| `GET /ready` | readiness | `200 {"status":"ready"}`, якщо таблиці створено і БД відповідає на `SELECT 1`; інакше `503` |
| `GET /` | — | HTML: версія, hostname, конфіг-параметри, маскований секрет |
| `GET /info` | — | те саме однорядковим JSON |

Liveness свідомо не перевіряє БД: якщо PostgreSQL недоступний, перезапуск pod-ів застосунку
не допоможе. Pod лише виключається з балансування через readiness.

### Параметри ConfigMap `portal-config`

| Ключ | Призначення | Приклад |
|---|---|---|
| `APP_GREETING` | заголовок головної сторінки | `Привіт з Kubernetes! Генератор багатовимірних порталів` |
| `LOG_LEVEL` | рівень логування Python | `INFO` |
| `ENVIRONMENT` | профіль конфігурації (`sandbox`/`production`/`testing`) | `sandbox` |
| `DEBUG` | показувати деталі помилок 500 | `False` |
| `POSTGRES_DB` | ім'я БД (читають і postgres, і застосунок) | `portal_db` |
| `POSTGRES_USER` | користувач БД | `portal` |
| `DB_HOST` | DNS-ім'я Service бази даних | `portal-db` |
| `DB_PORT` | порт PostgreSQL | `5432` |

### Параметри Secret `portal-secret`

Значення в репозиторії свідомо фейкові (`dev-only-not-real...`), лише для навчального кластера.

| Ключ | Призначення | Приклад |
|---|---|---|
| `POSTGRES_PASSWORD` | пароль БД; використовують postgres і `DATABASE_URL` | `dev-only-not-real-db-password` |
| `SECRET_KEY` | ключ підпису JWT (HS256, ≥ 32 байти) | `dev-only-not-real-jwt-signing-key-0123456789` |
| `API_KEY` | демонстраційний API-ключ; на сторінці лише перші 2 символи | `dev-only-not-real` → `de***` |

### Змінні, що формуються не з ConfigMap/Secret

| Змінна | Джерело | Приклад |
|---|---|---|
| `APP_VERSION` | `ARG`/`ENV` у `Dockerfile` (через `build-images.sh`) | `1.0.0`, `1.1.0` |
| `APP_RELEASE_NOTE` | `ARG`/`ENV` у `Dockerfile` | `Release 1.1.0: NEW rolling update...` |
| `DATABASE_URL` | `env` у `20-deployment.yaml`, збирається з `$(POSTGRES_USER)`, `$(POSTGRES_PASSWORD)`, `$(DB_HOST)`, `$(DB_PORT)`, `$(POSTGRES_DB)` | `postgresql+asyncpg://portal:***@portal-db:5432/portal_db` |

### Оновлення та відкат

```bash
kubectl set image deployment/portal-api -n dudko portal-api=portal-api:1.1.0
kubectl annotate deployment/portal-api -n dudko --overwrite kubernetes.io/change-cause="Update to portal-api:1.1.0"
kubectl rollout status deployment/portal-api -n dudko
kubectl rollout history deployment/portal-api -n dudko
kubectl rollout undo deployment/portal-api -n dudko
```

Стратегія `RollingUpdate` з `maxUnavailable: 0`, `maxSurge: 1`, readinessProbe і
`preStop: sleep 5` забезпечує оновлення без простою. Зміна ConfigMap/Secret не перезапускає pod-и
автоматично: після `kubectl apply` виконайте `kubectl rollout restart deployment/portal-api -n dudko`.

Django-клієнт (`portal_client/`) у цій лабораторній у кластер не розгортається.

---

## 9. Helm chart

Lab 4: маніфести з `k8s/` перетворено на власний Helm 3 чарт [`chart/portal/`](../chart/portal/).
Чарт створює ті самі об'єкти, що й `k8s/` (крім Namespace — його створює `--create-namespace`):
ConfigMap, Secret, PVC, Deployment і Service для `portal-api` та `portal-db`, Ingress
(якщо ввімкнено), а також pre-upgrade hook Job і тестовий Pod (Task 9, варіант b).
Детальна шпаргалка з очікуваним результатом кожної команди — [`docs/helm-commands.md`](../docs/helm-commands.md).

```text
chart/portal/
├── Chart.yaml               # name, version (чарту), appVersion (застосунку)
├── values.yaml              # значення за замовчуванням (= dev)
├── values-dev.yaml          # 1 репліка, малі ресурси, тег 1.0.0, ingress вимкнено
├── values-prod.yaml         # 3 репліки, більші ресурси, тег 1.1.0, ingress portal-helm-prod.local
└── templates/
    ├── _helpers.tpl         # portal.name, portal.fullname, portal.componentName, portal.labels, portal.selectorLabels
    ├── configmap.yaml  secret.yaml  pvc.yaml
    ├── deployment.yaml  service.yaml  ingress.yaml        # portal-api
    ├── db-deployment.yaml  db-service.yaml                # PostgreSQL
    ├── hooks/pre-upgrade-job.yaml
    ├── tests/test-connection.yaml
    └── NOTES.txt
```

### version vs appVersion

| Поле `Chart.yaml` | Значення | Що означає в цьому проєкті |
|---|---|---|
| `version` | `0.1.0` | Версія **чарту** — шаблонів і структури values. Підвищується, коли змінюються файли в `chart/portal/` (новий шаблон, новий ключ values), навіть якщо код застосунку той самий. |
| `appVersion` | `"1.0.0"` | Версія **застосунку** = тег образу `portal-api` (`scripts/build-images.sh` збирає `1.0.0` і `1.1.0`). Якщо `image.tag` порожній, шаблон бере саме її: `{{ .Values.image.tag \| default .Chart.AppVersion }}`. |

Тобто один і той самий чарт `0.1.0` може розгорнути і `portal-api:1.0.0` (dev), і `portal-api:1.1.0`
(prod / `--set image.tag=1.1.0`). У `helm list` видно обидва поля: `CHART portal-0.1.0`, `APP VERSION 1.0.0`.

### Пріоритет значень

```text
values.yaml  <  -f values-dev.yaml / -f values-prod.yaml (кілька -f: правіший сильніший)  <  --set key=value
```

Приклад: `replicaCount` = 1 у `values.yaml`, 3 у `values-prod.yaml`; з
`-f values-prod.yaml --set replicaCount=2` у кластері буде 2 репліки, і `helm get values` покаже `replicaCount: 2`.

### Усі значення (`values.yaml`)

| Ключ | За замовчуванням | Опис |
|---|---|---|
| `nameOverride` | `""` | Замінює ім'я чарту в `portal.name` |
| `fullnameOverride` | `""` | Повністю задає базове ім'я об'єктів замість `<release>[-portal]` |
| `image.repository` | `portal-api` | Образ застосунку |
| `image.tag` | `""` | Тег образу; порожній => `appVersion` (`1.0.0`) |
| `image.pullPolicy` | `IfNotPresent` | Образ уже завантажено в minikube, registry не потрібен |
| `replicaCount` | `1` | Кількість pod-ів `portal-api` |
| `containerPort` | `8000` | Порт uvicorn у контейнері (іменований порт `http`) |
| `service.type` | `ClusterIP` | Тип Service `portal-api` |
| `service.port` | `80` | Порт Service (на нього посилаються Ingress і `helm test`) |
| `resources` | req `100m`/`128Mi`, lim `500m`/`384Mi` | Ресурси контейнера `portal-api` |
| `config.APP_GREETING` | `Привіт з Helm! ...` | Привітання на головній сторінці |
| `config.LOG_LEVEL` | `INFO` | Рівень логування |
| `config.ENVIRONMENT` | `sandbox` | Профіль: `sandbox` / `production` / `testing` |
| `config.DEBUG` | `"False"` | Показ стектрейсів клієнту |
| `config.POSTGRES_DB` | `portal_db` | Ім'я БД (і для postgres, і для `DATABASE_URL`) |
| `config.POSTGRES_USER` | `portal` | Користувач БД |
| `config.DB_PORT` | `"5432"` | Порт БД у `DATABASE_URL` |
| — (`DB_HOST`) | `<fullname>-db` | Не значення, а обчислюється в `configmap.yaml` з імені релізу |
| `secrets.POSTGRES_PASSWORD` | `dev-only-not-real-db-password` | Пароль БД (фейковий) |
| `secrets.SECRET_KEY` | `dev-only-not-real-jwt-signing-key-0123456789` | Ключ підпису JWT (фейковий) |
| `secrets.API_KEY` | `dev-only-not-real` | Демонстраційний API-ключ (фейковий) |
| `ingress.enabled` | `false` | Створювати Ingress |
| `ingress.className` | `nginx` | IngressClass (minikube addon `ingress`) |
| `ingress.host` | `portal-helm.local` | Хост Ingress (НЕ `portal.local` — він у Lab 3) |
| `persistence.enabled` | `true` | PVC для PostgreSQL; `false` => `emptyDir` |
| `persistence.size` | `1Gi` | Розмір PVC |
| `persistence.storageClassName` | `""` | Порожньо => StorageClass за замовчуванням |
| `postgres.image.repository` | `postgres` | Образ БД |
| `postgres.image.tag` | `16-alpine` | Тег образу БД |
| `postgres.image.pullPolicy` | `IfNotPresent` | Політика завантаження образу БД |
| `postgres.port` | `5432` | Порт PostgreSQL |
| `postgres.resources` | req `100m`/`128Mi`, lim `500m`/`512Mi` | Ресурси контейнера БД |
| `utilityImage.repository` | `busybox` | Образ для pre-upgrade hook і `helm test` |
| `utilityImage.tag` | `1.36` | Тег busybox |
| `hooks.preUpgrade.enabled` | `true` | Чи створювати pre-upgrade Job |
| `hooks.preUpgrade.deletePolicy` | `before-hook-creation,hook-succeeded` | Коли видаляти Job; `before-hook-creation` залишає його для `kubectl logs` |

Відмінності профілів: `values-dev.yaml` — 1 репліка, `50m/96Mi`…`250m/256Mi`, тег `1.0.0`,
`LOG_LEVEL=DEBUG`, ingress вимкнено (host `portal-helm.local`); `values-prod.yaml` — 3 репліки,
`200m/256Mi`…`1/512Mi`, тег `1.1.0`, `ENVIRONMENT=production`, `LOG_LEVEL=WARNING`,
ingress увімкнено з host `portal-helm-prod.local`.

### Встановлення

```bash
# dev (те саме робить ./scripts/lab4-up.sh)
helm install portal chart/portal -n dudko-helm --create-namespace -f chart/portal/values-dev.yaml

# prod (нове встановлення або upgrade існуючого релізу)
helm install portal chart/portal -n dudko-helm --create-namespace -f chart/portal/values-prod.yaml
helm upgrade portal chart/portal -n dudko-helm -f chart/portal/values-prod.yaml --description "prod values"

helm test portal -n dudko-helm --logs     # GET http://portal-api:80/health має повернути 200
```

### Як співіснують Lab 3 і Lab 4

- **Різні namespace:** Lab 3 — `dudko` (`kubectl apply -f k8s/`), Lab 4 — завжди `dudko-helm`.
  У шаблонах namespace не прописано: Helm бере його з `-n` (`.Release.Namespace`), тому імена
  об'єктів (`portal-api`, `portal-db`, ...) можуть збігатися з Lab 3 без конфлікту.
- **Різні хости Ingress:** `portal.local` (Lab 3), `portal-helm.local` (dev), `portal-helm-prod.local` (prod),
  тож ingress-nginx ніколи не отримає двох правил для одного хоста.
- **Запускаються по черзі:** `scripts/lab3-up.sh` / `lab3-down.sh` і `scripts/lab4-up.sh [values]` /
  `lab4-down.sh`. Каталог `k8s/` чарт не змінює й не використовує.

## 10. GitOps з Argo CD (Lab 5)

Розгортання описане в Git (варіант b — каталоги в репозиторії застосунку, гілка `labs-5-7`),
а Argo CD у кластері сам приводить кластер до цього стану.

```text
bootstrap/root-lab5.yaml        кореневий Application (App of Apps) — єдиний kubectl apply вручну
argocd-apps/lab5/portal.yaml    Application застосунку (auto-sync, prune; selfHeal вмикається комітом)
charts/portal/                  чарт з Lab 4 (образ з GHCR, secrets.existingSecret)
envs/minikube/values.yaml       бажаний стан для minikube: тег образу, репліки, Ingress portal-gitops.local
```

- **Образ:** git-тег `v1.3.0` -> CI публікує `ghcr.io/volodymyrdudko1/backend:1.3.0` (не `latest`);
  версія вшивається під час збирання й видна на `/`, `/info` і новому ендпоінті **`/version`**.
- **Секрети:** у Git паролів немає; Secret `portal-secret` створюється поза Git до застосування root.
- **Реліз** = зміна `image.tag` у `envs/minikube/values.yaml` + commit + push.
- **Окремий namespace** `dudko-gitops` і хост `portal-gitops.local` — не перетинаються з Lab 3/4.

Підготовка, команди й пояснення: [`docs/argocd-commands.md`](../docs/argocd-commands.md);
демо: `./scripts/lab.sh demo 5`.

## 11. Canary з Argo Rollouts (Lab 6)

- Контролер Argo Rollouts встановлює Argo CD з Git: `argocd-apps/lab6/argo-rollouts.yaml`
  (Helm-чарт `argo-rollouts`), кореневий Application — `bootstrap/root-lab6.yaml`.
- `charts/portal`: `rollout.enabled: true` рендерить **Rollout** замість Deployment (спільний
  шаблон pod-а `_pod.tpl`); `envs/minikube/values-lab6.yaml` — 4 репліки й кроки canary
  25% → ручна пауза → 50% → 30 с → 75% → 20 с.
- Реліз — зміна тегу в Git; `promote` / `abort` — `kubectl argo rollouts`. Після abort Argo CD
  показує Synced / Degraded, відкат завершується `git revert`.

Підготовка, команди й пояснення: [`docs/rollouts-commands.md`](../docs/rollouts-commands.md);
демо: `./scripts/lab.sh demo 6`.
