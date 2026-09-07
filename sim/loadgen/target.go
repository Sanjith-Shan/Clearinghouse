package loadgen

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"time"
)

// A Target does one iteration of the workload: one HTTP request, or a short sequence
// of them. The runner calls Do from many goroutines at once, so it must be safe for
// concurrent use. iter is the request's sequence number in the schedule.
type Target interface {
	Do(ctx context.Context, iter int64) Outcome
}

// Outcome is what one iteration did. Class is empty on success, otherwise the error
// class of the first step that failed (see Classify).
type Outcome struct {
	Class string
	Steps []StepResult
}

// StepResult is one HTTP call inside an iteration.
type StepResult struct {
	Name     string
	Status   int
	Class    string
	Duration time.Duration
}

// Error classes that are not HTTP statuses.
const (
	ClassTimeout    = "timeout"    // the client's own timeout fired
	ClassCanceled   = "canceled"   // the run ended (drain deadline or interrupt) mid-request
	ClassConnection = "connection" // could not connect or the connection broke
	ClassDropped    = "dropped"    // never sent: still queued when the drain deadline passed
	ClassOther      = "other"
)

// StatusClass is the class for an unexpected HTTP status, e.g. "http_503".
func StatusClass(status int) string { return fmt.Sprintf("http_%d", status) }

// Group folds a class into a coarse bucket for the summary: http_4xx, http_5xx or the
// class itself.
func Group(class string) string {
	if strings.HasPrefix(class, "http_") && len(class) == 8 {
		return "http_" + class[5:6] + "xx"
	}
	return class
}

// Classify turns a transport error into an error class.
func Classify(ctx context.Context, err error) string {
	if err == nil {
		return ""
	}
	if ctx.Err() != nil {
		return ClassCanceled
	}
	var ne net.Error
	if errors.Is(err, context.DeadlineExceeded) || (errors.As(err, &ne) && ne.Timeout()) {
		return ClassTimeout
	}
	var oe *net.OpError
	if errors.As(err, &oe) || errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
		return ClassConnection
	}
	return ClassOther
}

// NewHTTPClient returns a client whose connection pool matches the cap on outstanding
// requests, so the generator never opens more connections than it has requests in
// flight and never waits on its own pool.
func NewHTTPClient(maxOutstanding int, timeout time.Duration) *http.Client {
	tr := &http.Transport{
		Proxy:               nil,
		DialContext:         (&net.Dialer{Timeout: 5 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
		MaxIdleConns:        maxOutstanding,
		MaxIdleConnsPerHost: maxOutstanding,
		MaxConnsPerHost:     maxOutstanding,
		IdleConnTimeout:     90 * time.Second,
		DisableCompression:  true,
	}
	return &http.Client{Transport: tr, Timeout: timeout}
}

// Request is the simplest Target: the same request every time.
type Request struct {
	Client *http.Client
	Method string
	URL    string
	Header http.Header
	Body   string
	// Expect is the status that counts as success. Zero means any 2xx.
	Expect int
}

// Do sends the request once and reads the whole response.
func (r *Request) Do(ctx context.Context, _ int64) Outcome {
	var body io.Reader
	if r.Body != "" {
		body = strings.NewReader(r.Body)
	}
	req, err := http.NewRequestWithContext(ctx, r.Method, r.URL, body)
	if err != nil {
		return Outcome{Class: ClassOther}
	}
	for k, vs := range r.Header {
		req.Header[k] = vs
	}
	step := SendAndDiscard(ctx, r.Client, req, r.Expect)
	step.Name = r.Method + " " + req.URL.Path
	return Outcome{Class: step.Class, Steps: []StepResult{step}}
}

// SendAndDiscard sends req, drains the body so the connection is reused, and times the
// whole exchange including the body.
func SendAndDiscard(ctx context.Context, client *http.Client, req *http.Request, expect int) StepResult {
	start := time.Now()
	resp, err := client.Do(req)
	if err != nil {
		return StepResult{Class: Classify(ctx, err), Duration: time.Since(start)}
	}
	_, err = io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	res := StepResult{Status: resp.StatusCode, Duration: time.Since(start)}
	switch {
	case err != nil:
		res.Class = Classify(ctx, err)
	case !StatusOK(resp.StatusCode, expect):
		res.Class = StatusClass(resp.StatusCode)
	}
	return res
}

// StatusOK says whether status is the expected one (any 2xx when expect is zero).
func StatusOK(status, expect int) bool {
	if expect == 0 {
		return status >= 200 && status < 300
	}
	return status == expect
}
