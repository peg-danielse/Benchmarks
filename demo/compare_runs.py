#!/usr/bin/env python3
"""Compare run-demo.sh runs (e.g. saturate vs gnn): per instance users, rate, p95 and
cores over time, plus a table of latency, cores, core-seconds and errors per run.
usage: compare_runs.py OUT.png LABEL=RUN_DIR LABEL=RUN_DIR ..."""
import csv, json, os, statistics, sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

args = sys.argv[1:]
title = None
if args[:1] == ["--title"]:
    title, args = args[1], args[2:]
out, runs = args[0], [a.split("=", 1) for a in args[1:]]

def load(run):
    apps = {}
    for app in sorted(os.listdir(run)):
        path = os.path.join(run, app, "loadgen.windows.csv")
        if not os.path.isfile(path):
            continue
        wins = {}
        for r in csv.DictReader(open(path)):
            w = wins.setdefault(int(r["window"]), dict(ms=int(r["unix_ms"]), users=0, rate=0, p95=0.0, p95w=0.0, avgw=0.0,
                                                       err=0, cores=0, csum=0))
            rate = int(r["service_rate"])
            w["users"] = max(w["users"], int(r["target_users"])); w["rate"] += rate
            w["p95"] = max(w["p95"], float(r["p95_us"]) / 1000); w["p95w"] += float(r["p95_us"]) / 1000 * rate
            w["avgw"] += float(r["avg_us"]) / 1000 * rate; w["err"] += int(r["errors"])
            w["cores"], w["csum"] = int(r["app_cores"]), int(r["core_sum"])
            w["clients"] = min(w.get("clients", 10**9), int(r["clients"]))
        ws = [wins[k] for k in sorted(wins)]
        for w in ws:
            w["p95w"] = w["p95w"] / w["rate"] if w["rate"] else 0
        apps[app] = ws
    t0 = min(ws[0]["ms"] for ws in apps.values())
    for ws in apps.values():
        for i, w in enumerate(ws):
            w["t"] = (w["ms"] - t0) / 1000
            nxt = ws[i + 1]["ms"] if i + 1 < len(ws) else None
            w["dt"] = (nxt - w["ms"]) / 1000 if nxt else 1.0
    return apps

def corr(a, b):
    if len(a) < 3 or statistics.pstdev(a) == 0 or statistics.pstdev(b) == 0:
        return float("nan")
    ma, mb = statistics.fmean(a), statistics.fmean(b)
    return sum((x - ma) * (y - mb) for x, y in zip(a, b)) / (len(a) * statistics.pstdev(a) * statistics.pstdev(b))

def grid(ws, key, step=5.0):  # mean of key per 5 s bucket since load start
    b = {}
    for w in ws:
        b.setdefault(int(w["t"] // step), []).append(w[key])
    return {k: statistics.fmean(v) for k, v in b.items()}

def smooth(v, n=5):
    return [statistics.fmean(v[max(0, i - n + 1):i + 1]) for i in range(len(v))]

data = {label: load(run) for label, run in runs}
insts = sorted({a for d in data.values() for a in d})
stats = []
for label, apps in data.items():
    for app in insts:
        ws = apps.get(app, [])
        if not ws:
            continue
        reqs = sum(w["rate"] * w["dt"] for w in ws)
        stats.append(dict(run=label, app=app, windows=len(ws), seconds=round(sum(w["dt"] for w in ws), 1),
                          rate_mean=round(statistics.fmean(w["rate"] for w in ws)),
                          lat_mean_ms=round(sum(w["avgw"] * w["dt"] for w in ws) / reqs, 2) if reqs else None,
                          p95_wmean_ms=round(sum(w["p95w"] * w["rate"] * w["dt"] for w in ws) / reqs, 2) if reqs else None,
                          p95_worst_median_ms=round(statistics.median(w["p95"] for w in ws), 2),
                          cores_mean=round(statistics.fmean(w["cores"] for w in ws), 2),
                          core_sum_mean=round(statistics.fmean(w["csum"] for w in ws), 2),
                          core_seconds=round(sum(w["cores"] * w["dt"] for w in ws)),
                          errors=sum(w["err"] for w in ws),
                          corr_users_cores=round(corr([w["users"] for w in ws], [w["cores"] for w in ws]), 3),
                          short_clients=sum(1 for w in ws if w.get("clients", w["users"]) < w["users"])))
cross = {}
for label, apps in data.items():
    if len(insts) == 2 and all(a in apps for a in insts):
        ga, gb = grid(apps[insts[0]], "cores"), grid(apps[insts[1]], "cores")
        keys = sorted(set(ga) & set(gb))
        cross[label] = round(corr([ga[k] for k in keys], [gb[k] for k in keys]), 3)
colors = {}
palette = ["tab:blue", "tab:red", "tab:green", "tab:purple"]
for i, (label, _) in enumerate(runs):
    colors[label] = palette[i % len(palette)]
rows = [("users", "target users", False), ("rate", "throughput (req/s, 5 s mean)", False),
        ("p95", "worst-route p95 (ms, 5 s mean)", True), ("cores", "app cores (distinct CPUs)", False)]
fig, axes = plt.subplots(len(rows) + 1, len(insts), figsize=(7 * len(insts), 15),
                         gridspec_kw=dict(height_ratios=[1] * len(rows) + [0.8]), squeeze=False)
for c, app in enumerate(insts):
    for r, (key, title, log) in enumerate(rows):
        ax = axes[r][c]
        for label, apps in data.items():
            ws = apps.get(app, [])
            y = [w[key] for w in ws]
            ax.plot([w["t"] for w in ws], y if key in ("users", "cores") else smooth(y), color=colors[label], label=label, lw=1.2)
        ax.set_title(f"{app}: {title}", fontsize=10)
        if log:
            ax.set_yscale("log")
        ax.grid(alpha=0.3)
        if r == 0:
            ax.legend(fontsize=9)
        if r == len(rows) - 1:
            ax.set_xlabel("seconds since load start")
    tab = axes[len(rows)][c]
    tab.axis("off")
    cols = ["run", "lat mean ms", "p95 wmean ms", "p95 worst med", "cores mean", "core-s", "rate mean", "errors", "corr users~cores"]
    cell = [[s["run"], s["lat_mean_ms"], s["p95_wmean_ms"], s["p95_worst_median_ms"], s["cores_mean"], s["core_seconds"],
             s["rate_mean"], s["errors"], s["corr_users_cores"]] for s in stats if s["app"] == app]
    t = tab.table(cellText=cell, colLabels=cols, loc="center")
    t.auto_set_font_size(False); t.set_fontsize(9); t.scale(1, 1.6)
fig.text(0.5, 0.01, "corr(cores %s, cores %s) on a 5 s grid: " % tuple(insts[:2]) + ", ".join("%s %.3f" % kv for kv in cross.items())
         + "   (negative = Mercury shifts cores between the instances)", ha="center", fontsize=10) if cross else None
if title is None:  # sine range after the ramp-in (users below the minimum only occur while ramping)
    ws_all = [w for d in data.values() for ws in d.values() for w in ws]
    hi = max(w["users"] for w in ws_all)
    lo = min(w["users"] for w in ws_all if w["t"] > 60)
    title = "Two hotels on one Mercury, %d-%d users sine" % (lo, hi)
fig.suptitle(title + ": " + " vs ".join(l for l, _ in runs))
fig.tight_layout()
fig.savefig(out, dpi=110)
json.dump({"stats": stats, "cross_cores_corr": cross}, open(os.path.splitext(out)[0] + ".json", "w"), indent=2)
w = max(len(s["run"]) for s in stats)
lines = ["%-8s %-*s %8s %9s %9s %9s %8s %8s %9s %6s %9s %6s" % ("app", w, "run", "lat_ms", "p95w_ms", "p95worst", "cores", "csum", "core_s", "rate", "errors", "corr_u~c", "short")]
for s in stats:
    lines.append("%-8s %-*s %8.2f %9.2f %9.2f %9.2f %8.2f %8d %9d %6d %9.3f %6d" % (s["app"], w, s["run"], s["lat_mean_ms"], s["p95_wmean_ms"],
                 s["p95_worst_median_ms"], s["cores_mean"], s["core_sum_mean"], s["core_seconds"], s["rate_mean"], s["errors"],
                 s["corr_users_cores"], s["short_clients"]))
for k, v in cross.items():
    lines.append("cross-instance corr(cores %s, cores %s) %s: %.3f" % (insts[0], insts[1], k, v))
open(os.path.splitext(out)[0] + ".txt", "w").write("\n".join(lines) + "\n")
print("\n".join(lines)); print("plot", out)
