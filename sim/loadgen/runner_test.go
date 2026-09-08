package loadgen

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func ms(us int64) time.Duration { return time.Duration(us) * time.Microsecond }

func get(t *testing.T, srv *httptest.Server, maxOut int) *Request {
	t.Helper()
	return &Request{Client: NewHTTPClient(maxOut, 10*time.Second), Method: "GET", URL: srv.URL + "/"}
}

// The coordinated omission demonstration. The server stalls once for a second. With
// one request allowed in flight, every request due during that second waits behind
// the stalled one. A closed-loop tool measuring from the actual send (service time)
// sees one slow request and a clean distribution; measuring from the intended send
// (response time) shows the second of queueing that about half the requests suffered.
func TestStallShowsUpInResponseTimeButNotServiceTime(t *testing.T) {
	const stall = time.Second
	var once sync.Once
	begin := time.Now()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if time.Since(begin) > 300*time.Millisecond {
			once.Do(func() { time.Sleep(stall) })
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	cfg := Config{Rate: 200, Duration: 2 * time.Second, Arrival: Constant, MaxOutstanding: 1,
		DrainTimeout: 5 * time.Second, LateThreshold: 10 * time.Millisecond}
	res, err := Run(context.Background(), cfg, get(t, srv, 1))
	if err != nil {
		t.Fatal(err)
	}

	t.Logf("service  %+v", PercentilesOf(res.Service))
	t.Logf("response %+v", PercentilesOf(res.Response))
	if res.Planned != 400 || res.OK != 400 || res.Dropped != 0 {
		t.Fatalf("planned %d ok %d dropped %d, want 400/400/0 (errors %v)", res.Planned, res.OK, res.Dropped, res.Errors)
	}
	// Service time: exactly one request took the stall.
	if max := ms(res.Service.Max()); max < stall {
		t.Errorf("service max %v, want at least the %v stall", max, stall)
	}
	if p99 := ms(res.Service.ValueAtQuantile(99)); p99 > 100*time.Millisecond {
		t.Errorf("service p99 %v: the stall should be invisible below the max", p99)
	}
	// Response time: ~200 requests were due during the stall, waiting from ~1s down
	// to ~0, so the upper quartile is hundreds of milliseconds.
	if p75 := ms(res.Response.ValueAtQuantile(75)); p75 < 300*time.Millisecond {
		t.Errorf("response p75 %v, want the queueing behind the stall (>= 300ms)", p75)
	}
	if p90 := ms(res.Response.ValueAtQuantile(90)); p90 < 600*time.Millisecond {
		t.Errorf("response p90 %v, want >= 600ms", p90)
	}
	if max := ms(res.Response.Max()); max < stall {
		t.Errorf("response max %v, want at least %v", max, stall)
	}
	if res.Late < 150 {
		t.Errorf("late %d, want the ~200 requests queued behind the stall", res.Late)
	}
}

func TestAchievedRateMatchesTargetOnAFastServer(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()

	const rate = 2000.0
	cfg := Config{Rate: rate, Duration: time.Second, Arrival: Constant, MaxOutstanding: 32,
		DrainTimeout: 5 * time.Second, LateThreshold: time.Millisecond}
	res, err := Run(context.Background(), cfg, get(t, srv, 32))
	if err != nil {
		t.Fatal(err)
	}
	if res.Planned != 2000 || res.Sent != 2000 || res.OK != 2000 {
		t.Fatalf("planned %d sent %d ok %d, want 2000 each (errors %v)", res.Planned, res.Sent, res.OK, res.Errors)
	}
	sent := float64(res.SentInWindow) / cfg.Duration.Seconds()
	if sent < rate*0.95 || sent > rate*1.001 {
		t.Errorf("sent %.0f/s inside the window, want %.0f within 5%% (send delay %+v)", sent, rate, PercentilesOf(res.SendDelay))
	}
	if res.Response.TotalCount() != 2000 || res.Service.TotalCount() != 2000 {
		t.Errorf("histogram counts %d/%d", res.Response.TotalCount(), res.Service.TotalCount())
	}
}

// A server that never answers must not make the run look fast: requests that could
// not be sent are counted as dropped and still recorded at a lower-bound latency.
func TestRequestsThatNeverSendAreCountedNotSkipped(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		<-r.Context().Done()
	}))
	defer srv.Close()

	cfg := Config{Rate: 50, Duration: 200 * time.Millisecond, Arrival: Constant, MaxOutstanding: 1,
		DrainTimeout: 300 * time.Millisecond, LateThreshold: time.Millisecond}
	res, err := Run(context.Background(), cfg, get(t, srv, 1))
	if err != nil {
		t.Fatal(err)
	}
	if res.Planned != 10 || res.Sent != 1 || res.Dropped != 9 {
		t.Fatalf("planned %d sent %d dropped %d, want 10/1/9", res.Planned, res.Sent, res.Dropped)
	}
	if res.Errors[ClassDropped] != 9 || res.Errors[ClassCanceled] != 1 {
		t.Errorf("errors %v, want 9 dropped and 1 canceled", res.Errors)
	}
	if res.Response.TotalCount() != 10 {
		t.Errorf("response histogram has %d values, want all 10", res.Response.TotalCount())
	}
	// The last request was due at 180ms and dropped at the 500ms drain deadline.
	if min := ms(res.Response.Min()); min < 250*time.Millisecond {
		t.Errorf("fastest recorded response %v; dropped requests must carry their wait", min)
	}
}

func TestInterruptStopsSchedulingAndCountsWhatWasQueued(t *testing.T) {
	var hits atomic.Int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
	}))
	defer srv.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Millisecond)
	defer cancel()
	cfg := Config{Rate: 100, Duration: 10 * time.Second, Arrival: Constant, MaxOutstanding: 4,
		DrainTimeout: time.Second, LateThreshold: time.Millisecond}
	res, err := Run(ctx, cfg, get(t, srv, 4))
	if err != nil {
		t.Fatal(err)
	}
	if !res.Interrupted {
		t.Error("not marked interrupted")
	}
	if res.Planned > 20 {
		t.Errorf("kept scheduling after the interrupt: planned %d", res.Planned)
	}
	if res.Completed+res.Dropped != res.Planned {
		t.Errorf("completed %d + dropped %d != planned %d", res.Completed, res.Dropped, res.Planned)
	}
}

func TestErrorStatusesAreClassified(t *testing.T) {
	var n atomic.Int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch n.Add(1) % 3 {
		case 0:
			w.WriteHeader(http.StatusServiceUnavailable)
		case 1:
			w.WriteHeader(http.StatusTooManyRequests)
		default:
			w.WriteHeader(http.StatusOK)
		}
	}))
	defer srv.Close()
	cfg := Config{Rate: 300, Duration: 100 * time.Millisecond, Arrival: Constant, MaxOutstanding: 1,
		DrainTimeout: time.Second, LateThreshold: time.Millisecond}
	res, err := Run(context.Background(), cfg, get(t, srv, 1))
	if err != nil {
		t.Fatal(err)
	}
	if res.OK != 10 || res.Errors["http_503"] != 10 || res.Errors["http_429"] != 10 {
		t.Fatalf("ok %d errors %v", res.OK, res.Errors)
	}
	s := Summarize(res, Meta{Target: srv.URL})
	if s.ErrorsByGroup["http_5xx"] != 10 || s.ErrorsByGroup["http_4xx"] != 10 {
		t.Errorf("groups %v", s.ErrorsByGroup)
	}
	if len(s.Steps) != 1 || s.Steps[0].Count != 30 || s.Steps[0].Errors["http_503"] != 10 {
		t.Errorf("steps %+v", s.Steps)
	}
}

func TestConfigValidation(t *testing.T) {
	bad := []Config{
		{Rate: 0, Duration: time.Second, MaxOutstanding: 1, Arrival: Constant},
		{Rate: 1, Duration: 0, MaxOutstanding: 1, Arrival: Constant},
		{Rate: 1, Duration: time.Second, MaxOutstanding: 0, Arrival: Constant},
		{Rate: 1, Duration: time.Second, MaxOutstanding: 1, Arrival: "burst"},
	}
	for _, c := range bad {
		if _, err := Run(context.Background(), c, &Request{}); err == nil {
			t.Errorf("accepted %+v", c)
		}
	}
}
