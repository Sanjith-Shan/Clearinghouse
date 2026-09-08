package loadgen

import (
	"math"
	"testing"
	"time"
)

func TestConstantOffsetsAreExactMultiplesOfThePeriod(t *testing.T) {
	cases := []struct {
		i    int64
		rate float64
		want time.Duration
	}{
		{0, 1000, 0},
		{1, 1000, time.Millisecond},
		{999, 1000, 999 * time.Millisecond},
		{3_600_000, 1000, time.Hour},
		{1, 3, 333_333_333 * time.Nanosecond}, // rounded to the nearest nanosecond
		{2, 3, 666_666_667 * time.Nanosecond},
		{3_000_000, 3, 1_000_000 * time.Second}, // no drift after three million periods of 1/3 s
		{7, 0.5, 14 * time.Second},
	}
	for _, c := range cases {
		if got := ConstantOffset(c.i, c.rate); got != c.want {
			t.Errorf("ConstantOffset(%d, %v) = %v, want %v", c.i, c.rate, got, c.want)
		}
	}
}

func TestConstantScheduleMatchesConstantOffset(t *testing.T) {
	s, err := NewSchedule(Constant, 3, 0)
	if err != nil {
		t.Fatal(err)
	}
	for i := int64(0); i < 10_000; i++ {
		if got, want := s.Next(), ConstantOffset(i, 3); got != want {
			t.Fatalf("request %d: got %v, want %v", i, got, want)
		}
	}
}

// Summing a rounded period would drift: 1/3 s rounds to 333,333,333ns, and three
// million of those land 1ms early.
func TestConstantScheduleDoesNotAccumulateRoundingError(t *testing.T) {
	s, _ := NewSchedule(Constant, 3, 0)
	var last time.Duration
	for i := 0; i <= 3_000_000; i++ {
		last = s.Next()
	}
	if last != 1_000_000*time.Second {
		t.Fatalf("request 3,000,000 at 3/s is due at %v, want exactly 1e6 s", last)
	}
}

func TestPoissonScheduleHasTheRightMeanAndSpread(t *testing.T) {
	const rate, n = 500.0, 200_000
	s, _ := NewSchedule(Poisson, rate, 42)
	var prev time.Duration
	var sum, sumSq float64
	if first := s.Next(); first != 0 {
		t.Fatalf("first request at %v, want 0", first)
	}
	for i := 0; i < n; i++ {
		off := s.Next()
		if off < prev {
			t.Fatalf("offset went backwards at %d: %v < %v", i, off, prev)
		}
		gap := (off - prev).Seconds()
		sum += gap
		sumSq += gap * gap
		prev = off
	}
	mean := sum / n
	sd := math.Sqrt(sumSq/n - mean*mean)
	if math.Abs(mean-1/rate)/(1/rate) > 0.01 {
		t.Errorf("mean gap %v, want %v within 1%%", mean, 1/rate)
	}
	// An exponential distribution's standard deviation equals its mean.
	if cv := sd / mean; math.Abs(cv-1) > 0.02 {
		t.Errorf("coefficient of variation %v, want 1 within 0.02", cv)
	}
}

func TestPoissonScheduleIsReproducibleFromItsSeed(t *testing.T) {
	a, _ := NewSchedule(Poisson, 100, 7)
	b, _ := NewSchedule(Poisson, 100, 7)
	c, _ := NewSchedule(Poisson, 100, 8)
	differs := false
	for i := 0; i < 1000; i++ {
		x, y, z := a.Next(), b.Next(), c.Next()
		if x != y {
			t.Fatalf("same seed diverged at %d", i)
		}
		if x != z {
			differs = true
		}
	}
	if !differs {
		t.Fatal("different seeds produced the same schedule")
	}
}

func TestNewScheduleRejectsBadInput(t *testing.T) {
	for _, rate := range []float64{0, -1, math.NaN(), math.Inf(1)} {
		if _, err := NewSchedule(Constant, rate, 0); err == nil {
			t.Errorf("rate %v accepted", rate)
		}
	}
	if _, err := ParseArrival("uniform"); err == nil {
		t.Error("unknown arrival accepted")
	}
}

func TestExpectedCountCoversTheSchedule(t *testing.T) {
	if got := ExpectedCount(Constant, 1000, 2*time.Second); got != 2001 {
		t.Errorf("constant: %d", got)
	}
	s, _ := NewSchedule(Poisson, 1000, 1)
	var n int64
	for s.Next() < 2*time.Second {
		n++
	}
	if max := ExpectedCount(Poisson, 1000, 2*time.Second); n > max {
		t.Errorf("poisson planned %d, above the buffer size %d", n, max)
	}
}
