# shellcheck shell=bash
# Спільні функції для scripts/lab.sh і демо-сценаріїв лабораторних (scripts/labs/labN.sh).
# Підключається через `source`, сам по собі не запускається.

# ---------- Вивід ----------
if [[ -t 1 ]]; then
  C_B=$'\e[1m'; C_DIM=$'\e[2m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_C=$'\e[36m'; C_R=$'\e[31m'; C_0=$'\e[0m'
else
  C_B=""; C_DIM=""; C_G=""; C_Y=""; C_C=""; C_R=""; C_0=""
fi
info() { echo "${C_C}>>>${C_0} $*"; }
warn() { echo "${C_Y}!!!${C_0} $*" >&2; }
die()  { echo "${C_R}ERROR:${C_0} $*" >&2; exit 1; }

port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# ---------- Фонові процеси (port-forward, цикли трафіку) прибираються при виході ----------
BG_PIDS=()
DEMO_TMP="$(mktemp -d)"
_cleanup() {
  for pid in "${BG_PIDS[@]}"; do kill "${pid}" 2>/dev/null || true; done
  pkill -P $$ -f "kubectl port-forward" 2>/dev/null || true
  rm -rf "${DEMO_TMP}"
}
trap _cleanup EXIT
trap 'exit 130' INT TERM

# ---------- Кластер ----------
cluster_up() { kubectl version --request-timeout=5s >/dev/null 2>&1; }

ensure_cluster() {
  if ! cluster_up; then
    info "minikube не запущено — стартую (≈1 хв)"
    minikube start
  fi
  info "Чекаю на ingress-nginx controller"
  kubectl wait -n ingress-nginx --for=condition=ready pod \
    -l app.kubernetes.io/component=controller --timeout=180s >/dev/null
}

# Образи, які лабораторні беруть з minikube (без registry).
ensure_images() {
  local have; have="$(minikube image ls 2>/dev/null)"
  if ! grep -q 'portal-api:1.0.0' <<<"${have}" || ! grep -q 'portal-api:1.1.0' <<<"${have}"; then
    warn "У minikube немає portal-api:1.0.0/1.1.0 — збираю (./scripts/build-images.sh)"
    ./scripts/build-images.sh
  fi
  local img
  for img in "$@"; do
    if ! grep -q "${img}" <<<"${have}"; then
      info "Завантажую ${img} у minikube заздалегідь (щоб не чекати під час демо)"
      minikube image pull "${img}"
    fi
  done
}

# ---------- Доступ до застосунку ----------
INGRESS_PORT="${INGRESS_PORT:-18080}"
SVC_PORT="${SVC_PORT:-18081}"

# port-forward до ingress-nginx: переживає rollout-и застосунку (прив'язаний до pod-а контролера).
ingress_pf() {
  port_busy "${INGRESS_PORT}" && return 0
  kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller "${INGRESS_PORT}:80" \
    >"${DEMO_TMP}/ingress-pf.log" 2>&1 &
  BG_PIDS+=("$!")
  local _
  for _ in $(seq 1 40); do port_busy "${INGRESS_PORT}" && return 0; sleep 0.25; done
  die "port-forward до ingress-nginx не піднявся: $(cat "${DEMO_TMP}/ingress-pf.log")"
}

# icurl <host> <path> — запит через Ingress-правило для <host>.
icurl() {
  ingress_pf
  curl -s --max-time 3 -H "Host: $1" "http://127.0.0.1:${INGRESS_PORT}$2"; echo
}

# svc_get <namespace> <service> <path> — разовий запит напряму до Service (коли Ingress вимкнено).
svc_get() {
  kubectl port-forward -n "$1" "svc/$2" "${SVC_PORT}:80" >"${DEMO_TMP}/svc-pf.log" 2>&1 &
  local pid=$! _
  for _ in $(seq 1 40); do port_busy "${SVC_PORT}" && break; sleep 0.25; done
  curl -s --max-time 3 "http://127.0.0.1:${SVC_PORT}$3"; echo
  kill "${pid}" 2>/dev/null || true; wait "${pid}" 2>/dev/null || true
}

# traffic_start <host> — фоновий цикл запитів /info через Ingress (доказ відсутності простою).
# traffic_stop          — зупинити й показати підсумок: скільки відповідей кожної версії і скільки помилок.
traffic_start() {
  ingress_pf
  local host="$1"
  : >"${DEMO_TMP}/traffic.log"
  (
    set +e
    while true; do
      out=$(curl -s --max-time 2 -w ' %{http_code}' -H "Host: ${host}" "http://127.0.0.1:${INGRESS_PORT}/info" 2>/dev/null) \
        || out="FAIL 000"
      code="${out##* }"
      ver=$(grep -o '"version":"[^"]*"' <<<"${out}" | cut -d'"' -f4)
      echo "$(date +%T) HTTP ${code} version=${ver:-none}" >>"${DEMO_TMP}/traffic.log"
      sleep 0.2
    done
  ) &
  BG_PIDS+=("$!")
  TRAFFIC_PID=$!
  info "Фоновий трафік на ${host}/info запущено (кожні 0.2 с)"
}
traffic_stop() {
  kill "${TRAFFIC_PID}" 2>/dev/null || true
  local total fails
  total=$(wc -l <"${DEMO_TMP}/traffic.log")
  fails=$(grep -vc 'HTTP 200' "${DEMO_TMP}/traffic.log" || true)
  echo "${C_B}Підсумок трафіку:${C_0} ${total} запитів"
  awk '{print $2, $3, $4}' "${DEMO_TMP}/traffic.log" | sort | uniq -c
  if [[ "${fails}" -eq 0 ]]; then
    echo "${C_G}Помилок: 0 — оновлення без простою${C_0}"
  else
    echo "${C_R}Помилок: ${fails}${C_0}"; grep -v 'HTTP 200' "${DEMO_TMP}/traffic.log" | head -5
  fi
}

# ---------- Покроковий сценарій ----------
# step "Заголовок" "Очікую: ..." 'команди'   — додає крок; run_steps виконує їх по черзі.
STEP_TITLES=(); STEP_EXPECT=(); STEP_CMDS=()
step() { STEP_TITLES+=("$1"); STEP_EXPECT+=("$2"); STEP_CMDS+=("$3"); }

list_steps() {
  local i
  for i in "${!STEP_TITLES[@]}"; do printf '  %2d. %s\n' "$((i + 1))" "${STEP_TITLES[$i]}"; done
}

# run_steps <from> <auto:0|1>
run_steps() {
  local from="${1:-1}" auto="${2:-0}" n=${#STEP_TITLES[@]} i key rc
  for ((i = from - 1; i < n; i++)); do
    echo
    echo "${C_B}${C_C}━━━ [$((i + 1))/${n}] ${STEP_TITLES[$i]} ━━━${C_0}"
    sed 's/^/  $ /' <<<"${STEP_CMDS[$i]}"
    [[ -n "${STEP_EXPECT[$i]}" ]] && echo "${C_DIM}  Очікую: ${STEP_EXPECT[$i]}${C_0}"
    if [[ "${auto}" != 1 ]]; then
      read -rsn1 -p "${C_Y}  [Enter] виконати  [s] пропустити  [q] вийти${C_0} " key </dev/tty; echo
      case "${key}" in
        s|S) continue ;;
        q|Q) info "Зупинено на кроці $((i + 1)). Продовжити: --from $((i + 1))"; return 0 ;;
      esac
    fi
    # eval у поточному shell (не в subshell): фонові port-forward реєструються в BG_PIDS і прибираються.
    set +e
    eval "${STEP_CMDS[$i]}"
    rc=$?
    set -e
    [[ ${rc} -ne 0 ]] && echo "${C_DIM}  (код виходу ${rc})${C_0}"
  done
  echo; info "${C_G}Демо завершено${C_0}"
}

# ---------- Ресурси ----------
show_resources() {
  echo "${C_B}Хост:${C_0}"; free -h | sed 's/^/  /'
  if docker inspect minikube >/dev/null 2>&1; then
    echo "${C_B}Контейнер minikube:${C_0}"
    docker stats --no-stream --format '  {{.Name}}: RAM {{.MemUsage}}  CPU {{.CPUPerc}}' minikube 2>/dev/null \
      || echo "  (зупинено)"
  fi
  if cluster_up; then
    echo "${C_B}Вузол (metrics-server):${C_0}"
    kubectl top node 2>/dev/null | sed 's/^/  /' || echo "  (metrics-server ще не готовий)"
    echo "${C_B}Найбільші pod-и:${C_0}"
    kubectl top pods -A --sort-by=memory 2>/dev/null | head -8 | sed 's/^/  /' || true
  fi
}
