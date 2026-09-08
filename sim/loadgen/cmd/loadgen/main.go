// Command loadgen sends open-loop HTTP load at fixed rates and reports latency
// percentiles measured from each request's intended send time.
//
//	loadgen run   -target http://127.0.0.1:4000 -scenario healthz -rate 500 -duration 30s -out DIR
//	loadgen sweep -target http://127.0.0.1:4000 -scenario confirm -rates 25,50,100 -slo-p99 250ms -out DIR
//	loadgen scenarios
//
// Scenarios that need a merchant take -key, or -admin-token to create one first.
// See docs/design/loadgen.md.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/Sanjith-Shan/Clearinghouse/sim/loadgen"
)

type varFlags map[string]string

func (v varFlags) String() string { return fmt.Sprint(map[string]string(v)) }
func (v varFlags) Set(s string) error {
	k, val, ok := strings.Cut(s, "=")
	if !ok || k == "" {
		return fmt.Errorf("want name=value, got %q", s)
	}
	v[k] = val
	return nil
}

func main() {
	if err := run(os.Args[1:], os.Stdout); err != nil {
		if !errors.Is(err, flag.ErrHelp) {
			fmt.Fprintln(os.Stderr, "loadgen:", err)
		}
		os.Exit(1)
	}
}

func usage() error {
	return fmt.Errorf("usage: loadgen run|sweep|scenarios [flags]; loadgen run -h for flags")
}

func run(args []string, stdout io.Writer) error {
	if len(args) == 0 {
		return usage()
	}
	switch args[0] {
	case "scenarios":
		for _, n := range loadgen.ScenarioNames() {
			fmt.Fprintf(stdout, "%-15s %s\n", n, loadgen.Scenarios[n].Description)
		}
		return nil
	case "run", "sweep":
		return runLoad(args[0], args[1:], stdout)
	}
	return usage()
}

// options are the flags shared by run and sweep.
type options struct {
	target, scenario, key, adminToken, label, out, arrival, rates string
	vars                                                          varFlags
	rate                                                          float64
	duration, warmup, timeout, drain, late, slo, spin             time.Duration
	seed                                                          int64
	maxOut                                                        int
	maxErr                                                        float64
	keepGoing                                                     bool
}

func parse(mode string, args []string) (*options, error) {
	o := &options{vars: varFlags{}}
	fs := flag.NewFlagSet("loadgen "+mode, flag.ContinueOnError)
	fs.StringVar(&o.target, "target", "http://127.0.0.1:4000", "base URL of the server")
	fs.StringVar(&o.scenario, "scenario", "healthz", "workload: "+strings.Join(loadgen.ScenarioNames(), ", "))
	fs.StringVar(&o.key, "key", os.Getenv("CLEARINGHOUSE_KEY"), "merchant secret key (default $CLEARINGHOUSE_KEY)")
	fs.StringVar(&o.adminToken, "admin-token", os.Getenv("CLEARINGHOUSE_ADMIN_TOKEN"),
		"admin token; with no -key, a merchant is created for the run (default $CLEARINGHOUSE_ADMIN_TOKEN)")
	fs.Var(o.vars, "var", "extra template variable name=value (repeatable)")
	fs.Float64Var(&o.rate, "rate", 100, "target rate, iterations per second (run)")
	fs.StringVar(&o.rates, "rates", "", "comma-separated rates (sweep)")
	fs.DurationVar(&o.slo, "slo-p99", 100*time.Millisecond, "p99 response-time objective (sweep)")
	fs.Float64Var(&o.maxErr, "max-error-rate", 0.001, "share of requests allowed to fail at a passing rate (sweep)")
	fs.BoolVar(&o.keepGoing, "keep-going", false, "run every rate even after one fails (sweep)")
	fs.DurationVar(&o.duration, "duration", 10*time.Second, "measured duration per rate")
	fs.DurationVar(&o.warmup, "warmup", 0, "unmeasured warmup at the same rate before each measured run")
	fs.StringVar(&o.arrival, "arrival", "constant", "constant or poisson")
	fs.Int64Var(&o.seed, "seed", 1, "seed for poisson arrivals")
	fs.IntVar(&o.maxOut, "max-outstanding", 64, "cap on iterations in flight (workers and connections)")
	fs.DurationVar(&o.timeout, "timeout", 10*time.Second, "per-request client timeout")
	fs.DurationVar(&o.drain, "drain", 0, "time after the schedule for queued requests to finish (default timeout+1s)")
	fs.DurationVar(&o.late, "late-threshold", time.Millisecond, "send delay above which a request counts as late")
	fs.DurationVar(&o.spin, "spin", time.Millisecond, "busy-wait this long before each send for timing accuracy (0 to only sleep)")
	fs.StringVar(&o.label, "label", "", "free-text machine label, e.g. 'M2 laptop, server on same host'")
	fs.StringVar(&o.out, "out", "", "directory for summary.json and .hgrm files")
	if err := fs.Parse(args); err != nil {
		return nil, err
	}
	if fs.NArg() > 0 {
		return nil, fmt.Errorf("unexpected arguments %v", fs.Args())
	}
	if o.drain == 0 {
		o.drain = o.timeout + time.Second
	}
	return o, nil
}

func parseRates(s string) ([]float64, error) {
	var out []float64
	for _, f := range strings.Split(s, ",") {
		if f = strings.TrimSpace(f); f == "" {
			continue
		}
		r, err := strconv.ParseFloat(f, 64)
		if err != nil || !(r > 0) {
			return nil, fmt.Errorf("bad rate %q", f)
		}
		out = append(out, r)
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("-rates is required for sweep")
	}
	return out, nil
}

func runLoad(mode string, args []string, stdout io.Writer) error {
	o, err := parse(mode, args)
	if err != nil {
		return err
	}
	sc, ok := loadgen.Scenarios[o.scenario]
	if !ok {
		return fmt.Errorf("unknown scenario %q (have %s)", o.scenario, strings.Join(loadgen.ScenarioNames(), ", "))
	}
	arr, err := loadgen.ParseArrival(o.arrival)
	if err != nil {
		return err
	}
	var rates []float64
	if mode == "sweep" {
		if rates, err = parseRates(o.rates); err != nil {
			return err
		}
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	client := loadgen.NewHTTPClient(o.maxOut, o.timeout)

	vars := map[string]string{}
	for k, v := range o.vars {
		vars[k] = v
	}
	if needsKey(sc) && o.key == "" {
		if o.adminToken == "" {
			return fmt.Errorf("scenario %s needs -key or -admin-token", sc.Name)
		}
		if o.key, err = loadgen.CreateMerchant(ctx, client, o.target, o.adminToken, "loadgen "+time.Now().UTC().Format(time.RFC3339)); err != nil {
			return err
		}
	}
	if o.key != "" {
		vars["key"] = o.key
	}
	machine := loadgen.CollectMachine(o.label)

	// once runs warmup and the measured run at one rate, with a fresh target so a
	// scenario's prepared state is sized for exactly that rate.
	once := func(ctx context.Context, rate float64) (loadgen.Summary, *loadgen.Result, error) {
		tgt, err := loadgen.NewScenarioTarget(o.target, client, sc, vars)
		if err != nil {
			return loadgen.Summary{}, nil, err
		}
		cfg := loadgen.Config{Rate: rate, Duration: o.duration, Arrival: arr, Seed: o.seed,
			MaxOutstanding: o.maxOut, DrainTimeout: o.drain, LateThreshold: o.late, SpinWindow: o.spin}
		if tgt.NeedsPrepare() {
			n := loadgen.ExpectedCount(arr, rate, o.duration)
			if o.warmup > 0 {
				n += loadgen.ExpectedCount(arr, rate, o.warmup)
			}
			fmt.Fprintf(stdout, "preparing %d iterations of %s...\n", n, sc.Name)
			if got := tgt.Prepare(ctx, n, o.maxOut); got < n {
				fmt.Fprintf(stdout, "prepared %d of %d (errors %v); the shortfall shows as %s\n",
					got, n, tgt.PrepareErrors, loadgen.ClassNoPrepared)
			}
		}
		if o.warmup > 0 {
			w := cfg
			w.Duration = o.warmup
			if _, err := loadgen.Run(ctx, w, tgt); err != nil {
				return loadgen.Summary{}, nil, err
			}
		}
		res, err := loadgen.Run(ctx, cfg, tgt)
		if err != nil {
			return loadgen.Summary{}, nil, err
		}
		sum := loadgen.Summarize(res, loadgen.Meta{Target: o.target, Scenario: sc.Name, Warmup: o.warmup,
			Machine: machine, Now: time.Now()})
		return sum, res, nil
	}

	if mode == "run" {
		sum, res, err := once(ctx, o.rate)
		if err != nil {
			return err
		}
		loadgen.PrintText(stdout, sum)
		return write(stdout, o.out, sum, res)
	}

	result, err := loadgen.Sweep(ctx, loadgen.SweepConfig{Rates: rates, SLOP99: o.slo, MaxErrorRate: o.maxErr,
		KeepGoing: o.keepGoing}, func(ctx context.Context, rate float64) (loadgen.Summary, error) {
		sum, res, err := once(ctx, rate)
		if err != nil {
			return sum, err
		}
		loadgen.PrintText(stdout, sum)
		fmt.Fprintln(stdout)
		if o.out != "" {
			err = write(stdout, filepath.Join(o.out, "rate-"+strconv.FormatFloat(rate, 'f', -1, 64)), sum, res)
		}
		return sum, err
	})
	if err != nil {
		return err
	}
	for _, p := range result.Points {
		verdict := "pass"
		if !p.Pass {
			verdict = "FAIL " + p.Reason
		}
		fmt.Fprintf(stdout, "rate %8.1f/s  p99 %9.3fms  %s\n", p.Rate, p.P99Ms, verdict)
	}
	fmt.Fprintf(stdout, "highest rate with p99 <= %v and error rate <= %v: %v/s\n", o.slo, o.maxErr, result.MaxRate)
	if o.out != "" {
		b, err := json.MarshalIndent(result, "", "  ")
		if err != nil {
			return err
		}
		if err := os.MkdirAll(o.out, 0o755); err != nil {
			return err
		}
		return os.WriteFile(filepath.Join(o.out, "sweep.json"), append(b, '\n'), 0o644)
	}
	return nil
}

func needsKey(sc loadgen.Scenario) bool {
	for _, r := range sc.Requires {
		if r == "key" {
			return true
		}
	}
	return false
}

func write(stdout io.Writer, dir string, sum loadgen.Summary, res *loadgen.Result) error {
	if dir == "" {
		return nil
	}
	if err := loadgen.WriteFiles(dir, sum, res); err != nil {
		return err
	}
	fmt.Fprintf(stdout, "wrote %s\n", dir)
	return nil
}
