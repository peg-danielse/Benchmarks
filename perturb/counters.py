"""Optional hardware counters and scheduler delay for perturb.py.

Backend: perf_event_open(2) via ctypes (same kernel interface and permission rules as
`perf stat`; the perf binary is not needed). Two scopes:
  cgroup  events of one Mercury daemon cgroup (pid = cgroup fd, PERF_FLAG_PID_CGROUP),
          opened on every CPU in --allowed (a cgroup event counts only on its CPU)
  cpu     system-wide events on given CPUs (pid = -1)
Events: cycles, instructions, cache-misses (generic), LLC read misses (HW_CACHE; Zen 1
often reports ENOENT for it, the column is then empty). Counts are scaled by
time_enabled/time_running when multiplexed.

Needs kernel.perf_event_paranoid <= 0 for cgroup/cpu-wide events as a normal user
(or CAP_PERFMON). Any open error degrades to empty columns with a reason string.

Run-delay: sum over the daemon's threads of /proc/<tid>/schedstat field 2 (ns waited on
a runqueue); reported as ms of wait per second of wall time.

PERTURB_COUNTERS=fake returns synthetic counts (offline test).
"""
import ctypes, os, struct

PERF_TYPE_HARDWARE, PERF_TYPE_HW_CACHE = 0, 3
EVENTS = {
    "cycles": (PERF_TYPE_HARDWARE, 0),
    "instructions": (PERF_TYPE_HARDWARE, 1),
    "cache_misses": (PERF_TYPE_HARDWARE, 3),
    "llc_load_misses": (PERF_TYPE_HW_CACHE, 2 | (0 << 8) | (1 << 16)),  # LL, READ, MISS
}
PERF_FLAG_FD_CLOEXEC, PERF_FLAG_PID_CGROUP = 1 << 3, 1 << 2
NR_PERF_EVENT_OPEN = 298  # x86_64
_libc = ctypes.CDLL(None, use_errno=True)


def paranoid():
    try:
        return int(open("/proc/sys/kernel/perf_event_paranoid").read())
    except OSError:
        return None


def _open(etype, config, pid, cpu, flags):
    attr = bytearray(128)
    # type, size, config, sample_period, sample_type, read_format, flags(bitfield)
    struct.pack_into("IIQQQQQ", attr, 0, etype, 128, config, 0, 0, 1 | 2, 0)
    buf = (ctypes.c_char * 128).from_buffer(attr)
    fd = _libc.syscall(NR_PERF_EVENT_OPEN, buf, pid, cpu, -1, flags | PERF_FLAG_FD_CLOEXEC)
    if fd < 0:
        e = ctypes.get_errno()
        raise OSError(e, os.strerror(e))
    return fd


def _read(fd):
    v, en, run = struct.unpack("QQQ", os.read(fd, 24))
    return v * en / run if run else 0.0


class Counters:
    """Open counters for one scope; sample() returns cumulative counts per event (None if unavailable)."""

    def __init__(self, scope, target, cpus, cg_root):
        self.fds, self.errors, self.cgfd = {}, {}, None
        self.fake = os.environ.get("PERTURB_COUNTERS") == "fake"
        self.n = 0
        if self.fake:
            return
        try:
            if scope == "cgroup":
                self.cgfd = os.open(os.path.join(cg_root, target), os.O_RDONLY)
                pid, flags = self.cgfd, PERF_FLAG_PID_CGROUP
            else:
                pid, flags = -1, 0
        except OSError as e:
            self.errors["all"] = str(e)
            return
        for name, (t, c) in EVENTS.items():
            fds = []
            try:
                for cpu in cpus:
                    fds.append(_open(t, c, pid, cpu, flags))
                self.fds[name] = fds
            except OSError as e:
                for fd in fds:
                    os.close(fd)
                self.errors[name] = e.strerror

    def sample(self):
        if self.fake:
            self.n += 1
            return {"cycles": 1e9 * self.n, "instructions": 1.5e9 * self.n,
                    "cache_misses": 2e6 * self.n, "llc_load_misses": 1e6 * self.n}
        return {name: (sum(_read(fd) for fd in self.fds[name]) if name in self.fds else None) for name in EVENTS}

    def status(self):
        if self.fake:
            return "fake"
        if not self.fds:
            p = paranoid()
            return f"unavailable ({'; '.join(f'{k}: {v}' for k, v in self.errors.items())}; perf_event_paranoid={p})"
        return "perf_event_open" + (f" (missing {', '.join(self.errors)})" if self.errors else "")

    def close(self):
        for fds in self.fds.values():
            for fd in fds:
                os.close(fd)
        self.fds = {}
        if self.cgfd is not None:
            os.close(self.cgfd)
            self.cgfd = None


def run_delay_ns(cg_root, daemon):
    """Total runqueue wait (ns) of all threads in the daemon's cgroup; None if unreadable."""
    if os.environ.get("PERTURB_COUNTERS") == "fake":
        run_delay_ns.n = getattr(run_delay_ns, "n", 0) + 1
        return 5e7 * run_delay_ns.n
    try:
        tids = open(os.path.join(cg_root, daemon, "cgroup.threads")).read().split()
    except OSError:
        return None
    tot, ok = 0, False
    for t in tids:
        try:
            tot += int(open(f"/proc/{t}/schedstat").read().split()[1])
            ok = True
        except (OSError, IndexError, ValueError):
            pass
    return tot if ok else None


def derived(samples):
    """samples: list of (t, counts, run_delay_ns) at window ends for one phase, paired with the
    previous sample. Returns ipc, misses per 1k instructions, run-delay ms/s."""
    d = {k: 0.0 for k in EVENTS}
    have = {k: True for k in EVENTS}
    rd = dt = 0.0
    rd_ok = True
    for (t0, c0, r0), (t1, c1, r1) in samples:
        dt += t1 - t0
        for k in EVENTS:
            if c0.get(k) is None or c1.get(k) is None:
                have[k] = False
            else:
                d[k] += c1[k] - c0[k]
        if r0 is None or r1 is None:
            rd_ok = False
        else:
            rd += r1 - r0
    ins = d["instructions"] if have["instructions"] and d["instructions"] > 0 else None

    def f(x):
        return "" if x is None else f"{x:.4f}"
    return {
        "ipc": f(ins / d["cycles"] if ins and have["cycles"] and d["cycles"] > 0 else None),
        "cache_mpki": f(1000 * d["cache_misses"] / ins if ins and have["cache_misses"] else None),
        "llc_mpki": f(1000 * d["llc_load_misses"] / ins if ins and have["llc_load_misses"] else None),
        "run_delay_ms_s": f(rd / 1e6 / dt if rd_ok and dt > 0 and samples else None),
    }
