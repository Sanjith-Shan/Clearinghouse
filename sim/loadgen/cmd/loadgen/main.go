// Command loadgen sends open-loop HTTP load at a fixed rate and reports latency
// percentiles measured from each request's intended send time.
//
//	loadgen -url http://127.0.0.1:4000/healthz -rate 500 -duration 30s -out results/raw/loadgen/x
package main

import (
	"context"
	"flag"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"time"

	"github.com/Sanjith-Shan/Clearinghouse/sim/loadgen"
)

type headerFlags []string

func (h *headerFlags) String() string     { return strings.Join(*h, ", ") }
func (h *headerFlags) Set(v string) error { *h = append(*h, v); return nil }

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "loadgen:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	fs := flag.NewFlagSet("loadgen", flag.ContinueOnError)
	target := fs.String("url", "", "URL to request (required)")
	method := fs.String("method", "GET", "HTTP method")
	body := fs.String("body", "", "request body")
	expect := fs.Int("expect", 0, "status that counts as success (0 means any 2xx)")
	var headers headerFlags
	fs.Var(&headers, "header", "request header 'Name: value' (repeatable)")
	rate := fs.Float64("rate", 100, "target rate, requests per second")
	duration := fs.Duration("duration", 10*time.Second, "measured duration")
	warmup := fs.Duration("warmup", 0, "unmeasured warmup at the same rate before the measured run")
	arrival := fs.String("arrival", "constant", "constant or poisson")
	seed := fs.Int64("seed", 1, "seed for poisson arrivals")
	maxOut := fs.Int("max-outstanding", 64, "cap on requests in flight (workers and connections)")
	timeout := fs.Duration("timeout", 10*time.Second, "per-request client timeout")
	drain := fs.Duration("drain", 0, "time after the schedule ends for queued requests to finish (default timeout+1s)")
	late := fs.Duration("late-threshold", time.Millisecond, "send delay above which a request counts as late")
	label := fs.String("label", "", "free-text machine label for the summary, e.g. 'laptop, server on same host'")
	out := fs.String("out", "", "directory for summary.json and .hgrm files")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *target == "" {
		return fmt.Errorf("-url is required")
	}
	arr, err := loadgen.ParseArrival(*arrival)
	if err != nil {
		return err
	}
	if *drain == 0 {
		*drain = *timeout + time.Second
	}
	h := http.Header{}
	for _, raw := range headers {
		k, v, ok := strings.Cut(raw, ":")
		if !ok {
			return fmt.Errorf("header %q is not 'Name: value'", raw)
		}
		h.Add(strings.TrimSpace(k), strings.TrimSpace(v))
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()

	client := loadgen.NewHTTPClient(*maxOut, *timeout)
	tgt := &loadgen.Request{Client: client, Method: *method, URL: *target, Header: h, Body: *body, Expect: *expect}
	cfg := loadgen.Config{Rate: *rate, Duration: *duration, Arrival: arr, Seed: *seed,
		MaxOutstanding: *maxOut, DrainTimeout: *drain, LateThreshold: *late}

	if *warmup > 0 {
		w := cfg
		w.Duration = *warmup
		if _, err := loadgen.Run(ctx, w, tgt); err != nil {
			return err
		}
	}
	res, err := loadgen.Run(ctx, cfg, tgt)
	if err != nil {
		return err
	}
	sum := loadgen.Summarize(res, loadgen.Meta{Target: *target, Scenario: *method + " " + *target,
		Warmup: *warmup, Machine: loadgen.CollectMachine(*label), Now: time.Now()})
	loadgen.PrintText(os.Stdout, sum)
	if *out != "" {
		if err := loadgen.WriteFiles(*out, sum, res); err != nil {
			return err
		}
		fmt.Printf("wrote %s\n", *out)
	}
	return nil
}
