#!/bin/bash
# One perturbation experiment end to end, mirroring ~/Mercury/src/test/dsb_ab.sh:
# own Mercury (port 8080, pool 1-60, worker CPU 0), operator autoscale ramp up to -users,
# perturb.py attached to the operator output at the given user levels.
#
#   perturb.sh hotel|social OUTDIR "<operator extra flags>" <perturb.py args...>
#   e.g. perturb.sh hotel labels/runs "-users 2048 -window-ms 3000" --daemon hotel-geo --kind stress \
#          --stressor cache --placement smt --intensity high --clients 256,1024,2048
#
# Refuses to run while anyone else's dsb_ab / operator / loadgen / mercury is up.
# On any exit: perturb.py restores cpusets+policy and kills stress-ng; this script then
# stops the operator (which kills its daemons), kills leftover app cgroups, stops Mercury,
# and kills any stress-ng it started.
set -u
SYS=$1; OUT=$2; EXTRA=$3; shift 3
# Host layout: defaults are dtn-01 (64 CPUs). hosts/$(hostname -s).env, or HOST_ENV=file, overrides them.
HERE=$(cd "$(dirname "$0")" && pwd)
HOST_ENV=${HOST_ENV:-$HERE/hosts/$(hostname -s).env}; [ -f "$HOST_ENV" ] && . "$HOST_ENV"
B=${DSB_ROOT:-/home/paul/Benchmarks}; M=${MERCURY_ROOT:-/home/paul/Mercury}; export DSB_ROOT=$B
MERCURY_CPU=${MERCURY_CPU:-0}; POOL=${POOL:-1-60}; GEN_CPU=${GEN_CPU:-60}
OP_CPU=${OP_CPU:-61}; HELPER_CPU=${HELPER_CPU:-62}
STRESS_CACHE_CPUS=${STRESS_CACHE_CPUS:-33-40}; STRESS_STREAM_CPUS=${STRESS_STREAM_CPUS:-41-47}
pool_list() { python3 -c "import sys; sys.path.insert(0, '$HERE'); from common import parse_cpuset; print(' '.join(map(str, parse_cpuset('$POOL'))))"; }
ncpus() { python3 -c "import sys; sys.path.insert(0, '$HERE'); from common import parse_cpuset; print(len(parse_cpuset('$1')))"; }
case $SYS in
  hotel) WD=$B/deathstar-hotelReservations; OP=$WD/bin/loadgen; PFX=hotel-;;
  social) WD=$B/deathstar-socialNetwork; OP=$WD/goperate/bin/goperate; PFX=social-;;
  *) echo "usage: $0 hotel|social OUTDIR 'operator flags' perturb-args..."; exit 2;;
esac

busy=$(pgrep -af 'dsb_ab\.sh|/build/mercury |/bin/loadgen|goperate|deathstar-.*/bin/|stress-ng|perturb\.py' | grep -v "^$$ " | grep -v pgrep)
if [ -n "$busy" ]; then echo "REFUSING: benchmark processes are running:"; echo "$busy"; exit 3; fi
if ls -d /sys/fs/cgroup/mercury/hotel-* /sys/fs/cgroup/mercury/social-* >/dev/null 2>&1; then
  echo "REFUSING: leftover Mercury app cgroups exist (someone else's run?)"; exit 3; fi

RUN=$(realpath -m $OUT)/$(date +%Y%m%d-%H%M%S); mkdir -p $RUN
killcg() { for c in /sys/fs/cgroup/mercury/$PFX*; do [ -d $c ] && echo 1 | sudo -n tee $c/cgroup.kill >/dev/null; done; sleep 1; for c in /sys/fs/cgroup/mercury/$PFX*; do [ -d $c ] && sudo -n rmdir $c 2>/dev/null; done; }
cleanup() {
  [ -n "${PPID_:-}" ] && kill -TERM $PPID_ 2>/dev/null && wait $PPID_ 2>/dev/null
  [ -n "${OPID:-}" ] && kill -INT $OPID 2>/dev/null; for i in $(seq 50); do kill -0 ${OPID:-0} 2>/dev/null || break; sleep 0.2; done
  [ -f $RUN/state.json ] && python3 $HERE/perturb.py restore --state $RUN/state.json
  pkill -u $(id -u) -f "^$B/stress-ng/stress-ng" 2>/dev/null
  killcg
  [ -n "${MPID:-}" ] && sudo -n kill -TERM $MPID 2>/dev/null; sleep 1
  echo "cleaned up $RUN"
}
trap cleanup EXIT; trap 'exit 130' INT TERM HUP

(cd $WD && exec sudo -n $M/build/mercury 8080 $MERCURY_CPU $(pool_list)) > $RUN/mercury.log 2>&1 &
sleep 1; MPID=$(pgrep -f "^$M/build/mercury 8080 $MERCURY_CPU" | head -1)
[ -n "$MPID" ] || { echo "mercury did not start"; exit 1; }
(cd $WD && exec taskset -c $OP_CPU $OP -mercury 127.0.0.1:8080 -cpu 2 -client mercury -gen-cpu $GEN_CPU -policy saturate -gen-out $RUN/loadgen.out $EXTRA autoscale) > $RUN/operate.out 2> $RUN/operate.err &
OPID=$!
for i in $(seq 120); do grep -q '^route ' $RUN/operate.out 2>/dev/null && break; sleep 1; done
taskset -c $HELPER_CPU python3 $HERE/perturb.py --prefix $PFX --watch $RUN/operate.out --state $RUN/state.json \
  --allowed $POOL --mercury-cpu $MERCURY_CPU --csv $(realpath -m $OUT)/perturb.csv --raw $(realpath -m $OUT)/perturb_windows.csv "$@" &
PPID_=$!; wait $PPID_; rc=$?; PPID_=""
echo "perturb.py exit $rc; run dir $RUN"
exit $rc
