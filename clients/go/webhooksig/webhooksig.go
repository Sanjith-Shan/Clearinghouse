// Package webhooksig verifies the Clearinghouse-Signature header on webhook
// deliveries from Clearinghouse.
//
// The header looks like
//
//	Clearinghouse-Signature: t=1700000000,v1=<hex HMAC-SHA256(secret, "1700000000." + raw body)>
//
// with one v1 per active secret while the endpoint's secret is being rotated. A
// delivery is valid if any v1 matches any secret the caller holds and the timestamp
// is within the tolerance of now, in either direction.
//
// This is the reference implementation for Go consumers. It follows the parsing rules
// of the Ruby verifier exactly, and both run the vectors in spec/fixtures/signatures.json.
// The rules and the reasons for them are in docs/design/webhook-security.md.
package webhooksig

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// Header is the HTTP header that carries the signature.
const Header = "Clearinghouse-Signature"

// DefaultTolerance is how far a delivery's timestamp may be from now.
const DefaultTolerance = 5 * time.Minute

// The verification errors. Their messages are the error codes used by the shared test
// vectors, so err.Error() can be logged or compared directly. Use errors.Is.
var (
	ErrNoMatchingSignature       = errors.New("no_matching_signature")
	ErrTimestampOutsideTolerance = errors.New("timestamp_outside_tolerance")
	ErrMalformedHeader           = errors.New("malformed_header")
)

// ErrInvalidArgument reports a mistake by the caller rather than a bad delivery.
var ErrInvalidArgument = errors.New("webhooksig: invalid argument")

// maxTimestampDigits keeps every timestamp inside int64 without overflow checks.
const maxTimestampDigits = 15

type parsed struct {
	timestamp     int64
	timestampText string
	signatures    []string
}

// Verify checks a delivery. payload must be the raw request body, byte for byte.
// secrets are the endpoint secrets the caller holds (during a rotation, hold both).
//
// It returns nil, ErrMalformedHeader, ErrNoMatchingSignature or
// ErrTimestampOutsideTolerance for a delivery, or an ErrInvalidArgument error when the
// caller passed no secrets, an empty secret or a negative tolerance. The signature is
// checked before the timestamp. The tolerance counts whole seconds, and zero means
// "exactly now"; it never disables the check.
func Verify(payload []byte, header string, secrets []string, now time.Time, tolerance time.Duration) error {
	if err := checkSecrets(secrets); err != nil {
		return err
	}
	if tolerance < 0 {
		return fmt.Errorf("%w: negative tolerance %s", ErrInvalidArgument, tolerance)
	}

	p, ok := parse(header)
	if !ok {
		return ErrMalformedHeader
	}

	if !matchesAny(p, payload, secrets) {
		return ErrNoMatchingSignature
	}

	// Inclusive boundary, whole seconds: exactly tolerance old or ahead passes.
	skew := now.Unix() - p.timestamp
	if skew < 0 {
		skew = -skew
	}
	if skew > int64(tolerance/time.Second) {
		return ErrTimestampOutsideTolerance
	}
	return nil
}

// Sign builds a header for payload at timestamp, one v1 per secret. Clearinghouse signs
// deliveries itself; this exists so consumers can write tests against their handlers.
func Sign(payload []byte, secrets []string, timestamp time.Time) (string, error) {
	if err := checkSecrets(secrets); err != nil {
		return "", err
	}
	t := strconv.FormatInt(timestamp.Unix(), 10)
	parts := []string{"t=" + t}
	for _, s := range secrets {
		parts = append(parts, "v1="+hex.EncodeToString(compute(s, t, payload)))
	}
	return strings.Join(parts, ","), nil
}

// parse applies the grammar
//
//	element *( "," element ),  element = OWS key "=" value OWS,  OWS = spaces and tabs
//
// with exactly one t of 1 to 15 ASCII digits and at least one non-empty v1. Other keys
// are ignored. An empty element, an element without "=" or with an empty key is
// malformed.
func parse(header string) (parsed, bool) {
	var p parsed
	seenT := false
	for _, raw := range strings.Split(header, ",") {
		element := strings.Trim(raw, " \t")
		key, value, found := strings.Cut(element, "=")
		if !found || key == "" {
			return p, false
		}
		switch key {
		case "t":
			if seenT || !isTimestamp(value) {
				return p, false
			}
			ts, err := strconv.ParseInt(value, 10, 64)
			if err != nil {
				return p, false
			}
			seenT = true
			p.timestamp = ts
			p.timestampText = value
		case "v1":
			if value == "" {
				return p, false
			}
			p.signatures = append(p.signatures, value)
		}
	}
	if !seenT || len(p.signatures) == 0 {
		return p, false
	}
	return p, true
}

func isTimestamp(s string) bool {
	if len(s) == 0 || len(s) > maxTimestampDigits {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// matchesAny compares each candidate, as the lowercase hex string it arrived as,
// against the expected hex for each secret. hmac.Equal is constant time for equal
// lengths; a length mismatch only reveals the candidate's length, which the sender
// chose. Uppercase hex does not match, as in the Ruby verifier and Stripe's libraries.
func matchesAny(p parsed, payload []byte, secrets []string) bool {
	expected := make([][]byte, len(secrets))
	for i, s := range secrets {
		sum := compute(s, p.timestampText, payload)
		expected[i] = []byte(hex.EncodeToString(sum))
	}
	for _, candidate := range p.signatures {
		c := []byte(candidate)
		for _, want := range expected {
			if hmac.Equal(want, c) {
				return true
			}
		}
	}
	return false
}

// compute signs the timestamp text exactly as it appeared in the header.
func compute(secret, timestampText string, payload []byte) []byte {
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(timestampText))
	mac.Write([]byte{'.'})
	mac.Write(payload)
	return mac.Sum(nil)
}

func checkSecrets(secrets []string) error {
	if len(secrets) == 0 {
		return fmt.Errorf("%w: no secrets", ErrInvalidArgument)
	}
	for _, s := range secrets {
		if s == "" {
			return fmt.Errorf("%w: empty secret", ErrInvalidArgument)
		}
	}
	return nil
}
