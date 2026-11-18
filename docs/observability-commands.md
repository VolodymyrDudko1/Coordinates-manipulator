# Lab 7: метрики, логи, дашборд і відкат за метриками — шпаргалка

Гілка `labs-5-7`, поверх Lab 5–6. Демо: `./scripts/lab.sh demo 7` (13 кроків).

## Що де лежить

| Шлях | Роль |
|---|---|
| `bootstrap/root-lab7.yaml` | кореневий Application Lab 7 |
| `argocd-apps/lab7/kube-prometheus-stack.yaml` | Prometheus, Alertmanager, Grafana (урізано: без node-exporter, retention 2h), wave -2 |
| `argocd-apps/lab7/loki.yaml` | Loki `deploymentMode: Monolithic` (один процес), filesystem, PVC 2 GiB |
| `argocd-apps/lab7/alloy.yaml` | Alloy (Deployment): логи pod-ів `dudko-gitops` через Kubernetes API -> Loki; мітки `version`, `pod`, `level` |
| `charts/portal/templates/servicemonitor.yaml` | збір `/metrics`; `podTargetLabels` — версія і hash pod-а в кожному ряді |
| `charts/portal/templates/analysistemplate.yaml` | частка не-5xx запитів **canary**-pod-ів >= 0.95 |
| `charts/portal/templates/prometheusrule.yaml` | алерт `PortalHighErrorRate` (> 5% 5xx, 1 хв) |
| `charts/portal/files/dashboard.json` + `dashboard-configmap.yaml` | дашборд як код, ConfigMap з міткою `grafana_dashboard: "1"` |
| `envs/minikube/values-lab7.yaml` | свій тег образу (1.4.0), `failRate`, canary з кроком analysis |
| `multidimensional-portal-generator/src/observability.py` | `/metrics`, JSON-логи, `FAIL_RATE` |

Пароль Grafana — поза Git: Secret `grafana-admin` у `monitoring`, значення в
`~/.config/portal-labs/grafana-admin-password` (створює `scripts/labs/lab7.sh`).

## Застосунок (п.2a, п.3, п.6b)

- `http_requests_total{method, route, status}` і `http_request_duration_seconds{method, route}`.
  `route` — **шаблон** маршруту (`/simulations/{sim_id}`), невідомі шляхи — `unmatched`:
  кількість рядів не росте від id у URL.
- Логи — один JSON-об'єкт на рядок: `time, level, logger, message, method, route, status, duration_ms`.
  uvicorn запущено з `--no-access-log`: рядки доступу пише сам застосунок (з маршрутом і тривалістю).
- `FAIL_RATE` (0..1) — частка відповідей 500; `/health`, `/ready`, `/metrics` не ламаються
  (інакше pod-и перезапускалися б і зник би сам ефект «поганої версії»).

## Поганий реліз (п.6c)

Один коміт у `envs/minikube/values-lab7.yaml`: `tag: "1.5.0"` + `failRate: "0.3"`.
`failRate` іде в `env` pod-а (а не в спільний ConfigMap), тож помилки дають **лише** нові pod-и.
Далі: 25% трафіку -> 20 с прогріву -> AnalysisRun (виміри кожні 15 с) -> 2-й провал ->
**Failed** -> Argo Rollouts сам робить abort -> усі pod-и знову 1.4.0. Argo CD: Synced / Degraded.
Завершення — `git revert` (тег і failRate повертаються разом).

## Запити

```promql
# RPS за версією
sum by (app_kubernetes_io_version) (rate(http_requests_total{namespace="dudko-gitops",service="portal-api",route!~"/health|/ready|/metrics"}[1m]))
# частка 5xx
sum(rate(http_requests_total{namespace="dudko-gitops",service="portal-api",status=~"5.."}[1m]))
  / sum(rate(http_requests_total{namespace="dudko-gitops",service="portal-api"}[1m]))
# p95 затримки
histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{namespace="dudko-gitops",service="portal-api"}[1m])))
# CPU і RAM pod-ів (cAdvisor у kubelet)
sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="dudko-gitops",container="portal-api"}[1m]))
sum by (pod) (container_memory_working_set_bytes{namespace="dudko-gitops",container="portal-api"})
```

```logql
{namespace="dudko-gitops", component="api"} | json | status >= 500
{namespace="dudko-gitops", component="api", version="1.5.0"} | json | status >= 500
sum by (version) (count_over_time({namespace="dudko-gitops", component="api"} | json | status >= 500 [5m]))
```

## Доступ

```bash
kubectl port-forward -n monitoring svc/kps-grafana 18100:80        # http://localhost:18100  (admin)
kubectl port-forward -n monitoring svc/kps-prometheus 18101:9090   # /targets, /alerts
kubectl port-forward -n monitoring svc/loki 18102:3100
```
Під час `lab.sh demo 7` ці port-forward-и тримає скрипт.

## RAM

Стек урізано (limits на всіх компонентах). Перед Lab 7 — закрити зайве; `lab.sh status`
показує споживання. Після демо `./scripts/lab.sh down 7` видаляє root-lab7 разом з моніторингом.
