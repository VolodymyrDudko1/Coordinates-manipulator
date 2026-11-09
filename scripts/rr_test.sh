#!/usr/bin/env bash
# Round-robin demo: N sequential requests to the balancer, print who served each one
# and a per-instance summary.
#   scripts/rr_test.sh [URL=http://localhost/whoami] [N=20]
# Exit code 1 if any request did not return HTTP 200.
set -uo pipefail
URL=${1:-http://localhost/whoami}
N=${2:-20}

declare -A count=()
fails=0
printf '%-4s %-6s %-8s %-32s %s\n' "#" "HTTP" "replica" "X-Upstream" "time"
for i in $(seq 1 "$N"); do
    # -D - : dump headers to stdout, body is discarded
    out=$(curl -s -o /dev/null -D - -w 'HTTP_CODE:%{http_code} TIME:%{time_total}\n' --max-time 30 "$URL")
    code=$(sed -n 's/^HTTP_CODE:\([0-9]*\).*/\1/p' <<<"$out")
    time=$(sed -n 's/.*TIME:\([0-9.]*\).*/\1/p' <<<"$out")
    served=$(sed -n 's/^[Xx]-[Ss]erved-[Bb]y: *\([^[:space:]]*\).*/\1/p' <<<"$out")
    # all tried upstreams, e.g. "172.20.0.7:8000,172.20.0.3:8000" after a failover retry
    upstream=$(sed -n 's/^[Xx]-[Uu]pstream: *//p' <<<"$out" | tr -d '\r ')
    served=${served:-"-"}
    [ "$code" = 200 ] || fails=$((fails + 1))
    count[$served]=$(( ${count[$served]:-0} + 1 ))
    printf '%-4s %-6s %-8s %-32s %ss\n' "$i" "$code" "$served" "${upstream:--}" "$time"
done

echo "---- summary: $N requests, non-200: $fails"
for k in $(printf '%s\n' "${!count[@]}" | sort); do
    printf '%-8s %3d  %s\n' "$k" "${count[$k]}" "$(printf '%*s' "${count[$k]}" '' | tr ' ' '#')"
done
[ "$fails" -eq 0 ]
