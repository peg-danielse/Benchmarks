package main

import (
	"context"
	"errors"
	"fmt"
	"math/rand"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	sn "socialnetwork/goperate/social_network"
)

func defaultGraph() string {
	return filepath.Join(socialRoot(), "datasets/social-graph/socfb-Reed98/socfb-Reed98.edges")
}

// alreadyStored matches the messages the C++ services return for a user or
// edge that exists, the same test as operate/graph.cpp.
func alreadyStored(err error) bool {
	var se *sn.ServiceException
	if !errors.As(err, &se) {
		return false
	}
	m := se.GetMessage()
	return strings.Contains(m, "already existed") || strings.Contains(m, "matching document") ||
		strings.Contains(m, "No matching")
}

// initGraph registers every user of the graph as user<id>/password and
// follows every edge, the Go equivalent of `operate init` (C++). It is only
// run by the explicit init subcommand.
func initGraph(cfg serviceConfig, graphPath string, workers int) error {
	w, err := loadGraph(graphPath)
	if err != nil {
		return err
	}
	userAddr, err := cfg.address("user-service")
	if err != nil {
		return err
	}
	graphAddr, err := cfg.address("social-graph-service")
	if err != nil {
		return err
	}
	edges := make([][2]int64, 0, len(w.edges))
	for e := range w.edges {
		edges = append(edges, e)
	}
	fmt.Printf("init  %s users=%d edges=%d\n", graphPath, len(w.users), len(edges))
	carrier := map[string]string{}

	err = parallel(workers, len(w.users), userAddr, "registered", func(ctx context.Context, c *tconn, i int) error {
		id := w.users[i]
		return sn.NewUserServiceClient(c.client).RegisterUserWithId(ctx, rand.Int63(), "First", "Last",
			username(id), "password", id, carrier)
	})
	if err != nil {
		return fmt.Errorf("register: %w", err)
	}
	err = parallel(workers, len(edges), graphAddr, "followed", func(ctx context.Context, c *tconn, i int) error {
		e := edges[i]
		return sn.NewSocialGraphServiceClient(c.client).Follow(ctx, rand.Int63(), e[0], e[1], carrier)
	})
	if err != nil {
		return fmt.Errorf("follow: %w", err)
	}
	fmt.Printf("init  done users=%d edges=%d\n", len(w.users), len(edges))
	return nil
}

// parallel runs fn for indexes 0..n-1 on workers connections, retrying each
// item up to 6 times and treating "already stored" as success.
func parallel(workers, n int, addr, verb string, fn func(context.Context, *tconn, int) error) error {
	var (
		next, done atomic.Int64
		once       sync.Once
		failed     error
		wg         sync.WaitGroup
	)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	fail := func(err error) { once.Do(func() { failed = err; cancel() }) }
	for k := 0; k < workers; k++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			c, err := dialThrift(addr)
			if err != nil {
				fail(err)
				return
			}
			defer func() { c.trans.Close() }()
			for ctx.Err() == nil {
				i := int(next.Add(1) - 1)
				if i >= n {
					return
				}
				var last error
				for attempt := 0; attempt < 6; attempt++ {
					last = fn(ctx, c, i)
					if last == nil || alreadyStored(last) {
						last = nil
						break
					}
					if transportBroken(last) {
						c.trans.Close()
						if c, err = dialThrift(addr); err != nil {
							fail(err)
							return
						}
					}
					time.Sleep(time.Duration(20*(attempt+1)) * time.Millisecond)
				}
				if last != nil {
					fail(fmt.Errorf("item %d: %w", i, last))
					return
				}
				if d := done.Add(1); d%2000 == 0 || d == int64(n) {
					fmt.Printf("init  %s %d/%d\n", verb, d, n)
				}
			}
		}()
	}
	wg.Wait()
	return failed
}
