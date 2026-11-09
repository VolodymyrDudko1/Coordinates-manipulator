#!/usr/bin/env bash
# Lab 6 comparative load test: 1 replica vs 3 replicas behind the same Nginx,
# identical Locust profile and identical per-container limits (docker-compose.lb.yml).
#   ./run_lab6_compare.sh [users=50] [spawn_rate=5] [run_time=3m]
# Results: results/lab6_single_* and results/lab6_lb3_* (+ _resources.csv, _backend.log)
set -euo pipefail
cd "$(dirname "$0")"
U=${1:-50}; R=${2:-5}; T=${3:-3m}
PY=${PY:-.venv/bin/python}; LOCUST=${LOCUST:-.venv/bin/locust}
DC="docker compose -f ../docker-compose.lb.yml"
HOST=http://localhost:${LB_PORT:-80}
P=portal-lb

wait_healthy() { for c in "$@"; do
  until [ "$(docker inspect -f '{{.State.Health.Status}}' "$c")" = healthy ]; do sleep 1; done; done; }

run() {  # name, upstream variant, replicas...
  local name=$1 algo=$2; shift 2
  local all=(web1 web2 web3) active=("$@") containers=()
  echo "=== $name: LB_ALGO=$algo, replicas: ${active[*]}"
  $DC up -d --wait "${all[@]}" >/dev/null 2>&1            # make sure every replica exists
  for w in "${active[@]}"; do containers+=("$P-$w-1"); done
  # restart the serving replicas -> independent runs, no queue left from a previous run
  docker restart "${containers[@]}" >/dev/null
  wait_healthy "${containers[@]}"
  for w in "${all[@]}"; do [[ " ${active[*]} " == *" $w "* ]] || $DC stop "$w" >/dev/null 2>&1; done
  LB_ALGO=$algo $DC up -d --no-deps --wait nginx >/dev/null 2>&1
  sleep 2
  local start; start=$(date +%s)
  $PY monitor.py --mode docker --containers "${containers[@]}" $P-db-1 $P-nginx-1 \
      --out "results/${name}_resources.csv" & local mon=$!
  sleep 3
  $LOCUST --config locust.conf --host "$HOST" -u "$U" -r "$R" -t "$T" \
      --csv "results/$name" --csv-full-history --html "results/$name.html" 2>&1 \
      | tee "results/$name.log" | grep -E '^\[summary\]' || true
  sleep 3; kill -TERM $mon; wait $mon 2>/dev/null || true
  for c in "${containers[@]}"; do docker logs --since "$start" "$c" > "results/${name}_${c#$P-}.backend.log" 2>&1; done
}

run lab6_single single web1
run lab6_lb3 round_robin web1 web2 web3
$DC up -d --wait >/dev/null 2>&1   # restore: all replicas + round robin
echo "done -> python compare_report.py"
