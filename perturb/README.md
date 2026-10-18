# perturb: vulnerability labels for the inference-aware policy

Labels for "how much does a route's rate/p95/p99 change when process d loses, moves or shares CPU",
in one CSV schema (`common.FIELDS` + `STRESS_FIELDS`), from three sources:

| source | tool | what |
|---|---|---|
| `perturb` | `perturb.py` / `perturb.sh` | controlled A-B-A on a frozen cpuset: remove, smt, l3, numa, migrate |
| `perturb` (kind `stress`) | same | stress-ng noisy neighbour on d's core / SMT sibling / L3 / NUMA node |
| `weak:*` | `weak_labels.py` | saturate/gnn add/remove/move events found in existing operator logs (read-only) |

## Training principle: vulnerability only shows under pressure

Perturbations under light load teach the model almost nothing, because a process only shows its
vulnerability when it's near its limit. Therefore:

- run stress-ng as a noisy neighbour on the same core, the SMT sibling, the same L3, or the same
  NUMA node (cpu/cache/memory-bandwidth/matrix stressors at several intensities);
- run perturbation experiments at loads near and beyond the 1024-user knee;
- hold out some stress-ng mixes from training to test generalisation to unseen pressure.

In the tools: `--kind stress --stressor cpu|cache|stream|vm|matrix --placement core|smt|l3|numa
--intensity low|mid|high`; `--clients 256,512,1024,2048` with the operator at `-users 2048`;
`--heldout stream:l3,matrix:smt,vm:numa` (default) labels those mixes `split=heldout`.

## Files

- `perturb.py`: attach to a running app under Mercury. Snapshots cpusets, freezes with
  `POST /scale policy none`, applies B with `POST /cpus` (or starts pinned stress-ng), A-B-A per
  window of the operator output, reverts, re-enables saturate. Restores and kills stress-ng on exit,
  SIGINT/SIGTERM/SIGHUP and exceptions; state in `--state` for `perturb.py restore`.
- `perturb.sh`: end-to-end run like `~/Mercury/src/test/dsb_ab.sh` (own Mercury 8080, pool 1-60,
  operator ramp, perturb.py). Refuses to start if any other dsb_ab/mercury/operator/loadgen/
  stress-ng process or app cgroup exists.
- `sweep.sh`: the matrix (daemons x {5 cpuset kinds, 5 stressors x 4 placements x 2 intensities}).
- `weak_labels.py`: read-only extraction; `labels/weak_labels.csv` + `.summary.json`.
- `test_perturb.sh`: offline test with a fake Mercury, fake cgroups and fake stress-ng.

## Commands

    cd ~/Benchmarks/perturb
    nice python3 weak_labels.py                       # read-only
    ./test_perturb.sh                                 # offline
    ./perturb.sh hotel labels/smoke "-users 64 -window-ms 2000" --daemon hotel-geo --kind smt --clients 64
    ./perturb.sh hotel labels/runs "-users 2048 -window-ms 3000" --daemon hotel-geo --kind stress \
        --stressor cache --placement smt --intensity high --clients 256,1024,2048
    ./sweep.sh hotel labels/sweep hotel-geo hotel-mongod

## Caveats

- Windows are timestamped on arrival (operator lines carry none); the plan switches at window
  boundaries, so each window is fully A or B. Each level gets 4 windows on the up-ramp: 1 warm-up
  is discarded, leaving A,B,A. Use longer `-window-ms` for less noise.
- Freezing (policy none) is itself a change from saturate; labels are "under frozen cpusets".
- Weak labels are confounded (policy picks the moment); `valid=1` keeps only clean single-daemon
  changes at constant users with a settled after-state. Hotel `.out` files have no cpu.stat, so
  `usage_cores_*` is empty there.
