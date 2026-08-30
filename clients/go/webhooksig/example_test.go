package webhooksig_test

import (
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"time"

	"github.com/Sanjith-Shan/Clearinghouse/clients/go/webhooksig"
)

// A handler verifies against the raw body before decoding it, and holds both secrets
// while the endpoint's secret is being rotated.
func Example() {
	secrets := []string{"whsec_current", "whsec_previous"}
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
		if err != nil {
			http.Error(w, "read error", http.StatusBadRequest)
			return
		}
		err = webhooksig.Verify(body, r.Header.Get(webhooksig.Header), secrets, time.Now(), webhooksig.DefaultTolerance)
		switch {
		case err == nil:
			w.WriteHeader(http.StatusOK) // decode body, dedupe on the event id, then act
		case errors.Is(err, webhooksig.ErrInvalidArgument):
			http.Error(w, "misconfigured", http.StatusInternalServerError)
		default:
			http.Error(w, err.Error(), http.StatusBadRequest)
		}
	})

	body := `{"id":"evt_1","object":"event"}`
	header, _ := webhooksig.Sign([]byte(body), []string{"whsec_previous"}, time.Now())
	for _, h := range []string{header, "t=1,v1=forged"} {
		req := httptest.NewRequest(http.MethodPost, "/webhooks", strings.NewReader(body))
		req.Header.Set(webhooksig.Header, h)
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		fmt.Println(strings.TrimSpace(fmt.Sprint(rec.Code, " ", rec.Body.String())))
	}
	// Output:
	// 200
	// 400 no_matching_signature
}
