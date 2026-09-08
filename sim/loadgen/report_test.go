package loadgen

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestGroup(t *testing.T) {
	for in, want := range map[string]string{
		"http_503": "http_5xx", "http_402": "http_4xx", "timeout": "timeout", "dropped": "dropped",
	} {
		if got := Group(in); got != want {
			t.Errorf("Group(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestPercentilesAreMilliseconds(t *testing.T) {
	h := newHist()
	for i := 1; i <= 1000; i++ {
		record(h, time.Duration(i)*time.Millisecond)
	}
	p := PercentilesOf(h)
	near := func(got, want float64) bool { return got >= want*0.999 && got <= want*1.001 }
	if p.Count != 1000 || !near(p.P50, 500) || !near(p.P99, 990) || !near(p.P999, 999) || !near(p.Max, 1000) {
		t.Errorf("%+v", p)
	}
}

func TestRecordClampsOutOfRangeValues(t *testing.T) {
	h := newHist()
	record(h, -time.Second)
	record(h, time.Hour)
	if h.TotalCount() != 2 || h.Max() < histHighest-histHighest/1000 {
		t.Errorf("count %d max %d", h.TotalCount(), h.Max())
	}
}

func TestIsLoopback(t *testing.T) {
	for target, want := range map[string]bool{
		"http://127.0.0.1:4000": true, "http://localhost:4000/x": true, "http://[::1]:80": true,
		"http://10.0.0.2:4000": false, "https://example.com": false,
	} {
		if got := isLoopback(target); got != want {
			t.Errorf("isLoopback(%q) = %v", target, got)
		}
	}
}

func TestCollectMachineLabelsTheRun(t *testing.T) {
	m := CollectMachine("ci")
	if m.NumCPU != runtime.NumCPU() || m.GOOS != runtime.GOOS || m.GoVersion != runtime.Version() || m.Label != "ci" {
		t.Errorf("%+v", m)
	}
	if runtime.GOOS == "darwin" && (m.CPU == "" || m.MemoryB == 0) {
		t.Errorf("darwin sysctl fields missing: %+v", m)
	}
}

func TestWriteFilesAndText(t *testing.T) {
	res, err := Run(context.Background(), Config{Rate: 100, Duration: 50 * time.Millisecond, Arrival: Constant,
		MaxOutstanding: 2, DrainTimeout: time.Second, LateThreshold: time.Millisecond}, fixedTarget{})
	if err != nil {
		t.Fatal(err)
	}
	s := Summarize(res, Meta{Target: "http://127.0.0.1:1", Scenario: "fixed", Machine: CollectMachine("t"), Now: time.Unix(0, 0)})
	dir := t.TempDir()
	if err := WriteFiles(dir, s, res); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(filepath.Join(dir, "summary.json"))
	if err != nil {
		t.Fatal(err)
	}
	var back map[string]any
	if err := json.Unmarshal(b, &back); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"machine", "response_time_ms", "service_time_ms", "rate", "errors", "target_is_loopback"} {
		if _, ok := back[key]; !ok {
			t.Errorf("summary.json lacks %q", key)
		}
	}
	if back["planned"].(float64) != 5 || back["target_is_loopback"] != true {
		t.Errorf("planned %v loopback %v", back["planned"], back["target_is_loopback"])
	}
	hgrm, err := os.ReadFile(filepath.Join(dir, "response.hgrm"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(hgrm), "Value") || !strings.Contains(string(hgrm), "Percentile") {
		t.Errorf("response.hgrm is not a percentile distribution:\n%s", hgrm)
	}
	var buf bytes.Buffer
	PrintText(&buf, s)
	if !strings.Contains(buf.String(), "response (from intended)") {
		t.Errorf("text report:\n%s", buf.String())
	}
}

type fixedTarget struct{}

func (fixedTarget) Do(context.Context, int64) Outcome {
	time.Sleep(time.Millisecond)
	return Outcome{Steps: []StepResult{{Name: "fixed", Status: 200, Duration: time.Millisecond}}}
}
