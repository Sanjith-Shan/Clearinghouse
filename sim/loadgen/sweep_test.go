package loadgen

import (
	"context"
	"errors"
	"testing"
	"time"
)

// fakeRun pretends latency grows with rate: p99 = rate/10 ms, and errors appear at 800/s.
func fakeRun(calls *[]float64) RunAt {
	return func(_ context.Context, rate float64) (Summary, error) {
		*calls = append(*calls, rate)
		s := Summary{ResponseTimeMs: Percentiles{P99: rate / 10}}
		if rate >= 800 {
			s.ErrorRate = 0.05
		}
		return s, nil
	}
}

func TestSweepFindsTheHighestRateUnderTheSLOAndStops(t *testing.T) {
	var calls []float64
	res, err := Sweep(context.Background(), SweepConfig{Rates: []float64{400, 100, 200, 800, 1600},
		SLOP99: 50 * time.Millisecond, MaxErrorRate: 0.01}, fakeRun(&calls))
	if err != nil {
		t.Fatal(err)
	}
	if res.MaxRate != 400 {
		t.Errorf("max rate %v, want 400", res.MaxRate)
	}
	if len(calls) != 4 || calls[0] != 100 || calls[3] != 800 {
		t.Errorf("ran %v; want ascending, stopping at the first failure (800)", calls)
	}
	if res.Points[3].Pass || res.Points[3].Reason == "" {
		t.Errorf("800 should fail with a reason: %+v", res.Points[3])
	}
}

func TestSweepLatencyFailure(t *testing.T) {
	var calls []float64
	res, _ := Sweep(context.Background(), SweepConfig{Rates: []float64{100, 200, 400},
		SLOP99: 25 * time.Millisecond, MaxErrorRate: 0.01, KeepGoing: true}, fakeRun(&calls))
	if res.MaxRate != 200 || len(calls) != 3 {
		t.Errorf("max %v calls %v", res.MaxRate, calls)
	}
}

// A rate that passes above a failing one does not count: the answer must hold for
// every rate below it.
func TestSweepNeedsAnUnbrokenRun(t *testing.T) {
	run := func(_ context.Context, rate float64) (Summary, error) {
		p99 := 10.0
		if rate == 200 {
			p99 = 500
		}
		return Summary{ResponseTimeMs: Percentiles{P99: p99}}, nil
	}
	res, _ := Sweep(context.Background(), SweepConfig{Rates: []float64{100, 200, 400},
		SLOP99: 100 * time.Millisecond, KeepGoing: true}, run)
	if res.MaxRate != 100 {
		t.Errorf("max %v, want 100", res.MaxRate)
	}
	res, _ = Sweep(context.Background(), SweepConfig{Rates: []float64{200}, SLOP99: 100 * time.Millisecond}, run)
	if res.MaxRate != 0 {
		t.Errorf("max %v when the only rate failed", res.MaxRate)
	}
}

func TestSweepErrors(t *testing.T) {
	if _, err := Sweep(context.Background(), SweepConfig{}, nil); err == nil {
		t.Error("empty sweep accepted")
	}
	boom := errors.New("boom")
	_, err := Sweep(context.Background(), SweepConfig{Rates: []float64{1}}, func(context.Context, float64) (Summary, error) {
		return Summary{}, boom
	})
	if !errors.Is(err, boom) {
		t.Errorf("err %v", err)
	}
}

func TestEvaluate(t *testing.T) {
	if ok, _ := Evaluate(Summary{Interrupted: true}, time.Second, 1); ok {
		t.Error("interrupted run passed")
	}
	if ok, why := Evaluate(Summary{ResponseTimeMs: Percentiles{P99: 100}}, 100*time.Millisecond, 0); !ok {
		t.Errorf("p99 equal to the SLO failed: %s", why)
	}
}
