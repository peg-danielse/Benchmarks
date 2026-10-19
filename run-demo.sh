#!/usr/bin/env bash
# Mercury demo: several app instances on ONE Mercury, each driven by its own sine of users.
#   --apps "hotel social"   hotel + social (dtn-01 default)
#   --apps hotel,hotel      two hotels: instances hotel-a and hotel-b, own ports (HOTEL_B_PORT_OFFSET)
# See DEMO.md. Settings come from (later wins): built-in defaults below,
# hosts/<host>.env, the environment, then command-line options.
# Per-instance keys: <INST>_<KEY> (HOTEL_B_PERIOD), else <KIND>_<KEY> (HOTEL_PERIOD), else DEMO_<KEY>.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

usage() {
  cat <<'U'
usage: run-demo.sh [options]
  --apps LIST       instances: "hotel social" or hotel,hotel (DEMO_APPS)
  --period D        sine period (DEMO_PERIOD; per instance HOTEL_A_PERIOD, SOCIAL_PERIOD, ...)
  --periods N       number of periods to run (DEMO_PERIODS; ignored when --duration is set)
  --duration D      load time per instance incl. ramp-in (DEMO_DURATION; <INST>_DURATION)
  --users-min N     (DEMO_USERS_MIN; <INST>_USERS_MIN)
  --users-max N     (DEMO_USERS_MAX; <INST>_USERS_MAX)
  --users-mean N    alternative to min/max (DEMO_USERS_MEAN; <INST>_USERS_MEAN)
  --users-amp N     amplitude around the mean (DEMO_USERS_AMP; default mean/2, the 1:2 min:max ratio)
  --step D          user-count update interval (DEMO_STEP)
  --ramp-in D       (DEMO_RAMP_IN)
  --phase INST=DEG  sine phase of one instance, e.g. --phase hotel-b=180 (<INST>_PHASE)
  --hotel-phase DEG / --social-phase DEG   (HOTEL_PHASE / SOCIAL_PHASE)
  --set KEY=VALUE   any setting, e.g. --set HOTEL_B_PERIOD=3m
  --policy saturate|gnn   (POLICY)   --model PATH (GNN_MODEL, for gnn)
  --jaeger | --no-jaeger  (JAEGER=1/0)
  --fake            use fake_mercury.py instead of Mercury (no root, FAKE=1)
  --out DIR         run directory (OUT; default demo/runs/<timestamp>)
  --dry-run         print the resolved settings, port map and commands, start nothing
Durations: 300, 300s, 5m, 1h. Host defaults: hosts/$(hostname -s).env or DEMO_HOST.
U
}

die() { echo "run-demo: $*" >&2; exit 1; }
ukey() { local k=${1^^}; echo "${k//-/_}"; }   # hotel-b -> HOTEL_B

# ---- options (applied after the env file so they win) ----
declare -A CLI=()
DRY=0
while [ $# -gt 0 ]; do
  case $1 in
    --period) CLI[DEMO_PERIOD]=$2; shift ;;
    --periods) CLI[DEMO_PERIODS]=$2; shift ;;
    --duration) CLI[DEMO_DURATION]=$2; shift ;;
    --users-min) CLI[DEMO_USERS_MIN]=$2; shift ;;
    --users-max) CLI[DEMO_USERS_MAX]=$2; shift ;;
    --users-mean) CLI[DEMO_USERS_MEAN]=$2; shift ;;
    --users-amp) CLI[DEMO_USERS_AMP]=$2; shift ;;
    --step) CLI[DEMO_STEP]=$2; shift ;;
    --ramp-in) CLI[DEMO_RAMP_IN]=$2; shift ;;
    --phase) CLI[$(ukey "${2%%=*}")_PHASE]=${2#*=}; shift ;;
    --hotel-phase) CLI[HOTEL_PHASE]=$2; shift ;;
    --social-phase) CLI[SOCIAL_PHASE]=$2; shift ;;
    --set) CLI[${2%%=*}]=${2#*=}; shift ;;
    --apps) CLI[DEMO_APPS]=$2; shift ;;
    --policy) CLI[POLICY]=$2; shift ;;
    --model) CLI[GNN_MODEL]=$2; shift ;;
    --jaeger) CLI[JAEGER]=1 ;;
    --no-jaeger) CLI[JAEGER]=0 ;;
    --fake) CLI[FAKE]=1 ;;
    --out) CLI[OUT]=$2; shift ;;
    --dry-run) DRY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

host=${DEMO_HOST:-$(hostname -s)}
envfile=$here/hosts/$host.env
# The env file only fills what the caller's environment did not set.
if [ -f "$envfile" ]; then
  while IFS= read -r line; do
    line=${line%%#*}; line=$(echo "$line" | sed 's/[[:space:]]*$//')
    case $line in *=*) ;; *) continue ;; esac
    k=${line%%=*}; v=${line#*=}
    [ -z "${!k+x}" ] && eval "export $k=\"$v\""
  done < "$envfile"
fi
for k in "${!CLI[@]}"; do export "$k=${CLI[$k]}"; done

# ---- defaults (dtn-01 layout; Apollo.env overrides) ----
: "${DSB_ROOT:=$(cd "$here/.." && pwd)}" "${MERCURY_ROOT:=$HOME/Mercury}"
: "${MERCURY_BIN:=$MERCURY_ROOT/build/mercury}" "${MERCURY_PORT:=28080}" "${MERCURY_CPU:=0}" "${POOL:=1-59}"
: "${POLICY:=saturate}" "${GNN_MODEL:=}" "${FAKE:=0}" "${SUDO:=sudo -n}" "${DEMO_APPS:=hotel social}"
: "${DEMO_PERIOD:=5m}" "${DEMO_PERIODS:=2}" "${DEMO_DURATION:=}" "${DEMO_USERS_MIN:=50}" "${DEMO_USERS_MAX:=150}" "${DEMO_USERS_MEAN:=}" "${DEMO_USERS_AMP:=}"
: "${DEMO_STEP:=5s}" "${DEMO_RAMP_IN:=30s}" "${DEMO_WINDOW_MS:=1000}"
: "${DEMO_SVC_MAX:=16}" "${DEMO_GEN_MAX:=8}"
# hotel + social
: "${HOTEL_PHASE:=0}" "${SOCIAL_PHASE:=180}"
: "${HOTEL_HOMES:=1-15}" "${SOCIAL_HOMES:=16-33}" "${HOTEL_GEN_CPU:=58}" "${SOCIAL_GEN_CPU:=59}"
: "${HOTEL_OP_CPU:=60}" "${SOCIAL_OP_CPU:=61}" "${HOTEL_JAEGER_CPUS:=62}" "${SOCIAL_JAEGER_CPUS:=63}"
: "${HOTEL_JAEGER_OFFSET:=20000}" "${SOCIAL_JAEGER_OFFSET:=21000}" "${HOTEL_PORT_OFFSET:=0}"
# two hotels (hotel,hotel): hotel-a keeps the stock ports, hotel-b adds HOTEL_B_PORT_OFFSET to every one
: "${HOTEL_A_PHASE:=0}" "${HOTEL_B_PHASE:=180}"
: "${HOTEL_A_HOMES:=1-15}" "${HOTEL_B_HOMES:=16-33}" "${HOTEL_A_GEN_CPU:=58}" "${HOTEL_B_GEN_CPU:=59}"
: "${HOTEL_A_OP_CPU:=60}" "${HOTEL_B_OP_CPU:=61}" "${HOTEL_A_JAEGER_CPUS:=62}" "${HOTEL_B_JAEGER_CPUS:=63}"
: "${HOTEL_A_JAEGER_OFFSET:=20000}" "${HOTEL_B_JAEGER_OFFSET:=21000}" "${HOTEL_A_PORT_OFFSET:=0}" "${HOTEL_B_PORT_OFFSET:=2000}"
: "${JAEGER:=0}" "${TRACE_SAMPLE:=0.02}"
: "${SOCIAL_MONGO:=own}" "${SOCIAL_MONGO_PORT:=27018}" "${SOCIAL_INIT:=auto}" "${SOCIAL_LIB_DIR:=}" "${SOCIAL_REDIS_BIN:=}" "${SOCIAL_RABBITMQ_SERVER:=}" "${SOCIAL_ERLANG_BIN:=}"
: "${SPECULATOR_EVERY:=10}" "${LOADGEN_CHECK_S:=30}"
: "${HOTEL_FILE:=$DSB_ROOT/mercury-hotel.txt}" "${DEMO_BIN:=$here/bin}" "${OUT:=$here/runs/$(date +%Y%m%d-%H%M%S)}"
OUT=$(realpath -m "$OUT")   # operators run in the app trees: every path they get must be absolute
export DSB_ROOT
# app trees: config files and the operators/Mercury cwd (dtn-01: the demo worktrees, not the shared checkouts)
: "${HOTEL_DIR:=$DSB_ROOT/deathstar-hotelReservations}" "${SOCIAL_DIR:=$DSB_ROOT/deathstar-socialNetwork}"

to_sec() {  # 300 | 300s | 5m | 1h | 1m30s
  python3 -c "import re,sys
s=sys.argv[1]; t=0
for n,u in re.findall(r'([0-9.]+)([smh]?)', s): t+=float(n)*{'':1,'s':1,'m':60,'h':3600}[u]
print(int(round(t)))" "$1"
}
cpu_list() { python3 -c "import sys
out=[]
for p in sys.argv[1].split(','):
  a,_,b=p.partition('-'); out+=range(int(a),int(b or a)+1)
print(' '.join(map(str,out)))" "$1"; }
first_cpu() { cpu_list "$1" | awk '{print $1}'; }

# ---- instances: a kind listed twice becomes <kind>-a, <kind>-b ----
declare -A KIND=() NK=() SEEN=()
INSTS=""
for k in ${DEMO_APPS//,/ }; do NK[$k]=$(( ${NK[$k]:-0} + 1 )); done
for k in ${DEMO_APPS//,/ }; do
  case $k in hotel|social) ;; *) die "unknown app $k (hotel or social)" ;; esac
  if [ "${NK[$k]}" -gt 1 ]; then
    [ $k = hotel ] || die "only hotel can run twice"
    n=${SEEN[$k]:-0}; SEEN[$k]=$(( n + 1 )); inst=$k-$(echo abcdefgh | cut -c$(( n + 1 )))
  else inst=$k; fi
  INSTS+=" $inst"; KIND[$inst]=$k
done
INSTS=${INSTS# }
# iv INST KEY: <INST>_KEY, else <KIND>_KEY, else DEMO_KEY
iv() { local v; for v in "$(ukey "$1")_$2" "$(ukey "${KIND[$1]}")_$2" "DEMO_$2"; do
  if [ -n "${!v:-}" ]; then echo "${!v}"; return; fi; done; }

declare -A P
for inst in $INSTS; do
  period=$(iv $inst PERIOD); ramp=$(iv $inst RAMP_IN); dur=$(iv $inst DURATION)
  if [ -z "$dur" ]; then
    dur="$(( $(to_sec "$ramp") + $(to_sec "$period") * $(iv $inst PERIODS) ))s"
  fi
  P[$inst.period]=$(to_sec "$period")s; P[$inst.ramp]=$(to_sec "$ramp")s; P[$inst.duration]=$(to_sec "$dur")s
  mean=$(iv $inst USERS_MEAN)
  if [ -n "$mean" ]; then  # --users-mean/--users-amp win over min/max
    amp=$(iv $inst USERS_AMP); amp=${amp:-$(( mean / 2 ))}
    P[$inst.min]=$(( mean - amp )); P[$inst.max]=$(( mean + amp ))
  else
    P[$inst.min]=$(iv $inst USERS_MIN); P[$inst.max]=$(iv $inst USERS_MAX)
  fi
  [ "${P[$inst.min]}" -ge 1 ] && [ "${P[$inst.max]}" -ge "${P[$inst.min]}" ] || die "$inst users ${P[$inst.min]}-${P[$inst.max]} invalid"
  P[$inst.step]=$(to_sec "$(iv $inst STEP)")s
  P[$inst.phase]=$(iv $inst PHASE)
  for key in HOMES GEN_CPU OP_CPU SVC_MAX GEN_MAX JAEGER_OFFSET JAEGER_CPUS PORT_OFFSET; do P[$inst.$key]=$(iv $inst $key); done
done

EPOCH_MS=$(( $(date +%s%3N) + ${DEMO_EPOCH_DELAY_S:-0} * 1000 ))
echo "demo host $host env ${envfile/#$here\//} out $OUT"
echo "instances: $INSTS"
echo "mercury $( [ "$FAKE" = 1 ] && echo fake || echo "$MERCURY_BIN") port $MERCURY_PORT cpu $MERCURY_CPU pool $POOL policy $POLICY${GNN_MODEL:+ model $GNN_MODEL}"
echo "sine epoch_ms $EPOCH_MS (phase 0 of every instance)  jaeger $JAEGER sample $TRACE_SAMPLE"
for inst in $INSTS; do
  echo "$inst: users ${P[$inst.min]}-${P[$inst.max]} (mean $(( (P[$inst.min] + P[$inst.max]) / 2 ))) period ${P[$inst.period]} phase ${P[$inst.phase]} step ${P[$inst.step]} ramp_in ${P[$inst.ramp]} duration ${P[$inst.duration]}  homes ${P[$inst.HOMES]} gen_cpu ${P[$inst.GEN_CPU]} op_cpu ${P[$inst.OP_CPU]} svc_max ${P[$inst.SVC_MAX]} gen_max ${P[$inst.GEN_MAX]}$( [ ${KIND[$inst]} = hotel ] && echo " port_offset ${P[$inst.PORT_OFFSET]}") jaeger_offset ${P[$inst.JAEGER_OFFSET]}"
done
[ "$DRY" = 1 ] && DRYRUN=echo || DRYRUN=

# ---- preflight ----
has_kind() { local i; for i in $INSTS; do [ ${KIND[$i]} = $1 ] && return 0; done; return 1; }
has_kind hotel && { [ -x "$DEMO_BIN/operate" ] || die "$DEMO_BIN/operate missing: run ./build.sh"; }
has_kind social && { [ -x "$DEMO_BIN/goperate" ] || die "$DEMO_BIN/goperate missing: run ./build.sh"; }
[ "$FAKE" = 1 ] || [ -x "$MERCURY_BIN" ] || die "$MERCURY_BIN missing (build Mercury, or --fake)"
[ "$POLICY" != gnn ] || [ "$FAKE" = 1 ] || [ -n "$GNN_MODEL" ] || echo "warning: gnn without GNN_MODEL uses Mercury's built-in model path"
OUT_PARENT_EXISTS=0; [ -d "$OUT" ] && OUT_PARENT_EXISTS=1
mkdir -p "$OUT" || die "cannot create $OUT"
for inst in $INSTS; do mkdir -p "$OUT/$inst"; done

# ---- hotel deployment per instance: config.json, wrappers and port list with PORT_OFFSET ----
gen_hotel() {  # inst -> $OUT/inst/{config.json,cwd/,mercury-hotel.txt,ports.txt}
  local inst=$1 d=$OUT/$1
  python3 - "$HOTEL_DIR/config.json" "$HOTEL_FILE" "$d" "${P[$inst.PORT_OFFSET]}" "${P[$inst.JAEGER_OFFSET]}" <<'PY'
import json, os, sys
cfg_src, deploy_src, d, off, joff = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
def shift(addr):
    h, p = addr.rsplit(":", 1)
    return f"{h}:{int(p) + off}"
c = json.load(open(cfg_src))
ports = []
c["mongo"] = shift(c["mongo"]); ports.append(("mongod", c["mongo"]))
c["memcached"] = {k: shift(v) for k, v in c["memcached"].items()}
ports += [(f"memcached-{k}", v) for k, v in c["memcached"].items()]
c["services"] = {k: shift(v) for k, v in c["services"].items()}
ports += [(k, v) for k, v in c["services"].items()]
c["jaeger"] = "127.0.0.1:%d" % (6831 + joff)
for sub in ("cwd", "bin", "memcached", "mongodb"):
    os.makedirs(os.path.join(d, sub), exist_ok=True)
json.dump(c, open(os.path.join(d, "config.json"), "w"), indent=2)
link = os.path.join(d, "cwd", "config.json")
if not os.path.lexists(link):
    os.symlink("../config.json", link)
out = []
for raw in open(deploy_src):
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    path, hostn = line.split()
    name = os.path.basename(path)
    if name.isdigit():                       # memcached: the program name is its port
        new = os.path.join(d, "memcached", str(int(name) + off))
        if os.path.lexists(new): os.remove(new)
        os.symlink(os.path.realpath(path), new)
    elif name == "mongod":                   # runtime/mongodb/mongod keeps data in <root>/<port>/db
        new = os.path.join(d, "mongodb", "mongod")
        open(new, "w").write(f"#!/bin/sh\nexec {path} --advertise-port {int(c['mongo'].rsplit(':',1)[1])}\n")
        os.chmod(new, 0o755)
    else:                                    # Go services read config.json from their cwd
        new = os.path.join(d, "bin", name)
        open(new, "w").write(f"#!/bin/sh\ncd {d}/cwd || exit 1\nexec {path} \"$@\"\n")
        os.chmod(new, 0o755)
    out.append(f"{new} {hostn}")
open(os.path.join(d, "mercury-hotel.txt"), "w").write("# generated by run-demo.sh\n" + "\n".join(out) + "\n")
with open(os.path.join(d, "ports.txt"), "w") as f:
    for role, addr in ports:
        f.write(f"{addr.rsplit(':', 1)[1]} {role}\n")
PY
}
jaeger_ports() { local off=$1 p; for p in 6831 6832 14268 14250 4317 4318 16686 16685 13133; do echo "$(( p + off )) jaeger-$p"; done; }

: > "$OUT/ports.txt"
echo "$MERCURY_PORT mercury mercury" >> "$OUT/ports.txt"
for inst in $INSTS; do
  if [ ${KIND[$inst]} = hotel ]; then
    gen_hotel $inst || die "cannot generate the $inst deployment"
    sed "s/\$/ $inst/" "$OUT/$inst/ports.txt" | awk '{print $1, $3, $2}' >> "$OUT/ports.txt"
  else
    { for p in $(seq 10001 10012); do echo "$p social service"; done
      for p in 11311 11312 11313; do echo "$p social memcached"; done
      echo "6379 social redis"; echo "5672 social rabbitmq"
      [ "$SOCIAL_MONGO" = own ] && echo "$SOCIAL_MONGO_PORT social mongod"; } >> "$OUT/ports.txt"
  fi
  [ "$JAEGER" = 1 ] && jaeger_ports "${P[$inst.JAEGER_OFFSET]}" | awk -v i=$inst '{print $1, i, $2}' >> "$OUT/ports.txt"
done
echo "port map ($OUT/ports.txt: port instance role):"
for inst in mercury $INSTS; do echo "  $inst: $(awk -v i=$inst '$2==i{printf "%s=%s ", $3, $1}' "$OUT/ports.txt")"; done
port_busy() { (exec 3<>/dev/tcp/127.0.0.1/$1) 2>/dev/null; }
dups=$(awk '{print $1}' "$OUT/ports.txt" | sort | uniq -d | tr '\n' ' '); [ -z "$dups" ] || die "port plan collides: $dups"
busy=""; for p in $(awk '{print $1}' "$OUT/ports.txt"); do port_busy $p && busy+=" $p"; done
[ -z "$busy" ] || die "ports already in use:$busy (stop what holds them first)"

# ---- social deployment for this run: own MongoDB port, optional lib dir ----
SOCIAL_FILE=$DSB_ROOT/mercury-social.txt SOCIAL_CONFIG=$SOCIAL_DIR/config/service-config.json
if has_kind social; then
  d=$OUT/social; mkdir -p "$d/run" "$d/mongo"
  SOCIAL_CONFIG=$d/service-config.json
  python3 - "$SOCIAL_DIR/config/service-config.json" "$SOCIAL_CONFIG" "$SOCIAL_MONGO" "$SOCIAL_MONGO_PORT" <<'PY'
import json, sys
src, dst, mode, port = sys.argv[1:]
c = json.load(open(src))
if mode == "own":
    for k, v in c.items():
        if k.endswith("-mongodb") and isinstance(v, dict):
            v["port"] = int(port)
json.dump(c, open(dst, "w"), indent=2)
PY
  SOCIAL_FILE=$d/mercury-social.txt
  : > "$SOCIAL_FILE"
  while read -r path hostn; do
    case $path in ''|'#'*) continue ;; esac
    name=$(basename "$path")
    if [ "$name" = mongod ]; then
      [ "$SOCIAL_MONGO" = own ] || continue           # shared: hotel's mongod on 27017 serves both
      printf '#!/bin/sh\nexec %s --advertise-port %s\n' "$path" "$SOCIAL_MONGO_PORT" > "$d/mongo/mongod"
      chmod +x "$d/mongo/mongod"; path=$d/mongo/mongod
    elif [ "$name" = redis-server ] && [ -n "$SOCIAL_REDIS_BIN" ]; then  # same arguments as runtime/redis/redis-server.c
      mkdir -p "$d/redis"
      printf '#!/bin/sh\nmkdir -p %s\nexec %s --bind 127.0.0.1 --port 6379 --dir %s --dbfilename dump.rdb --daemonize no --protected-mode yes --logfile ""\n' \
        "$DSB_ROOT/runtime/redis/6379" "$SOCIAL_REDIS_BIN" "$DSB_ROOT/runtime/redis/6379" > "$d/redis/redis-server"
      chmod +x "$d/redis/redis-server"; path=$d/redis/redis-server
    elif [ "$name" = rabbitmq-server ] && [ -n "$SOCIAL_RABBITMQ_SERVER" ]; then  # runtime/rabbitmq/rabbitmq-server.c, other server/Erlang
      mkdir -p "$d/rabbitmq"; rb=$here/state/rabbitmq-5672
      cat > "$d/rabbitmq/rabbitmq-server" <<RB
#!/bin/sh
mkdir -p $rb/mnesia $rb/log && echo 'listeners.tcp.default = 5672' > $rb/rabbitmq.conf || exit 1
export RABBITMQ_NODE_PORT=5672 RABBITMQ_NODENAME=rabbit-5672@\$(hostname -s) RABBITMQ_MNESIA_BASE=$rb/mnesia RABBITMQ_LOG_BASE=$rb/log RABBITMQ_CONFIG_FILE=$rb/rabbitmq.conf HOME=$rb
${SOCIAL_ERLANG_BIN:+export PATH=$SOCIAL_ERLANG_BIN:\$PATH}
exec $SOCIAL_RABBITMQ_SERVER
RB
      chmod +x "$d/rabbitmq/rabbitmq-server"; path=$d/rabbitmq/rabbitmq-server
    elif [ "$(basename "$(dirname "$path")")" = run ]; then
      # Own wrapper instead of the checkout's run/<Service>: cd to SOCIAL_RUNDIR (this run's config/), optional lib dir.
      bin=$(cd "$(dirname "$path")/.." && pwd)/bin/$name
      { echo '#!/bin/sh'
        [ -n "$SOCIAL_LIB_DIR" ] && echo "export LD_LIBRARY_PATH=$SOCIAL_LIB_DIR\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
        echo "cd \"\${SOCIAL_RUNDIR:-$SOCIAL_DIR}\" || exit 1"
        echo "exec $bin \"\$@\""; } > "$d/run/$name"
      chmod +x "$d/run/$name"; path=$d/run/$name
    fi
    echo "$path $hostn" >> "$SOCIAL_FILE"
  done < "$DSB_ROOT/mercury-social.txt"
  [ "$SOCIAL_MONGO" = shared ] && ! has_kind hotel && die "SOCIAL_MONGO=shared needs hotel's mongod"
fi
deploy_file() { [ ${KIND[$1]} = hotel ] && echo "$OUT/$1/mercury-hotel.txt" || echo "$SOCIAL_FILE"; }

# ---- cleanup (Ctrl-C, errors, normal end) ----
MPID="" OPIDS="" SPECPID=""; declare -A OPID=()
ids_for() {  # Mercury daemon ids an instance may have started
  local inst=$1
  grep -v '^\s*#' "$(deploy_file $inst)" | awk 'NF{print $1}' | while read -r p; do echo "$inst-$(basename "$p")"; done
  echo "$inst-loadgen"; echo "$inst-jaeger"
}
cleanup() {
  trap '' INT TERM; trap - EXIT   # a second Ctrl-C must not cut the cleanup short
  echo "run-demo: cleaning up"
  for p in $OPIDS; do kill -TERM -- -$p 2>/dev/null || kill -TERM $p 2>/dev/null; done
  for i in $(seq 120); do alive=0; for p in $OPIDS; do kill -0 $p 2>/dev/null && alive=1; done; [ $alive = 0 ] && break; sleep 0.5; done
  for p in $OPIDS; do kill -KILL -- -$p 2>/dev/null; done
  [ -n "$SPECPID" ] && kill $SPECPID 2>/dev/null
  [ -n "${TAILPID:-}" ] && kill $TAILPID 2>/dev/null
  [ -n "${CHECKPID:-}" ] && kill $CHECKPID 2>/dev/null
  if [ -n "$MPID" ]; then
    for inst in $INSTS; do for id in $(ids_for $inst); do
      curl -s -m 5 -X POST -d "{\"daemon_id\":\"$id\"}" http://127.0.0.1:$MERCURY_PORT/kill >/dev/null 2>&1; done; done
    if [ "$FAKE" = 1 ]; then kill -TERM $MPID 2>/dev/null; else $SUDO kill -TERM $MPID 2>/dev/null; fi
    for i in $(seq 50); do [ -d /proc/$MPID ] || break; sleep 0.2; done
  fi
  if [ "$FAKE" != 1 ]; then  # Mercury's daemon cgroups of this demo
    for inst in $INSTS; do for c in /sys/fs/cgroup/mercury/$inst-*; do
      [ -d "$c" ] || continue; echo 1 | $SUDO tee "$c/cgroup.kill" >/dev/null 2>&1; done; done
    sleep 1
    for inst in $INSTS; do for c in /sys/fs/cgroup/mercury/$inst-*; do [ -d "$c" ] && $SUDO rmdir "$c" 2>/dev/null; done; done
  fi
  echo "run-demo: cleanup done"
}
[ "$DRY" = 1 ] || trap 'cleanup; exit 130' INT TERM
[ "$DRY" = 1 ] || trap cleanup EXIT
echo $$ > "$OUT/run-demo.pid"

# ---- Mercury ----
POOL_LIST=$(cpu_list "$POOL")
if [ "$FAKE" = 1 ]; then
  export MERCURY_CGROUP_ROOT=$OUT/cgroup
  $DRYRUN env FAKE_MERCURY_POOL="$POOL" FAKE_MERCURY_CGROUP="$MERCURY_CGROUP_ROOT" FAKE_MERCURY_LOGS="$OUT/daemons" \
    setsid python3 "$here/fake_mercury.py" "$MERCURY_PORT" "$HOTEL_DIR" > "$OUT/mercury.log" 2>&1 &
  MPID=$!
else
  # Mercury's cwd is the hotel tree; the generated hotel wrappers and the social wrappers cd themselves.
  ( cd "$HOTEL_DIR" && exec $DRYRUN setsid $SUDO env ${GNN_MODEL:+MERCURY_GNN_MODEL=$GNN_MODEL} "$MERCURY_BIN" "$MERCURY_PORT" $MERCURY_CPU $POOL_LIST ) > "$OUT/mercury.log" 2>&1 &
  MPID=$!
fi
if [ "$DRY" != 1 ]; then
  for i in $(seq 100); do curl -s -m 1 http://127.0.0.1:$MERCURY_PORT/ping | grep -q pong && break; [ -d /proc/$MPID ] || die "Mercury exited: $(tail -3 "$OUT/mercury.log")"; sleep 0.2; done
  curl -s -m 1 http://127.0.0.1:$MERCURY_PORT/ping | grep -q pong || die "Mercury is not answering on $MERCURY_PORT"
  echo "mercury up (pid $MPID, log $OUT/mercury.log)"
fi

op_cmd() {  # inst -> operator command line (array OP)
  local inst=$1
  OP=(taskset -c "${P[$inst.OP_CPU]}")
  if [ ${KIND[$inst]} = hotel ]; then
    OP+=("$DEMO_BIN/operate" -prefix "$inst" -file "$OUT/$inst/mercury-hotel.txt" -config "$OUT/$inst/config.json" -gen-bin "$DEMO_BIN/operate"
         -ready-file "$OUT/$inst/ready")
  else
    OP+=("$DEMO_BIN/goperate" -file "$SOCIAL_FILE" -config "$SOCIAL_CONFIG" -gen-bin "$DEMO_BIN/goperate" -run-dir "$OUT/social/social-cwd")
  fi
  OP+=(-mercury 127.0.0.1:$MERCURY_PORT -cpu "$(first_cpu "${P[$inst.HOMES]}")" -homes "${P[$inst.HOMES]}" -client mercury
       -gen-cpu "${P[$inst.GEN_CPU]}" -gen-max "${P[$inst.GEN_MAX]}" -gen-procs "${P[$inst.GEN_MAX]}" -svc-max "${P[$inst.SVC_MAX]}"
       -policy "$POLICY" -window-ms "$DEMO_WINDOW_MS" -gen-out "$OUT/$inst/loadgen.out" -status-file "$OUT/$inst/status")
}
sine_args() { local inst=$1
  SINE=(-load sine -users-min "${P[$inst.min]}" -users-max "${P[$inst.max]}" -period "${P[$inst.period]}" -phase "${P[$inst.phase]}"
        -step "${P[$inst.step]}" -ramp-in "${P[$inst.ramp]}" -duration "${P[$inst.duration]}" -sine-epoch-ms "$EPOCH_MS")
  JG=()
  if [ "$JAEGER" = 1 ]; then
    JG=(-jaeger -jaeger-port-offset "${P[$inst.JAEGER_OFFSET]}" -jaeger-cpus "${P[$inst.JAEGER_CPUS]}" -trace-sample "$TRACE_SAMPLE" -trace-out "$OUT/$inst/traces.csv"); fi
}

# ---- social graph for a fresh MongoDB ----
if has_kind social && [ "$SOCIAL_MONGO" = own ]; then
  marker=$here/state/social-mongo-$SOCIAL_MONGO_PORT.loaded
  if [ "$SOCIAL_INIT" = always ] || { [ "$SOCIAL_INIT" = auto ] && [ ! -f "$marker" ]; }; then
    op_cmd social
    echo "social init (graph into MongoDB :$SOCIAL_MONGO_PORT): ${OP[*]} init"
    if [ "$DRY" != 1 ]; then
      ( cd "$SOCIAL_DIR" && exec setsid "${OP[@]}" init ) > "$OUT/social/init.out" 2>&1 & ip=$!; OPIDS=$ip
      wait $ip || die "social init failed: see $OUT/social/init.out"
      OPIDS=""; mkdir -p "$here/state" && date > "$marker"
    fi
  fi
fi

# ---- operators ----
for inst in $INSTS; do
  op_cmd $inst; sine_args $inst
  dir=$HOTEL_DIR; [ ${KIND[$inst]} = social ] && dir=$SOCIAL_DIR
  extra=$(ukey $inst)_ARGS; [ -n "${!extra:-}" ] || extra=$(ukey ${KIND[$inst]})_ARGS
  cmd=("${OP[@]}" "${SINE[@]}" "${JG[@]}" ${!extra:-} autoscale)
  printf '%q ' "${cmd[@]}" > "$OUT/$inst/command.txt"; echo >> "$OUT/$inst/command.txt"
  echo "$inst: $(cat "$OUT/$inst/command.txt")"
  [ "$DRY" = 1 ] && continue
  ( cd "$dir" && exec setsid "${cmd[@]}" ) > "$OUT/$inst/operate.out" 2> "$OUT/$inst/operate.err" &
  OPIDS+=" $!"; OPID[$inst]=$!
done
[ "$DRY" = 1 ] && exit 0

# ---- port and entry-point checks: every daemon up, no load yet (hotel -ready-file / go file) ----
owner_ok() {  # port inst -> listener's process is in one of inst's Mercury cgroups
  local pid; pid=$($SUDO ss -Hltnp "sport = :$1" 2>/dev/null | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)
  [ -n "$pid" ] && grep -q "/mercury/$2-" /proc/$pid/cgroup 2>/dev/null
}
started_by() {  # port inst -> listener's process descends from inst's operator (bare Jaeger) or sits in inst's cgroup
  local pid; pid=$($SUDO ss -Hltnp "sport = :$1" 2>/dev/null | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)
  [ -n "$pid" ] || return 1
  grep -q "/mercury/$2-" /proc/$pid/cgroup 2>/dev/null && return 0
  while [ -n "$pid" ] && [ "$pid" -gt 1 ]; do [ "$pid" = "${OPID[$2]:-x}" ] && return 0; pid=$(awk '{print $4}' /proc/$pid/stat 2>/dev/null); done
  return 1
}
if has_kind hotel; then
  for inst in $INSTS; do [ ${KIND[$inst]} = hotel ] || continue
    for i in $(seq 900); do [ -f "$OUT/$inst/ready" ] && break
      kill -0 "${OPID[$inst]}" 2>/dev/null || die "$inst operator exited before its daemons were up: $(tail -n 2 "$OUT/$inst/operate.err")"; sleep 0.2; done
    [ -f "$OUT/$inst/ready" ] || die "$inst never got its daemons up: see $OUT/$inst/operate.err"
  done
  {
    echo "== port check $(date +%T): port instance role listening owner"
    fail=0
    while read -r port inst role; do
      [ "$inst" = mercury ] && continue
      l=no; port_busy $port && l=yes
      case $role in jaeger-*)  # informational: which Jaeger ports a v2 collector opens depends on its config (6831/6832 are UDP)
        o=-; [ $l = yes ] && [ "$FAKE" != 1 ] && { started_by $port $inst && o=ok || o=WRONG; }
        echo "$port $inst $role $l $o (info)"; [ $o = WRONG ] && fail=1; continue ;; esac
      o=-; if [ "$FAKE" != 1 ] && [ ${KIND[$inst]} = hotel ]; then owner_ok $port $inst && o=ok || o=WRONG; fi
      echo "$port $inst $role $l $o"
      { [ $l = yes ] && [ $o != WRONG ]; } || { [ ${KIND[$inst]} = hotel ] && fail=1; }
    done < "$OUT/ports.txt"
    for inst in $INSTS; do [ ${KIND[$inst]} = hotel ] || continue
      fe=$(awk '$2=="frontend"{print $1}' "$OUT/$inst/ports.txt")
      code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$fe/")
      echo "frontend $inst :$fe GET / -> $code"; [ "$code" = 200 ] || fail=1
    done
    echo "result $([ $fail = 0 ] && echo OK || echo FAIL)"
  } > "$OUT/portcheck.txt" 2>&1
  cat "$OUT/portcheck.txt" | grep -E 'result|frontend|WRONG| no '
  grep -q 'result OK' "$OUT/portcheck.txt" || die "port check failed: see $OUT/portcheck.txt"
  for inst in $INSTS; do [ ${KIND[$inst]} = hotel ] && touch "$OUT/$inst/ready.go"; done
  echo "port check OK: load starts ($(date +%T))"
  # Each loadgen talks only to its own instance's ports (checked once the load runs).
  ( sleep "$LOADGEN_CHECK_S"
    for inst in $INSTS; do [ ${KIND[$inst]} = hotel ] || continue
      pid=$(curl -s -m 3 http://127.0.0.1:$MERCURY_PORT/map | python3 -c "import json,sys
m=json.load(sys.stdin); print(next((str(d['pid']) for d in m.get('daemons',[]) if d['daemon_id']=='$inst-loadgen'),''))")
      [ -n "$pid" ] || { echo "loadgen $inst: not found in /map"; continue; }
      peers=$($SUDO ss -Htnp state established 2>/dev/null | grep "pid=$pid," | awk '{print $4}' | sed 's/.*://' | sort -n | uniq -c | awk '{printf "%s:%s ", $2, $1}')
      own=" $(awk '{print $1}' "$OUT/$inst/ports.txt" | tr '\n' ' ') "
      bad=""; for pc in $peers; do p=${pc%%:*}; [[ "$own" == *" $p "* ]] || bad+=" $p"; done
      echo "loadgen $inst pid $pid peer ports (port:conns): $peers-> $([ -z "$bad" ] && echo "only own ports OK" || echo "FOREIGN:$bad")"
    done ) >> "$OUT/portcheck.txt" 2>&1 &
  CHECKPID=$!
fi

# ---- live: per-window summaries here; speculator snapshots to a log ----
SPEC=$DEMO_BIN/speculator
st=(); for inst in $INSTS; do st+=(--status "$OUT/$inst/status" --app "$inst"); done
echo "live view (yours, another terminal): $SPEC $MERCURY_PORT  then Enter, a, pick each instance (see DEMO.md 5)"
printf '%q ' "$SPEC" "$MERCURY_PORT" --watch 2 "${st[@]}" > "$OUT/speculator.cmd"; echo >> "$OUT/speculator.cmd"
if [ -x "$SPEC" ] && [ "$SPECULATOR_EVERY" -gt 0 ]; then
  ( while sleep "$SPECULATOR_EVERY"; do echo "=== $(date +%T)"; "$SPEC" "$MERCURY_PORT" --once "${st[@]}" 2>&1 < /dev/null | sed -n '/^apps/,$p'; done ) > "$OUT/speculator.log" 2>&1 &
  SPECPID=$!
fi
tail -n0 -F "${OUT}"/*/operate.out 2>/dev/null | grep --line-buffered -E '^demo app|^traces |loadgen error' &
TAILPID=$!

rc=0
for p in $OPIDS; do wait $p || rc=1; done
kill $TAILPID 2>/dev/null
OPIDS=""
for inst in $INSTS; do echo "$inst operate exit: $(tail -2 "$OUT/$inst/operate.err" | tr '\n' ' ')"; done
cleanup; trap - EXIT
python3 "$here/plot_demo.py" "$OUT" || rc=1
echo "summary $OUT/summary.txt plot $OUT/demo.png"
echo "done $(date +%T) rc $rc" > "$OUT/done"
exit $rc
