package loadgen

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
)

// CreateMerchant creates a merchant through the admin bootstrap endpoint
// (POST /v1/merchants, see docs/design/api.md) and returns its secret key, so a run
// can start from nothing but the server URL and CLEARINGHOUSE_ADMIN_TOKEN.
func CreateMerchant(ctx context.Context, client *http.Client, base, adminToken, name string) (string, error) {
	form := url.Values{"name": {name}}.Encode()
	req, err := http.NewRequestWithContext(ctx, "POST", strings.TrimRight(base, "/")+"/v1/merchants", strings.NewReader(form))
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "Bearer "+adminToken)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return "", err
	}
	if resp.StatusCode != http.StatusCreated {
		return "", fmt.Errorf("create merchant: HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	var m struct {
		SecretKey string `json:"secret_key"`
	}
	if err := json.Unmarshal(body, &m); err != nil || m.SecretKey == "" {
		return "", fmt.Errorf("create merchant: no secret_key in response")
	}
	return m.SecretKey, nil
}
