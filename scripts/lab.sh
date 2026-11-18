#!/usr/bin/env bash
# Одна точка входу для перемикання між лабораторними й покрокових демо на захисті.
# Одночасно працює лише ОДНА лабораторна: перед запуском інша автоматично вимикається (економія RAM).
#
#   ./scripts/lab.sh status                 що зараз розгорнуто + споживання RAM
#   ./scripts/lab.sh demo 3                 покрокове демо Lab 3 (Enter — виконати крок, s — пропустити, q — вийти)
#   ./scripts/lab.sh demo 4 --from 9        продовжити з кроку 9
#   ./scripts/lab.sh demo 4 --list          лише перелік кроків
#   ./scripts/lab.sh demo 4 --yes           без пауз (репетиція)
#   ./scripts/lab.sh up 4 [values-файл]     розгорнути лабораторну в готовому стані (для запитань викладача)
#   ./scripts/lab.sh down [N|all]           вимкнути лабораторну N або всі
#   ./scripts/lab.sh sleep [--docker]       вимкнути всі лаби й зупинити minikube (звільнити RAM для дзвінка);
#                                           --docker: якщо активний Docker Desktop — зупинити і його VM
#   ./scripts/lab.sh wake                   запустити minikube (і Docker Desktop, якщо активний контекст desktop-linux)
#
# Лабораторні описані у scripts/labs/labN.sh; нові (5, 6, 7) додаються новими файлами.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

# shellcheck source=labs/lib.sh
source scripts/labs/lib.sh

LABS=()
for f in scripts/labs/lab[0-9]*.sh; do
  # shellcheck disable=SC1090
  source "${f}"
  n="${f##*/lab}"; LABS+=("${n%.sh}")
done

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

check_lab() {
  [[ -n "${1:-}" ]] || usage 1
  local l
  for l in "${LABS[@]}"; do [[ "${l}" == "$1" ]] && return 0; done
  die "невідома лабораторна '$1'. Доступні: ${LABS[*]}"
}

# Вимкнути всі лабораторні, крім $1. TARGET_LAB бачать labN_down (напр. Lab 5 не гасить Argo CD,
# якщо наступна лаба теж на ньому).
others_down() {
  local l
  TARGET_LAB="${1:-}"
  for l in "${LABS[@]}"; do
    [[ "${l}" == "${1:-}" ]] && continue
    if "lab${l}_is_up"; then
      info "Вимикаю Lab ${l}, щоб звільнити ресурси"
      "lab${l}_down"
    fi
  done
  # Argo CD потрібен лише Lab 5–7; для інших (і для `down all`) — масштабувати до 0.
  if [[ ! "${TARGET_LAB}" =~ ^[5-9]$ ]] && argocd_awake; then argocd_sleep; fi
}

cmd_status() {
  if cluster_up; then
    local l any=0
    echo "${C_B}Лабораторні:${C_0}"
    for l in "${LABS[@]}"; do
      if "lab${l}_is_up"; then echo "  ${C_G}●${C_0} $("lab${l}_title")"; any=1
      else echo "  ${C_DIM}○ $("lab${l}_title")${C_0}"; fi
    done
    [[ ${any} == 1 ]] || echo "  (жодна не розгорнута)"
    if argocd_installed; then
      if argocd_awake; then echo "  Argo CD: ${C_G}працює${C_0} (UI: http://localhost:${ARGOCD_PORT} під час демо)"
      else echo "  ${C_DIM}Argo CD: масштабовано до 0${C_0}"; fi
    fi
  else
    echo "${C_B}Кластер:${C_0} minikube зупинено (./scripts/lab.sh wake)"
  fi
  show_resources
}

cmd_demo() {
  local lab="$1"; shift
  local from=1 auto=0 list=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from) from="$2"; shift 2 ;;
      --yes)  auto=1; shift ;;
      --list) list=1; shift ;;
      *) die "невідомий параметр $1" ;;
    esac
  done
  if [[ ${list} == 1 ]]; then "lab${lab}_steps"; echo "$("lab${lab}_title"):"; list_steps; return; fi

  ensure_cluster
  others_down "${lab}"
  # Демо з першого кроку починається з чистого стану (сам деплой — частина демо).
  if [[ "${from}" == 1 ]] && "lab${lab}_is_up"; then
    local ans=y
    [[ ${auto} == 1 ]] || read -rp "Lab ${lab} уже розгорнута. Скинути до чистого стану? [Y/n] " ans </dev/tty
    TARGET_LAB="${lab}"
    [[ "${ans:-y}" =~ ^[Nn] ]] || "lab${lab}_down"
  fi
  "lab${lab}_prepare"
  # Кроки будуються ПІСЛЯ prepare: Lab 5 підставляє в них поточний тег образу з Git.
  "lab${lab}_steps"
  ingress_pf
  info "$("lab${lab}_title") — ${#STEP_TITLES[@]} кроків. Браузер/curl через Ingress: http://<host>:${INGRESS_PORT}/"
  run_steps "${from}" "${auto}"
}

cmd_up() {
  local lab="$1"; shift
  ensure_cluster
  others_down "${lab}"
  "lab${lab}_prepare"
  if "lab${lab}_is_up"; then info "Lab ${lab} уже розгорнута"; else "lab${lab}_up" "$@"; fi
  info "Готово. Ingress: kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller ${INGRESS_PORT}:80"
}

cmd_down() {
  local what="${1:-all}"
  cluster_up || { info "minikube зупинено — нічого вимикати"; return; }
  if [[ "${what}" == all ]]; then others_down ""; else check_lab "${what}"; "lab${what}_down"; fi
}

cmd_sleep() {
  if cluster_up; then cmd_down all; fi
  info "Зупиняю minikube"
  minikube stop || true
  if [[ "${1:-}" == --docker ]]; then
    if [[ "$(docker context show 2>/dev/null)" == desktop-linux ]]; then
      info "Зупиняю Docker Desktop"
      systemctl --user stop docker-desktop || warn "не вдалося: закрийте Docker Desktop вручну"
    else
      info "Docker Engine (docker-ce): окремої VM немає — після minikube stop RAM уже звільнено"
    fi
  fi
  show_resources
}

cmd_wake() {
  if ! docker info >/dev/null 2>&1; then
    [[ "$(docker context show 2>/dev/null)" == desktop-linux ]] \
      || die "Docker Engine не відповідає: sudo systemctl start docker"
    info "Запускаю Docker Desktop"
    systemctl --user start docker-desktop
    local _
    for _ in $(seq 1 60); do docker info >/dev/null 2>&1 && break; sleep 2; done
    docker info >/dev/null 2>&1 || die "Docker Desktop не запустився"
  fi
  ensure_cluster
  cmd_status
}

case "${1:-}" in
  status) cmd_status ;;
  demo)   check_lab "${2:-}"; cmd_demo "${@:2}" ;;
  up)     check_lab "${2:-}"; cmd_up "${@:2}" ;;
  down)   cmd_down "${2:-all}" ;;
  sleep)  cmd_sleep "${2:-}" ;;
  wake)   cmd_wake ;;
  -h|--help|help|"") usage 0 ;;
  *) usage 1 ;;
esac
