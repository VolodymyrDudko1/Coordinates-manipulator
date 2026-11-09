"""Sample server CPU / RAM every N seconds into a CSV while a load test runs.

Modes
  docker  (default) - `docker stats --no-stream` for the given containers
  process           - psutil for a process found by --pid or --name (incl. children)
  host              - psutil for the whole machine

Examples
  python monitor.py --mode docker --containers portal-web-1 portal-db-1
  python monitor.py --mode process --name uvicorn
  python monitor.py --mode host --duration 330
Stop with Ctrl+C or --duration seconds.

Output columns: timestamp (ISO), epoch, target, cpu_percent, mem_mb, mem_percent
Note: in docker/process mode cpu_percent is relative to ONE core (can exceed 100%).
"""

import argparse
import csv
import json
import signal
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

import psutil


def _to_mb(text: str) -> float:
    units = {
        "b": 1,
        "kib": 1024,
        "kb": 1000,
        "mib": 1024**2,
        "mb": 1000**2,
        "gib": 1024**3,
        "gb": 1000**3,
    }
    text = text.strip().lower()
    num = text.rstrip("abcdefghijklmnopqrstuvwxyz")
    unit = text[len(num) :] or "b"
    return float(num) * units.get(unit, 1) / 1024**2


def sample_docker(containers):
    out = subprocess.run(
        ["docker", "stats", "--no-stream", "--format", "{{json .}}", *containers],
        capture_output=True,
        text=True,
        timeout=30,
        check=True,
    ).stdout
    rows = []
    for line in out.splitlines():
        s = json.loads(line)
        rows.append(
            (
                s["Name"],
                float(s["CPUPerc"].rstrip("%") or 0),
                _to_mb(s["MemUsage"].split("/")[0]),
                float(s["MemPerc"].rstrip("%") or 0),
            )
        )
    return rows


def find_process(pid, name):
    if pid:
        return psutil.Process(pid)
    for p in psutil.process_iter(["name", "cmdline"]):
        cmd = " ".join(p.info["cmdline"] or [])
        if name in (p.info["name"] or "") or name in cmd:
            if p.pid != psutil.Process().pid:
                return p
    sys.exit(f"process matching {name!r} not found")


def sample_process(proc):
    procs = [proc, *proc.children(recursive=True)]
    cpu = mem = 0.0
    for p in procs:
        try:
            cpu += p.cpu_percent(None)
            mem += p.memory_info().rss
        except psutil.NoSuchProcess:
            pass
    total = psutil.virtual_memory().total
    return [(f"pid:{proc.pid}", cpu, mem / 1024**2, mem / total * 100)]


def sample_host():
    vm = psutil.virtual_memory()
    return [("host", psutil.cpu_percent(None), vm.used / 1024**2, vm.percent)]


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--mode", choices=["docker", "process", "host"], default="docker")
    ap.add_argument("--containers", nargs="+", default=["portal-web-1", "portal-db-1"])
    ap.add_argument("--pid", type=int)
    ap.add_argument("--name", default="uvicorn")
    ap.add_argument("--interval", type=float, default=1.0)
    ap.add_argument(
        "--duration", type=float, default=0, help="seconds, 0 = until Ctrl+C"
    )
    ap.add_argument("--out", default="results/resources.csv")
    args = ap.parse_args()

    def _on_term(*_):  # background jobs in scripts ignore SIGINT, so accept TERM too
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, _on_term)

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    proc = find_process(args.pid, args.name) if args.mode == "process" else None
    if proc:  # prime cpu_percent counters
        for p in [proc, *proc.children(recursive=True)]:
            p.cpu_percent(None)
    psutil.cpu_percent(None)

    started = time.time()
    with out.open("w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(
            ["timestamp", "epoch", "target", "cpu_percent", "mem_mb", "mem_percent"]
        )
        print(f"monitor: mode={args.mode} -> {out} (Ctrl+C to stop)", flush=True)
        try:
            while not args.duration or time.time() - started < args.duration:
                tick = time.time()
                if args.mode == "docker":
                    rows = sample_docker(args.containers)  # itself takes ~1-2 s
                elif args.mode == "process":
                    rows = sample_process(proc)
                else:
                    rows = sample_host()
                now = time.time()
                for target, cpu, mem_mb, mem_pct in rows:
                    w.writerow(
                        [
                            datetime.fromtimestamp(now).isoformat(timespec="seconds"),
                            round(now, 3),
                            target,
                            round(cpu, 2),
                            round(mem_mb, 1),
                            round(mem_pct, 2),
                        ]
                    )
                fh.flush()
                time.sleep(max(0.0, args.interval - (time.time() - tick)))
        except KeyboardInterrupt:
            pass
    print(f"monitor: stopped, {out}")


if __name__ == "__main__":
    main()
