package loadgen

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"text/template"
	"time"
)

// A Step is one HTTP call. Path, Body and header values are Go text/templates over the
// iteration's variables: the run's variables (-var and the key), the built-ins below,
// and anything an earlier step captured.
//
// Built-ins: {{.iter}} is the iteration number (prepare iterations are "p0", "p1",
// ...), {{.run}} is random per run, so {{.run}}-{{.iter}} is a unique idempotency key.
type Step struct {
	Name        string
	Method      string
	Path        string
	Header      map[string]string
	Body        string
	ContentType string
	// Expect is the success status; zero means any 2xx.
	Expect int
	// Capture maps a variable name to a dotted path into the JSON response
	// ("id", "latest_charge.id"). A step with a missing capture fails.
	Capture map[string]string
}

// A Scenario is a workload. Steps run once per scheduled iteration and are measured.
// Prepare steps, if any, run before the measured phase, one set per planned
// iteration, closed loop and unmeasured; each measured iteration then starts from the
// variables one prepare iteration captured. That is how a run measures confirm alone:
// the intents it confirms were created beforehand.
type Scenario struct {
	Name        string
	Description string
	Requires    []string // variables that must be set, e.g. "key"
	Prepare     []Step
	Steps       []Step
}

// ClassNoPrepared: a measured iteration found no prepared state left.
// ClassCapture: a step's response lacked a value to capture.
const (
	ClassNoPrepared = "no_prepared_state"
	ClassCapture    = "capture_missing"
	ClassTemplate   = "template"
)

const authHeader = "Bearer {{.key}}"

const createIntentBody = "amount=1000&currency=usd&payment_method=pm_card_visa&capture_method=automatic"

func createIntentStep() Step {
	return Step{
		Name: "create", Method: "POST", Path: "/v1/payment_intents",
		Header:  map[string]string{"Authorization": authHeader, "Idempotency-Key": "lg-{{.run}}-{{.iter}}-create"},
		Body:    createIntentBody,
		Capture: map[string]string{"id": "id"},
	}
}

func confirmStep() Step {
	return Step{
		Name: "confirm", Method: "POST", Path: "/v1/payment_intents/{{.id}}/confirm",
		Header: map[string]string{"Authorization": authHeader, "Idempotency-Key": "lg-{{.run}}-{{.iter}}-confirm"},
	}
}

// Scenarios are the built-in workloads, by name.
var Scenarios = map[string]Scenario{
	"healthz": {
		Name: "healthz", Description: "GET /healthz: Puma, Sinatra and one SELECT 1",
		Steps: []Step{{Name: "healthz", Method: "GET", Path: "/healthz", Expect: 200}},
	},
	"account": {
		Name: "account", Description: "GET /v1/account: adds key authentication (one indexed lookup) and versioned rendering",
		Requires: []string{"key"},
		Steps: []Step{{Name: "account", Method: "GET", Path: "/v1/account", Expect: 200,
			Header: map[string]string{"Authorization": authHeader}}},
	},
	"create-confirm": {
		Name: "create-confirm", Description: "create a PaymentIntent for pm_card_visa, then confirm it with an Idempotency-Key",
		Requires: []string{"key"},
		Steps:    []Step{createIntentStep(), confirmStep()},
	},
	"confirm": {
		Name: "confirm", Description: "confirm only: intents are created unmeasured before the run (experiment 8)",
		Requires: []string{"key"},
		Prepare:  []Step{createIntentStep()},
		Steps:    []Step{confirmStep()},
	},
}

// ScenarioNames lists the built-ins in order.
func ScenarioNames() []string {
	names := make([]string, 0, len(Scenarios))
	for n := range Scenarios {
		names = append(names, n)
	}
	sort.Strings(names)
	return names
}

type compiledStep struct {
	Step
	path, body *template.Template
	header     map[string]*template.Template
}

// ScenarioTarget runs a Scenario against a base URL. It implements Target.
type ScenarioTarget struct {
	Base   string
	Client *http.Client
	Vars   map[string]string

	scenario Scenario
	prepare  []compiledStep
	steps    []compiledStep
	prepared chan map[string]string
	// PrepareErrors counts prepare iterations that failed, by class.
	PrepareErrors map[string]int64
}

// NewScenarioTarget checks the scenario's variables and compiles its templates.
func NewScenarioTarget(base string, client *http.Client, sc Scenario, vars map[string]string) (*ScenarioTarget, error) {
	vs := map[string]string{"run": randomHex(6)}
	for k, v := range vars {
		vs[k] = v
	}
	for _, r := range sc.Requires {
		if vs[r] == "" {
			return nil, fmt.Errorf("scenario %s needs the variable %q", sc.Name, r)
		}
	}
	t := &ScenarioTarget{Base: strings.TrimRight(base, "/"), Client: client, Vars: vs, scenario: sc,
		PrepareErrors: map[string]int64{}}
	var err error
	if t.prepare, err = compile(sc.Prepare); err != nil {
		return nil, err
	}
	if t.steps, err = compile(sc.Steps); err != nil {
		return nil, err
	}
	if len(t.steps) == 0 {
		return nil, fmt.Errorf("scenario %s has no steps", sc.Name)
	}
	return t, nil
}

func compile(steps []Step) ([]compiledStep, error) {
	out := make([]compiledStep, len(steps))
	for i, s := range steps {
		c := compiledStep{Step: s, header: map[string]*template.Template{}}
		var err error
		parse := func(what, text string) *template.Template {
			if err != nil {
				return nil
			}
			var tpl *template.Template
			tpl, err = template.New(s.Name + " " + what).Option("missingkey=error").Parse(text)
			return tpl
		}
		c.path = parse("path", s.Path)
		c.body = parse("body", s.Body)
		for k, v := range s.Header {
			c.header[k] = parse("header "+k, v)
		}
		if err != nil {
			return nil, fmt.Errorf("step %s: %w", s.Name, err)
		}
		out[i] = c
	}
	return out, nil
}

// NeedsPrepare says whether Prepare must run before the measured phase.
func (t *ScenarioTarget) NeedsPrepare() bool { return len(t.prepare) > 0 }

// Prepare runs the prepare steps n times with the given concurrency, closed loop, and
// keeps each successful iteration's variables for a measured iteration to use. It
// returns how many succeeded; failures are counted in PrepareErrors.
func (t *ScenarioTarget) Prepare(ctx context.Context, n int64, concurrency int) int64 {
	t.prepared = make(chan map[string]string, n)
	var next, ok atomic.Int64
	var mu sync.Mutex
	var wg sync.WaitGroup
	for w := 0; w < concurrency; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				i := next.Add(1) - 1
				if i >= n || ctx.Err() != nil {
					return
				}
				vars := t.iterVars("p" + strconv.FormatInt(i, 10))
				out := t.runSteps(ctx, t.prepare, vars)
				if out.Class != "" {
					mu.Lock()
					t.PrepareErrors[out.Class]++
					mu.Unlock()
					continue
				}
				ok.Add(1)
				t.prepared <- vars
			}
		}()
	}
	wg.Wait()
	return ok.Load()
}

// Do runs one measured iteration.
func (t *ScenarioTarget) Do(ctx context.Context, iter int64) Outcome {
	var vars map[string]string
	if t.NeedsPrepare() {
		select {
		case vars = <-t.prepared:
		default:
			return Outcome{Class: ClassNoPrepared}
		}
	} else {
		vars = t.iterVars("")
	}
	vars["iter"] = strconv.FormatInt(iter, 10)
	return t.runSteps(ctx, t.steps, vars)
}

func (t *ScenarioTarget) iterVars(iter string) map[string]string {
	vs := make(map[string]string, len(t.Vars)+4)
	for k, v := range t.Vars {
		vs[k] = v
	}
	vs["iter"] = iter
	return vs
}

// runSteps stops at the first failing step: later steps usually depend on its captures.
func (t *ScenarioTarget) runSteps(ctx context.Context, steps []compiledStep, vars map[string]string) Outcome {
	out := Outcome{Steps: make([]StepResult, 0, len(steps))}
	for _, s := range steps {
		res := t.runStep(ctx, s, vars)
		out.Steps = append(out.Steps, res)
		if res.Class != "" {
			out.Class = res.Class
			return out
		}
	}
	return out
}

func (t *ScenarioTarget) runStep(ctx context.Context, s compiledStep, vars map[string]string) StepResult {
	res := StepResult{Name: s.Name}
	req, err := t.build(ctx, s, vars)
	if err != nil {
		res.Class = ClassTemplate
		return res
	}
	start := time.Now()
	resp, err := t.Client.Do(req)
	if err != nil {
		res.Class, res.Duration = Classify(ctx, err), time.Since(start)
		return res
	}
	var body []byte
	if len(s.Capture) > 0 {
		body, err = io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	} else {
		_, err = io.Copy(io.Discard, resp.Body)
	}
	resp.Body.Close()
	res.Status, res.Duration = resp.StatusCode, time.Since(start)
	switch {
	case err != nil:
		res.Class = Classify(ctx, err)
	case !StatusOK(resp.StatusCode, s.Expect):
		res.Class = StatusClass(resp.StatusCode)
	case len(s.Capture) > 0:
		if !capture(body, s.Capture, vars) {
			res.Class = ClassCapture
		}
	}
	return res
}

func (t *ScenarioTarget) build(ctx context.Context, s compiledStep, vars map[string]string) (*http.Request, error) {
	path, err := render(s.path, vars)
	if err != nil {
		return nil, err
	}
	body, err := render(s.body, vars)
	if err != nil {
		return nil, err
	}
	var rd io.Reader
	if body != "" {
		rd = strings.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, s.Method, t.Base+path, rd)
	if err != nil {
		return nil, err
	}
	if body != "" {
		ct := s.ContentType
		if ct == "" {
			ct = "application/x-www-form-urlencoded"
		}
		req.Header.Set("Content-Type", ct)
	}
	for k, tpl := range s.header {
		v, err := render(tpl, vars)
		if err != nil {
			return nil, err
		}
		req.Header.Set(k, v)
	}
	return req, nil
}

func render(tpl *template.Template, vars map[string]string) (string, error) {
	var b bytes.Buffer
	if err := tpl.Execute(&b, vars); err != nil {
		return "", err
	}
	return b.String(), nil
}

// capture reads each dotted path out of a JSON object into vars. Strings are taken
// as they are, numbers and booleans in their JSON spelling.
func capture(body []byte, paths map[string]string, vars map[string]string) bool {
	var doc any
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.UseNumber()
	if dec.Decode(&doc) != nil {
		return false
	}
	for name, path := range paths {
		v := doc
		for _, key := range strings.Split(path, ".") {
			obj, ok := v.(map[string]any)
			if !ok {
				return false
			}
			v = obj[key]
		}
		switch x := v.(type) {
		case string:
			vars[name] = x
		case json.Number:
			vars[name] = x.String()
		case bool:
			vars[name] = strconv.FormatBool(x)
		default:
			return false
		}
	}
	return true
}

func randomHex(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}
