"""Build charts + report.md from Locust CSVs and monitor.py resource samples.

Inputs (per run NAME, e.g. run_50u), all in results/:
    NAME_stats.csv, NAME_stats_history.csv     (locust --csv NAME --csv-full-history)
    NAME_resources.csv  or  resources.csv      (monitor.py)
Outputs:
    results/NAME_latency.png, NAME_throughput.png, NAME_resources.png
    results/scalability.png   (when >= 2 runs)
    results/summary_NAME.csv  (summary table)
    report.md                 (Ukrainian)

Usage:
    python make_report.py                       # every results/run_*_stats.csv, main = run_50u
    python make_report.py --runs run_50u --main run_50u
"""

import argparse
import platform
import re
import subprocess
from datetime import datetime
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import pandas as pd  # noqa: E402

HERE = Path(__file__).resolve().parent
RES = HERE / "results"

# Validated categorical slots 1..2 + reserved status "critical" (dataviz palette).
BLUE, ORANGE, AQUA, YELLOW = "#2a78d6", "#eb6834", "#1baf7a", "#eda100"
CRITICAL = "#d03b3b"
INK, INK2, GRID, SURFACE = "#0b0b0b", "#52514e", "#e4e3df", "#fcfcfb"

plt.rcParams.update(
    {
        "figure.facecolor": SURFACE,
        "axes.facecolor": SURFACE,
        "savefig.facecolor": SURFACE,
        "axes.edgecolor": GRID,
        "axes.labelcolor": INK2,
        "xtick.color": INK2,
        "ytick.color": INK2,
        "axes.grid": True,
        "grid.color": GRID,
        "grid.linewidth": 0.8,
        "axes.spines.top": False,
        "axes.spines.right": False,
        "axes.titlecolor": INK,
        "axes.titlesize": 11,
        "axes.titleweight": "bold",
        "axes.titlelocation": "left",
        "font.size": 9,
        "legend.frameon": False,
        "lines.linewidth": 2,
    }
)

PLACEHOLDER = (
    "⟪НЕМАЄ ДАНИХ — запустіть `./run_test.sh 50` і повторіть `python make_report.py`⟫"
)


# ----------------------------------------------------------------------- loading
def users_of(run: str) -> int:
    m = re.search(r"(\d+)u", run)
    return int(m.group(1)) if m else 0


def load_run(run: str) -> dict:
    stats = pd.read_csv(RES / f"{run}_stats.csv")
    hist = pd.read_csv(RES / f"{run}_stats_history.csv")
    for c in hist.columns:
        if c not in ("Type", "Name"):
            hist[c] = pd.to_numeric(hist[c], errors="coerce")

    agg = hist[hist["Name"] == "Aggregated"].copy().sort_values("Timestamp")
    t0 = agg["Timestamp"].iloc[0]
    agg["t"] = agg["Timestamp"] - t0
    # Locust's history only has a *cumulative* average; derive the per-interval one.
    total_ms = agg["Total Average Response Time"] * agg["Total Request Count"]
    d_req = agg["Total Request Count"].diff()
    agg["avg_interval"] = (total_ms.diff() / d_req).where(d_req > 0)
    agg["err_interval"] = (agg["Total Failure Count"].diff() / d_req * 100).where(
        d_req > 0
    )

    res_file = RES / f"{run}_resources.csv"
    if not res_file.exists():
        res_file = RES / "resources.csv"
    res = None
    if res_file.exists():
        res = pd.read_csv(res_file)
        res["t"] = res["epoch"] - t0
        res = res[(res["t"] >= -5) & (res["t"] <= agg["t"].max() + 10)]
        if res.empty:
            res = None
    fail_file = RES / f"{run}_failures.csv"
    failures = pd.read_csv(fail_file) if fail_file.exists() else pd.DataFrame()
    log_file = RES / f"{run}_backend.log"
    server_errors = {}
    if log_file.exists():
        for line in log_file.read_text(errors="replace").splitlines():
            m = re.match(r"^([\w.]+(?:Error|Exception|Timeout)): (.{0,80})", line)
            if m:
                key = f"{m.group(1)}: {m.group(2)}"
                server_errors[key] = server_errors.get(key, 0) + 1
    return {
        "run": run,
        "users": users_of(run),
        "stats": stats,
        "agg": agg,
        "res": res,
        "failures": failures,
        "server_errors": server_errors,
        "res_file": res_file.name if res is not None else None,
    }


# ----------------------------------------------------------------------- tables
def summary_table(d: dict) -> pd.DataFrame:
    s = d["stats"]
    duration = max(d["agg"]["t"].max(), 1)
    out = pd.DataFrame(
        {
            "Ендпоінт": (s["Type"].fillna("") + " " + s["Name"]).str.strip(),
            "Запитів": s["Request Count"],
            "RPS": (s["Request Count"] / duration).round(2),
            "Avg, мс": s["Average Response Time"].round(1),
            "Min, мс": s["Min Response Time"].round(1),
            "Median, мс": s["Median Response Time"],
            "p95, мс": s["95%"],
            "p99, мс": s["99%"],
            "Max, мс": s["Max Response Time"].round(1),
            "Помилки, %": (
                s["Failure Count"] / s["Request Count"].clip(lower=1) * 100
            ).round(2),
        }
    )
    out.loc[out["Ендпоінт"] == "Aggregated", "Ендпоінт"] = "**Усього**"
    return out


def to_md(df: pd.DataFrame) -> str:
    cols = list(df.columns)
    lines = [
        "| " + " | ".join(cols) + " |",
        "|" + "|".join(["---"] + ["---:"] * (len(cols) - 1)) + "|",
    ]
    for _, r in df.iterrows():
        lines.append("| " + " | ".join(str(r[c]) for c in cols) + " |")
    return "\n".join(lines)


def steady_part(d: dict) -> pd.DataFrame:
    """Plateau: all users spawned, +15 s so the on_start (register/login) burst has drained."""
    agg = d["agg"]
    full = agg[agg["User Count"] >= d["users"]]
    if full.empty:
        return full
    return agg[agg["t"] >= full["t"].min() + 15]


def failures_md(d: dict) -> str:
    f = d["failures"]
    if f.empty:
        return "Помилок не зафіксовано.\n"
    f = f.groupby(["Method", "Name", "Error"], as_index=False)["Occurrences"].sum()
    f = f.sort_values("Occurrences", ascending=False)
    lines = ["| Запит | Помилка | К-сть |", "|---|---|---:|"]
    for _, r in f.iterrows():
        err = (
            str(r["Error"])
            .replace("CatchResponseError(", "")
            .rstrip(")")
            .replace("|", "/")[:140]
        )
        lines.append(f"| `{r['Method']} {r['Name']}` | {err} | {r['Occurrences']} |")
    if d["server_errors"]:
        lines += [
            "",
            "Виключення в лозі backend за час прогону:",
            "",
            "| Виключення | К-сть |",
            "|---|---:|",
        ]
        for k, v in sorted(d["server_errors"].items(), key=lambda kv: -kv[1])[:5]:
            lines.append(f"| `{k}` | {v} |")
    return "\n".join(lines) + "\n"


def totals(d: dict) -> dict:
    s = d["stats"]
    a = s[s["Name"] == "Aggregated"].iloc[0]
    duration = max(d["agg"]["t"].max(), 1)
    steady = steady_part(d)
    out = {
        "users": d["users"],
        "requests": int(a["Request Count"]),
        "rps": a["Request Count"] / duration,
        "rps_steady": steady["Requests/s"].mean() if not steady.empty else float("nan"),
        "p95_steady": steady["95%"].median() if not steady.empty else float("nan"),
        "avg_steady": steady["avg_interval"].mean()
        if not steady.empty
        else float("nan"),
        "p95_ramp_max": d["agg"][
            d["agg"]["t"] < (steady["t"].min() if not steady.empty else 0)
        ]["95%"].max(),
        "avg": a["Average Response Time"],
        "p50": a["Median Response Time"],
        "p95": a["95%"],
        "p99": a["99%"],
        "max": a["Max Response Time"],
        "err": a["Failure Count"] / max(a["Request Count"], 1) * 100,
        "cpu_max": float("nan"),
        "cpu_mean": float("nan"),
        "mem_max": float("nan"),
        "db_cpu_max": float("nan"),
    }
    if d["res"] is not None:
        r = d["res"]
        backend = r[r["target"].str.contains("backend|pid:|host", regex=True)]
        db = r[r["target"].str.contains("db", regex=False)]
        if not backend.empty:
            load = backend[backend["t"].between(0, d["agg"]["t"].max())]
            out["cpu_max"] = backend["cpu_percent"].max()
            out["cpu_mean"] = load["cpu_percent"].mean()
            out["mem_max"] = backend["mem_mb"].max()
        if not db.empty:
            out["db_cpu_max"] = db["cpu_percent"].max()
    return out


# ----------------------------------------------------------------------- charts
def _users_panel(ax, agg):
    ax.fill_between(
        agg["t"], agg["User Count"], step="post", color=BLUE, alpha=0.12, lw=0
    )
    ax.step(agg["t"], agg["User Count"], where="post", color=BLUE, lw=2)
    ax.set_ylabel("VUsers")
    ax.set_xlabel("час від старту тесту, с")
    ax.set_ylim(bottom=0)
    ax.set_title("Кількість віртуальних користувачів")


def chart_latency(d: dict) -> str:
    agg = d["agg"]
    fig, (ax, axu) = plt.subplots(
        2, 1, figsize=(10, 6), sharex=True, gridspec_kw={"height_ratios": [3, 1]}
    )
    ax.plot(agg["t"], agg["avg_interval"], color=BLUE, label="avg (за інтервал)")
    ax.plot(agg["t"], agg["95%"], color=ORANGE, label="p95 (вікно 10 с)")
    ax.set_ylabel("час відповіді, мс")
    ax.set_ylim(bottom=0)
    ax.set_title(f"Час відповіді — {d['run']} (усі ендпоінти)")
    ax.legend(loc="upper left")
    _users_panel(axu, agg)
    fig.tight_layout()
    name = f"{d['run']}_latency.png"
    fig.savefig(RES / name, dpi=130)
    plt.close(fig)
    return name


def chart_throughput(d: dict) -> str:
    agg = d["agg"]
    fig, (ax, axu) = plt.subplots(
        2, 1, figsize=(10, 6), sharex=True, gridspec_kw={"height_ratios": [3, 1]}
    )
    ax.plot(agg["t"], agg["Requests/s"], color=BLUE, label="запитів/с (RPS)")
    ax.plot(agg["t"], agg["Failures/s"], color=CRITICAL, label="помилок/с")
    ax.set_ylabel("запитів за секунду")
    ax.set_ylim(bottom=0)
    ax.set_title(f"Пропускна здатність і помилки — {d['run']}")
    ax.legend(loc="upper left")
    _users_panel(axu, agg)
    fig.tight_layout()
    name = f"{d['run']}_throughput.png"
    fig.savefig(RES / name, dpi=130)
    plt.close(fig)
    return name


def chart_resources(d: dict) -> str | None:
    r = d["res"]
    if r is None:
        return None
    fig, (axc, axm) = plt.subplots(2, 1, figsize=(10, 6), sharex=True)
    colors = [BLUE, ORANGE, AQUA, YELLOW]
    for i, (target, g) in enumerate(
        sorted(r.groupby("target"), key=lambda kv: "db" in kv[0])
    ):
        c = colors[i % len(colors)]
        axc.plot(g["t"], g["cpu_percent"], color=c, label=target)
        axm.plot(g["t"], g["mem_mb"], color=c, label=target)
    axc.set_title(f"CPU — {d['run']} (100% = одне ядро)")
    axc.set_ylabel("CPU, %")
    axc.set_ylim(bottom=0)
    axc.legend(loc="upper left")
    axm.set_title("Пам'ять (RSS / usage)")
    axm.set_ylabel("RAM, МБ")
    axm.set_ylim(bottom=0)
    axm.set_xlabel("час від старту тесту, с")
    axm.legend(loc="upper left")
    for ax in (axc, axm):
        ax.axvspan(0, d["agg"]["t"].max(), color=INK2, alpha=0.04, lw=0)
    fig.tight_layout()
    name = f"{d['run']}_resources.png"
    fig.savefig(RES / name, dpi=130)
    plt.close(fig)
    return name


def chart_scalability(tots: list[dict]) -> str | None:
    if len(tots) < 2:
        return None
    df = pd.DataFrame(tots).sort_values("users")
    fig, (a1, a2, a3) = plt.subplots(1, 3, figsize=(12, 3.6))
    a1.plot(df["users"], df["rps_steady"], color=BLUE, marker="o", ms=7)
    a1.set_title("RPS на плато")
    a1.set_ylabel("запитів/с")
    a2.plot(df["users"], df["p95_steady"], color=ORANGE, marker="o", ms=7)
    a2.set_title("p95 на плато (медіана)")
    a2.set_ylabel("мс")
    a3.plot(df["users"], df["err"], color=CRITICAL, marker="o", ms=7)
    a3.set_title("Помилки")
    a3.set_ylabel("%")
    for a in (a1, a2, a3):
        a.set_xlabel("VUsers")
        a.set_ylim(bottom=0)
        a.set_xticks(df["users"])
    fig.tight_layout()
    fig.savefig(RES / "scalability.png", dpi=130)
    plt.close(fig)
    return "scalability.png"


# ----------------------------------------------------------------------- analysis
def first_errors(d: dict) -> dict | None:
    agg = d["agg"]
    hit = agg[agg["err_interval"] > 1]
    if hit.empty:
        return None
    row = hit.iloc[0]
    return {"users": int(row["User Count"]), "t": row["t"], "rps": row["Requests/s"]}


def fmt(x, nd=1):
    return "—" if pd.isna(x) else f"{x:,.{nd}f}".replace(",", " ")


def bottlenecks(
    runs: list[dict], tots: list[dict], main: dict, cores: int | None
) -> list[str]:
    out = []
    s = main["stats"]
    ep = s[s["Name"] != "Aggregated"].sort_values("95%", ascending=False)
    top = ep.iloc[0]
    out.append(
        f"**Найповільніший ендпоінт ({main['run']}):** `{top['Type']} {top['Name']}` — "
        f"p95 = {fmt(top['95%'], 0)} мс, avg = {fmt(top['Average Response Time'])} мс, "
        f"max = {fmt(top['Max Response Time'], 0)} мс. Далі: "
        + ", ".join(
            f"`{r['Name']}` (p95 {fmt(r['95%'], 0)} мс)"
            for _, r in ep.iloc[1:3].iterrows()
        )
        + "."
    )
    auth = ep[ep["Name"].str.startswith("/auth")]
    other = ep[~ep["Name"].str.startswith("/auth")]
    if not auth.empty and not other.empty:
        a_avg = (auth["Average Response Time"] * auth["Request Count"]).sum() / auth[
            "Request Count"
        ].sum()
        o_med = other["Median Response Time"].median()
        if a_avg > 5 * max(o_med, 1):
            out.append(
                f"**Автентифікація домінує у часі відповіді:** середній час `/auth/*` = {fmt(a_avg, 0)} мс "
                f"проти медіани ~{fmt(o_med, 0)} мс для решти ендпоінтів. За кодом "
                "(`src/auth.py`) `hash_password`/`verify_password` — синхронний bcrypt, який "
                "викликається всередині `async def` і блокує єдиний event loop uvicorn; "
                "поки йде хешування, чекають усі інші запити — це пояснює «хвіст» p95/p99 у "
                "легких ендпоінтів (`/users/me`, `/admin/dashboard`)."
            )

    # Auth capacity: the fastest login in the lightest run ~= cost of one bcrypt verify on an idle loop.
    base_run = min(runs, key=lambda d: d["users"])
    bs = base_run["stats"]
    lg = bs[bs["Name"] == "/auth/login"]
    if not lg.empty and lg.iloc[0]["Min Response Time"] > 0:
        bc = float(lg.iloc[0]["Min Response Time"])
        cap = 1000 / bc
        need = 2 * 5  # spawn rate 5 VU/s x (register + login) per new VU
        collapsed = sorted(t["users"] for t in tots if t["err"] > 50)
        out.append(
            f"**Ємність автентифікації:** мінімальний час `/auth/login` у `{base_run['run']}` = {fmt(bc, 0)} мс — "
            f"це ціна одного bcrypt на вільному event loop, тобто сервер здатен виконати лише ~{fmt(cap)} "
            f"bcrypt-операцій/с. Розгін {need // 2} VU/с потребує ~{need} операцій/с (register + login), тож черга "
            "росте швидше, ніж обробляється, доки ramp-up не завершиться."
            + (
                f" При {', '.join(map(str, collapsed))} VU ramp-up триває ≥ {min(collapsed) // 5} с, запити "
                "чекають довше за таймаут клієнта (60 с), сервер продовжує обробляти вже покинуті запити, а "
                "VUsers із невдалою реєстрацією повторюють її — система переходить у стан колапсу "
                "(майже 100% помилок, RPS падає до ~2)."
                if collapsed
                else ""
            )
        )

    for t in sorted(tots, key=lambda t: t["users"]):
        if not pd.isna(t["p95_ramp_max"]) and t["p95_ramp_max"] > 3 * max(
            t["p95_steady"], 1
        ):
            out.append(
                f"**Сплеск під час ramp-up ({t['users']} VU):** поки VUsers реєструються й логіняться "
                f"(on_start), p95 сягає {fmt(t['p95_ramp_max'], 0)} мс проти медіани {fmt(t['p95_steady'], 0)} мс "
                "на плато — масові реєстрації (bcrypt) перевантажують сервер."
            )
    df0 = pd.DataFrame(tots).sort_values("users")
    if len(df0) >= 2:
        b = df0.iloc[0]
        knee = df0[df0["p95_steady"] > 3 * max(b["p95_steady"], 1)]
        if not knee.empty:
            r = knee.iloc[0]
            out.append(
                f"**Перелом латентності:** p95 на плато зростає з {fmt(b['p95_steady'], 0)} мс "
                f"({int(b['users'])} VU) до {fmt(r['p95_steady'], 0)} мс при {int(r['users'])} VU "
                f"(~{fmt(r['rps_steady'])} RPS) — більше ніж утричі."
            )
        else:
            out.append(
                f"**Перелом латентності:** у діапазоні {int(df0['users'].min())}–{int(df0['users'].max())} VU "
                "p95 на плато не зріс більш ніж утричі відносно базового прогону."
            )
    df = pd.DataFrame(tots).sort_values("users")
    if len(df) >= 2:
        base = df.iloc[0]
        per_user = base["rps_steady"] / max(base["users"], 1)
        lines = []
        for _, r in df.iterrows():
            eff = (
                r["rps_steady"] / (per_user * r["users"]) * 100
                if per_user
                else float("nan")
            )
            lines.append(
                f"{int(r['users'])} VU → {fmt(r['rps_steady'])} RPS ({fmt(eff, 0)}% від лінійного)"
            )
        out.append("**Масштабування пропускної здатності:** " + "; ".join(lines) + ".")
        sat = df[(df["rps_steady"] / (per_user * df["users"])) < 0.8]
        if not sat.empty:
            r = sat.iloc[0]
            out.append(
                f"**Точка насичення:** починаючи з ~{int(r['users'])} VUsers RPS росте менш ніж на 80% "
                f"від лінійного — сервер більше не встигає за навантаженням (RPS ≈ {fmt(r['rps_steady'])}, "
                f"p95 = {fmt(r['p95'], 0)} мс)."
            )
    err_runs = [t for t in tots if t["err"] > 1]
    if err_runs:
        r = min(err_runs, key=lambda t: t["users"])
        d = next(x for x in runs if x["users"] == r["users"])
        fe = first_errors(d)
        extra = (
            f", перші помилки (>1% за інтервал) на {fmt(fe['t'], 0)} с при {fe['users']} VUsers"
            if fe
            else ""
        )
        out.append(
            f"**Помилки:** вперше перевищують 1% при {r['users']} VUsers "
            f"(загалом {fmt(r['err'], 2)}%{extra})."
        )
        for t in sorted(err_runs, key=lambda t: t["users"]):
            dd = next(x for x in runs if x["users"] == t["users"])
            fl = dd["failures"]
            if fl.empty:
                continue
            by_ep = fl.groupby("Name")["Occurrences"].sum().sort_values(ascending=False)
            pool = sum(v for k, v in dd["server_errors"].items() if "QueuePool" in k)
            msg = f"{t['users']} VU — помилки за ендпоінтами: " + ", ".join(
                f"`{k}` {v}" for k, v in by_ep.items()
            )
            if pool:
                msg += (
                    f"; у лозі backend {pool}× `sqlalchemy TimeoutError: QueuePool limit of size 5 "
                    "overflow 10 reached` — вичерпано пул з'єднань до БД (5+10, очікування 30 с)"
                )
            out.append(msg + ".")
    else:
        out.append(
            "**Помилки:** в жодному прогоні частка помилок не перевищила 1% "
            f"(максимум {fmt(max(t['err'] for t in tots), 2)}%)."
        )
    cpu = [t for t in tots if not pd.isna(t["cpu_max"])]
    if cpu:
        cpu_s = "; ".join(
            f"{t['users']} VU: max {fmt(t['cpu_max'], 0)}%, avg {fmt(t['cpu_mean'], 0)}%, "
            f"RAM max {fmt(t['mem_max'], 0)} МБ"
            for t in sorted(cpu, key=lambda t: t["users"])
        )
        cap = f" (доступно {cores} ядер → стеля {cores * 100}%)" if cores else ""
        out.append(
            f"**CPU/RAM backend-контейнера{cap}:** {cpu_s}. "
            + "CPU БД: "
            + ", ".join(
                f"{t['users']} VU {fmt(t['db_cpu_max'], 0)}%"
                for t in sorted(cpu, key=lambda t: t["users"])
            )
            + "."
        )
        hottest = max(cpu, key=lambda t: t["cpu_mean"])
        if hottest["cpu_mean"] >= 85:
            out.append(
                f"**Насичення CPU:** при {hottest['users']} VUsers середнє завантаження backend "
                f"≈ {fmt(hottest['cpu_mean'], 0)}% — тобто приблизно одне повністю зайняте ядро. "
                "Event loop uvicorn однопотоковий (1 воркер), тож вузьке місце — одне ядро, "
                "навіть якщо загальна кількість ядер більша."
            )
    return out


# ----------------------------------------------------------------------- env
def environment() -> dict:
    env = {
        "os": f"{platform.system()} {platform.release()}",
        "python": platform.python_version(),
    }
    try:
        import psutil

        env["host_cpu"] = psutil.cpu_count()
        env["host_ram"] = f"{psutil.virtual_memory().total / 1024**3:.1f} ГБ"
    except Exception:  # noqa: BLE001
        pass
    try:
        out = subprocess.run(
            [
                "docker",
                "info",
                "--format",
                "{{.NCPU}}|{{.MemTotal}}|{{.ServerVersion}}",
            ],
            capture_output=True,
            text=True,
            timeout=10,
        ).stdout.strip()
        ncpu, mem, ver = out.split("|")
        env["docker"] = f"Docker {ver}, VM: {ncpu} CPU, {int(mem) / 1024**3:.2f} ГБ RAM"
        env["docker_cpus"] = int(ncpu)
    except Exception:  # noqa: BLE001
        env["docker"] = "⟪вкажіть параметри Docker⟫"
    try:
        import locust

        env["locust"] = locust.__version__
    except Exception:  # noqa: BLE001
        env["locust"] = "?"
    return env


# ----------------------------------------------------------------------- report
def write_report(runs, main_name, out_path: Path):
    env = environment()
    by = {d["run"]: d for d in runs}
    main = by.get(main_name) or (
        max(runs, key=lambda d: d["users"] == 50) if runs else None
    )
    tots = [totals(d) for d in runs]
    charts = {}
    for d in runs:
        charts[d["run"]] = (chart_latency(d), chart_throughput(d), chart_resources(d))
        summary_table(d).to_csv(RES / f"summary_{d['run']}.csv", index=False)
    scal = chart_scalability(tots)

    md = []
    w = md.append
    w("# Лабораторна робота №4. Початкове навантажувальне тестування\n")
    w(
        f"*Згенеровано `make_report.py` {datetime.now():%Y-%m-%d %H:%M}. Усі числа нижче взято з CSV у `results/`.*\n"
    )
    w("## 1. Мета\n")
    w(
        "Створити та виконати базові сценарії навантажувального тестування API "
        "«Multidimensional Portal Generator» (розрахунок викривлених траєкторій порталів), "
        "зібрати метрики продуктивності (RPS, латентність, частка помилок, CPU/RAM сервера) "
        "і визначити перші вузькі місця системи.\n"
    )
    w("## 2. Інструмент та обґрунтування\n")
    w(
        f"**Locust {env['locust']}** (Python). Сценарії пишуться звичайним Python-кодом — тією ж мовою, що й "
        "застосунок, тож легко генерувати реалістичні дані, працювати з JWT і перевіряти тіло відповіді. "
        "JMeter вимагає GUI/XML-планів і важчий у підтримці; k6 (JavaScript) і Gatling (Scala/Java) "
        "швидші як генератори, але додають другу мову в проєкт. Для MVP-навантаження в сотні VUsers "
        "продуктивності Locust (gevent) достатньо, а headless-режим з `--csv`/`--html` дає все потрібне для звіту.\n"
    )
    w("## 3. Тестове середовище\n")
    w("| Параметр | Значення |\n|---|---|")
    w("| Система | FastAPI + SQLAlchemy (async) + PostgreSQL 16, JWT (HS256), bcrypt |")
    w(
        "| Запуск | `docker compose` (сервіси `db`, `backend`, `client`); backend = `uvicorn src.main:app` (1 воркер) + `ProcessPoolExecutor` для обчислень |"
    )
    w("| URL | `http://localhost:8000` (порт 8000 проброшено з контейнера `backend`) |")
    w(
        f"| Хост | {env['os']}, {env.get('host_cpu', '?')} CPU, {env.get('host_ram', '?')} RAM |"
    )
    w(f"| Docker | {env['docker']} |")
    w(
        f"| Генератор навантаження | Locust {env['locust']}, Python {env['python']}, на тому ж хості (один процес) |"
    )
    w(
        "| Моніторинг | `monitor.py --mode docker` (`docker stats --no-stream`, інтервал ≈ 2 с) |\n"
    )
    w(
        "> Генератор і система працюють на одній машині, тому частина CPU хоста витрачається на Locust — "
        "абсолютні числа є нижньою оцінкою можливостей сервера.\n"
    )
    w("## 4. Профіль навантаження\n")
    w("Детальний план — [`docs/test_plan.md`](docs/test_plan.md).\n")
    w(
        "| Прогін | VUsers | Spawn rate | Тривалість | wait_time |\n|---|---:|---:|---:|---|"
    )
    if runs:
        for d in sorted(runs, key=lambda x: x["users"]):
            dur = d["agg"]["t"].max()
            w(
                f"| `{d['run']}`{' (основний)' if main and d['run'] == main['run'] else ''} | {d['users']} | 5/с | {dur / 60:.1f} хв | between(1, 3) с |"
            )
    else:
        w(f"| {PLACEHOLDER} | | | | |")
    w("")
    w("## 5. Сценарій\n")
    w(
        "Кожен віртуальний користувач у `on_start` реєструє власний акаунт (`POST /auth/register`) "
        "і логіниться (`POST /auth/login`), зберігаючи JWT. Далі виконує зважені задачі з паузою 1–3 с:\n"
    )
    w("| Задача | Запит | Вага | Що перевіряється |\n|---|---|---:|---|")
    w("| Перегляд профілю | `GET /users/me` | 6 | 200 і `id` збігається з власним |")
    w(
        "| Розрахунок траєкторії | `POST /simulations/run [geodesic]` | 4 | 201, кількість точок = max(8, complexity·8)+1, `user_id` свій |"
    )
    w(
        "| Трансформація координат | `POST /simulations/run [coordinates]` | 1 | 201, довжина масиву збігається |"
    )
    w("| Оновлення профілю | `PUT /users/[id]` | 1 | 200, новий email збережено |")
    w("| Повторний логін | `POST /auth/login` | 1 | 200 і наявний `access_token` |")
    w(
        "| Перевірка RBAC | `GET /admin/dashboard (expect 403)` | 1 | звичайний користувач отримує 403 |\n"
    )
    w(
        "Дані випадкові: `complexity` 1–10 (70%), 11–50 (25%), 51–100 (5%); `dimension_id` 1–1000; "
        "`initial_speed` 0–5000; `object_mass` 0.1–10 000; масиви координат 3–60 елементів. "
        "Відповіді валідуються через `catch_response`, динамічні URL згруповані через `name=`.\n"
    )

    w("## 6. Результати\n")
    if not runs:
        w(PLACEHOLDER + "\n")
    else:
        w("### 6.1 Зведення по прогонах\n")
        w(
            "| VUsers | Запитів | RPS (середнє) | RPS (плато) | Avg, мс | Median, мс | p95, мс | p99, мс | Max, мс | p95 плато, мс | Помилки, % | CPU backend max / avg, % | RAM backend max, МБ |"
        )
        w("|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
        for t in sorted(tots, key=lambda t: t["users"]):
            w(
                f"| {t['users']} | {t['requests']} | {fmt(t['rps'])} | {fmt(t['rps_steady'])} | {fmt(t['avg'])} | "
                f"{fmt(t['p50'], 0)} | {fmt(t['p95'], 0)} | {fmt(t['p99'], 0)} | {fmt(t['max'], 0)} | {fmt(t['p95_steady'], 0)} | "
                f"{fmt(t['err'], 2)} | {fmt(t['cpu_max'], 0)} / {fmt(t['cpu_mean'], 0)} | {fmt(t['mem_max'], 0)} |"
            )
        w("")
        if scal:
            w(f"![Масштабування](results/{scal})\n")
        for d in sorted(runs, key=lambda x: (x is not main, x["users"])):
            lat, thr, res = charts[d["run"]]
            w(
                f"### 6.{2 if d is main else 3} Прогін `{d['run']}`{' — основний' if d is main else ''}\n"
            )
            w(
                "Метрики по ендпоінтах (Min/Max — точні, перцентилі — апроксимація Locust):\n"
            )
            w(to_md(summary_table(d)) + "\n")
            w(f"![Час відповіді](results/{lat})\n")
            w(f"![Пропускна здатність](results/{thr})\n")
            w(
                f"![CPU і RAM](results/{res})\n"
                if res
                else "⟪немає файлу ресурсів — запустіть `monitor.py` разом із тестом⟫\n"
            )
            w("Помилки:\n")
            w(failures_md(d))
            w(
                f"HTML-звіт Locust: [`results/{d['run']}.html`](results/{d['run']}.html)\n"
            )

    w("## 7. Виявлені вузькі місця\n")
    if runs and main:
        for b in bottlenecks(runs, tots, main, env.get("docker_cpus")):
            w(f"- {b}")
        w("")
    else:
        w(PLACEHOLDER + "\n")

    w("## 8. Висновки та наступні кроки\n")
    w("<!-- CONCLUSIONS -->")
    if runs:
        main_t = totals(main)
        w(
            f"- За базового профілю ({main['users']} VUsers) система обробила {main_t['requests']} запитів "
            f"із середнім RPS {fmt(main_t['rps'])}, p95 = {fmt(main_t['p95'], 0)} мс, помилок {fmt(main_t['err'], 2)}%."
        )
    else:
        w(f"- {PLACEHOLDER}")
    w("- Наступні кроки:")
    w(
        "  1. Винести bcrypt з event loop (`await run_in_threadpool(hash_password, ...)` або зробити "
        "ендпоінти автентифікації синхронними `def`) і повторити прогін — очікується зниження p95 легких ендпоінтів."
    )
    w(
        "  2. Запускати uvicorn/gunicorn з кількома воркерами (`--workers N`) і порівняти масштабування."
    )
    w(
        "  3. Зменшити cost-фактор bcrypt для тестового середовища або кешувати користувача з JWT, "
        "щоб не робити `SELECT` на кожен запит."
    )
    w(
        "  4. Додати ендпоінти читання симуляцій (`GET /simulations`, `GET /simulations/{id}`) з пагінацією "
        "і включити їх у сценарій — зараз API не має read-операцій над симуляціями."
    )
    w(
        "  5. Винести генератор навантаження на окрему машину, додати stress/soak-тести (30–60 хв) "
        "і моніторинг пулу з'єднань PostgreSQL."
    )
    out_path.write_text("\n".join(md) + "\n", encoding="utf-8")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--runs", nargs="*", help="run names (default: all results/run_*_stats.csv)"
    )
    ap.add_argument("--main", default="run_50u")
    ap.add_argument("--out", default=str(HERE / "report.md"))
    args = ap.parse_args()
    names = args.runs or sorted(
        {p.name[: -len("_stats.csv")] for p in RES.glob("run_*_stats.csv")},
        key=users_of,
    )
    runs = [load_run(n) for n in names if (RES / f"{n}_stats_history.csv").exists()]
    write_report(runs, args.main, Path(args.out))
    print(
        f"report: {args.out}; runs: {[d['run'] for d in runs] or 'none (placeholders)'}"
    )


if __name__ == "__main__":
    main()
