package loadgen

import (
	"context"
	"fmt"
	"sort"
	"time"
)

// SweepConfig runs the same workload at several rates to find the highest one that
// meets a latency objective.
type SweepConfig struct {
	Rates []float64
	// SLOP99 is the objective on response time (from intended send), p99.
	SLOP99 time.Duration
	// MaxErrorRate is the share of planned requests allowed to fail (including drops).
	MaxErrorRate float64
	// KeepGoing runs every rate even after one fails. By default the sweep stops at
	// the first failure: past saturation, every higher rate fails too and only
	// takes longer to say so.
	KeepGoing bool
}

// SweepPoint is one rate's outcome.
type SweepPoint struct {
	Rate    float64 `json:"rate"`
	Pass    bool    `json:"pass"`
	Reason  string  `json:"reason,omitempty"`
	P99Ms   float64 `json:"p99_ms"`
	Summary Summary `json:"summary"`
}

// SweepResult is the whole sweep. MaxRate is the highest rate that passed with every
// lower rate also passing, or zero if the lowest rate failed.
type SweepResult struct {
	SLOP99Ms     float64      `json:"slo_p99_ms"`
	MaxErrorRate float64      `json:"max_error_rate"`
	MaxRate      float64      `json:"max_rate_meeting_slo"`
	Points       []SweepPoint `json:"points"`
}

// Evaluate judges one run against the objective.
func Evaluate(s Summary, slo time.Duration, maxErrorRate float64) (bool, string) {
	sloMs := float64(slo) / float64(time.Millisecond)
	switch {
	case s.Interrupted:
		return false, "interrupted"
	case s.ErrorRate > maxErrorRate:
		return false, fmt.Sprintf("error rate %.4f above %.4f", s.ErrorRate, maxErrorRate)
	case s.ResponseTimeMs.P99 > sloMs:
		return false, fmt.Sprintf("p99 %.3fms above %.3fms", s.ResponseTimeMs.P99, sloMs)
	}
	return true, ""
}

// RunAt runs the workload at one rate and returns its summary.
type RunAt func(ctx context.Context, rate float64) (Summary, error)

// Sweep runs the rates in ascending order.
func Sweep(ctx context.Context, cfg SweepConfig, run RunAt) (SweepResult, error) {
	rates := append([]float64(nil), cfg.Rates...)
	sort.Float64s(rates)
	out := SweepResult{SLOP99Ms: float64(cfg.SLOP99) / float64(time.Millisecond), MaxErrorRate: cfg.MaxErrorRate}
	if len(rates) == 0 {
		return out, fmt.Errorf("no rates to sweep")
	}
	unbroken := true
	for _, r := range rates {
		if ctx.Err() != nil {
			break
		}
		s, err := run(ctx, r)
		if err != nil {
			return out, fmt.Errorf("rate %v: %w", r, err)
		}
		pass, why := Evaluate(s, cfg.SLOP99, cfg.MaxErrorRate)
		out.Points = append(out.Points, SweepPoint{Rate: r, Pass: pass, Reason: why, P99Ms: s.ResponseTimeMs.P99, Summary: s})
		if pass && unbroken {
			out.MaxRate = r
		}
		if !pass {
			unbroken = false
			if !cfg.KeepGoing {
				break
			}
		}
	}
	return out, nil
}
