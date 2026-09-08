package loadgen

import (
	"context"
	"errors"
	"sync"
	"time"

	hdrhistogram "github.com/HdrHistogram/hdrhistogram-go"
)

// Histogram range, in microseconds: 1us to 10 minutes at three significant figures.
// Anything slower is clamped to the top and still counted.
const (
	histLowest  = 1
	histHighest = int64(10 * time.Minute / time.Microsecond)
	histSigFigs = 3
)

func newHist() *hdrhistogram.Histogram { return hdrhistogram.New(histLowest, histHighest, histSigFigs) }

func record(h *hdrhistogram.Histogram, d time.Duration) {
	us := int64(d / time.Microsecond)
	if us < histLowest {
		us = histLowest
	}
	if us > histHighest {
		us = histHighest
	}
	_ = h.RecordValue(us) // cannot fail: the value was clamped into range
}

// Config is one fixed-rate run.
type Config struct {
	Rate     float64       // requests (iterations) per second
	Duration time.Duration // how long to keep scheduling requests
	Arrival  Arrival
	Seed     int64
	// MaxOutstanding caps requests in flight. It is also the number of workers and
	// the size of the connection pool. A request due while all are busy waits in the
	// queue, and the wait is part of its latency.
	MaxOutstanding int
	// DrainTimeout is how long after the schedule ends queued and in-flight requests
	// may still finish. Requests still queued then are dropped (counted, with a
	// lower-bound latency); requests still in flight are canceled.
	DrainTimeout time.Duration
	// LateThreshold: a request sent more than this long after its intended time
	// counts as late.
	LateThreshold time.Duration
}

func (c *Config) validate() error {
	switch {
	case !(c.Rate > 0):
		return errors.New("rate must be positive")
	case c.Duration <= 0:
		return errors.New("duration must be positive")
	case c.MaxOutstanding < 1:
		return errors.New("max outstanding must be at least 1")
	case c.DrainTimeout < 0 || c.LateThreshold < 0:
		return errors.New("drain timeout and late threshold must not be negative")
	}
	return nil
}

// StepStats are the per-step numbers across a run.
type StepStats struct {
	Count   int64
	Errors  map[string]int64
	Service *hdrhistogram.Histogram
}

// Result is everything a run measured. Histograms are in microseconds.
type Result struct {
	Config Config
	Start  time.Time
	// Elapsed runs from Start to the last completion (or drop).
	Elapsed time.Duration

	Planned           int64 // requests the schedule produced inside the window
	Sent              int64 // requests handed to the target
	SentInWindow      int64 // of those, sent before the window closed
	Completed         int64 // iterations that returned, success or not
	CompletedInWindow int64
	OK                int64
	Late              int64 // sent more than LateThreshold after their intended time
	Dropped           int64 // never sent
	Interrupted       bool  // the caller canceled the run before the schedule ended

	// Response is intended send time to completion: the latency a user would see.
	// It includes dropped requests at a lower bound (see Config.DrainTimeout).
	Response *hdrhistogram.Histogram
	// Service is actual send time to completion: what the server spent, plus the
	// network. The gap between Response and Service is queueing the server caused.
	Service *hdrhistogram.Histogram
	// SendDelay is actual send time minus intended send time.
	SendDelay *hdrhistogram.Histogram

	Errors    map[string]int64 // by class, over iterations
	Steps     map[string]*StepStats
	StepOrder []string
}

type job struct {
	i        int64
	intended time.Time
}

type recorder struct {
	mu        sync.Mutex
	res       *Result
	windowEnd time.Time
	lastEnd   time.Time
}

func (r *recorder) done(j job, sendAt, end time.Time, out Outcome) {
	r.mu.Lock()
	defer r.mu.Unlock()
	res := r.res
	res.Completed++
	if end.Before(r.windowEnd) {
		res.CompletedInWindow++
	}
	if out.Class == "" {
		res.OK++
	} else {
		res.Errors[out.Class]++
	}
	record(res.Response, end.Sub(j.intended))
	record(res.Service, end.Sub(sendAt))
	for _, s := range out.Steps {
		st := res.Steps[s.Name]
		if st == nil {
			st = &StepStats{Errors: map[string]int64{}, Service: newHist()}
			res.Steps[s.Name] = st
			res.StepOrder = append(res.StepOrder, s.Name)
		}
		st.Count++
		if s.Class != "" {
			st.Errors[s.Class]++
		}
		record(st.Service, s.Duration)
	}
	if end.After(r.lastEnd) {
		r.lastEnd = end
	}
}

func (r *recorder) sent(j job, sendAt time.Time) {
	r.mu.Lock()
	defer r.mu.Unlock()
	res := r.res
	res.Sent++
	if sendAt.Before(r.windowEnd) {
		res.SentInWindow++
	}
	delay := sendAt.Sub(j.intended)
	record(res.SendDelay, delay)
	if delay > res.Config.LateThreshold {
		res.Late++
	}
}

// dropped records a request that was never sent. Its true latency is unknown but at
// least now minus its intended time, and that lower bound goes into Response: leaving
// it out would let a server that never answers look fast.
func (r *recorder) dropped(j job, now time.Time) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.res.Dropped++
	r.res.Errors[ClassDropped]++
	record(r.res.Response, now.Sub(j.intended))
	if now.After(r.lastEnd) {
		r.lastEnd = now
	}
}

// Run drives target at cfg.Rate for cfg.Duration and returns what it measured.
// Canceling ctx stops scheduling; anything still queued is counted as dropped.
func Run(ctx context.Context, cfg Config, target Target) (*Result, error) {
	if err := cfg.validate(); err != nil {
		return nil, err
	}
	sched, err := NewSchedule(cfg.Arrival, cfg.Rate, cfg.Seed)
	if err != nil {
		return nil, err
	}

	res := &Result{
		Config: cfg, Response: newHist(), Service: newHist(), SendDelay: newHist(),
		Errors: map[string]int64{}, Steps: map[string]*StepStats{},
	}
	// The queue holds requests that are due but have no free worker. It is sized for
	// the whole run so the dispatcher never blocks on it; if it ever did, the
	// dispatcher would fall behind, which is still measured correctly because every
	// job carries its intended time.
	queueCap := ExpectedCount(cfg.Arrival, cfg.Rate, cfg.Duration)
	if queueCap > 1<<20 {
		queueCap = 1 << 20
	}
	jobs := make(chan job, queueCap)

	start := time.Now()
	res.Start = start
	rec := &recorder{res: res, windowEnd: start.Add(cfg.Duration), lastEnd: start}

	// Requests run under rctx, which ends at the drain deadline, so nothing outlives
	// the run.
	rctx, cancel := context.WithDeadline(ctx, start.Add(cfg.Duration+cfg.DrainTimeout))
	defer cancel()

	var wg sync.WaitGroup
	for w := 0; w < cfg.MaxOutstanding; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := range jobs {
				if rctx.Err() != nil {
					rec.dropped(j, time.Now())
					continue
				}
				sendAt := time.Now()
				rec.sent(j, sendAt)
				out := target.Do(rctx, j.i)
				rec.done(j, sendAt, time.Now(), out)
			}
		}()
	}

	res.Planned, res.Interrupted = dispatch(ctx, sched, start, cfg.Duration, jobs)
	close(jobs)
	wg.Wait()
	res.Elapsed = rec.lastEnd.Sub(start)
	return res, nil
}

// dispatch puts each request on the queue at its intended time. It never waits for a
// response: that is what makes the load open loop.
func dispatch(ctx context.Context, sched Schedule, start time.Time, window time.Duration, jobs chan<- job) (int64, bool) {
	timer := time.NewTimer(time.Hour)
	timer.Stop()
	defer timer.Stop()
	var n int64
	for {
		off := sched.Next()
		if off >= window {
			return n, false
		}
		intended := start.Add(off)
		if wait := time.Until(intended); wait > 0 {
			timer.Reset(wait)
			select {
			case <-timer.C:
			case <-ctx.Done():
				return n, true
			}
		}
		select {
		case jobs <- job{i: n, intended: intended}:
			n++
		case <-ctx.Done():
			return n, true
		}
	}
}
