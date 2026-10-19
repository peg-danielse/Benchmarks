package main

import (
	"os"
	"strings"
	"testing"
	"time"
)

func TestBucketBounds(t *testing.T) {
	values := []uint64{0, 1, 15, 16, 17, 31, 32, 100, 999, 1 << 20, 123456789, 1<<63 + 5, ^uint64(0)}
	for _, v := range values {
		b := bucketOf(v)
		if b < 0 || b >= histBuckets {
			t.Fatalf("bucketOf(%d) = %d out of range", v, b)
		}
		if v > bucketUpper(b) {
			t.Fatalf("%d above its bucket %d upper %d", v, b, bucketUpper(b))
		}
		if b > 0 && v <= bucketUpper(b-1) {
			t.Fatalf("%d at or below previous bucket upper %d", v, bucketUpper(b-1))
		}
		if v >= 16 && float64(bucketUpper(b)-v) > float64(v)/8 {
			t.Fatalf("bucket for %d too wide: upper %d", v, bucketUpper(b))
		}
	}
	for v := uint64(0); v < 5000; v++ {
		if bucketOf(v) > bucketOf(v+1) {
			t.Fatalf("not monotonic at %d", v)
		}
	}
	if bucketUpper(histBuckets-1) != ^uint64(0) {
		t.Fatalf("last bucket upper %d", bucketUpper(histBuckets-1))
	}
}

func TestSnapPercentile(t *testing.T) {
	var s snap
	if s.percentile(0.95) != 0 {
		t.Fatal("empty percentile not 0")
	}
	for v := uint64(1); v <= 100; v++ {
		s.hist[bucketOf(v)]++
	}
	if got := s.percentile(0.95); got != 95 {
		t.Fatalf("p95 = %d", got) // 95 is the upper edge of bucket [88,95]
	}
	if got := s.percentile(0.5); got < 50 || got > 55 {
		t.Fatalf("p50 = %d", got)
	}
	if got := s.percentile(1); got != 103 {
		t.Fatalf("p100 = %d", got) // 100 lands in [96,103]
	}
}

func TestSnapshotDiff(t *testing.T) {
	rec := newRecorder()
	rec.shard(0).add(uint64(time.Millisecond))
	rec.shard(0).sent.Add(1)
	before := rec.snapshot()
	for i := 0; i < 200; i++ {
		sh := rec.shard(i)
		sh.sent.Add(1)
		sh.add(uint64(10 * time.Millisecond))
	}
	rec.shard(3).errs.Add(4)
	d := rec.snapshot().sub(before)
	if d.sent != 200 || d.done != 200 || d.errs != 4 {
		t.Fatalf("diff %d/%d/%d", d.sent, d.done, d.errs)
	}
	if d.sumNs != 200*uint64(10*time.Millisecond) {
		t.Fatalf("sum %d", d.sumNs)
	}
	var n uint64
	for _, c := range d.hist {
		n += c
	}
	if n != 200 {
		t.Fatalf("hist count %d", n)
	}
	if p := d.percentile(0.95); p < uint64(10*time.Millisecond) || p > uint64(10*time.Millisecond)*9/8 {
		t.Fatalf("p95 %d excludes the 1ms sample before the window? got %d", p, p)
	}
}

func TestCountCPUs(t *testing.T) {
	for spec, want := range map[string]int{"60": 1, "60-63": 4, "1,5,18,22": 4, "5,26": 2, "60-61,63": 3, "?": 0, "": 0, "x": 0, "5-3": 0} {
		if got := countCPUs(spec); got != want {
			t.Fatalf("countCPUs(%q) = %d want %d", spec, got, want)
		}
	}
}

func TestParseUsage(t *testing.T) {
	got, ok := parseUsage("usage_usec 1500000\nuser_usec 1000000\nsystem_usec 500000\n")
	if !ok || got != 1500*time.Millisecond {
		t.Fatalf("parseUsage = %v %v", got, ok)
	}
	if _, ok := parseUsage("user_usec 3\n"); ok {
		t.Fatal("parseUsage without usage_usec ok")
	}
}

func TestGenMeterBound(t *testing.T) {
	busy := time.Duration(0)
	cpus := "60-61"
	g := &genMeter{cpus: func() string { return cpus }, busy: func() (time.Duration, bool) { return busy, true }, max: 2}
	s := g.begin()
	time.Sleep(20 * time.Millisecond)
	busy = 2 * time.Second // far more than 2 cores over 20ms
	got := g.end(s)
	if !strings.Contains(got, "gen_cpus 60-61") || !strings.Contains(got, "gen_resized 0") || !strings.Contains(got, "gen_bound 1") {
		t.Fatalf("end = %q", got)
	}
	s = g.begin()
	cpus = "60-62"
	if got := g.end(s); !strings.Contains(got, "gen_resized 1") || !strings.Contains(got, "gen_bound 0") {
		t.Fatalf("end after resize = %q", got)
	}
}

func TestTailLoadgen(t *testing.T) {
	path := t.TempDir() + "/gen.out"
	if err := writeFile(path, "route geo clients 1\nloadgen done\nignored\n"); err != nil {
		t.Fatal(err)
	}
	var out strings.Builder
	if err := tailLoadgen(path, func() bool { return true }, &out, time.Millisecond); err != nil {
		t.Fatal(err)
	}
	if out.String() != "route geo clients 1\nloadgen done\n" {
		t.Fatalf("copied %q", out.String())
	}
	if err := writeFile(path, "route geo\nloadgen error: boom\n"); err != nil {
		t.Fatal(err)
	}
	if err := tailLoadgen(path, func() bool { return true }, &strings.Builder{}, time.Millisecond); err == nil || !strings.Contains(err.Error(), "boom") {
		t.Fatalf("error line: %v", err)
	}
	if err := writeFile(path, "route geo\npartial"); err != nil {
		t.Fatal(err)
	}
	if err := tailLoadgen(path, func() bool { return false }, &strings.Builder{}, time.Millisecond); err == nil {
		t.Fatal("dead loadgen without done line returned nil")
	}
}

func writeFile(path, text string) error {
	return os.WriteFile(path, []byte(text), 0o644)
}
