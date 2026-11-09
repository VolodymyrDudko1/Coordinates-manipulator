#!/usr/bin/env bash
# Usage: ./run_test.sh <users> [run_time=5m] [spawn_rate=5]
# Starts monitor.py, runs a headless Locust test from locust.conf, stops the monitor.
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?users}; T=${2:-5m}; R=${3:-5}; NAME=run_${U}u
PY=${PY:-.venv/bin/python}; LOCUST=${LOCUST:-.venv/bin/locust}
mkdir -p results
if [ -n "${RESTART_CONTAINER:-}" ]; then   # e.g. RESTART_CONTAINER=portal-web-1 for independent runs
  docker restart "$RESTART_CONTAINER" >/dev/null
  until [ "$(docker inspect -f '{{.State.Health.Status}}' "$RESTART_CONTAINER")" = healthy ]; do sleep 1; done
fi
START=$(date +%s)
$PY monitor.py --mode "${MONITOR_MODE:-docker}" --out "results/${NAME}_resources.csv" & MON=$!
trap 'kill -TERM $MON 2>/dev/null || true; wait $MON 2>/dev/null || true' EXIT
sleep 3   # idle baseline
$LOCUST --config locust.conf -u "$U" -r "$R" -t "$T" \
  --csv "results/$NAME" --csv-full-history --html "results/$NAME.html" 2>&1 | tee "results/$NAME.log" | grep -E '^\[summary\]|Aggregated' || true
sleep 3   # cool-down tail
if [ -n "${BACKEND_CONTAINER:-portal-web-1}" ] && command -v docker >/dev/null; then
  docker logs --since "$START" "${BACKEND_CONTAINER:-portal-web-1}" > "results/${NAME}_backend.log" 2>&1 || true
fi
