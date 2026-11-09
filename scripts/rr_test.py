#!/usr/bin/env python3
"""Load-balancing demo / mini-benchmark (stdlib only).

Sequential mode (default) — the round-robin demo:
    python3 scripts/rr_test.py                      # 20 x GET http://localhost/whoami
    python3 scripts/rr_test.py -n 30 --url http://localhost/whoami

Concurrent mode — compare algorithms under uneven request durations (/slow):
    python3 scripts/rr_test.py --url "http://localhost/slow" -n 120 -c 6 --quiet

Prints who served each request (X-Served-By), a per-instance summary and, for
concurrent runs, wall time and latency percentiles.
"""

import argparse
import statistics
import sys
import time
import urllib.error
import urllib.request
from collections import Counter
from concurrent.futures import ThreadPoolExecutor


def one(url: str) -> tuple[int, str, str, float]:
    start = time.perf_counter()
    try:
        with urllib.request.urlopen(url, timeout=60) as resp:
            resp.read()
            code, headers = resp.status, resp.headers
    except urllib.error.HTTPError as exc:  # 4xx/5xx still carry headers
        code, headers = exc.code, exc.headers
    except OSError as exc:
        return 0, f"ERR:{type(exc).__name__}", "-", time.perf_counter() - start
    return (
        code,
        headers.get("X-Served-By", "-"),
        headers.get("X-Upstream", "-"),
        time.perf_counter() - start,
    )


def pct(values: list[float], p: float) -> float:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round(p / 100 * (len(ordered) - 1))))]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--url", default="http://localhost/whoami")
    ap.add_argument("-n", "--requests", type=int, default=20)
    ap.add_argument("-c", "--concurrency", type=int, default=1)
    ap.add_argument("--quiet", action="store_true", help="only the summary")
    args = ap.parse_args()

    t0 = time.perf_counter()
    with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        results = list(pool.map(lambda _: one(args.url), range(args.requests)))
    wall = time.perf_counter() - t0

    if not args.quiet:
        print(f"{'#':<4} {'HTTP':<5} {'replica':<8} {'X-Upstream':<18} time")
        for i, (code, served, upstream, dt) in enumerate(results, 1):
            print(f"{i:<4} {code:<5} {served:<8} {upstream:<18} {dt * 1000:.0f} ms")

    bad = sum(1 for r in results if r[0] != 200)
    counts = Counter(r[1] for r in results)
    print(f"---- summary: {len(results)} requests, non-200: {bad}")
    for name in sorted(counts):
        share = counts[name] / len(results) * 100
        print(f"{name:<8} {counts[name]:>4}  {share:5.1f}%  {'#' * counts[name]}")
    if args.concurrency > 1:
        lat = [r[3] * 1000 for r in results]
        print(
            f"wall={wall:.2f}s  throughput={len(results) / wall:.2f} req/s  "
            f"avg={statistics.mean(lat):.0f} ms  p50={pct(lat, 50):.0f} ms  "
            f"p95={pct(lat, 95):.0f} ms  max={max(lat):.0f} ms"
        )
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
