"""Lab 6: compare two Locust runs — 1 replica vs 3 replicas behind Nginx.

Inputs (results/, produced by run_lab6_compare.sh):
    lab6_single_stats.csv, lab6_single_stats_history.csv, lab6_single_resources.csv
    lab6_lb3_stats.csv,    lab6_lb3_stats_history.csv,    lab6_lb3_resources.csv
Outputs:
    results/lab6_compare_rps.png        RPS + failures/s over time, both runs
    results/lab6_compare_p95.png        p95 (and avg) over time, both runs
    results/lab6_compare_resources.png  CPU of replicas / db / nginx, both runs
    results/lab6_compare_summary.csv    the comparison table
    results/lab6_compare.md             Markdown tables (pasted into the README)

Usage:  python compare_report.py [--a lab6_single] [--b lab6_lb3]
"""

import argparse

import matplotlib.pyplot as plt
import pandas as pd
from make_report import (
    BLUE,
    CRITICAL,
    INK2,
    ORANGE,
    RES,
    fmt,
    load_run,
    steady_part,
    to_md,
)

LABELS = {"lab6_single": "1 репліка", "lab6_lb3": "3 репліки (RR)"}
COLORS = {"lab6_single": ORANGE, "lab6_lb3": BLUE}


def load(run: str) -> dict:
    d = load_run(run)
    d["users"] = int(d["agg"]["User Count"].max())  # run names carry no "<N>u"
    d["label"] = LABELS.get(run, run)
    d["color"] = COLORS.get(run, INK2)
    return d


def resources(d: dict) -> dict:
    """CPU (% of one core) per role during the load window."""
    out = {}
    r = d["res"]
    if r is None:
        return out
    r = r[r["t"].between(0, d["agg"]["t"].max())]
    r = r.assign(role=r["target"].str.extract(r"-(web\d|db|nginx)-")[0])
    per_ts = r.pivot_table(index="t", columns="role", values="cpu_percent", aggfunc="sum")
    webs = [c for c in per_ts.columns if c.startswith("web")]
    per_ts["web_total"] = per_ts[webs].sum(axis=1)
    out["replicas"] = len(webs)
    out["web_cpu_mean"] = per_ts["web_total"].mean()
    out["web_cpu_max"] = per_ts["web_total"].max()
    out["web_cpu_per_replica"] = per_ts[webs].mean().mean()
    out["db_cpu_mean"] = per_ts.get("db", pd.Series(dtype=float)).mean()
    out["db_cpu_max"] = per_ts.get("db", pd.Series(dtype=float)).max()
    out["nginx_cpu_max"] = per_ts.get("nginx", pd.Series(dtype=float)).max()
    mem = r[r["role"].str.startswith("web", na=False)].groupby("role")["mem_mb"].max()
    out["web_mem_max"] = mem.max()
    out["series"] = per_ts
    return out


def summarize(d: dict) -> dict:
    s = d["stats"]
    a = s[s["Name"] == "Aggregated"].iloc[0]
    duration = max(d["agg"]["t"].max(), 1)
    steady = steady_part(d)
    row = {
        "run": d["run"],
        "label": d["label"],
        "requests": int(a["Request Count"]),
        "failures": int(a["Failure Count"]),
        "rps": a["Request Count"] / duration,
        "rps_steady": steady["Requests/s"].mean(),
        "avg": a["Average Response Time"],
        "p50": a["Median Response Time"],
        "p95": a["95%"],
        "p99": a["99%"],
        "max": a["Max Response Time"],
        "p95_steady": steady["95%"].median(),
        "err": a["Failure Count"] / max(a["Request Count"], 1) * 100,
    }
    # Settled state: the last 60 s, after the on_start registration burst has drained.
    agg = d["agg"]
    tail = agg[agg["t"] >= agg["t"].max() - 60]
    span = max(tail["t"].max() - tail["t"].min(), 1)
    d_req = tail["Total Request Count"].iloc[-1] - tail["Total Request Count"].iloc[0]
    d_fail = tail["Total Failure Count"].iloc[-1] - tail["Total Failure Count"].iloc[0]
    row["rps_last60"] = d_req / span
    row["p95_last60"] = tail["95%"].median()
    row["err_last60"] = d_fail / max(d_req, 1) * 100
    row.update({k: v for k, v in resources(d).items() if k != "series"})
    return row


# ----------------------------------------------------------------------- charts
def _save(fig, name: str) -> str:
    fig.tight_layout()
    fig.savefig(RES / name, dpi=130)
    plt.close(fig)
    return name


def chart_rps(runs: list[dict]) -> str:
    fig, ax = plt.subplots(figsize=(10, 4.8))
    for d in runs:
        agg = d["agg"]
        ax.plot(agg["t"], agg["Requests/s"], color=d["color"], lw=2,
                label=f"{d['label']}: RPS")
        if agg["Failures/s"].max() > 0:
            ax.plot(agg["t"], agg["Failures/s"], color=d["color"], lw=1.2, ls="--",
                    label=f"{d['label']}: помилок/с")
    ax.set_title("Пропускна здатність: 1 vs 3 репліки за Nginx")
    ax.set_xlabel("час від старту тесту, с")
    ax.set_ylabel("запитів за секунду")
    ax.set_ylim(bottom=0)
    ax.legend(loc="upper left")
    return _save(fig, "lab6_compare_rps.png")


def chart_p95(runs: list[dict]) -> str:
    fig, ax = plt.subplots(figsize=(10, 4.8))
    for d in runs:
        agg = d["agg"]
        ax.plot(agg["t"], agg["95%"], color=d["color"], lw=2, label=f"{d['label']}: p95")
        ax.plot(agg["t"], agg["avg_interval"], color=d["color"], lw=1, alpha=0.55,
                label=f"{d['label']}: avg")
    ax.set_title("Час відповіді (p95 у вікні 10 с та середній): 1 vs 3 репліки")
    ax.set_xlabel("час від старту тесту, с")
    ax.set_ylabel("мс (логарифмічна шкала)")
    ax.set_yscale("log")
    ax.legend(loc="upper right")
    return _save(fig, "lab6_compare_p95.png")


def chart_resources(runs: list[dict]) -> str | None:
    have = [(d, resources(d)) for d in runs if d["res"] is not None]
    if not have:
        return None
    fig, axes = plt.subplots(1, len(have), figsize=(11, 4.2), sharey=True, squeeze=False)
    for ax, (d, r) in zip(axes[0], have):
        s = r["series"]
        ax.plot(s.index, s["web_total"], color=d["color"], lw=2,
                label=f"репліки разом ({r['replicas']})")
        if "db" in s:
            ax.plot(s.index, s["db"], color=INK2, lw=1.4, label="db (PostgreSQL)")
        if "nginx" in s:
            ax.plot(s.index, s["nginx"], color=CRITICAL, lw=1.2, label="nginx")
        ax.axhline(100 * r["replicas"], color=d["color"], lw=1, ls=":",
                   label=f"ліміт cpus: {r['replicas']} × 1.0")
        ax.set_title(d["label"])
        ax.set_xlabel("час, с")
        ax.legend(loc="upper left", fontsize=8)
    axes[0][0].set_ylabel("CPU, % одного ядра")
    axes[0][0].set_ylim(bottom=0)
    fig.suptitle("CPU під навантаженням", x=0.01, ha="left", fontweight="bold")
    return _save(fig, "lab6_compare_resources.png")


# ----------------------------------------------------------------------- tables
def comparison_md(a: dict, b: dict) -> str:
    def ratio(x, y):
        return f"×{y / x:.2f}" if x else "—"

    rows = [
        ("Запитів за прогін", f"{a['requests']}", f"{b['requests']}", ratio(a["requests"], b["requests"])),
        ("RPS (середнє за тест)", fmt(a["rps"]), fmt(b["rps"]), ratio(a["rps"], b["rps"])),
        ("RPS (плато)", fmt(a["rps_steady"]), fmt(b["rps_steady"]), ratio(a["rps_steady"], b["rps_steady"])),
        ("RPS, останні 60 с", fmt(a["rps_last60"]), fmt(b["rps_last60"]), ratio(a["rps_last60"], b["rps_last60"])),
        ("p95, останні 60 с, мс", fmt(a["p95_last60"], 0), fmt(b["p95_last60"], 0), ratio(a["p95_last60"], b["p95_last60"])),
        ("Помилки, останні 60 с, %", fmt(a["err_last60"], 2), fmt(b["err_last60"], 2), "—"),
        ("Avg, мс", fmt(a["avg"]), fmt(b["avg"]), ratio(a["avg"], b["avg"])),
        ("Median, мс", fmt(a["p50"], 0), fmt(b["p50"], 0), ratio(a["p50"], b["p50"])),
        ("p95, мс", fmt(a["p95"], 0), fmt(b["p95"], 0), ratio(a["p95"], b["p95"])),
        ("p95 на плато, мс", fmt(a["p95_steady"], 0), fmt(b["p95_steady"], 0), ratio(a["p95_steady"], b["p95_steady"])),
        ("p99, мс", fmt(a["p99"], 0), fmt(b["p99"], 0), ratio(a["p99"], b["p99"])),
        ("Max, мс", fmt(a["max"], 0), fmt(b["max"], 0), ratio(a["max"], b["max"])),
        ("Помилки, %", fmt(a["err"], 2), fmt(b["err"], 2), "—"),
    ]
    if "web_cpu_mean" in a and "web_cpu_mean" in b:
        rows += [
            ("CPU реплік разом, avg / max %",
             f"{fmt(a['web_cpu_mean'], 0)} / {fmt(a['web_cpu_max'], 0)}",
             f"{fmt(b['web_cpu_mean'], 0)} / {fmt(b['web_cpu_max'], 0)}", "—"),
            ("CPU на одну репліку, avg %", fmt(a["web_cpu_per_replica"], 0),
             fmt(b["web_cpu_per_replica"], 0), "—"),
            ("CPU PostgreSQL, avg / max %",
             f"{fmt(a['db_cpu_mean'], 0)} / {fmt(a['db_cpu_max'], 0)}",
             f"{fmt(b['db_cpu_mean'], 0)} / {fmt(b['db_cpu_max'], 0)}", "—"),
            ("CPU Nginx, max %", fmt(a["nginx_cpu_max"], 1), fmt(b["nginx_cpu_max"], 1), "—"),
            ("RAM репліки, max МБ", fmt(a["web_mem_max"], 0), fmt(b["web_mem_max"], 0), "—"),
        ]
    out = [f"| Метрика | {a['label']} | {b['label']} | 3 / 1 |", "|---|---:|---:|---:|"]
    out += [f"| {m} | {x} | {y} | {r} |" for m, x, y, r in rows]
    return "\n".join(out)


def endpoints_md(a: dict, b: dict) -> str:
    def ep(d):
        s = d["stats"][d["stats"]["Name"] != "Aggregated"]
        return s.set_index("Name")[["Request Count", "Failure Count", "Average Response Time", "95%"]]

    ea, eb = ep(a), ep(b)
    names = sorted(set(ea.index) | set(eb.index))
    df = pd.DataFrame({
        "Ендпоінт": [f"`{n}`" for n in names],
        "Запитів (1 / 3)": [f"{int(ea['Request Count'].get(n, 0))} / {int(eb['Request Count'].get(n, 0))}" for n in names],
        "Avg, мс (1 / 3)": [f"{fmt(ea['Average Response Time'].get(n), 0)} / {fmt(eb['Average Response Time'].get(n), 0)}" for n in names],
        "p95, мс (1 / 3)": [f"{fmt(ea['95%'].get(n), 0)} / {fmt(eb['95%'].get(n), 0)}" for n in names],
        "Помилок (1 / 3)": [f"{int(ea['Failure Count'].get(n, 0))} / {int(eb['Failure Count'].get(n, 0))}" for n in names],
    })
    return to_md(df)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--a", default="lab6_single")
    ap.add_argument("--b", default="lab6_lb3")
    args = ap.parse_args()
    runs = [load(args.a), load(args.b)]
    a, b = (summarize(d) for d in runs)
    pd.DataFrame([a, b]).to_csv(RES / "lab6_compare_summary.csv", index=False)
    charts = [chart_rps(runs), chart_p95(runs), chart_resources(runs)]
    md = [
        f"Профіль: {runs[0]['users']} VUsers, однаковий для обох прогонів; "
        f"тривалість {runs[0]['agg']['t'].max() / 60:.1f} / {runs[1]['agg']['t'].max() / 60:.1f} хв.",
        "",
        comparison_md(a, b),
        "",
        "По ендпоінтах:",
        "",
        endpoints_md(*runs),
        "",
    ] + [f"![{c}](load-tests/results/{c})" for c in charts if c]
    (RES / "lab6_compare.md").write_text("\n".join(md) + "\n", encoding="utf-8")
    print("\n".join(md))


if __name__ == "__main__":
    main()
