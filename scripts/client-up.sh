#!/usr/bin/env bash
# Запустити Django-клієнт (portal_client) локально і підключити його до API в кластері.
# Працює і для Lab 3 (k8s/, namespace dudko), і для Lab 4 (Helm, namespace dudko-helm).
#
# Використання (з будь-якого каталогу):
#   ./scripts/client-up.sh          # автовизначення: де зараз розгорнуто API
#   ./scripts/client-up.sh lab3     # явно Lab 3
#   ./scripts/client-up.sh lab4     # явно Lab 4
# Змінні оточення:
#   API_PORT     (8000)   локальний порт, на який прокидається Service API
#   CLIENT_PORT  (8080)   порт Django-клієнта  => http://localhost:8080/
#   INGRESS_PORT (18080)  порт ingress-nginx  => http://portal.local:18080/ (якщо в namespace є Ingress)
#   RELEASE      (portal) ім'я Helm-релізу для Lab 4
#
# Що відбувається:
#   браузер -> Django :CLIENT_PORT -> kubectl port-forward :API_PORT -> Service API -> pod-и -> PostgreSQL
#   браузер -> http://<host Ingress>:INGRESS_PORT -> port-forward -> ingress-nginx -> Ingress -> Service API
# Для другого маршруту в /etc/hosts потрібен рядок "127.0.0.1 portal.local".
# Ctrl+C зупиняє клієнт і всі port-forward.
set -euo pipefail
cd "$(dirname "$0")/.."

API_PORT="${API_PORT:-8000}"
CLIENT_PORT="${CLIENT_PORT:-8080}"
INGRESS_PORT="${INGRESS_PORT:-18080}"
RELEASE="${RELEASE:-portal}"
LOG_DIR="$(mktemp -d)"
PF_LOG="${LOG_DIR}/port-forward.log"
INGRESS_PF_LOG="${LOG_DIR}/ingress-port-forward.log"
PF_LOOPS=()

die() { echo "ERROR: $*" >&2; exit 1; }
port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# --- 1. Кластер доступний? ---
if ! kubectl version --request-timeout=5s >/dev/null 2>&1; then
  die "kubectl не бачить кластер. Перевірте 'minikube status'; якщо Stopped: minikube start --driver=docker"
fi

# --- 2. Знайти Service API для обраної лабораторної ---
# Друкує "<namespace> <service>" або нічого, якщо API не розгорнуто.
find_api() {
  case "$1" in
    lab3)
      kubectl get svc portal-api -n dudko -o name >/dev/null 2>&1 && echo "dudko portal-api"
      ;;
    lab4)
      # Ім'я Service будує Helm з імені релізу, тому шукаємо за мітками чарта.
      local svc
      svc=$(kubectl get svc -n dudko-helm \
        -l "app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/component=api" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
      [[ -n "${svc}" ]] && echo "dudko-helm ${svc}"
      ;;
  esac
  return 0
}

LAB="${1:-auto}"
case "${LAB}" in
  lab3|lab4) TARGET="$(find_api "${LAB}")"
             [[ -n "${TARGET}" ]] || die "API для ${LAB} не знайдено. Спершу: ./scripts/${LAB}-up.sh" ;;
  auto)      L3="$(find_api lab3)"; L4="$(find_api lab4)"
             if [[ -n "${L3}" && -n "${L4}" ]]; then
               die "розгорнуто і Lab 3, і Lab 4 — вкажіть явно: $0 lab3 | lab4"
             elif [[ -n "${L3}" ]]; then LAB=lab3; TARGET="${L3}"
             elif [[ -n "${L4}" ]]; then LAB=lab4; TARGET="${L4}"
             else die "API не розгорнуто. Спершу: ./scripts/lab3-up.sh або ./scripts/lab4-up.sh"; fi ;;
  *)         die "невідомий аргумент '${LAB}'. Використання: $0 [lab3|lab4]" ;;
esac
read -r NAMESPACE SERVICE <<<"${TARGET}"
echo ">>> ${LAB}: Service ${SERVICE} у namespace ${NAMESPACE}"

# --- 3. Python з Django ---
if [[ -x .venv/bin/python ]]; then PYTHON="${PWD}/.venv/bin/python"; else PYTHON="$(command -v python3)"; fi
"${PYTHON}" -c "import django, httpx" 2>/dev/null \
  || die "у ${PYTHON} немає Django/httpx. Встановіть: ${PYTHON} -m pip install -r portal_client/requirements.txt"

# --- 4. Порти вільні? ---
for port in "${API_PORT}" "${CLIENT_PORT}"; do
  if port_busy "${port}"; then
    die "порт ${port} уже зайнятий (інший port-forward чи runserver?). Звільніть його або задайте API_PORT/CLIENT_PORT"
  fi
done

# --- 5. Дочекатися готових pod-ів API ---
echo ">>> Чекаю, поки pod-и API стануть Ready..."
SELECTOR=$(kubectl get svc "${SERVICE}" -n "${NAMESPACE}" \
  -o go-template='{{range $k, $v := .spec.selector}}{{$k}}={{$v}},{{end}}')
kubectl wait pod -n "${NAMESPACE}" -l "${SELECTOR%,}" --for=condition=Ready --timeout=180s >/dev/null

# --- 6. port-forward у фоні з автоперезапуском ---
# port-forward через Service насправді прив'язується до ОДНОГО pod-а. Коли цей pod
# зникає (delete, rollout, scale), з'єднання рветься — цикл одразу піднімає його знову.
cleanup() {
  for pid in "${PF_LOOPS[@]}"; do kill "${pid}" 2>/dev/null || true; done
  pkill -f "kubectl port-forward -n ${NAMESPACE} svc/${SERVICE} ${API_PORT}:" 2>/dev/null || true
  pkill -f "kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller ${INGRESS_PORT}:" 2>/dev/null || true
  rm -rf "${LOG_DIR}"
  echo ">>> Клієнт і port-forward зупинено"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# keep_forwarding <namespace> <svc/name> <local:remote> <log> — port-forward, що перезапускається.
keep_forwarding() {
  (
    while true; do
      kubectl port-forward -n "$1" "$2" "$3" >>"$4" 2>&1 || true
      sleep 1
    done
  ) &
  PF_LOOPS+=("$!")
}

keep_forwarding "${NAMESPACE}" "svc/${SERVICE}" "${API_PORT}:80" "${PF_LOG}"

for _ in $(seq 1 30); do
  "${PYTHON}" -c "import urllib.request as u; u.urlopen('http://127.0.0.1:${API_PORT}/health', timeout=1)" \
    2>/dev/null && break
  sleep 0.5
done
"${PYTHON}" -c "import urllib.request as u; print('>>> API:', u.urlopen('http://127.0.0.1:${API_PORT}/info', timeout=2).read().decode())" \
  || die "API не відповідає через port-forward. Лог: $(cat "${PF_LOG}")"

# --- 7. Ingress (Lab 3 завжди; Lab 4 — якщо ingress.enabled=true) ---
INGRESS_URL=""
INGRESS_HOST=$(kubectl get ingress -n "${NAMESPACE}" -o jsonpath='{.items[0].spec.rules[0].host}' 2>/dev/null || true)
if [[ -z "${INGRESS_HOST}" ]]; then
  echo ">>> Ingress у namespace ${NAMESPACE} немає — пропускаю маршрут через ingress-nginx"
elif port_busy "${INGRESS_PORT}"; then
  echo ">>> Порт ${INGRESS_PORT} уже зайнятий (ingress port-forward запущено окремо?) — не дублюю"
  INGRESS_URL="http://${INGRESS_HOST}:${INGRESS_PORT}/"
else
  keep_forwarding ingress-nginx svc/ingress-nginx-controller "${INGRESS_PORT}:80" "${INGRESS_PF_LOG}"
  INGRESS_URL="http://${INGRESS_HOST}:${INGRESS_PORT}/"
  for _ in $(seq 1 30); do port_busy "${INGRESS_PORT}" && break; sleep 0.5; done
fi
if [[ -n "${INGRESS_URL}" ]] && ! getent hosts "${INGRESS_HOST}" >/dev/null; then
  echo ">>> УВАГА: ${INGRESS_HOST} немає в /etc/hosts. Додайте:"
  echo "      echo \"127.0.0.1 ${INGRESS_HOST}\" | sudo tee -a /etc/hosts"
fi

# --- 8. Django-клієнт на передньому плані ---
echo ">>> Відкрийте:"
echo "      http://localhost:${CLIENT_PORT}/   — клієнт (Django dashboard)"
[[ -n "${INGRESS_URL}" ]] && echo "      ${INGRESS_URL}   — API через Ingress (версія, hostname pod-а)"
echo "      http://localhost:${API_PORT}/   — API напряму (port-forward до Service)"
echo ">>> Зупинити все: Ctrl+C"
cd portal_client

# Міграції Django для ЛОКАЛЬНОЇ sqlite-бази клієнта (portal_client/db.sqlite3): auth, sessions...
# Ідемпотентно: вже застосовані пропускаються. Схему PostgreSQL у кластері створює сам API
# під час старту (create_all), тому для бази в Kubernetes тут нічого не запускаємо.
echo ">>> Django migrate (локальна sqlite клієнта)"
FASTAPI_BACKEND_URL="http://127.0.0.1:${API_PORT}" "${PYTHON}" manage.py migrate --noinput -v 0
FASTAPI_BACKEND_URL="http://127.0.0.1:${API_PORT}" \
  "${PYTHON}" manage.py runserver "${CLIENT_PORT}"
