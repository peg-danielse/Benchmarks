# Mercury demo: two apps on one Mercury, each driven by a sine of users

One Mercury manages every daemon. Each app instance runs its own operator
(`operate` for hotel, `goperate` for social). Each operator drives its own sine of
concurrent users, so Mercury has to move cores from one instance to the other.

Two modes:

| mode | `--apps` / `DEMO_APPS` | where |
|---|---|---|
| two hotels | `hotel,hotel`: instances **hotel-a** and **hotel-b** | PC (Apollo) default |
| hotel + social | `"hotel social"`: instances **hotel** and **social** | dtn-01 default |

## 1. Prerequisites
- Mercury built from branch `demo` (speculator with `--status/--app/--watch`). Use `MERCURY_BIN` to point at a build.
- Hotel and social checkouts on branch `demo` (sine load, `-prefix`, `-ready-file`).
- Passwordless `sudo -n` for Mercury (cgroups), `ss -p` and the cgroup cleanup. Go, g++, python3 with matplotlib, and curl.
- Social on the PC also needs the extra libraries and servers set in `hosts/Apollo.env`: `SOCIAL_LIB_DIR`, `SOCIAL_REDIS_BIN`, `SOCIAL_RABBITMQ_SERVER` and `SOCIAL_ERLANG_BIN`. Social currently does not run on the PC (see Troubleshooting).
- Do not use port 8080 or ports 18180-18199 (Kurt's runs). On dtn-01, make sure Kurt's sweep and tests have finished before you start, and use the demo worktrees (section 8).

## 2. Build
```
cd ~/Documents/Benchmarks/demo      # dtn-01: ~/Benchmarks/demo
HOTEL_SRC=<hotel demo checkout> SOCIAL_SRC=<social demo checkout> MERCURY_SRC=<mercury demo checkout> ./build.sh
```
This writes `bin/operate`, `bin/goperate` and `bin/speculator`. Without the variables it uses ../deathstar-* and ~/Mercury.

## 3. Configure
Settings are applied in this order, and later ones win: built-in defaults, then `hosts/<hostname>.env`, then the environment, then options.
The env file only fills variables that are not already set.
For each instance, a value is looked up as `<INST>_<KEY>` (for example `HOTEL_B_PERIOD`), then `<KIND>_<KEY>` (`HOTEL_PERIOD`), then `DEMO_<KEY>`.

| option | variable | default |
|---|---|---|
| `--apps` | DEMO_APPS | Apollo `hotel,hotel`; dtn-01 `hotel social` |
| `--period` | DEMO_PERIOD | 5m (dtn-01.env: 10m) |
| `--periods` | DEMO_PERIODS | 2 |
| `--duration` | DEMO_DURATION | ramp-in + periods × period |
| `--users-min` / `--users-max` | DEMO_USERS_MIN / _MAX | 50 / 150 |
| `--users-mean` / `--users-amp` | DEMO_USERS_MEAN / _AMP | unset (amp = mean/2, so 1:2 min:max) |
| `--step` | DEMO_STEP | 5s |
| `--ramp-in` | DEMO_RAMP_IN | 30s |
| `--phase hotel-b=180` | HOTEL_A_PHASE / HOTEL_B_PHASE | 0 / 180 |
| `--hotel-phase` / `--social-phase` | HOTEL_PHASE / SOCIAL_PHASE | 0 / 180 |
| `--set KEY=VAL` | any variable | for example `--set HOTEL_B_USERS_MAX=200` |
| `--policy` / `--model` | POLICY / GNN_MODEL | saturate |
| `--jaeger` / `--no-jaeger` | JAEGER | Apollo 1, dtn-01 1 |
| `--fake` | FAKE | 0 (1 = fake_mercury.py, no root needed) |
| `--out` | OUT | runs/<timestamp> |
| `--dry-run` | | prints settings, the port map and commands; starts nothing |

Per-instance layout keys (`<INST>_...`):
- `HOMES`: daemon home CPUs.
- `GEN_CPU`: loadgen home.
- `OP_CPU`: operator CPU, outside the pool.
- `JAEGER_CPUS`.
- `SVC_MAX` and `GEN_MAX`: maximum cores.
- `JAEGER_OFFSET`.
- `PORT_OFFSET`: hotel only.

Shared keys: `MERCURY_PORT` (28080), `MERCURY_CPU` (0) and `POOL` (Apollo 1-27, dtn-01 1-59).

Apollo layout (i9-14900HX; P-cores 0-15 with SMT, E-cores 16-31):
- Mercury runs on CPU 0, and the pool is 1-27.
- hotel-a uses homes 1-7, its loadgen on 16 and its operator on 28.
- hotel-b uses homes 8-15, its loadgen on 20 and its operator on 29.
- The two Jaegers run on 30 and 31.

### Port map
hotel-a uses the stock ports. hotel-b adds `HOTEL_B_PORT_OFFSET` (default 2000) to every one.
The two Jaegers use different offsets.

| role | hotel-a | hotel-b |
|---|---|---|
| frontend (entry point) | 5000 | 7000 |
| srv-profile … srv-attractions | 8081-8089 | 10081-10089 |
| memcached profile/rate/reservation/review | 11211-11214 | 13211-13214 |
| mongod | 27017 | 29017 |
| Jaeger (offset 20000 / 21000): UDP 6831/6832, collector 14268/14250, OTLP 4317/4318, query 16686/16685, health 13133 | 26831.. 36686 | 27831.. 37686 |
| Mercury | 28080 (shared) | |

Hotel has no consul/registry: every address comes from that instance's `config.json`.

In hotel + social mode:
- hotel keeps its stock ports.
- social uses 10001-10012, memcached 11311-11313, redis 6379, rabbitmq 5672, and its own mongod on 27018.
- Jaeger offsets are 20000 for hotel and 21000 for social (dtn-01: 21000 / 22000, hotel ports +1000 and social mongod 27028; see section 8).

For every hotel instance, run-demo.sh generates `<run>/<inst>/` containing:
- `config.json` with the shifted ports;
- `mercury-hotel.txt`, the deployment list;
- `bin/<svc>` wrappers that `cd` into `cwd/` (where config.json is) and exec the real service;
- `memcached/<port>` symlinks (the program name is the port);
- `mongodb/mongod`, which runs `--advertise-port <port>` and stores its data in runtime/mongodb/<port>;
- `ports.txt`.

All ports go into `<run>/ports.txt`. Before anything starts, run-demo.sh refuses to run if the plan has duplicate ports or if a port is already busy.

Daemon ids, which are also the cgroups under /sys/fs/cgroup/mercury, are `<inst>-<program>`. Examples: `hotel-a-geo`, `hotel-b-13211`, `hotel-b-loadgen`, `hotel-a-jaeger`.
Each instance gets its own output directory, `<run>/<inst>/`.

## 4. Run
```
cd ~/Documents/Benchmarks/demo      # dtn-01: ~/Benchmarks/demo
./run-demo.sh --dry-run                       # check the resolved values and the port map
MERCURY_BIN=$HOME/agent-tools/demo/m/build/mercury ./run-demo.sh            # Apollo: two hotels, 2 x 5 min
./run-demo.sh --apps "hotel social"           # dtn-01 mode
./run-demo.sh --period 3m --periods 3 --set HOTEL_B_USERS_MAX=200
```
To start it detached (it survives closing the terminal):
```
setsid nohup ./run-demo.sh --out runs/my-run > runs/my-run.log 2>&1 < /dev/null &
```
What run-demo.sh does, in order:
1. Starts Mercury.
2. Starts the operators. Hotel operators start their daemons and then wait (`-ready-file`).
3. Runs the **port check**, written to `<run>/portcheck.txt`:
   - every port of every instance is listening;
   - its listener is a process inside that instance's own Mercury cgroups (or, for Jaeger, a child of that instance's operator);
   - each frontend answers `GET /` with 200 on its own port.
4. Only then starts the load.
5. After `LOADGEN_CHECK_S` (30 s), checks that each loadgen's TCP peers are only its own instance's ports. Note that the hotel loadgen calls the services' gRPC ports directly, plus its own frontend.

## 5. What to watch
run-demo.sh does **not** open speculator for you. Its only use of speculator is a background snapshot written to `<run>/speculator.log` every 10 s. That never touches your terminal; set `SPECULATOR_EVERY=0` to turn it off.

Open speculator yourself, in a second terminal, and add the instances by hand:
```
~/Documents/Benchmarks/demo/bin/speculator 28080     # dtn-01: ~/Benchmarks/demo/bin/speculator
```
It refreshes every 2 s and shows Mercury's group tree. Then:
1. Press **Enter**. The menu appears: `a) add app   r) remove app   q) quit   Enter) back`.
2. Type **a** and Enter. It lists the daemon prefixes it found in Mercury, for example `1) hotel-a  2) hotel-b  3) hotel`.
3. Type **1** (or `hotel-a`) and Enter.
4. It suggests the status file of the newest run, e.g. `[.../runs/<run>/hotel-a/status]`. Press **Enter** to accept it, type another path, or type `-` for none (cores only, no users/latency).
5. Repeat for hotel-b. Shortcut without the menu: type `a hotel-b` and Enter, then Enter for the suggested status file.
6. To remove one: Enter, then `r`, then pick the number; or type `r hotel-b`. To quit: `q`.

Once both are added, you see:
- under `apps`: daemons, distinct cores, core_sum and CPUs per instance;
- under `demo`: target users, rate, worst-route p95 (and which route), weighted-mean p95, cores, errors, and Jaeger critical-path shares (`cp` lines, when JAEGER=1).

Daemons that belong to no added app are grouped by their first id segment (`hotel`).

Non-interactive use:
- Start with the apps already added: `speculator 28080 --app hotel-a=<run>/hotel-a/status --app hotel-b=<run>/hotel-b/status`.
- `--once` prints one snapshot.
- `--runs DIR` (or SPECULATOR_RUNS) changes where status files are suggested from; the default is ~/Documents/Benchmarks/demo/runs when that exists (the PC), else ~/Benchmarks/demo/runs (dtn-01).

The two sines are 180° apart. When hotel-a's users peak, hotel-b's bottom out, and with gnn you can watch the cores follow.

Other outputs:
- the run log prints one `demo app <inst> window ...` line per window;
- at the end you get `<run>/summary.txt`, `summary.json` and `demo.png` (users, rate, p95 and cores per instance over time).

## 6. Stop and clean up
Ctrl-C, or `kill -TERM $(cat <run>/run-demo.pid)` for a detached run. The cleanup:
1. stops the operators;
2. sends `/kill` for every daemon id;
3. stops Mercury;
4. removes the leftover `/sys/fs/cgroup/mercury/<inst>-*` cgroups (cgroup.kill + rmdir).

The plot is only produced on a normal end; to plot a stopped run, use `python3 plot_demo.py <run>`. To check that nothing is left:
```
pgrep -af 'mercury|operate|jaeger|mongod|memcached'; ls /sys/fs/cgroup/mercury | grep -E 'hotel|social'
```

## 7. Troubleshooting
- **"ports already in use"**: something else holds a port; `ss -ltnp 'sport = :PORT'` shows what. Change the layout with `HOTEL_B_PORT_OFFSET`, `*_JAEGER_OFFSET` or `MERCURY_PORT`.
- **"port check failed"**: look in `<run>/portcheck.txt`. `no` means a daemon did not listen (see that instance's `operate.err`). `WRONG` means the port belongs to some other process.
- **cores 0 in the summary**: the loadgen reads `/sys/fs/cgroup/mercury/<inst>-*/cpuset.cpus`, so it must be the `demo` build of `operate`.
- **Social on Manjaro (PC)**:
  - The binaries come from Debian, so they need boost 1.83, mongoc, hiredis and redis++ from `demo/lib`.
  - The pacman valkey needs a newer glibc, so use redis 7.2 from `demo/opt`.
  - rabbitmq 4.3.1 fails on OTP 29, so use generic-unix 4.1.4 with OTP 28.1 from `demo/opt`.
  - Open issue: SocialGraphService throws std::bad_alloc in `sw::redis::ConnectionPool::ConnectionPool` (redis++ ABI mismatch with the Debian-built binary). Social is not usable on the PC yet; use the two-hotel mode there.
- **gnn**: `--policy gnn --model PATH`. Not tested in the demo.

## 8. dtn-01
dtn-01 is shared with Kurt. Never build or run in his checkouts (`~/Benchmarks/deathstar-*`, `~/Mercury`): they hold his uncommitted work.
The demo uses its own trees:

| what | path | branch |
|---|---|---|
| demo scripts (this repo) | `~/Benchmarks/demo` | `demo` |
| hotel operator source | `~/Benchmarks/demo-wt/hotel` (worktree of `~/Benchmarks/deathstar-hotelReservations`) | `demo` |
| social operator source | `~/Benchmarks/demo-wt/social` (worktree of `~/Benchmarks/deathstar-socialNetwork`) | `demo` |
| Mercury source + build | `~/Benchmarks/demo-wt/mercury`, build in `build-demo/` (worktree of `~/Mercury`) | `demo` |
| demo binaries | `~/Benchmarks/demo/bin/{operate,goperate,speculator}` | |

Read-only from the shared tree (`DSB_ROOT=~/Benchmarks`): the stock hotel service binaries (`deathstar-hotelReservations/bin`), the social binaries (`deathstar-socialNetwork/bin` and `run/` wrappers), the `runtime/` wrappers, `mercury-hotel.txt`, `mercury-social.txt` and `jaeger/run-jaeger.sh`.
`HOTEL_DIR` and `SOCIAL_DIR` (set in `hosts/dtn-01.env`) point at the worktrees. They provide config.json / service-config.json and serve as the cwd of Mercury and the operators.
The hotel mongod stores its data in `runtime/mongodb/28017` (hotel, hotel-a) and `runtime/mongodb/29017` (hotel-b); the social mongod uses `runtime/mongodb/27028`. That keeps the demo away from Kurt's 27017/27018 data.

Before you start, check that the host is free. Nothing in the output below should be Kurt's (ctest, `*_it.sh`, mercury on 18180, operate/goperate, jaeger, stress-ng, perturb/sweep):
```
pgrep -af 'mercury|operate|jaeger|stress-ng|perturb|sweep|spinner|ctest|loadgen' | grep -v cursor-agent
ss -Hltn | awk '{print $4}' | grep -E ':(5000|6379|5672|8080|1818[0-9]|2701[78]|10001)$'
```

Build (niced, pinned away from CPUs 0-11/32-43, where Kurt's tests run):
```
W=~/Benchmarks/demo-wt
cd ~/Benchmarks/demo && nice -n 19 taskset -c 50-57 env HOTEL_SRC=$W/hotel SOCIAL_SRC=$W/social MERCURY_SRC=$W/mercury ./build.sh
cd $W/mercury && cmake -S . -B build-demo -DCMAKE_BUILD_TYPE=Release && nice -n 19 taskset -c 50-57 cmake --build build-demo -j 8
```

Layout (`hosts/dtn-01.env`; EPYC 7301, NUMA node n = CPUs 4n..4n+3 plus 32+4n..32+4n+3):

| | hotel + social | hotel,hotel |
|---|---|---|
| Mercury | CPU 0, port 28080, pool 1-59 | same |
| homes | hotel 1-15 (nodes 0-3), social 16-31 (nodes 4-7; 18 daemons round-robin) | hotel-a 1-15, hotel-b 16-30 |
| loadgen homes | 58 / 59 | 58 / 59 |
| operators | 60 / 61 | 60 / 61 |
| Jaeger (JAEGER=1 by default) | both on 62, offsets 21000 / 22000 | both on 62, offsets 21000 / 22000 |
| hotel port offset | 1000 (frontend 6000, 9081-9089, 12211-12214, mongod 28017) | hotel-a 1000, hotel-b 2000 (frontend 7000, 10081-10089, 13211-13214, mongod 29017) |

The Jaeger offset 20000 and Mercury ports 8080 and 18180-18199 are Kurt's. CPU 63 stays free.
Social's own ports are fixed: 10001-10012, memcached 11311-11313, redis 6379 and rabbitmq 5672. Kurt's social deployment uses the same ones, so never run social next to it (the port check refuses).
The first social run loads the graph into mongod :27028 (marker `state/social-mongo-27028.loaded`).

Run:
```
cd ~/Benchmarks/demo
./run-demo.sh --dry-run                                   # settings, port map, commands
./run-demo.sh                                             # hotel + social, 2 x 10 min, saturate, Jaeger on
./run-demo.sh --apps hotel,hotel                          # two hotels
./run-demo.sh --apps hotel,hotel --policy gnn             # gnn (model: demo-wt/mercury/models/gnn_v3.json)
# smoke test (~2 min, low users):
./run-demo.sh --apps "hotel social" --duration 90s --period 60s --ramp-in 10s --users-min 2 --users-max 4 --out runs/smoke-hs
./run-demo.sh --apps hotel,hotel    --duration 90s --period 60s --ramp-in 10s --users-min 2 --users-max 4 --out runs/smoke-hh
~/Benchmarks/demo/bin/speculator 28080                    # live view, second terminal (section 5)
```
After a run, check that nothing is left behind (section 6). Also check the demo ports: `ss -Hltn | grep -E ':(28080|6000|7000|2[78]017|29017|27028|2[5-8][0-9]{3}|3[4-8][0-9]{3})\b'`.
