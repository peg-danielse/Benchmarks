package main

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/delimitrou/DeathStarBench/tree/master/hotelReservation/boot"
)

// -svc-min / -svc-max: service scale bounds (-svc-min N -svc-max N = fixed N cores).
var (
	autoMaxCores = 16
	svcMinCores  = 1
)

const (
	autoWindows = 4

	// Linux CPU 0 is Mercury. Homes begin at CPU 1, one per line of
	// mercury-hotel.txt. The loader keeps clientFirstCPU through clientLastCPU.
	homeFirstLinux = 1
)

// autoscaleServices places every daemon from the deployment file on its own
// core, caps each one at 16 cores with the saturate policy, and drives every
// hotel route at the same time from 1 caller up to maxUsers and back down.
//
// On this 64-CPU machine start Mercury with the daemon pool only:
//
//	mercury 8080 1 2 3 ... 60
//	go run ./operate -mercury 127.0.0.1:8080 -cpu 2 -users 1024 autoscale
//
// CPU 0 stays with Mercury. The 15 programs in mercury-hotel.txt take Linux
// CPUs 1-15 as their home cores. Saturate grows a daemon by taking the lowest
// pool CPU that daemon does not already have, up to 16, so those sets overlap
// inside CPUs 1-59. All ten routes run together, so the programs grow at the
// same time and share that pool. CPUs 60-63 are this process and are left off
// Mercury's command line.
//
// /start passes GOMAXPROCS=16 to each Go service, MEMCACHED_THREADS=16 to each
// cache, and MONGO_WT_READ_TRANSACTIONS=16 plus MONGO_WT_WRITE_TRANSACTIONS=16
// to mongod. The saturate max is the same 16.
// clientOpts chooses how autoscale drives load.
//
// client "mercury" (default) starts bin/loadgen as a Mercury daemon with
// POST /start, sets its home cpuset with POST /cpus, and attaches saturate
// between genMin and genMax cores. The orchestrator then copies loadgen's
// output file to stdout until loadgen exits.
//
// client "inproc" is the original client: this process pins itself to
// clientFirstCPU-clientLastCPU and drives the routes itself.
type clientOpts struct {
	mode     string
	bin      string
	out      string
	config   string
	homeCPU  int
	genMin   int
	genMax   int
	genProcs int
	conns    int
}

const (
	clientMercury = "mercury"
	clientInproc  = "inproc"
	loadgenID     = "hotel-loadgen"

	defaultGenCPU   = 60
	defaultGenMin   = 2
	defaultGenMax   = 8
	defaultGenProcs = 8
)

func autoscaleServices(base string, cfg boot.Config, lines []tuple, maxUsers int, opts clientOpts, track func(tuple)) error {
	homes, err := daemonHomes(len(lines))
	if err != nil {
		return err
	}
	if opts.mode == clientInproc {
		if err := pinTasks(clientCPUs()); err != nil {
			return err
		}
		runtime.GOMAXPROCS(len(clientCPUs()))
		fmt.Printf("layout linux_cpus=64 mercury=0 homes=%d-%d max_cores=%d clients=%d-%d\n",
			homes[0], homes[len(homes)-1], autoMaxCores, clientFirstCPU, clientLastCPU)
	} else {
		fmt.Printf("layout linux_cpus=64 mercury=0 homes=%d-%d max_cores=%d clients=mercury:%s home=%d saturate=%d-%d gomaxprocs=%d conns=%d\n",
			homes[0], homes[len(homes)-1], autoMaxCores, loadgenID, opts.homeCPU, opts.genMin, opts.genMax, opts.genProcs, opts.conns)
	}
	fmt.Print("homes")
	for i, line := range lines {
		spec := strconv.Itoa(homes[i])
		if err := setCpus(base, line.id, spec); err != nil {
			return err
		}
		mn, mx := svcRange(line, svcMinCores, autoMaxCores)
		if err := enableScale(base, line.id, servicePolicy, mn, mx); err != nil {
			return err
		}
		fmt.Printf(" %s=%s", filepath.Base(line.path), spec)
	}
	fmt.Println()
	fmt.Printf("policy %s placement %s tick_ms %d min %d max %d users 1-%d\n", servicePolicy, servicePlacement, serviceTickMs, svcMinCores, autoMaxCores, maxUsers)

	for _, name := range hotelServiceNames {
		if _, ok := findLine(lines, name); !ok {
			return fmt.Errorf("deployment has no %s", name)
		}
	}
	w, finishTraces, err := beginTraceAnalysis()
	if err != nil {
		return err
	}
	defer finishTraces()
	if opts.mode == clientInproc {
		traceMarks = tracing.enabled()
		gen := &genMeter{cpus: inprocCPUs, busy: selfBusy, max: len(clientCPUs())}
		return driveRoutes(cfg, maxUsers, w, lines, gen)
	}
	return runMercuryLoadgen(base, lines, maxUsers, opts, track, w)
}

// driveRoutes ramps every hotel route together and prints one line per route
// per window. Columns up to cpus match the earlier autoscaleN.out files; the
// gen_* columns describe the load generator during that window.
func driveRoutes(cfg boot.Config, maxUsers int, w io.Writer, lines []tuple, gen *genMeter) error {
	routes, err := openRoutes(cfg, maxUsers)
	defer stopRoutes(routes)
	if err != nil {
		return err
	}

	var marks markCounter
	for level, clients := range rampClients(maxUsers) {
		for _, route := range routes {
			route.rec.setActive(int32(clients))
		}
		for window := 0; window < autoWindows; window++ {
			g0 := gen.begin()
			t0 := time.Now()
			readings := measureRoutes(routes)
			t1 := time.Now()
			gw := gen.end(g0)
			cpus := cpuSetList(lines, readCPUSet)
			marks.emit(w, level, window, clients, t0, t1) // -jaeger only: window marker for the trace analyser
			for i, route := range routes {
				reading := readings[i]
				fmt.Fprintf(w, "route %s clients %d arrival_rate %d service_rate %d avg_us %.1f p95_us %.1f p99_us %.1f errors %d cpus %s %s\n",
					route.name, clients, reading.arrivalRate, reading.serviceRate, reading.avgUs, reading.p95Us, reading.p99Us, reading.errors,
					cpus, gw)
			}
		}
	}
	return nil
}

type liveRoute struct {
	name   string
	work   load
	rec    *recorder
	cancel context.CancelFunc
}

func openRoutes(cfg boot.Config, maxUsers int) ([]liveRoute, error) {
	routes := make([]liveRoute, 0, len(hotelServiceNames))
	for _, name := range hotelServiceNames {
		work, err := openLoad(cfg, name, maxUsers)
		if err != nil {
			return routes, err
		}
		ctx, cancel := context.WithCancel(context.Background())
		rec := startLoad(ctx, work.call, maxUsers, 1)
		routes = append(routes, liveRoute{name: name, work: work, rec: rec, cancel: cancel})
		if err := waitReady(rec, name); err != nil {
			return routes, err
		}
	}
	return routes, nil
}

func stopRoutes(routes []liveRoute) {
	for _, route := range routes {
		if route.cancel != nil {
			route.cancel()
		}
	}
	for _, route := range routes {
		if route.rec != nil {
			route.rec.wg.Wait()
		}
		if route.work.close != nil {
			route.work.close()
		}
	}
}

// windowMs is the autoscale measurement window (-window-ms, LOADGEN_WINDOW_MS); default 1 s.
var windowMs = 1000

func measureRoutes(routes []liveRoute) []reading {
	befores := make([]snap, len(routes))
	for i, route := range routes {
		befores[i] = route.rec.snapshot()
	}
	began := time.Now()
	time.Sleep(time.Duration(windowMs) * time.Millisecond)
	elapsed := time.Since(began)
	out := make([]reading, len(routes))
	for i, route := range routes {
		out[i] = readWindow(befores[i], route.rec.snapshot(), elapsed)
	}
	return out
}

func daemonHomes(n int) ([]int, error) {
	if n < 1 {
		return nil, fmt.Errorf("no daemons")
	}
	homes := make([]int, n)
	for i := range homes {
		cpu := homeFirstLinux + i
		if cpu >= clientFirstCPU {
			return nil, fmt.Errorf("daemon %d needs linux cpu %d, loader owns %d-%d", i, cpu, clientFirstCPU, clientLastCPU)
		}
		homes[i] = cpu
	}
	return homes, nil
}

func rampClients(maxUsers int) []int {
	up := []int{1}
	for up[len(up)-1] < maxUsers {
		next := up[len(up)-1] * 2
		if next <= up[len(up)-1] || next > maxUsers {
			next = maxUsers
		}
		up = append(up, next)
	}
	clients := make([]int, 0, len(up)*2-1)
	clients = append(clients, up...)
	for i := len(up) - 2; i >= 0; i-- {
		clients = append(clients, up[i])
	}
	return clients
}

func enableSaturate(base, id string, minCores, maxCores int) error {
	return enableScale(base, id, "saturate", minCores, maxCores)
}

// Policy for the service daemons (-policy, -tick-ms, -placement). The load generator stays on saturate.
var (
	servicePolicy    = "saturate"
	serviceTickMs    = 10
	servicePlacement = "least_loaded"
	servicePin       = true // -pin: gnn pins busy threads (false: cpuset sizing only)
)

// enableScale attaches policy (saturate or gnn) to a daemon with the -placement core hand-out.
// tick_ms is sent for gnn only.
func enableScale(base, id, policy string, minCores, maxCores int) error {
	req := map[string]any{
		"daemon_id": id,
		"policy":    policy,
		"min":       minCores,
		"max":       maxCores,
		"placement": servicePlacement,
	}
	if policy == "gnn" {
		req["tick_ms"] = serviceTickMs
		req["pin"] = servicePin
	}
	status, body, err := post(base, "/scale", req)
	if err != nil {
		return err
	}
	if status != http.StatusOK || !bytes.Contains(body, []byte(`"ok":true`)) {
		return fmt.Errorf("POST /scale %s: %d %s", id, status, bytes.TrimSpace(body))
	}
	return nil
}

func readCPUSet(id string) string {
	data, err := os.ReadFile("/sys/fs/cgroup/mercury/" + id + "/cpuset.cpus")
	if err != nil {
		return "?"
	}
	text := strings.TrimSpace(string(data))
	if text == "" {
		return "?"
	}
	return text
}

func cpuSetList(lines []tuple, spec func(string) string) string {
	var b strings.Builder
	for i, line := range lines {
		if i > 0 {
			b.WriteByte(' ')
		}
		b.WriteString(filepath.Base(line.path))
		b.WriteByte('=')
		b.WriteString(spec(line.id))
	}
	return b.String()
}

// svcFixed (-svc-fixed "geo=1,mongod=2"): per-program fixed allocation (/scale min = max), keyed by the
// deployment line's program name (memcached port, mongod, service name). Others use -svc-min/-svc-max.
var svcFixed = map[string]int{}

func parseSvcFixed(s string) error {
	for _, kv := range strings.Split(s, ",") {
		if kv == "" {
			continue
		}
		k, v, ok := strings.Cut(kv, "=")
		n, err := strconv.Atoi(v)
		if !ok || err != nil || n < 1 {
			return fmt.Errorf("-svc-fixed: bad entry %q (want name=cores)", kv)
		}
		svcFixed[k] = n
	}
	return nil
}

func svcRange(line tuple, mn, mx int) (int, int) {
	if k, ok := svcFixed[filepath.Base(line.path)]; ok {
		return k, k
	}
	return mn, mx
}
