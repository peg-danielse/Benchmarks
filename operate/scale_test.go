package main

import (
	"math"
	"testing"
	"time"
)

func TestCPUSpec(t *testing.T) {
	if got := cpuSpec(1); got != "1" {
		t.Fatalf("cpuSpec(1) = %q", got)
	}
	if got := cpuSpec(4); got != "1-4" {
		t.Fatalf("cpuSpec(4) = %q", got)
	}
	if got := cpuSpec(32); got != "1-32" {
		t.Fatalf("cpuSpec(32) = %q", got)
	}
}

func TestPerSecond(t *testing.T) {
	if got := perSecond(1000, time.Second); got != 1000 {
		t.Fatalf("perSecond = %d", got)
	}
	if got := perSecond(500, 2*time.Second); got != 250 {
		t.Fatalf("perSecond = %d", got)
	}
	if got := perSecond(0, time.Second); got != 0 {
		t.Fatalf("perSecond = %d", got)
	}
}

func TestPercentile(t *testing.T) {
	samples := make([]uint64, 100)
	for i := range samples {
		samples[i] = uint64(i + 1)
	}
	if got := percentile(samples, 0.95); got != 95 {
		t.Fatalf("p95 = %d", got)
	}
	if got := percentile(nil, 0.95); got != 0 {
		t.Fatalf("empty p95 = %d", got)
	}
}

func TestReadWindow(t *testing.T) {
	rec := newRecorder()
	before := rec.snapshot()
	for i, us := range []uint64{1000, 2000, 3000, 4000} {
		sh := rec.shard(i)
		sh.sent.Add(1)
		sh.add(us * uint64(time.Microsecond))
	}
	rec.shard(9).sent.Add(96)
	rec.shard(9).errs.Add(2)
	for i := 0; i < 92; i++ {
		rec.shard(i).done.Add(1) // counted but outside the histogram: avg uses sum/done
	}
	got := readWindow(before, rec.snapshot(), time.Second)
	if got.arrivalRate != 100 || got.serviceRate != 96 || got.errors != 2 {
		t.Fatalf("rates %+v", got)
	}
	if math.Abs(got.avgUs-10000.0/96) > 0.1 {
		t.Fatalf("avg_us %v", got.avgUs)
	}
	// 4000us sits in a bucket at most 12.5% wide.
	if got.p95Us < 4000 || got.p95Us > 4000*1.125 {
		t.Fatalf("p95_us %v", got.p95Us)
	}
}
