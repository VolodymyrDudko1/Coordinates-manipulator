#!/usr/bin/env bash
# Failover demo for the Nginx load balancer (Lab 6).
#   scripts/failover_test.sh [victim=web2] [stop|kill]
# 1) all replicas up -> round robin; 2) stop the victim -> 20 requests must all be
# 200 and served only by the others; 3) Nginx log lines about the failed upstream;
# 4) start the victim again -> it is back in rotation.
set -uo pipefail
cd "$(dirname "$0")/.."
VICTIM=${1:-web2}
HOW=${2:-stop}
URL=${URL:-http://localhost:${LB_PORT:-80}/whoami}
DC="docker compose -f docker-compose.lb.yml"
RR=scripts/rr_test.sh
rc=0

step() { printf '\n\033[1m=== %s\033[0m\n' "$*"; }

step "1. All replicas up"
$DC ps --format 'table {{.Service}}\t{{.Status}}' | grep -E 'SERVICE|web|nginx'
$RR "$URL" 20 | tail -4

step "2. docker compose $HOW $VICTIM"
since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
$DC "$HOW" "$VICTIM" 2>&1 | tail -1

step "3. 20 requests with $VICTIM down (expect only 200, no $VICTIM)"
out=$($RR "$URL" 20); echo "$out"
if grep -qE "^[0-9]+ +(5[0-9][0-9]|000) " <<<"$out"; then echo "FAIL: client saw 5xx/errors"; rc=1; fi
if grep -qE "^$VICTIM " <<<"$(sed -n '/summary/,$p' <<<"$out")"; then echo "FAIL: $VICTIM still served"; rc=1; fi
[ $rc -eq 0 ] && echo "OK: all requests succeeded without $VICTIM"

step "4. Nginx log lines about the failed upstream (since $since)"
$DC logs --no-log-prefix --since "$since" nginx 2>&1 \
  | grep -E '\[(error|warn)\]|, [0-9.]+:8000|ustatus=[0-9]+, ' | head -12

step "5. docker compose start $VICTIM, wait until healthy"
$DC start "$VICTIM" 2>&1 | tail -1
cid=$($DC ps -q "$VICTIM")
for _ in $(seq 1 60); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' "$cid")" = healthy ] && break; sleep 1
done
echo "$VICTIM: $(docker inspect -f '{{.State.Health.Status}}' "$cid")"
# DNS re-resolution (valid=5s) + end of fail_timeout (10s) before Nginx retries it.
sleep "${REJOIN_WAIT:-11}"

step "6. 20 requests after recovery (expect $VICTIM back)"
out=$($RR "$URL" 20); echo "$out" | tail -4
grep -qE "^$VICTIM " <<<"$(sed -n '/summary/,$p' <<<"$out")" && echo "OK: $VICTIM is back in rotation" || { echo "FAIL: $VICTIM not back"; rc=1; }
exit $rc
