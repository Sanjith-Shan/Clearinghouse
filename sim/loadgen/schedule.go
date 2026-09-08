// Package loadgen is an open-loop HTTP load generator for Clearinghouse.
//
// Open loop means requests are sent at times fixed in advance by the target rate,
// whether or not earlier requests have come back. Every latency is measured from the
// time a request was supposed to be sent, so when the server stalls, the requests that
// should have gone out during the stall are charged for the wait. A closed-loop tool
// (send, wait, send again) quietly stops sending while the server is stuck and so never
// measures the stall. That is coordinated omission; docs/design/loadgen.md explains it.
package loadgen

import (
	"fmt"
	"math"
	"math/rand"
	"time"
)

// Arrival is how requests are spaced.
type Arrival string

const (
	// Constant spaces requests exactly 1/rate apart.
	Constant Arrival = "constant"
	// Poisson draws exponential gaps with mean 1/rate, which is how independent
	// clients arrive. Bursts happen, so queues form at rates a constant schedule
	// would not show.
	Poisson Arrival = "poisson"
)

// ParseArrival reads a flag value.
func ParseArrival(s string) (Arrival, error) {
	switch Arrival(s) {
	case Constant, Poisson:
		return Arrival(s), nil
	}
	return "", fmt.Errorf("unknown arrival %q (want constant or poisson)", s)
}

// A Schedule yields the intended send time of each request, as an offset from the
// start of the run. Offsets never decrease. It is called from one goroutine.
type Schedule interface {
	Next() time.Duration
}

// NewSchedule builds the schedule for an arrival process. rate is requests per second.
// seed makes a Poisson schedule reproducible; a constant schedule ignores it.
func NewSchedule(arrival Arrival, rate float64, seed int64) (Schedule, error) {
	if !(rate > 0) || math.IsInf(rate, 0) {
		return nil, fmt.Errorf("rate must be a positive number, got %v", rate)
	}
	switch arrival {
	case Constant:
		return &constantSchedule{rate: rate}, nil
	case Poisson:
		return &poissonSchedule{rate: rate, rng: rand.New(rand.NewSource(seed))}, nil
	}
	return nil, fmt.Errorf("unknown arrival %q", arrival)
}

// ConstantOffset is the intended offset of request i at a constant rate. It is computed
// from i directly rather than by adding 1/rate each time, so rounding error does not
// accumulate over a long run: request 3,600,000 at 1000/s is due at exactly one hour.
func ConstantOffset(i int64, rate float64) time.Duration {
	return time.Duration(math.Round(float64(i) * float64(time.Second) / rate))
}

type constantSchedule struct {
	rate float64
	i    int64
}

func (s *constantSchedule) Next() time.Duration {
	d := ConstantOffset(s.i, s.rate)
	s.i++
	return d
}

// poissonSchedule keeps the running sum in float64 seconds and rounds once per request,
// for the same reason ConstantOffset does.
type poissonSchedule struct {
	rate  float64
	rng   *rand.Rand
	sumS  float64
	begun bool
}

func (s *poissonSchedule) Next() time.Duration {
	// The first request goes at offset zero, like the constant schedule, so a run's
	// window starts with a request rather than a random gap.
	if s.begun {
		s.sumS += s.rng.ExpFloat64() / s.rate
	}
	s.begun = true
	return time.Duration(math.Round(s.sumS * float64(time.Second)))
}

// ExpectedCount is how many requests a schedule plans in a window, used to size
// buffers. For Poisson it adds six standard deviations so the buffer is effectively
// never too small.
func ExpectedCount(arrival Arrival, rate float64, window time.Duration) int64 {
	n := rate * window.Seconds()
	if arrival == Poisson {
		n += 6*math.Sqrt(n) + 16
	}
	return int64(math.Ceil(n)) + 1
}
