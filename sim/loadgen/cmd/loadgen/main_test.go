package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRunWritesSummaryAndHistograms(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/healthz" {
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()
	dir := t.TempDir()
	var out bytes.Buffer
	err := run([]string{"run", "-target", srv.URL, "-scenario", "healthz", "-rate", "100", "-duration", "200ms",
		"-warmup", "100ms", "-label", "test", "-out", dir}, &out)
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range []string{"summary.json", "response.hgrm", "service.hgrm", "send_delay.hgrm"} {
		if _, err := os.Stat(filepath.Join(dir, f)); err != nil {
			t.Errorf("%s: %v", f, err)
		}
	}
	var s struct {
		Planned  int64   `json:"planned"`
		OK       int64   `json:"ok"`
		Scenario string  `json:"scenario"`
		WarmupS  float64 `json:"warmup_s"`
		Machine  struct {
			Label string `json:"label"`
		} `json:"machine"`
	}
	b, _ := os.ReadFile(filepath.Join(dir, "summary.json"))
	if err := json.Unmarshal(b, &s); err != nil {
		t.Fatal(err)
	}
	if s.Planned != 20 || s.OK != 20 || s.Scenario != "healthz" || s.WarmupS != 0.1 || s.Machine.Label != "test" {
		t.Errorf("%+v", s)
	}
}

func TestSweepWritesOneDirectoryPerRate(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer srv.Close()
	dir := t.TempDir()
	var out bytes.Buffer
	err := run([]string{"sweep", "-target", srv.URL, "-rates", "50,100", "-duration", "100ms",
		"-slo-p99", "1s", "-out", dir}, &out)
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range []string{"sweep.json", "rate-50/summary.json", "rate-100/response.hgrm"} {
		if _, err := os.Stat(filepath.Join(dir, f)); err != nil {
			t.Errorf("%s: %v", f, err)
		}
	}
	if !strings.Contains(out.String(), "highest rate with p99 <= 1s") || !strings.Contains(out.String(), ": 100/s") {
		t.Errorf("output:\n%s", out.String())
	}
}

func TestFlagErrors(t *testing.T) {
	var out bytes.Buffer
	cases := [][]string{
		{},
		{"bogus"},
		{"run", "-scenario", "nope"},
		{"run", "-scenario", "account", "-key", "", "-admin-token", ""},
		{"sweep", "-rates", ""},
		{"sweep", "-rates", "10,-1"},
		{"run", "-arrival", "burst"},
		{"run", "-var", "novalue"},
	}
	for _, c := range cases {
		if err := run(c, &out); err == nil {
			t.Errorf("%v accepted", c)
		}
	}
	if err := run([]string{"scenarios"}, &out); err != nil || !strings.Contains(out.String(), "create-confirm") {
		t.Errorf("scenarios: %v\n%s", err, out.String())
	}
}
