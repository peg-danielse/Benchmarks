#!/usr/bin/env python3
"""User-space stand-in for Mercury's worker API, for testing the operators on a
machine without root. Implements GET /ping and /map, POST /start (exec with
only the given env plus PATH/HOME, like Mercury), /kill, /cpus and /scale.

Usage: fake_mercury.py PORT [CWD]

Optional environment:
  FAKE_MERCURY_POOL    daemon CPU pool, e.g. 1-27. /start refuses a cpu outside
                       it (like Mercury) and the scale loop grows into it.
  FAKE_MERCURY_CGROUP  directory standing in for /sys/fs/cgroup/mercury: one
                       subdirectory per daemon with cpuset.cpus and cpu.stat
                       (usage_usec). Point the operators' MERCURY_CGROUP_ROOT
                       here. Default /tmp/fake-mercury/cgroup.
  FAKE_MERCURY_LOGS    daemon stdout/stderr logs (default /tmp/fake-mercury).
  FAKE_MERCURY_PIN     1 (default): apply each cpuset with sched_setaffinity to
                       every thread of the daemon's process tree (no root needed
                       for your own processes). 0: bookkeeping only.
  FAKE_MERCURY_TICK_MS scale loop period (default 200).

The scale loop is a crude saturate: a daemon above 80% busy on its cores, or
whose threads waited runnable for more than 25% of its cores' time, gets
the lowest pool CPU it does not have yet (up to max); below 30% it gives back
its highest non-home CPU (down to min) when it also barely waits. It is not Mercury's policy and has no
gnn; it only makes cpusets move so the demo plumbing can be tested."""
import json, os, signal, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

def parse_list(spec):
    out = []
    for part in str(spec).split(","):
        part = part.strip()
        if not part:
            continue
        a, _, b = part.partition("-")
        out.extend(range(int(a), int(b or a) + 1))
    return sorted(set(out))

def fmt_list(cpus):
    cpus = sorted(set(cpus)); out = []; i = 0
    while i < len(cpus):
        j = i
        while j + 1 < len(cpus) and cpus[j + 1] == cpus[j] + 1:
            j += 1
        out.append(str(cpus[i]) if i == j else "%d-%d" % (cpus[i], cpus[j])); i = j + 1
    return ",".join(out)

pool = parse_list(os.environ.get("FAKE_MERCURY_POOL", ""))
cgroot = os.environ.get("FAKE_MERCURY_CGROUP", "/tmp/fake-mercury/cgroup")
logdir = os.environ.get("FAKE_MERCURY_LOGS", "/tmp/fake-mercury")
pin = os.environ.get("FAKE_MERCURY_PIN", "1") == "1"
tick = int(os.environ.get("FAKE_MERCURY_TICK_MS", "200")) / 1000.0
cwd = sys.argv[2] if len(sys.argv) > 2 else os.getcwd()
os.makedirs(logdir, exist_ok=True); os.makedirs(cgroot, exist_ok=True)
CLK = os.sysconf("SC_CLK_TCK")

lock = threading.Lock()
daemons = {}  # id -> dict(proc, cpus, home, scale, min, max, usage_us, last_ticks)

def tree(pid):
    pids, todo = [], [pid]
    while todo:
        p = todo.pop(); pids.append(p)
        try:
            for t in os.listdir("/proc/%d/task" % p):
                with open("/proc/%d/task/%s/children" % (p, t)) as f:
                    todo.extend(int(c) for c in f.read().split())
        except OSError:
            pass
    return pids

def tree_ticks(pid):
    total = 0
    for p in tree(pid):
        try:
            with open("/proc/%d/stat" % p) as f:
                fields = f.read().rsplit(")", 1)[1].split()
            total += int(fields[11]) + int(fields[12]) + int(fields[13]) + int(fields[14])  # utime stime cutime cstime
        except (OSError, IndexError, ValueError):
            pass
    return total

def tree_wait_ns(pid):
    total = 0
    for p in tree(pid):
        try:
            for t in os.listdir("/proc/%d/task" % p):
                with open("/proc/%d/task/%s/schedstat" % (p, t)) as f:
                    total += int(f.read().split()[1])  # time spent runnable but waiting
        except (OSError, IndexError, ValueError):
            pass
    return total

def apply(d_id, d):
    d["cpus"] = sorted(set(d["cpus"]))
    path = os.path.join(cgroot, d_id)
    os.makedirs(path, exist_ok=True)
    with open(os.path.join(path, "cpuset.cpus"), "w") as f:
        f.write(fmt_list(d["cpus"]) + "\n")
    if not pin:
        return
    for p in tree(d["proc"].pid):
        try:
            for t in os.listdir("/proc/%d/task" % p):
                try: os.sched_setaffinity(int(t), d["cpus"])
                except OSError: pass
        except OSError:
            pass

def write_stat(d_id, d):
    try:
        with open(os.path.join(cgroot, d_id, "cpu.stat"), "w") as f:
            f.write("usage_usec %d\nuser_usec 0\nsystem_usec 0\n" % d["usage_us"])
    except OSError:
        pass

def scale_loop():
    while True:
        time.sleep(tick)
        with lock:
            for d_id, d in list(daemons.items()):
                if d["proc"].poll() is not None:
                    continue
                ticks = tree_ticks(d["proc"].pid)
                delta = max(0, ticks - d["last_ticks"]); d["last_ticks"] = ticks
                d["usage_us"] += int(delta * 1e6 / CLK); write_stat(d_id, d)
                if not d["scale"] or not pool:
                    continue
                wait = tree_wait_ns(d["proc"].pid); dw = max(0, wait - d.get("last_wait", wait)); d["last_wait"] = wait
                util = delta / CLK / tick / max(1, len(d["cpus"]))
                waiting = dw / 1e9 / tick / max(1, len(d["cpus"]))
                if (util > 0.8 or waiting > 0.25) and len(d["cpus"]) < d["max"]:
                    free = [c for c in pool if c not in d["cpus"]]
                    if free:
                        d["cpus"].append(free[0]); apply(d_id, d)
                elif util < 0.3 and waiting < 0.05 and len(d["cpus"]) > d["min"]:
                    extra = [c for c in d["cpus"] if c != d["home"]]
                    if extra:
                        d["cpus"].remove(max(extra)); apply(d_id, d)

prev_stat = {}
def cpu_loads():
    loads = {}
    with open("/proc/stat") as f:
        for line in f:
            if line.startswith("cpu") and line[3].isdigit():
                v = [int(x) for x in line.split()[1:]]
                cpu = int(line.split()[0][3:]); idle = v[3] + v[4]; total = sum(v[:8])
                p = prev_stat.get(cpu, (idle, total)); prev_stat[cpu] = (idle, total)
                dt = total - p[1]
                loads[cpu] = 0.0 if dt <= 0 else 1.0 - (idle - p[0]) / dt
    return loads

def map_json():
    loads = cpu_loads()
    with lock:
        ds = [{"daemon_id": k, "pid": d["proc"].pid, "cpus": d["cpus"]} for k, d in daemons.items() if d["proc"].poll() is None]
    cpus = pool or sorted(loads)
    groups = [{"level": "machine", "name": "machine", "parent": "", "children": ["cpu%d" % c for c in cpus],
               "linux_cpus": cpus, "load": sum(loads.get(c, 0) for c in cpus) / max(1, len(cpus)), "samples": 0,
               "daemons": [d["daemon_id"] for d in ds]}]
    for c in cpus:
        groups.append({"level": "core", "name": "cpu%d" % c, "parent": "machine", "children": [], "linux_cpus": [c],
                       "load": round(loads.get(c, 0), 4), "samples": 0,
                       "daemons": [d["daemon_id"] for d in ds if c in d["cpus"]]})
    return {"mercury_cpu": -1, "allocatable": cpus, "daemons": ds, "groups": groups}

class H(BaseHTTPRequestHandler):
    def log_message(self, fmt, *a):
        sys.stderr.write("fake-mercury: " + (fmt % a) + "\n")
    def reply(self, code, obj):
        b = json.dumps(obj, separators=(",", ":")).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if self.path == "/ping":
            b = b"pong\n"; self.send_response(200); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
        elif self.path == "/map":
            self.reply(200, map_json())
        else:
            self.reply(404, {"ok": False})
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); req = json.loads(self.rfile.read(n) or b"{}")
        did = req.get("daemon_id", "")
        if self.path == "/start":
            cpu = int(req.get("cpu", -1))
            if pool and cpu not in pool:
                return self.reply(400, {"pid": 0})
            with lock:
                if did in daemons and daemons[did]["proc"].poll() is None:
                    return self.reply(400, {"pid": 0})
            env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": os.environ.get("HOME", "/tmp")}
            env.update({k: str(v) for k, v in (req.get("env") or {}).items()})
            log = open(os.path.join(logdir, did + ".log"), "ab")
            try:
                p = subprocess.Popen([req["exec_path"]], cwd=cwd, env=env, stdout=log, stderr=log, start_new_session=True)
            except OSError as e:
                return self.reply(400, {"pid": 0, "error": str(e)})
            d = {"proc": p, "cpus": [cpu] if cpu >= 0 else [], "home": cpu, "scale": False, "min": 1, "max": 1,
                 "usage_us": 0, "last_ticks": 0}
            with lock:
                daemons[did] = d
                if d["cpus"]:
                    apply(did, d)
                write_stat(did, d)
            return self.reply(200, {"ok": True, "pid": p.pid})
        if self.path == "/kill":
            with lock:
                d = daemons.pop(did, None)
            if d is None:
                return self.reply(404, {"ok": False, "error": "unknown daemon"})
            stop(d["proc"])
            try:
                for f in ("cpuset.cpus", "cpu.stat"):
                    os.remove(os.path.join(cgroot, did, f))
                os.rmdir(os.path.join(cgroot, did))
            except OSError:
                pass
            return self.reply(200, {"ok": True})
        with lock:
            d = daemons.get(did)
            if d is None:
                return self.reply(404, {"ok": False})
            if self.path == "/cpus":
                try:
                    cpus = parse_list(req.get("cpus", ""))
                except ValueError:
                    return self.reply(400, {"ok": False})
                if not cpus or (pool and any(c not in pool for c in cpus)):
                    return self.reply(400, {"ok": False})
                d["cpus"] = cpus; d["home"] = cpus[0]; apply(did, d)
                return self.reply(200, {"ok": True})
            if self.path == "/scale":
                d["scale"] = req.get("policy", "saturate") != "none"
                d["min"], d["max"] = int(req.get("min", 1)), int(req.get("max", 16))
                return self.reply(200, {"ok": True, "min": d["min"], "max": d["max"], "cores": len(d["cpus"]),
                                        "policy": req.get("policy", "saturate")})
        self.reply(404, {"ok": False})

def stop(p):
    try:
        os.killpg(p.pid, signal.SIGTERM); p.wait(timeout=10)
    except Exception:
        try: os.killpg(p.pid, signal.SIGKILL)
        except Exception: pass

def shutdown(*_):
    with lock:
        for d in daemons.values():
            try: os.killpg(d["proc"].pid, signal.SIGTERM)
            except Exception: pass
    os._exit(0)

signal.signal(signal.SIGTERM, shutdown); signal.signal(signal.SIGINT, shutdown)
threading.Thread(target=scale_loop, daemon=True).start()
ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
