// Command goperate drives the DeathStarBench social network under Mercury,
// mirroring deathstar-hotelReservations/operate.
//
// Mercury is started separately (sudo ~/Mercury/build/mercury 8080). The
// services are the C++ Thrift binaries in ../bin, launched through ../run/
// so they find config/service-config.json. There is no nginx front end; the
// load generator speaks Thrift (framed, binary) to the services directly.
//
//	goperate -mercury 127.0.0.1:8080 -cpu 2 start      start all of mercury-social.txt, leave running
//	goperate -mercury 127.0.0.1:8080 stop              kill every daemon in the list
//	goperate -mercury 127.0.0.1:8080 -cpu 2 init       start, load -graph users+edges into MongoDB, stop
//	goperate -mercury 127.0.0.1:8080 -cpu 2 autoscale  start, ramp load with saturate, stop
//
// autoscale gives every daemon a home core (CPU 1 upward), attaches saturate
// 1..16, and drives -routes together from 1 user to -users and back down,
// four 1 s windows per step. -client mercury (default) runs the generator as
// Mercury daemon social-loadgen (bin/loadgen, same binary with
// OPERATE_ROLE=loadgen) homed on -gen-cpu with saturate -gen-min..-gen-max;
// -client inproc pins this process to CPUs 60-63 instead.
//
// init must have run once against the same MongoDB before autoscale, so the
// users user<id>/password and their follow edges exist.
package main

import (
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"
	"time"
)

func main() {
	if os.Getenv(envRole) == roleGen {
		if err := runLoadgen(); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	mercury := flag.String("mercury", "127.0.0.1:8080", "Mercury host:port")
	cpu := flag.Int("cpu", 0, "daemon CPU number Mercury was given (not the CPU Mercury pinned itself to)")
	users := flag.Int("users", 1024, "maximum concurrent users per route (scaled by -mix)")
	file := flag.String("file", benchmarksRoot()+"/mercury-social.txt", "deployment list")
	configPath := flag.String("config", socialRoot()+"/config/service-config.json", "service-config.json")
	graph := flag.String("graph", defaultGraph(), "social graph .edges file (init loads it; autoscale draws user ids from it)")
	routes := flag.String("routes", defaultRoutes, "comma-separated routes: compose-post,read-home-timeline,read-user-timeline,follow,login")
	mix := flag.String("mix", "", "route weights, e.g. compose-post=0.1,read-home-timeline=0.6,read-user-timeline=0.3 (DSB mixed workload); empty = every route runs -users")
	initWorkers := flag.Int("init-workers", 8, "parallel connections for init")
	client := flag.String("client", clientMercury, "autoscale load generator: mercury (bin/loadgen as a Mercury daemon) or inproc (this process pinned to CPUs 60-63)")
	conns := flag.Int("conns", 0, "Thrift connections per route shared by its workers; 0 = one per worker. A Thrift connection carries one call at a time, so N>0 also caps in-flight calls per route at N")
	genBin := flag.String("gen-bin", socialRoot()+"/goperate/bin/loadgen", "loadgen binary for -client mercury")
	genOut := flag.String("gen-out", "", "loadgen output file (default output/loadgen-<unix>.out)")
	genCPU := flag.Int("gen-cpu", defaultGenCPU, "loadgen home Linux CPU")
	genMin := flag.Int("gen-min", defaultGenMin, "loadgen saturate min cores")
	genMax := flag.Int("gen-max", defaultGenMax, "loadgen saturate max cores")
	genProcs := flag.Int("gen-procs", defaultGenProcs, "loadgen GOMAXPROCS (keep >= gen-max so busy threads can exceed cores)")
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "usage: goperate [flags] start|stop|init|autoscale\n\n")
		flag.PrintDefaults()
	}
	flag.Parse()
	if flag.NArg() != 1 {
		flag.Usage()
		os.Exit(2)
	}
	cmd := flag.Arg(0)
	switch cmd {
	case "start", "stop", "init", "autoscale":
	default:
		flag.Usage()
		os.Exit(2)
	}
	if *client != clientMercury && *client != clientInproc {
		fmt.Fprintf(os.Stderr, "-client must be %s or %s\n", clientMercury, clientInproc)
		os.Exit(2)
	}
	if *conns < 0 || *genMin < 1 || *genMax < *genMin || *genProcs < 1 || *users < 1 || *initWorkers < 1 {
		fmt.Fprintln(os.Stderr, "need -users >= 1, -conns >= 0, 1 <= -gen-min <= -gen-max, -gen-procs >= 1, -init-workers >= 1")
		os.Exit(2)
	}
	names, err := parseRoutes(*routes)
	if err == nil {
		_, err = parseMix(*mix, names)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	connsPerRoute = *conns
	opts := clientOpts{
		mode: *client, bin: *genBin, out: *genOut, config: *configPath, file: *file, graph: *graph,
		routes: *routes, mix: *mix, homeCPU: *genCPU, genMin: *genMin, genMax: *genMax,
		genProcs: *genProcs, conns: *conns,
	}
	if err := run(*mercury, *cpu, *users, *initWorkers, cmd, opts); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(mercury string, cpu, users, initWorkers int, cmd string, opts clientOpts) error {
	lines, err := parseFile(opts.file)
	if err != nil {
		return err
	}
	cfg, err := loadConfig(opts.config)
	if err != nil {
		return err
	}
	if cmd == "init" || cmd == "autoscale" {
		if _, err := loadGraph(opts.graph); err != nil {
			return fmt.Errorf("graph: %w", err)
		}
	}
	base := mercuryURL(mercury)
	if err := ping(base); err != nil {
		return err
	}
	if cmd == "stop" {
		return stopAll(base, lines)
	}
	if cpu < 1 {
		return fmt.Errorf("-cpu is required: pass a daemon CPU from the mercury command line")
	}

	var (
		startedMu sync.Mutex
		started   []tuple
	)
	track := func(t tuple) {
		startedMu.Lock()
		started = append(started, t)
		startedMu.Unlock()
	}
	stopStarted := func() {
		startedMu.Lock()
		defer startedMu.Unlock()
		for i := len(started) - 1; i >= 0; i-- {
			if err := kill(base, started[i].id); err != nil {
				fmt.Fprintf(os.Stderr, "kill %s: %v\n", started[i].id, err)
			}
		}
		started = nil
	}
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sig
		stopStarted()
		os.Exit(1)
	}()

	for _, line := range lines {
		addr, err := listenAddr(line, cfg)
		if err != nil {
			stopStarted()
			return err
		}
		if addr != "" {
			if err := portFree(addr); err != nil {
				stopStarted()
				return fmt.Errorf("%s: %w", line.id, err)
			}
		}
		env := daemonEnv(line)
		pid, err := start(base, line, cpu, env)
		if err != nil {
			stopStarted()
			return fmt.Errorf("%s: %w", line.id, err)
		}
		fmt.Printf("started %s daemon_id=%s pid %d %s\n", filepath.Base(line.path), line.id, pid, formatEnv(env))
		track(line)
		if addr == "" {
			// WriteHomeTimelineService only consumes RabbitMQ; require it to stay up.
			time.Sleep(time.Second)
			if !processAlive(pid) {
				stopStarted()
				return fmt.Errorf("%s exited right after start", line.id)
			}
			continue
		}
		if err := waitPort(addr, 90*time.Second); err != nil {
			stopStarted()
			return fmt.Errorf("%s did not listen on %s: %w", line.id, addr, err)
		}
	}

	if cmd == "start" {
		fmt.Printf("left %d daemons running\n", len(lines))
		return nil
	}
	snapshot := func() []tuple {
		startedMu.Lock()
		defer startedMu.Unlock()
		return append([]tuple(nil), started...)
	}
	switch cmd {
	case "init":
		err = initGraph(cfg, opts.graph, initWorkers)
	case "autoscale":
		err = autoscaleServices(base, cfg, snapshot(), users, opts, track)
	}
	stopStarted()
	return err
}
