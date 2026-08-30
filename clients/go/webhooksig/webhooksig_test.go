package webhooksig

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The vectors are shared with the Ruby verifier and RiskGate. The path is relative to
// this package, so go test finds them from inside the repo.
var vectorsPath = filepath.Join("..", "..", "..", "spec", "fixtures", "signatures.json")

type vector struct {
	Name      string   `json:"name"`
	Secrets   []string `json:"secrets"`
	Payload   string   `json:"payload"`
	Header    string   `json:"header"`
	Now       int64    `json:"now"`
	Tolerance int64    `json:"tolerance"`
	Valid     bool     `json:"valid"`
	Error     *string  `json:"error"`
}

func loadVectors(t testing.TB) []vector {
	t.Helper()
	raw, err := os.ReadFile(vectorsPath)
	if err != nil {
		t.Fatalf("reading vectors: %v", err)
	}
	dec := json.NewDecoder(strings.NewReader(string(raw)))
	dec.DisallowUnknownFields()
	var vs []vector
	if err := dec.Decode(&vs); err != nil {
		t.Fatalf("decoding vectors: %v", err)
	}
	if len(vs) == 0 {
		t.Fatal("no vectors")
	}
	return vs
}

func TestSharedVectors(t *testing.T) {
	codes := map[string]error{
		"no_matching_signature":       ErrNoMatchingSignature,
		"timestamp_outside_tolerance": ErrTimestampOutsideTolerance,
		"malformed_header":            ErrMalformedHeader,
	}
	for _, v := range loadVectors(t) {
		t.Run(v.Name, func(t *testing.T) {
			err := Verify([]byte(v.Payload), v.Header, v.Secrets, time.Unix(v.Now, 0),
				time.Duration(v.Tolerance)*time.Second)
			if v.Valid {
				if err != nil {
					t.Fatalf("want valid, got %v", err)
				}
				return
			}
			if v.Error == nil {
				t.Fatal("invalid vector without an error code")
			}
			want, ok := codes[*v.Error]
			if !ok {
				t.Fatalf("unknown error code %q", *v.Error)
			}
			if !errors.Is(err, want) {
				t.Fatalf("want %v, got %v", want, err)
			}
			if err.Error() != *v.Error {
				t.Fatalf("error text %q is not the vector's code %q", err.Error(), *v.Error)
			}
		})
	}
}

func TestSignMatchesOpenSSL(t *testing.T) {
	// printf '%s' '1700000000.{"id":"evt_1"}' | openssl dgst -sha256 -hmac whsec_test_clearinghouse_single_secret
	got, err := Sign([]byte(`{"id":"evt_1"}`), []string{"whsec_test_clearinghouse_single_secret"}, time.Unix(1700000000, 0))
	if err != nil {
		t.Fatal(err)
	}
	want := "t=1700000000,v1=6f725583e4a1287c7f5fdce17433d48868a1e2a4e0fb3dea71c732e49bdf2c70"
	if got != want {
		t.Fatalf("got %s want %s", got, want)
	}
}

func TestSignThenVerifyDuringRotation(t *testing.T) {
	now := time.Unix(1700000000, 0)
	payload := []byte(`{"id":"evt_2"}`)
	header, err := Sign(payload, []string{"whsec_new", "whsec_old"}, now)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Count(header, "v1=") != 2 {
		t.Fatalf("want two v1 values, got %s", header)
	}
	for _, held := range [][]string{{"whsec_old"}, {"whsec_new"}, {"whsec_old", "whsec_new"}} {
		if err := Verify(payload, header, held, now.Add(DefaultTolerance), DefaultTolerance); err != nil {
			t.Fatalf("holding %v: %v", held, err)
		}
	}
	if err := Verify(payload, header, []string{"whsec_other"}, now, DefaultTolerance); !errors.Is(err, ErrNoMatchingSignature) {
		t.Fatalf("want no match, got %v", err)
	}
}

func TestZeroToleranceMeansExactlyNow(t *testing.T) {
	now := time.Unix(1700000000, 0)
	header, _ := Sign(nil, []string{"s"}, now)
	if err := Verify(nil, header, []string{"s"}, now, 0); err != nil {
		t.Fatalf("at now: %v", err)
	}
	if err := Verify(nil, header, []string{"s"}, now.Add(time.Second), 0); !errors.Is(err, ErrTimestampOutsideTolerance) {
		t.Fatalf("a second later: %v", err)
	}
}

func TestInvalidArguments(t *testing.T) {
	now := time.Unix(1700000000, 0)
	cases := map[string]error{
		"no secrets":         Verify(nil, "t=1,v1=a", nil, now, DefaultTolerance),
		"empty secret":       Verify(nil, "t=1,v1=a", []string{""}, now, DefaultTolerance),
		"negative tolerance": Verify(nil, "t=1,v1=a", []string{"s"}, now, -time.Second),
	}
	for name, err := range cases {
		if !errors.Is(err, ErrInvalidArgument) {
			t.Errorf("%s: want ErrInvalidArgument, got %v", name, err)
		}
	}
	if _, err := Sign(nil, nil, now); !errors.Is(err, ErrInvalidArgument) {
		t.Errorf("Sign with no secrets: %v", err)
	}
}

// FuzzVerify checks that no header makes Verify panic, and that anything Sign produces
// verifies. Under plain go test it runs the shared vectors as its seed corpus.
func FuzzVerify(f *testing.F) {
	for _, v := range loadVectors(f) {
		f.Add([]byte(v.Payload), v.Header, v.Secrets[0])
	}
	now := time.Unix(1700000000, 0)
	f.Fuzz(func(t *testing.T, payload []byte, header, secret string) {
		if secret == "" {
			return
		}
		_ = Verify(payload, header, []string{secret}, now, DefaultTolerance)
		signed, err := Sign(payload, []string{secret}, now)
		if err != nil {
			t.Fatal(err)
		}
		if err := Verify(payload, signed, []string{secret}, now, DefaultTolerance); err != nil {
			t.Fatalf("own signature rejected: %v", err)
		}
	})
}
