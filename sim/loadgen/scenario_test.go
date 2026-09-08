package loadgen

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakePayments is a stand-in for the Stripe-shaped PaymentIntents routes: create
// returns an id, confirm needs a known id, the right key and an Idempotency-Key.
type fakePayments struct {
	mu        sync.Mutex
	intents   map[string]string // id -> status
	idemKeys  map[string]int
	creates   int
	failEvery int // fail every nth create with a 500
}

func (f *fakePayments) handler(t *testing.T) http.Handler {
	mux := http.NewServeMux()
	auth := func(w http.ResponseWriter, r *http.Request) bool {
		if r.Header.Get("Authorization") != "Bearer sk_test_abc" {
			w.WriteHeader(http.StatusUnauthorized)
			return false
		}
		return true
	}
	mux.HandleFunc("POST /v1/payment_intents", func(w http.ResponseWriter, r *http.Request) {
		if !auth(w, r) {
			return
		}
		if err := r.ParseForm(); err != nil || r.Form.Get("amount") != "1000" || r.Form.Get("payment_method") != "pm_card_visa" ||
			r.Header.Get("Content-Type") != "application/x-www-form-urlencoded" {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		f.mu.Lock()
		defer f.mu.Unlock()
		f.creates++
		f.idemKeys[r.Header.Get("Idempotency-Key")]++
		if f.failEvery > 0 && f.creates%f.failEvery == 0 {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		id := fmt.Sprintf("pi_%06d", f.creates)
		f.intents[id] = "requires_confirmation"
		fmt.Fprintf(w, `{"id":%q,"object":"payment_intent","amount":1000,"status":"requires_confirmation"}`, id)
	})
	mux.HandleFunc("POST /v1/payment_intents/{id}/confirm", func(w http.ResponseWriter, r *http.Request) {
		if !auth(w, r) {
			return
		}
		key := r.Header.Get("Idempotency-Key")
		f.mu.Lock()
		defer f.mu.Unlock()
		id := r.PathValue("id")
		if f.intents[id] != "requires_confirmation" || key == "" {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		f.idemKeys[key]++
		f.intents[id] = "succeeded"
		fmt.Fprintf(w, `{"id":%q,"status":"succeeded"}`, id)
	})
	return mux
}

func newFake() *fakePayments {
	return &fakePayments{intents: map[string]string{}, idemKeys: map[string]int{}}
}

func quickConfig(rate float64, d time.Duration, maxOut int) Config {
	return Config{Rate: rate, Duration: d, Arrival: Constant, MaxOutstanding: maxOut,
		DrainTimeout: 2 * time.Second, LateThreshold: 5 * time.Millisecond}
}

func TestCreateConfirmCapturesTheIdAndUsesFreshIdempotencyKeys(t *testing.T) {
	f := newFake()
	srv := httptest.NewServer(f.handler(t))
	defer srv.Close()
	tgt, err := NewScenarioTarget(srv.URL, NewHTTPClient(8, 5*time.Second), Scenarios["create-confirm"],
		map[string]string{"key": "sk_test_abc"})
	if err != nil {
		t.Fatal(err)
	}
	res, err := Run(context.Background(), quickConfig(200, 250*time.Millisecond, 8), tgt)
	if err != nil {
		t.Fatal(err)
	}
	if res.OK != 50 || len(res.Errors) != 0 {
		t.Fatalf("ok %d errors %v", res.OK, res.Errors)
	}
	for id, st := range f.intents {
		if st != "succeeded" {
			t.Errorf("%s left %s", id, st)
		}
	}
	if len(f.idemKeys) != 100 {
		t.Errorf("%d distinct idempotency keys for 100 requests", len(f.idemKeys))
	}
	for k, n := range f.idemKeys {
		if n != 1 || !strings.HasPrefix(k, "lg-") {
			t.Errorf("key %q used %d times", k, n)
		}
	}
	if got := strings.Join(res.StepOrder, ","); got != "create,confirm" {
		t.Errorf("steps %s", got)
	}
	if res.Steps["confirm"].Count != 50 {
		t.Errorf("confirm count %d", res.Steps["confirm"].Count)
	}
}

func TestConfirmScenarioMeasuresOnlyConfirm(t *testing.T) {
	f := newFake()
	srv := httptest.NewServer(f.handler(t))
	defer srv.Close()
	tgt, err := NewScenarioTarget(srv.URL, NewHTTPClient(4, 5*time.Second), Scenarios["confirm"],
		map[string]string{"key": "sk_test_abc"})
	if err != nil {
		t.Fatal(err)
	}
	cfg := quickConfig(100, 200*time.Millisecond, 4)
	if got := tgt.Prepare(context.Background(), ExpectedCount(cfg.Arrival, cfg.Rate, cfg.Duration), 4); got != 21 {
		t.Fatalf("prepared %d, want 21", got)
	}
	res, err := Run(context.Background(), cfg, tgt)
	if err != nil {
		t.Fatal(err)
	}
	if res.OK != 20 || len(res.StepOrder) != 1 || res.StepOrder[0] != "confirm" {
		t.Fatalf("ok %d steps %v errors %v", res.OK, res.StepOrder, res.Errors)
	}
}

// Prepared state that runs out is a counted error, never a silent skip.
func TestPrepareShortfallIsCounted(t *testing.T) {
	f := newFake()
	f.failEvery = 2
	srv := httptest.NewServer(f.handler(t))
	defer srv.Close()
	tgt, _ := NewScenarioTarget(srv.URL, NewHTTPClient(1, 5*time.Second), Scenarios["confirm"],
		map[string]string{"key": "sk_test_abc"})
	if got := tgt.Prepare(context.Background(), 10, 1); got != 5 || tgt.PrepareErrors["http_500"] != 5 {
		t.Fatalf("prepared %d, errors %v", got, tgt.PrepareErrors)
	}
	res, _ := Run(context.Background(), quickConfig(100, 100*time.Millisecond, 1), tgt)
	if res.OK != 5 || res.Errors[ClassNoPrepared] != 5 {
		t.Fatalf("ok %d errors %v", res.OK, res.Errors)
	}
}

func TestFailedStepStopsTheIteration(t *testing.T) {
	f := newFake()
	srv := httptest.NewServer(f.handler(t))
	defer srv.Close()
	tgt, _ := NewScenarioTarget(srv.URL, NewHTTPClient(1, 5*time.Second), Scenarios["create-confirm"],
		map[string]string{"key": "sk_test_wrong"})
	out := tgt.Do(context.Background(), 0)
	if out.Class != "http_401" || len(out.Steps) != 1 {
		t.Fatalf("%+v", out)
	}
}

func TestMissingRequiredVariableIsRejected(t *testing.T) {
	if _, err := NewScenarioTarget("http://x", nil, Scenarios["account"], nil); err == nil {
		t.Fatal("account scenario accepted without a key")
	}
}

func TestTemplatesAndCaptures(t *testing.T) {
	var got []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = append(got, r.Method+" "+r.URL.Path+" "+r.Header.Get("X-Thing"))
		json.NewEncoder(w).Encode(map[string]any{"data": map[string]any{"n": 42, "ok": true, "s": "x/y"}})
	}))
	defer srv.Close()
	sc := Scenario{Name: "t", Steps: []Step{
		{Name: "a", Method: "GET", Path: "/a/{{.iter}}", Header: map[string]string{"X-Thing": "{{.who}}"},
			Capture: map[string]string{"n": "data.n", "ok": "data.ok", "s": "data.s"}},
		{Name: "b", Method: "GET", Path: "/b/{{.n}}/{{.ok}}/{{urlquery .s}}"},
	}}
	tgt, err := NewScenarioTarget(srv.URL+"/", NewHTTPClient(1, time.Second), sc, map[string]string{"who": "me"})
	if err != nil {
		t.Fatal(err)
	}
	if out := tgt.Do(context.Background(), 7); out.Class != "" {
		t.Fatalf("%+v", out)
	}
	want := []string{"GET /a/7 me", "GET /b/42/true/x/y "}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Errorf("requests %q, want %q", got, want)
	}

	missing := Scenario{Name: "m", Steps: []Step{{Name: "a", Method: "GET", Path: "/", Capture: map[string]string{"id": "nope.id"}}}}
	tgt, _ = NewScenarioTarget(srv.URL, NewHTTPClient(1, time.Second), missing, nil)
	if out := tgt.Do(context.Background(), 0); out.Class != ClassCapture {
		t.Errorf("missing capture gave %q", out.Class)
	}
	undefined := Scenario{Name: "u", Steps: []Step{{Name: "a", Method: "GET", Path: "/{{.nothing}}"}}}
	tgt, _ = NewScenarioTarget(srv.URL, NewHTTPClient(1, time.Second), undefined, nil)
	if out := tgt.Do(context.Background(), 0); out.Class != ClassTemplate {
		t.Errorf("undefined variable gave %q", out.Class)
	}
	if _, err := NewScenarioTarget(srv.URL, nil, Scenario{Name: "bad", Steps: []Step{{Path: "{{"}}}, nil); err == nil {
		t.Error("unparseable template accepted")
	}
}

func TestCreateMerchant(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/merchants" || r.Header.Get("Authorization") != "Bearer admin" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		r.ParseForm()
		w.WriteHeader(http.StatusCreated)
		fmt.Fprintf(w, `{"id":"acct_1","name":%q,"secret_key":"sk_test_new"}`, r.Form.Get("name"))
	}))
	defer srv.Close()
	c := NewHTTPClient(1, time.Second)
	key, err := CreateMerchant(context.Background(), c, srv.URL, "admin", "lg")
	if err != nil || key != "sk_test_new" {
		t.Fatalf("key %q err %v", key, err)
	}
	if _, err := CreateMerchant(context.Background(), c, srv.URL, "wrong", "lg"); err == nil || !strings.Contains(err.Error(), "401") {
		t.Errorf("err %v", err)
	}
}
