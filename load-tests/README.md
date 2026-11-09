# Load tests (Lab 4) — Locust

Навантажувальні тести API Multidimensional Portal Generator.

```
load-tests/
├── locustfile.py      # сценарій (HttpUser, JWT, зважені задачі)
├── locust.conf        # відтворюваний профіль основного прогону (50 VU, 5/с, 5 хв)
├── run_test.sh        # monitor.py + locust + зупинка монітора одним рядком
├── monitor.py         # CPU/RAM → results/*resources.csv (docker | process | host)
├── make_report.py     # таблиці, PNG-графіки, report.md
├── docs/test_plan.md  # план тестування
├── results/           # згенеровані CSV / HTML / PNG
└── report.md          # звіт (укр.)
```

## 1. Встановлення

```bash
cd load-tests
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

## 2. Запуск застосунку

З кореня репозиторію — контейнеризований стек з ЛР №5 (`web` = gunicorn + uvicorn workers, `db` = PostgreSQL 16).
Потрібен `.env` (шаблон — `.env.example`):

```bash
cp .env.example .env            # і замінити паролі/секрет
docker compose up --build -d --wait
curl -s http://localhost:8000/health   # {"status":"ok","database":"ok"}
```

Контейнери: `portal-web-1` і `portal-db-1` (типові для `monitor.py` і `run_test.sh`).
API опубліковано на `http://localhost:${WEB_PORT:-8000}` — це `host` у `locust.conf`; якщо змінили `WEB_PORT`,
передайте `--host http://localhost:<port>`. Кількість воркерів — `WEB_CONCURRENCY` у `.env` (за замовчуванням 2).

> Результати ЛР №4 у `results/` отримано на попередній конфігурації (`uvicorn`, 1 воркер, контейнер
> `portal-lt-backend-1`). Повторний прогін на стеку ЛР №5 дасть інші числа — це очікувано.

Без Docker: `cd multidimensional-portal-generator && uvicorn src.main:app --port 8000`
(SQLite за замовчуванням) і моніторинг через `--mode process --name uvicorn`.

## 3. Smoke-прогін (5 VU, 30 с)

```bash
.venv/bin/locust --config locust.conf -u 5 -r 5 -t 30s --csv results/smoke_5u --html results/smoke_5u.html
```

Очікується 0% помилок.

## 4. Моніторинг ресурсів

В окремому терміналі, перед стартом Locust:

```bash
.venv/bin/python monitor.py --mode docker --containers portal-web-1 portal-db-1 --out results/run_50u_resources.csv
# альтернативи:
.venv/bin/python monitor.py --mode process --name uvicorn --out results/resources.csv   # процес + дочірні
.venv/bin/python monitor.py --mode host --out results/resources.csv                     # весь хост
```

Зупинка — Ctrl+C (або `--duration 330`). Альтернатива без Python:

```bash
while true; do docker stats --no-stream --format '{{.Name}},{{.CPUPerc}},{{.MemUsage}}' \
  | sed "s/^/$(date -Is),/" >> results/docker_stats.csv; done
```

## 5. Основний прогін (50 VU, 5/с, 5 хв)

```bash
.venv/bin/locust -f locustfile.py --host http://localhost:8000 --headless -u 50 -r 5 -t 5m \
  --csv results/run_50u --csv-full-history --html results/run_50u.html
# те саме з конфігом:
.venv/bin/locust --config locust.conf
```

Або все разом (монітор + тест), включно з пошуком точки перелому:

```bash
./run_test.sh 50 5m
./run_test.sh 10 3m && ./run_test.sh 100 3m && ./run_test.sh 200 3m
```

Щоб прогони були незалежними (без «хвоста» черги від попереднього), перезапускайте backend перед кожним:

```bash
export RESTART_CONTAINER=portal-web-1
./run_test.sh 100 3m && ./run_test.sh 200 3m
```

Скрипт також зберігає лог backend за час прогону в `results/run_<N>u_backend.log`
(`make_report.py` рахує з нього помилки `QueuePool`).

## 6. Звіт

```bash
.venv/bin/python make_report.py            # усі results/run_*u, основний — run_50u
```

Створює `results/*_latency.png`, `*_throughput.png`, `*_resources.png`, `scalability.png`,
`summary_*.csv` і перезаписує `report.md`. Якщо даних ще немає, у звіті з'являються позначені
заглушки `⟪НЕМАЄ ДАНИХ …⟫`.

## 7. ЛР 6: 1 репліка vs 3 репліки за Nginx

Стек `docker-compose.lb.yml` (Nginx на `:80`, web1..3, по 1 CPU / 512 MB). Скрипт сам перемикає
upstream (`single` → `round_robin`), перезапускає репліки, знімає ресурси й логи:

```bash
./run_lab6_compare.sh 50 5 3m          # results/lab6_single_*, results/lab6_lb3_*
.venv/bin/python compare_report.py     # таблиця + results/lab6_compare_*.png
```

Locust ходить на `http://localhost` (Nginx), сценарій `locustfile.py` той самий.
Опис і висновки — розділ «Лабораторна робота 6» у `multidimensional-portal-generator/README.md`.
