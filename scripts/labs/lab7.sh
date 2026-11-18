# shellcheck shell=bash
# Lab 7: observability — метрики, логи, дашборд і автоматичний відкат canary за метриками.
# root-lab7 -> kube-prometheus-stack, Loki, Alloy (namespace monitoring), argo-rollouts, portal
# (charts/portal + envs/minikube/values.yaml + values-lab7.yaml). Релізи Lab 7 змінюють
# envs/minikube/values-lab7.yaml (свій тег образу), тож не впливають на демо Lab 5/6.
# Використовує l5_* (lab5.sh) і ro_* / l6_* (lab6.sh).

L7_ROOT=bootstrap/root-lab7.yaml
L7_VALUES=envs/minikube/values-lab7.yaml
L7_GOOD=1.4.0                      # образ з /metrics і JSON-логами
L7_BAD=1.5.0                       # «погана» версія: той самий код + failRate з Git
L7_FAIL_RATE=0.3
L7_MON=monitoring
L7_GRAFANA_PORT=18100
L7_PROM_PORT=18101
L7_LOKI_PORT=18102
L7_LOAD=l7-loadgen
L7_NSSEL="namespace=\"dudko-gitops\",service=\"portal-api\",route!~\"/health|/ready|/metrics\""

lab7_title() { echo "Lab 7 — метрики, логи, дашборд, відкат за метриками (root-lab7)"; }
lab7_is_up() { kubectl get application root-lab7 -n argocd >/dev/null 2>&1; }

# ---------- допоміжні ----------
l7_tag()       { sed -n 's/^  tag: "\([^"]*\)".*/\1/p' "${L7_VALUES}"; }
l7_failrate()  { sed -n 's/^failRate: "\([^"]*\)".*/\1/p' "${L7_VALUES}"; }
l7_set()       { sed -i "s/^  tag: .*/  tag: \"$1\"/; s/^failRate: \"[^\"]*\"/failRate: \"$2\"/" "${L7_VALUES}"; }

l7_grafana_pw_file() {
  local f="${LABS_CFG}/grafana-admin-password"
  if [[ ! -s "${f}" ]]; then
    mkdir -p "${LABS_CFG}"; chmod 700 "${LABS_CFG}"
    (umask 077; echo "graf-$(l5_rand 6)" >"${f}")
  fi
  echo "${f}"
}

# Пароль Grafana поза Git: Secret grafana-admin (на нього посилається values kube-prometheus-stack).
l7_secrets() {
  kubectl create namespace "${L7_MON}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl create secret generic grafana-admin -n "${L7_MON}" \
    --from-literal=admin-user=admin --from-literal=admin-password="$(cat "$(l7_grafana_pw_file)")" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

# Port-forward-и до Grafana/Prometheus/Loki — лише коли стек уже розгорнуто (працює і з --from N).
l7_pf() {
  kubectl get svc kps-grafana kps-prometheus loki -n "${L7_MON}" >/dev/null 2>&1 \
    || { warn "стек моніторингу ще не розгорнуто"; return 1; }
  pf_bg "${L7_MON}" svc/kps-grafana "${L7_GRAFANA_PORT}" 80
  pf_bg "${L7_MON}" svc/kps-prometheus "${L7_PROM_PORT}" 9090
  pf_bg "${L7_MON}" svc/loki "${L7_LOKI_PORT}" 3100
}

# promql '<запит>' — миттєвий запит до Prometheus, вивід «мітки => значення».
promql() {
  l7_pf || return 1
  curl -s --max-time 10 -G "http://127.0.0.1:${L7_PROM_PORT}/api/v1/query" --data-urlencode "query=$1" \
    | python3 -c 'import json,sys
r=json.load(sys.stdin)["data"]["result"]
print("  (порожньо)") if not r else None
for s in r:
    m={k:v for k,v in s["metric"].items() if k!="__name__"}
    print("  ", m or "{}", "=>", s["value"][1])'
}

# logql '<запит>' [limit] — останні рядки логів з Loki (за 10 хв).
logql() {
  l7_pf || return 1
  curl -s --max-time 10 -G "http://127.0.0.1:${L7_LOKI_PORT}/loki/api/v1/query_range" \
    --data-urlencode "query=$1" --data-urlencode "limit=${2:-5}" --data-urlencode "since=10m" \
    | python3 -c 'import json,sys
d=json.load(sys.stdin)["data"]
if d["resultType"]=="streams":
    rows=sorted(((v[0],s["stream"].get("version","?"),s["stream"].get("pod","?"),v[1]) for s in d["result"] for v in s["values"]),reverse=True)
    print("  (порожньо)") if not rows else None
    for _,ver,pod,line in rows[:int(sys.argv[1])]: print("  ", ver, pod, line[:150])
else:
    print("  (порожньо)") if not d["result"] else None
    for s in d["result"]: print("  ", s["metric"], "=>", s["values"][-1][1])' "${2:-5}"
}

# Генератор навантаження в кластері: N паралельних циклів запитів до Service portal-api.
l7_load_start() {
  kubectl delete deploy "${L7_LOAD}" -n "${L5_NS}" --ignore-not-found >/dev/null
  kubectl create deployment "${L7_LOAD}" -n "${L5_NS}" --image=busybox:1.36 -- sh -c \
    'for w in 1 2 3 4 5 6; do (while true; do wget -q -O /dev/null -T 2 http://portal-api/info; wget -q -O /dev/null -T 2 http://portal-api/version; done) & done; wait' >/dev/null
  kubectl rollout status deploy/"${L7_LOAD}" -n "${L5_NS}" --timeout=60s >/dev/null
  info "Навантаження: deploy/${L7_LOAD} — 6 паралельних циклів /info + /version"
}
l7_load_stop() { kubectl delete deploy "${L7_LOAD}" -n "${L5_NS}" --ignore-not-found >/dev/null; }

l7_reset_git() {
  [[ "$(l7_tag)" == "${L7_GOOD}" && -z "$(l7_failrate)" ]] && return 0
  info "Скидаю стан демо Lab 7 в Git (тег ${L7_GOOD}, failRate порожній) і пушу"
  l7_set "${L7_GOOD}" ""
  l5_commit_push "lab7 demo: reset (image ${L7_GOOD}, no failRate)" "${L7_VALUES}" || warn "push не вдався"
}

# ---------- інтерфейс для lab.sh ----------
lab7_prepare() {
  command -v argocd >/dev/null || die "немає argocd CLI — див. docs/argocd-commands.md"
  command -v kubectl-argo-rollouts >/dev/null || die "немає плагіна kubectl argo rollouts — див. docs/rollouts-commands.md"
  git_check_pushed "${L5_BRANCH}"
  l7_reset_git
  argocd_wake
  argocd_pf
  l5_secrets
  l7_secrets
  local have img; have="$(minikube image ls 2>/dev/null)"
  for img in "${L5_IMAGE}:${L7_GOOD}" "${L5_IMAGE}:${L7_BAD}" postgres:16-alpine busybox:1.36; do
    grep -q "${img}" <<<"${have}" || { info "Завантажую ${img} у minikube"; minikube image pull "${img}" >/dev/null 2>&1 || warn "не вдалося: ${img}"; }
  done
  argocd_login_quiet || warn "argocd CLI: не вдалося увійти (пароль у $(argocd_password_file))"
}

lab7_up() {
  lab7_prepare
  kubectl apply -f "${L7_ROOT}"
  app_exists root-lab7 || return 1
  local a
  for a in kube-prometheus-stack loki alloy argo-rollouts portal; do app_exists "${a}" && app_wait "${a}" Healthy 600; done
}

lab7_down() {
  l7_load_stop 2>/dev/null || true
  if lab7_is_up; then
    argocd_wake
    info "Видаляю root-lab7 (каскадно: моніторинг, argo-rollouts, portal)"
    kubectl delete -f "${L7_ROOT}" --wait --timeout=300s >/dev/null || warn "root-lab7 видаляється довше за 5 хв"
    kubectl wait --for=delete application/portal application/argo-rollouts application/kube-prometheus-stack \
      application/loki application/alloy -n argocd --timeout=180s >/dev/null 2>&1 || true
  fi
  [[ "${TARGET_LAB:-}" =~ ^[5-9]$ ]] || argocd_sleep
}

lab7_steps() {
  local NS="-n ${L5_NS}" pw; pw="$(l7_grafana_pw_file)"

  step "п.1 Стек моніторингу з Git: kube-prometheus-stack, Loki (один процес), Alloy" \
    "root-lab7 -> 5 Application (wave -2 моніторинг, -1 argo-rollouts, 0 portal), усі Synced/Healthy; pod-и monitoring Running. Перший запуск ~3-5 хв (образи)" \
    "ls argocd-apps/lab7
kubectl apply -f ${L7_ROOT}
app_exists root-lab7 && argocd app wait root-lab7 --sync --timeout 120
# app_wait опитує статус і переживає тимчасовий Degraded (Prometheus/Alertmanager ще стартують);
# argocd app wait --health на ньому одразу завершився б з помилкою.
for a in kube-prometheus-stack loki alloy argo-rollouts portal; do app_exists \$a && app_wait \$a Healthy 900; done
argocd app list
kubectl get pods -n ${L7_MON}"

  step "п.1 Grafana відкривається (пароль admin — поза Git, Secret grafana-admin)" \
    "database: ok; браузер: http://localhost:${L7_GRAFANA_PORT} (admin / пароль нижче), Prometheus: http://localhost:${L7_PROM_PORT}" \
    "l7_pf
curl -s http://127.0.0.1:${L7_GRAFANA_PORT}/api/health; echo
echo \"Grafana: http://localhost:${L7_GRAFANA_PORT}  admin / \$(cat ${pw})\"
echo 'Prometheus: http://localhost:${L7_PROM_PORT}/targets'"

  step "п.2a Ендпоінт /metrics: лічильник з method/route/status і гістограма тривалості" \
    "http_requests_total{method,route,status} — route це шаблон маршруту (мала кардинальність); http_request_duration_seconds_bucket" \
    "icurl ${L5_HOST} /version >/dev/null; icurl ${L5_HOST} /info >/dev/null
icurl ${L5_HOST} /metrics | grep -E '^http_requests_total|^http_request_duration_seconds_count' | head -8"

  step "п.2b ServiceMonitor у чарті -> ціль у Prometheus UP -> запит до своєї метрики" \
    "ServiceMonitor portal-api; 4 цілі health=up; запит повертає ряди з route/status і версією pod-а" \
    "kubectl get servicemonitor ${NS}
curl -s http://127.0.0.1:${L7_PROM_PORT}/api/v1/targets?state=active | python3 -c 'import json,sys
for t in json.load(sys.stdin)[\"data\"][\"activeTargets\"]:
    if \"portal-api\" in t[\"labels\"].get(\"job\",\"\"): print(\"  \", t[\"labels\"][\"pod\"], t[\"health\"], t[\"scrapeUrl\"])'
promql 'sum by (route, status, app_kubernetes_io_version) (http_requests_total{${L7_NSSEL}})'"

  step "п.3 JSON-логи в stdout -> Alloy -> Loki; фільтр LogQL" \
    "рядок логу — JSON (time, level, message, method, route, status, duration_ms); у Loki ті самі рядки з мітками version/pod" \
    "kubectl logs ${NS} \$(kubectl get pods ${NS} -l app.kubernetes.io/component=api -o name | head -1) --tail=2
logql '{namespace=\"${L5_NS}\",component=\"api\"} | json | route=\"/info\"' 3
echo 'Grafana Explore -> Loki:  {namespace=\"${L5_NS}\",component=\"api\"} | json | status >= 500'"

  step "п.4 Дашборд як код: ConfigMap з міткою grafana_dashboard у чарті" \
    "ConfigMap portal-dashboard (grafana_dashboard=1); у Grafana — «Portal API (Lab 7)»: RPS, 5xx, p95, CPU, RAM, логи" \
    "kubectl get configmap ${NS} -l grafana_dashboard=1
curl -s -u \"admin:\$(cat ${pw})\" 'http://127.0.0.1:${L7_GRAFANA_PORT}/api/search?query=Portal' | python3 -c 'import json,sys; [print(\"  \", d[\"title\"], d[\"url\"]) for d in json.load(sys.stdin)]'
echo 'Відкрити: http://localhost:${L7_GRAFANA_PORT}/d/portal-api-lab7'"

  step "п.5 Навантаження: на дашборді ростуть RPS, затримка і CPU" \
    "через ~1 хв: RPS > 0 для ${L7_GOOD}, p95 у мілісекундах, CPU pod-ів зростає (див. дашборд)" \
    "l7_load_start
sleep 60
promql 'sum by (app_kubernetes_io_version) (rate(http_requests_total{${L7_NSSEL}}[1m]))'
promql 'histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{${L7_NSSEL}}[1m])))'
promql 'sum by (pod) (rate(container_cpu_usage_seconds_total{namespace=\"${L5_NS}\",container=\"portal-api\"}[1m]))'"

  step "п.5 Ще одна зміна: вимкнути pod — на дашборді видно провал і новий pod" \
    "pod видалено, Rollout створює новий; на графіках CPU/RAM — новий pod, RPS перерозподіляється, помилок немає" \
    "kubectl delete \$(kubectl get pods ${NS} -l app.kubernetes.io/component=api -o name | head -1) ${NS} --wait=false
sleep 20; kubectl get pods ${NS} -l app.kubernetes.io/component=api"

  step "п.6a AnalysisTemplate у чарті + крок analysis у canary" \
    "запит: частка не-5xx запитів ЛИШЕ canary-pod-ів (rollouts_pod_template_hash), поріг 0.95; у кроках: setWeight 25 -> pause 20s -> analysis" \
    "kubectl get analysistemplate ${NS}
kubectl get analysistemplate portal-success-rate ${NS} -o jsonpath='{.spec.metrics[0].successCondition}{\"\\n\"}{.spec.metrics[0].provider.prometheus.query}'
sed -n '/steps:/,/setWeight: 50/p' ${L7_VALUES}"

  step "п.6b-c Поганий реліз під навантаженням: ${L7_BAD} + failRate ${L7_FAIL_RATE} одним комітом" \
    "canary 25% -> AnalysisRun Failed -> Rollout сам abort -> усі pod-и знову ${L7_GOOD} (~1.5 хв); Argo CD Synced / Degraded" \
    "l7_set ${L7_BAD} ${L7_FAIL_RATE}
git diff -- ${L7_VALUES}
l5_commit_push 'Release ${L7_BAD} (bad: failRate ${L7_FAIL_RATE})' ${L7_VALUES}
l6_refresh
ro_wait Degraded 300            # 25% -> 20 с -> analysis провалюється на 2-му вимірі -> abort
kubectl get analysisrun ${NS}
kubectl argo rollouts get rollout ${L6_RO} ${NS} | sed -n '1,12p'
argocd app get portal | grep -E 'Sync Status|Health Status'"

  step "п.6c Сплеск помилок на дашборді й логи 5xx ЛИШЕ з pod-ів нової версії (Loki)" \
    "5xx за версіями: лише ${L7_BAD}; LogQL з | json | status >= 500 — рядки лише з version=${L7_BAD}" \
    "promql 'sum by (app_kubernetes_io_version) (increase(http_requests_total{${L7_NSSEL},status=~\"5..\"}[5m]))'
logql 'sum by (version) (count_over_time({namespace=\"${L5_NS}\",component=\"api\"} | json | status >= 500 [10m]))'
logql '{namespace=\"${L5_NS}\",component=\"api\"} | json | status >= 500' 3"

  step "п.6d (за бажанням) PrometheusRule: алерт PortalHighErrorRate" \
    "правило > 5% 5xx протягом 1 хв; під час поганого релізу — pending/firing (після abort згасає)" \
    "kubectl get prometheusrule ${NS}
curl -s http://127.0.0.1:${L7_PROM_PORT}/api/v1/alerts | python3 -c 'import json,sys
a=[x for x in json.load(sys.stdin)[\"data\"][\"alerts\"] if x[\"labels\"][\"alertname\"]==\"PortalHighErrorRate\"]
print(\"  \", [(x[\"state\"], x[\"value\"]) for x in a] or \"неактивний (помилки вже згасли)\")'
echo 'Prometheus: http://localhost:${L7_PROM_PORT}/alerts'"

  step "п.6c Завершити відкат через Git: git revert поганого релізу" \
    "тег знову ${L7_GOOD} без failRate = stable: Rollout Healthy; Argo CD Synced / Healthy; навантаження зупинено" \
    "git revert --no-edit HEAD
git push -q origin ${L5_BRANCH}
l6_refresh
ro_wait Healthy 180
argocd app wait portal --sync --health --timeout 180
git log --oneline -3
l7_load_stop"
}
