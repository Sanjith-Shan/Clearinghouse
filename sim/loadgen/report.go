package loadgen

import (
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"

	hdrhistogram "github.com/HdrHistogram/hdrhistogram-go"
)

// Percentiles are milliseconds.
type Percentiles struct {
	Count int64   `json:"count"`
	Mean  float64 `json:"mean"`
	P50   float64 `json:"p50"`
	P90   float64 `json:"p90"`
	P99   float64 `json:"p99"`
	P999  float64 `json:"p99_9"`
	Max   float64 `json:"max"`
}

// PercentilesOf reads a microsecond histogram into milliseconds.
func PercentilesOf(h *hdrhistogram.Histogram) Percentiles {
	ms := func(us int64) float64 { return round3(float64(us) / 1000) }
	return Percentiles{
		Count: h.TotalCount(),
		Mean:  round3(h.Mean() / 1000),
		P50:   ms(h.ValueAtQuantile(50)),
		P90:   ms(h.ValueAtQuantile(90)),
		P99:   ms(h.ValueAtQuantile(99)),
		P999:  ms(h.ValueAtQuantile(99.9)),
		Max:   ms(h.Max()),
	}
}

func round3(x float64) float64 { return math.Round(x*1000) / 1000 }

// Machine labels where a number was measured. A latency without it is not a result.
type Machine struct {
	GOOS      string `json:"goos"`
	GOARCH    string `json:"goarch"`
	NumCPU    int    `json:"num_cpu"`
	CPU       string `json:"cpu,omitempty"`
	Model     string `json:"model,omitempty"`
	MemoryB   int64  `json:"memory_bytes,omitempty"`
	GoVersion string `json:"go_version"`
	Label     string `json:"label,omitempty"`
}

// CollectMachine reads what it can about this machine. Anything it cannot read is left
// empty rather than guessed.
func CollectMachine(label string) Machine {
	m := Machine{GOOS: runtime.GOOS, GOARCH: runtime.GOARCH, NumCPU: runtime.NumCPU(),
		GoVersion: runtime.Version(), Label: label}
	switch runtime.GOOS {
	case "darwin":
		m.CPU = sysctl("machdep.cpu.brand_string")
		m.Model = sysctl("hw.model")
		m.MemoryB, _ = strconv.ParseInt(sysctl("hw.memsize"), 10, 64)
	case "linux":
		m.CPU = procField("/proc/cpuinfo", "model name")
		if kb, err := strconv.ParseInt(strings.TrimSuffix(procField("/proc/meminfo", "MemTotal"), " kB"), 10, 64); err == nil {
			m.MemoryB = kb * 1024
		}
	}
	return m
}

func sysctl(name string) string {
	out, err := exec.Command("sysctl", "-n", name).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func procField(path, key string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(b), "\n") {
		if k, v, ok := strings.Cut(line, ":"); ok && strings.TrimSpace(k) == key {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

// Rates are requests (iterations) per second.
type Rates struct {
	Target    float64 `json:"target"`
	Scheduled float64 `json:"scheduled"` // planned / duration
	Sent      float64 `json:"sent"`      // sent inside the window / duration
	Completed float64 `json:"completed"` // completed inside the window / duration
}

// StepSummary is one step of the scenario.
type StepSummary struct {
	Name          string           `json:"name"`
	Count         int64            `json:"count"`
	Errors        map[string]int64 `json:"errors"`
	ServiceTimeMs Percentiles      `json:"service_time_ms"`
}

// Summary is the JSON written for every run.
type Summary struct {
	Tool            string    `json:"tool"`
	Timestamp       time.Time `json:"timestamp"`
	Target          string    `json:"target"`
	SameHost        bool      `json:"target_is_loopback"`
	Scenario        string    `json:"scenario"`
	Arrival         Arrival   `json:"arrival"`
	Seed            int64     `json:"seed"`
	DurationS       float64   `json:"duration_s"`
	WarmupS         float64   `json:"warmup_s"`
	MaxOutstanding  int       `json:"max_outstanding"`
	LateThresholdMs float64   `json:"late_threshold_ms"`
	SpinWindowMs    float64   `json:"spin_window_ms"`
	Rate            Rates     `json:"rate"`

	Planned     int64 `json:"planned"`
	Sent        int64 `json:"sent"`
	Completed   int64 `json:"completed"`
	OK          int64 `json:"ok"`
	Late        int64 `json:"late"`
	Dropped     int64 `json:"dropped"`
	Interrupted bool  `json:"interrupted"`

	ErrorRate     float64          `json:"error_rate"`
	Errors        map[string]int64 `json:"errors"`
	ErrorsByGroup map[string]int64 `json:"errors_by_group"`

	// ResponseTimeMs is measured from each request's intended send time, so it
	// includes queueing (coordinated omission corrected). ServiceTimeMs is from the
	// actual send. Use ResponseTimeMs for claims.
	ResponseTimeMs Percentiles   `json:"response_time_ms"`
	ServiceTimeMs  Percentiles   `json:"service_time_ms"`
	SendDelayMs    Percentiles   `json:"send_delay_ms"`
	Steps          []StepSummary `json:"steps"`

	Machine Machine `json:"machine"`
}

// Meta is what the caller knows about a run that the runner does not.
type Meta struct {
	Target   string
	Scenario string
	Warmup   time.Duration
	Machine  Machine
	Now      time.Time
}

// Summarize builds the JSON summary of a run.
func Summarize(r *Result, meta Meta) Summary {
	secs := r.Config.Duration.Seconds()
	s := Summary{
		Tool: "clearinghouse-loadgen", Timestamp: meta.Now.UTC(), Target: meta.Target,
		SameHost: isLoopback(meta.Target), Scenario: meta.Scenario, Arrival: r.Config.Arrival,
		Seed: r.Config.Seed, DurationS: secs, WarmupS: meta.Warmup.Seconds(),
		MaxOutstanding:  r.Config.MaxOutstanding,
		LateThresholdMs: float64(r.Config.LateThreshold) / float64(time.Millisecond),
		SpinWindowMs:    float64(r.Config.SpinWindow) / float64(time.Millisecond),
		Rate: Rates{
			Target:    r.Config.Rate,
			Scheduled: round3(float64(r.Planned) / secs),
			Sent:      round3(float64(r.SentInWindow) / secs),
			Completed: round3(float64(r.CompletedInWindow) / secs),
		},
		Planned: r.Planned, Sent: r.Sent, Completed: r.Completed, OK: r.OK, Late: r.Late,
		Dropped: r.Dropped, Interrupted: r.Interrupted,
		Errors: r.Errors, ErrorsByGroup: map[string]int64{},
		ResponseTimeMs: PercentilesOf(r.Response), ServiceTimeMs: PercentilesOf(r.Service),
		SendDelayMs: PercentilesOf(r.SendDelay), Machine: meta.Machine,
	}
	var failed int64
	for class, n := range r.Errors {
		s.ErrorsByGroup[Group(class)] += n
		failed += n
	}
	if r.Planned > 0 {
		s.ErrorRate = float64(failed) / float64(r.Planned)
	}
	for _, name := range r.StepOrder {
		st := r.Steps[name]
		s.Steps = append(s.Steps, StepSummary{Name: name, Count: st.Count, Errors: st.Errors,
			ServiceTimeMs: PercentilesOf(st.Service)})
	}
	return s
}

func isLoopback(target string) bool {
	u, err := url.Parse(target)
	if err != nil {
		return false
	}
	host := u.Hostname()
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// WriteFiles writes summary.json, response.hgrm, service.hgrm and send_delay.hgrm into
// dir. The .hgrm files are HdrHistogram's percentile distribution format in
// milliseconds, which HdrHistogram's plotter reads.
func WriteFiles(dir string, s Summary, r *Result) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	b, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(dir, "summary.json"), append(b, '\n'), 0o644); err != nil {
		return err
	}
	for name, h := range map[string]*hdrhistogram.Histogram{
		"response.hgrm": r.Response, "service.hgrm": r.Service, "send_delay.hgrm": r.SendDelay,
	} {
		if err := writeHgrm(filepath.Join(dir, name), h); err != nil {
			return err
		}
	}
	return nil
}

func writeHgrm(path string, h *hdrhistogram.Histogram) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	if h.TotalCount() > 0 {
		if _, err := h.PercentilesPrint(f, 5, 1000.0); err != nil {
			f.Close()
			return err
		}
	}
	return f.Close()
}

// PrintText writes a short human-readable report.
func PrintText(w io.Writer, s Summary) {
	fmt.Fprintf(w, "%s  scenario=%s  arrival=%s  target=%.1f/s  duration=%gs  max_outstanding=%d\n",
		s.Target, s.Scenario, s.Arrival, s.Rate.Target, s.DurationS, s.MaxOutstanding)
	fmt.Fprintf(w, "rate/s: scheduled %.1f  sent %.1f  completed %.1f\n", s.Rate.Scheduled, s.Rate.Sent, s.Rate.Completed)
	fmt.Fprintf(w, "requests: planned %d  sent %d  ok %d  late %d  dropped %d  error rate %.4f\n",
		s.Planned, s.Sent, s.OK, s.Late, s.Dropped, s.ErrorRate)
	if len(s.Errors) > 0 {
		keys := make([]string, 0, len(s.Errors))
		for k := range s.Errors {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		parts := make([]string, len(keys))
		for i, k := range keys {
			parts[i] = fmt.Sprintf("%s=%d", k, s.Errors[k])
		}
		fmt.Fprintf(w, "errors: %s\n", strings.Join(parts, " "))
	}
	tw := tabwriter.NewWriter(w, 0, 0, 2, ' ', tabwriter.AlignRight)
	fmt.Fprintln(tw, "ms\tp50\tp90\tp99\tp99.9\tmax\t")
	row := func(name string, p Percentiles) {
		fmt.Fprintf(tw, "%s\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t\n", name, p.P50, p.P90, p.P99, p.P999, p.Max)
	}
	row("response (from intended)", s.ResponseTimeMs)
	row("service (from sent)", s.ServiceTimeMs)
	row("send delay", s.SendDelayMs)
	for _, st := range s.Steps {
		row("  step "+st.Name, st.ServiceTimeMs)
	}
	tw.Flush()
	fmt.Fprintf(w, "machine: %s %s/%s cpus=%d mem=%dGiB %s\n", s.Machine.CPU, s.Machine.GOOS, s.Machine.GOARCH,
		s.Machine.NumCPU, s.Machine.MemoryB>>30, s.Machine.Label)
}
