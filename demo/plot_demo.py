#!/usr/bin/env python3
"""Summary and plot of a run-demo.sh run directory.

Reads <run>/<app>/loadgen.windows.csv (one row per route per window, written by
operate/goperate with -load sine) and writes <run>/summary.txt, summary.json
and demo.png: target users, throughput, p95 and cores per app over time."""
import csv, json, os, statistics, sys

run = sys.argv[1] if len(sys.argv) > 1 else "."
apps = {}
for app in sorted(os.listdir(run)):
    path = os.path.join(run, app, "loadgen.windows.csv")
    if not os.path.isfile(path):
        continue
    wins = {}
    with open(path) as f:
        for r in csv.DictReader(f):
            w = wins.setdefault(int(r["window"]), {"ms": int(r["unix_ms"]), "users": 0, "rate": 0, "p95": 0.0,
                                                  "wsum": 0.0, "errors": 0, "cores": 0, "core_sum": 0, "gen": 0})
            rate = int(r["service_rate"]); p95 = float(r["p95_us"]) / 1000
            w["users"] = max(w["users"], int(r["target_users"])); w["rate"] += rate
            w["p95"] = max(w["p95"], p95); w["wsum"] += p95 * rate; w["errors"] += int(r["errors"])
            w["cores"], w["core_sum"], w["gen"] = int(r["app_cores"]), int(r["core_sum"]), int(r["gen_cores"])
    if wins:
        apps[app] = [wins[k] for k in sorted(wins)]
if not apps:
    sys.exit("no <app>/loadgen.windows.csv under %s" % run)
t0 = min(ws[0]["ms"] for ws in apps.values())

def corr(a, b):
    if len(a) < 3 or statistics.pstdev(a) == 0 or statistics.pstdev(b) == 0:
        return float("nan")
    ma, mb = statistics.fmean(a), statistics.fmean(b)
    return sum((x - ma) * (y - mb) for x, y in zip(a, b)) / (len(a) * statistics.pstdev(a) * statistics.pstdev(b))

def q(v, p):
    v = sorted(v); return v[min(len(v) - 1, int(p * len(v)))] if v else float("nan")

summary, lines = {}, ["Mercury demo summary: %s" % os.path.abspath(run), ""]
for app, ws in apps.items():
    users = [w["users"] for w in ws]; rate = [w["rate"] for w in ws]; cores = [w["cores"] for w in ws]
    p95 = [w["p95"] for w in ws]; errors = sum(w["errors"] for w in ws)
    s = {"windows": len(ws), "seconds": round((ws[-1]["ms"] - ws[0]["ms"]) / 1000, 1),
         "users_min": min(users), "users_max": max(users), "rate_mean": round(statistics.fmean(rate)),
         "rate_max": max(rate), "p95_ms_median": round(q(p95, 0.5), 2), "p95_ms_p90": round(q(p95, 0.9), 2),
         "cores_min": min(cores), "cores_mean": round(statistics.fmean(cores), 1), "cores_max": max(cores),
         "core_sum_mean": round(statistics.fmean([w["core_sum"] for w in ws]), 1), "errors": errors,
         "corr_users_rate": round(corr(users, rate), 3), "corr_users_cores": round(corr(users, cores), 3)}
    summary[app] = s
    lines.append("%-7s %d windows over %.0f s: users %d-%d, rate mean %d/s (max %d), p95 (worst route) median %.2f ms p90 %.2f ms,"
                 % (app, s["windows"], s["seconds"], s["users_min"], s["users_max"], s["rate_mean"], s["rate_max"],
                    s["p95_ms_median"], s["p95_ms_p90"]))
    lines.append("        cores %d-%d (mean %.1f, cpuset sum mean %.1f), errors %d, corr(users,rate) %.2f, corr(users,cores) %.2f"
                 % (s["cores_min"], s["cores_max"], s["cores_mean"], s["core_sum_mean"], errors, s["corr_users_rate"], s["corr_users_cores"]))
if len(apps) == 2:
    (a, wa), (b, wb) = list(apps.items())
    # cores of both apps on a common 5 s grid
    def grid(ws):
        return {int((w["ms"] - t0) / 5000): w["cores"] for w in ws}
    ga, gb = grid(wa), grid(wb); keys = sorted(set(ga) & set(gb))
    if keys:
        c = corr([ga[k] for k in keys], [gb[k] for k in keys])
        summary["cross"] = {"corr_cores_%s_%s" % (a, b): round(c, 3), "overlap_s": len(keys) * 5}
        lines += ["", "cross-app: corr(cores %s, cores %s) %.2f over %d s of overlap (negative = Mercury shifts cores between them)"
                  % (a, b, c, len(keys) * 5)]
open(os.path.join(run, "summary.txt"), "w").write("\n".join(lines) + "\n")
json.dump(summary, open(os.path.join(run, "summary.json"), "w"), indent=2)
print("\n".join(lines))

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
fig, ax = plt.subplots(4, 1, figsize=(11, 10), sharex=True)
for app, ws in apps.items():
    t = [(w["ms"] - t0) / 1000 for w in ws]
    ax[0].plot(t, [w["users"] for w in ws], label=app)
    ax[1].plot(t, [w["rate"] for w in ws], label=app)
    ax[2].plot(t, [w["p95"] for w in ws], label=app + " worst route")
    ax[2].plot(t, [w["wsum"] / w["rate"] if w["rate"] else 0 for w in ws], ls=":", label=app + " rate-weighted")
    ax[3].plot(t, [w["cores"] for w in ws], label=app + " cores (distinct CPUs)")
    ax[3].plot(t, [w["core_sum"] for w in ws], ls=":", label=app + " cpuset sum")
for a, lab in zip(ax, ["target users per route", "throughput (req/s, all routes)", "p95 (ms)", "cores allocated"]):
    a.set_ylabel(lab); a.grid(alpha=0.3); a.legend(fontsize=8, loc="upper right")
ax[2].set_yscale("log")
ax[3].set_xlabel("seconds since first window")
fig.suptitle("Mercury demo: %s" % os.path.basename(os.path.abspath(run)))
fig.tight_layout()
fig.savefig(os.path.join(run, "demo.png"), dpi=110)
print("plot", os.path.join(run, "demo.png"))
