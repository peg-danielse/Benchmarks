#!/bin/bash
# A/B/C placement experiment: who decides where threads run, with and without interference.
#   modes:  none | static | react-thread | react-cgroup   (placer.py side-car; Mercury only sizes)
#           gnn-pin                                       (Kurt's built-in pin(), POLICY must be gnn)
#   stress: off | on   (on = stress-ng --cache on CPUs 33-40 and --stream on 41-47: the SMT siblings of
#                       the home cores, started when the load generator starts)
#   abc.sh hotel|social OUTDIR [REPS]
# Env: MODES, STRESS ("off on"), POLICY ("saturate" or "gnn"; gnn runs with -pin=false except gnn-pin),
#      OPF (operator flags, default "-users 2048 -window-ms 2500", crosses the 1024-user knee).
# Same Mercury/operator launch as ~/Mercury/src/test/dsb_ab.sh. Refuses to start while other
# benchmark processes run. Cleanup on any exit: placer (restores affinity/cpusets), stress-ng, ctrlog,
# operator, app cgroups, Mercury.
set -u
SYS=$1; OUT=$(realpath -m $2); REPS=${3:-1}
B=/home/paul/Benchmarks; M=/home/paul/Mercury; HERE=$(cd "$(dirname "$0")" && pwd)
case $SYS in
  hotel) WD=$B/deathstar-hotelReservations; OP=$WD/bin/loadgen; PFX=hotel-;;
  social) WD=$B/deathstar-socialNetwork; OP=$WD/goperate/bin/goperate; PFX=social-;;
  *) echo "usage: $0 hotel|social OUTDIR [REPS]"; exit 2;;
esac
MODES=${MODES:-none static react-thread react-cgroup}; STRESS=${STRESS:-off on}
POLICY=${POLICY:-saturate}; OPF=${OPF:--users 2048 -window-ms 2500}
SNG=$B/stress-ng/stress-ng

others() { pgrep -af 'dsb_ab\.sh|/build/mercury |/bin/loadgen|goperate|deathstar-.*/bin/|stress-ng|perturb\.py|placer\.py' | grep -v "^$$ " | grep -v pgrep; }
if [ -n "$(others)" ] || ls -d /sys/fs/cgroup/mercury/hotel-* /sys/fs/cgroup/mercury/social-* >/dev/null 2>&1; then
  echo "REFUSING: other benchmark processes or app cgroups exist:"; others; exit 3; fi

RUN=$OUT/$(date +%Y%m%d-%H%M%S); mkdir -p $RUN
killcg() { for c in /sys/fs/cgroup/mercury/$PFX*; do [ -d $c ] && echo 1 | sudo -n tee $c/cgroup.kill >/dev/null; done; sleep 1; for c in /sys/fs/cgroup/mercury/$PFX*; do [ -d $c ] && sudo -n rmdir $c 2>/dev/null; done; }
stop_run() {
  [ -n "${PLPID:-}" ] && sudo -n kill -TERM $PLPID 2>/dev/null; for i in $(seq 25); do sudo -n kill -0 ${PLPID:-0} 2>/dev/null || break; sleep 0.2; done; PLPID=""
  pkill -u $(id -u) -f "^$SNG" 2>/dev/null; [ -n "${CLPID:-}" ] && kill $CLPID 2>/dev/null; CLPID=""
  [ -n "${OPID:-}" ] && kill -INT $OPID 2>/dev/null; for i in $(seq 50); do kill -0 ${OPID:-0} 2>/dev/null || break; sleep 0.2; done; OPID=""
  killcg
  [ -n "${MPID:-}" ] && sudo -n kill -TERM $MPID 2>/dev/null; for i in $(seq 50); do kill -0 ${MPID:-0} 2>/dev/null || break; sleep 0.2; done; MPID=""
}
trap stop_run EXIT; trap 'exit 130' INT TERM HUP

for r in $(seq 1 $REPS); do for mode in $MODES; do for st in $STRESS; do
  D=$RUN/$r-$mode-stress$st; mkdir -p $D; echo "== $D"
  PARGS="-policy $POLICY"; [ $POLICY = gnn ] && { [ $mode = gnn-pin ] && PARGS="-policy gnn" || PARGS="-policy gnn -pin=false"; }
  (cd $WD && exec sudo -n $M/build/mercury 8080 0 $(seq 1 60)) > $D/mercury.log 2>&1 &
  sleep 1; MPID=$(pgrep -f "^$M/build/mercury 8080 0" | head -1)
  for i in $(seq 50); do curl -s -m 1 127.0.0.1:8080/ping >/dev/null && break; sleep 0.2; done
  (cd $WD && exec taskset -c 61 $OP -mercury 127.0.0.1:8080 -cpu 2 -client mercury $PARGS -gen-out $D/loadgen.out $OPF autoscale) > $D/operate.out 2> $D/operate.err &
  OPID=$!
  for i in $(seq 300); do [ -d /sys/fs/cgroup/mercury/${PFX}loadgen ] && break; sleep 1; done
  taskset -c 62 python3 $HERE/ctrlog.py --prefix $PFX --cpus 1-60 --out $D/counters.jsonl & CLPID=$!
  if [ $st = on ]; then
    taskset -c 33-40 $SNG --cache 8 --taskset 33-40 --timeout 3600s --quiet &
    taskset -c 41-47 $SNG --stream 7 --taskset 41-47 --timeout 3600s --quiet &
  fi
  case $mode in gnn-pin) ;; *) sudo -n taskset -c 62 python3 $HERE/placer.py --mode $mode --prefix $PFX --log $D/placer.jsonl & PLPID=$!;; esac
  wait $OPID; echo "  operator exit $? routes=$(grep -c ^route $D/operate.out)"; OPID=""
  stop_run
done; done; done
python3 $HERE/pin_compare.py $RUN | tee $RUN/summary.txt
