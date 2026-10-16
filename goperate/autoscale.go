package main

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"time"
)

const (
	root   = "/home/paul/Benchmarks"
	snRoot = root + "/deathstar-socialNetwork"

	autoMaxCores = 16
	autoWindows  = 4
	scaleMeasure = time.Second

	// Linux CPU 0 is Mercury. Homes begin at CPU 1, one per line of
	// mercury-social.txt. The in-process client keeps CPUs 60-63.
	homeFirstLinux = 1
	clientFirstCPU = 60
	clientLastCPU  = 63

	clientMercury = "mercury"
	clientInproc  = "inproc"
	loadgenID     = "social-loadgen"

	defaultGenCPU   = 60
	defaultGenMin   = 2
	defaultGenMax   = 8
	defaultGenProcs = 8
)

// clientOpts chooses how autoscale drives load; see hotel operate for the
// same design. mercury: bin/loadgen as Mercury daemon social-loadgen.
// inproc: this process pinned to CPUs 60-63.
type clientOpts struct {
	mode     string
	bin      string
	out      string
	config   string
	file     string
	graph    string
	routes   string
	mix      string
	homeCPU  int
	genMin   int
	genMax   int
	genProcs int
	conns    int
}

func clientCPUs() []int {
	cpus := make([]int, 0, clientLastCPU-clientFirstCPU+1)
	for cpu := clientFirstCPU; cpu <= clientLastCPU; cpu++ {
		cpus = append(cpus, cpu)
	}
	return cpus
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

// autoscaleServices puts every daemon on its own home core, attaches
// saturate 1..16, and drives the social-network routes together from 1 user
// to maxUsers and back down.
func autoscaleServices(base string, cfg serviceConfig, lines []tuple, maxUsers int, opts clientOpts, track func(tuple)) error {
	homes, err := daemonHomes(len(lines))
	if err != nil {
		return err
	}
	names, err := parseRoutes(opts.routes)
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
		if err := enableSaturate(base, line.id, 1, autoMaxCores); err != nil {
			return err
		}
		fmt.Printf(" %s=%s", filepath.Base(line.path), spec)
	}
	fmt.Println()
	fmt.Printf("policy saturate min 1 max %d users 1-%d routes %s mix %s graph %s\n",
		autoMaxCores, maxUsers, opts.routes, orDefault(opts.mix, "equal"), opts.graph)

	if opts.mode == clientInproc {
		w, err := loadGraph(opts.graph)
		if err != nil {
			return err
		}
		if w.mix, err = parseMix(opts.mix, names); err != nil {
			return err
		}
		gen := &genMeter{cpus: inprocCPUs, busy: selfBusy, max: len(clientCPUs())}
		return driveRoutes(cfg, names, maxUsers, w, os.Stdout, lines, gen)
	}
	return runMercuryLoadgen(base, maxUsers, opts, track)
}

func orDefault(s, d string) string {
	if s == "" {
		return d
	}
	return s
}

// driveRoutes ramps every route together and prints one line per route per
// window, in the hotel autoscaleN.out format: route, clients (this route's
// active users), arrival_rate, service_rate, avg_us, p95_us, errors, cpus,
// then the gen_* columns.
func driveRoutes(cfg serviceConfig, names []string, maxUsers int, wl *workload, w io.Writer, lines []tuple, gen *genMeter) error {
	routes, err := openRoutes(cfg, names, maxUsers, wl)
	defer stopRoutes(routes)
	if err != nil {
		return err
	}
	for _, clients := range rampClients(maxUsers) {
		for _, route := range routes {
			route.rec.setActive(int32(routeUsers(clients, route.weight)))
		}
		for window := 0; window < autoWindows; window++ {
			g0 := gen.begin()
			readings := measureRoutes(routes)
			gw := gen.end(g0)
			cpus := cpuSetList(lines, readCPUSet)
			for i, route := range routes {
				reading := readings[i]
				fmt.Fprintf(w, "route %s clients %d arrival_rate %d service_rate %d avg_us %.1f p95_us %.1f errors %d cpus %s %s\n",
					route.name, routeUsers(clients, route.weight), reading.arrivalRate, reading.serviceRate,
					reading.avgUs, reading.p95Us, reading.errors, cpus, gw)
			}
		}
	}
	return nil
}
