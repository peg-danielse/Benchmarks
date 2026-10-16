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
	samples := []uint64{
		1000 * uint64(time.Microsecond),
		2000 * uint64(time.Microsecond),
		3000 * uint64(time.Microsecond),
		4000 * uint64(time.Microsecond),
	}
	got := readWindow(
		snap{sent: 10, done: 8, errs: 1},
		snap{sent: 110, done: 104, errs: 3},
		time.Second,
		samples,
	)
	if got.arrivalRate != 100 || got.serviceRate != 96 || got.errors != 2 {
		t.Fatalf("rates %+v", got)
	}
	if math.Abs(got.avgUs-2500) > 0.1 {
		t.Fatalf("avg_us %v", got.avgUs)
	}
	if math.Abs(got.p95Us-4000) > 0.1 {
		t.Fatalf("p95_us %v", got.p95Us)
	}
}
