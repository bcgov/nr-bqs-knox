// Command nr-bqs-knox is a small website backend that authenticates to Knox
// Vault using the AppRole authentication method and retrieves a set of secrets,
// which it then renders as a simple web page.
//
// The AppRole method is the recommended approach for container workloads: the
// role_id is baked into the image at build time, and a short-lived secret_id is
// provided at runtime as a Kubernetes secret. The app caches the resulting
// client token and only re-authenticates when the lease is close to expiring,
// so it is efficient and does not hit Vault on every request.
//
// Required environment variables:
//
//	VAULT_ROLE_ID     AppRole role_id      (may be supplied at build via --build-arg ROLE_ID)
//	VAULT_SECRET_ID   AppRole secret_id    (must be supplied at runtime)
//
// Optional environment variables:
//
//	VAULT_ADDR        Vault base URL        (default: https://knox.io.nrs.gov.bc.ca)
//	VAULT_SECRET_PATH secret path to read   (default: secret/data/nr-bqs-knox, KV v2)
//	VAULT_NAMESPACE   Vault namespace       (default: none)
//	VAULT_INSECURE    "true" to skip TLS verification (default: false)
//	PORT              HTTP listen port       (default: 8080)
//
// It uses only the Go standard library, so no go.sum is required.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

// roleID is the AppRole role_id baked into the image at build time via
// --build-arg ROLE_ID=... (see Dockerfile). It can always be overridden at
// runtime by the VAULT_ROLE_ID environment variable.
//
// It is declared as a plain string literal so the Go linker's
// "-X main.roleID=..." flag can override its value; a runtime initializer such
// as os.Getenv(...) would clobber the linked value at init time.
var roleID = ""

const (
	defaultVaultAddr     = "https://knox.io.nrs.gov.bc.ca"
	defaultSecretPath    = "secret/data/nr-bqs-knox" // KV v2 data path
	defaultPort          = "8080"
	// refresh 60s before the lease expires so we never serve an expired token.
	refreshBeforeExpiry = 60 * time.Second
)

// vaultResponse is the top-level shape returned by the AppRole login endpoint.
type vaultLoginResponse struct {
	Auth struct {
		ClientToken   string `json:"client_token"`
		LeaseDuration int    `json:"lease_duration"`
	} `json:"auth"`
	Warnings []string `json:"warnings"`
}

// vaultSecretResponse is the envelope returned when reading a KV secret.
// For KV v2 the actual payload lives under data.data; for KV v1 under data.
type vaultSecretResponse struct {
	Data map[string]interface{} `json:"data"`
}

// vaultClient performs AppRole authentication and reads secrets. It caches the
// client token and refreshes it lazily, just before it would expire.
type vaultClient struct {
	addr    string
	roleID  string
	secretID string
	path    string
	namespace string
	insecure bool

	http *http.Client

	mu          sync.Mutex
	token       string
	expiry      time.Time
}

// auth logs in via AppRole when the cached token is missing or near expiry,
// returning a valid client token.
func (c *vaultClient) auth() (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	// Reuse the cached token while it still has enough life left.
	if c.token != "" && time.Now().Before(c.expiry.Add(-refreshBeforeExpiry)) {
		return c.token, nil
	}

	resp, err := c.http.Post(
		c.addr+"/v1/auth/approle/login",
		"application/json",
		strings.NewReader(fmt.Sprintf(`{"role_id":%q,"secret_id":%q}`, c.roleID, c.secretID)),
	)
	if err != nil {
		return "", fmt.Errorf("approle login request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return "", fmt.Errorf("approle login failed: HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}

	var parsed vaultLoginResponse
	if err := json.NewDecoder(resp.Body).Decode(&parsed); err != nil {
		return "", fmt.Errorf("decode login response: %w", err)
	}
	if parsed.Auth.ClientToken == "" {
		return "", fmt.Errorf("approle login returned an empty client token")
	}

	// Default lease to a conservative 1h if the server did not report one.
	lease := time.Duration(parsed.Auth.LeaseDuration) * time.Second
	if lease <= 0 {
		lease = time.Hour
	}

	c.token = parsed.Auth.ClientToken
	c.expiry = time.Now().Add(lease)
	log.Printf("authenticated to %s via AppRole (lease %s)", c.addr, lease)
	return c.token, nil
}

// read fetches a single KV secret path and returns its flattened string values.
// It transparently supports both KV v1 (payload under .data) and KV v2
// (payload under .data.data).
func (c *vaultClient) read() (map[string]string, error) {
	token, err := c.auth()
	if err != nil {
		return nil, err
	}

	url := fmt.Sprintf("%s/v1/%s", c.addr, strings.TrimPrefix(c.path, "v1/"))
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("X-Vault-Token", token)
	if c.namespace != "" {
		req.Header.Set("X-Vault-Namespace", c.namespace)
	}

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("secret read request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return nil, fmt.Errorf("secret read failed: HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}

	var envelope vaultSecretResponse
	if err := json.NewDecoder(resp.Body).Decode(&envelope); err != nil {
		return nil, fmt.Errorf("decode secret response: %w", err)
	}

	// KV v2 nests the payload one level deeper under data.data.
	payload := envelope.Data
	if inner, ok := payload["data"].(map[string]interface{}); ok {
		payload = inner
	}

	// Flatten non-secret scalar values into a map for display.
	out := make(map[string]string, len(payload))
	for k, v := range payload {
		switch typed := v.(type) {
		case string:
			out[k] = typed
		case float64:
			out[k] = fmt.Sprintf("%v", typed)
		case bool:
			out[k] = fmt.Sprintf("%t", typed)
		default:
			// Skip nested maps/slices in this basic renderer.
		}
	}
	return out, nil
}

// newClient builds a vaultClient from the environment, failing fast if the
// required credentials are not present so misconfiguration is obvious at start.
func newClient() (*vaultClient, error) {
	r := os.Getenv("VAULT_ROLE_ID")
	if r == "" {
		r = roleID // build-time fallback
	}
	s := os.Getenv("VAULT_SECRET_ID")
	if r == "" || s == "" {
		return nil, fmt.Errorf("VAULT_ROLE_ID and VAULT_SECRET_ID must both be set")
	}

	addr := os.Getenv("VAULT_ADDR")
	if addr == "" {
		addr = defaultVaultAddr
	}
	addr = strings.TrimRight(addr, "/")

	path := os.Getenv("VAULT_SECRET_PATH")
	if path == "" {
		path = defaultSecretPath
	}

	return &vaultClient{
		addr:      addr,
		roleID:    r,
		secretID:  s,
		path:      path,
		namespace: os.Getenv("VAULT_NAMESPACE"),
		http:      newHTTPClient(30 * time.Second),
	}, nil
}

func main() {
	client, err := newClient()
	if err != nil {
		log.Fatalf("configuration error: %v", err)
	}

	// Eagerly authenticate and fetch at startup so the page is ready to serve
	// and any credential/permission problem surfaces immediately.
	if _, err := client.read(); err != nil {
		log.Printf("WARNING: initial secret retrieval failed: %v", err)
	}

	mux := http.NewServeMux()

	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, "ok\n")
	})

	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		serveHome(w, client)
	})

	port := os.Getenv("PORT")
	if port == "" {
		port = defaultPort
	}
	addr := ":" + port
	log.Printf("listening on %s", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatalf("server error: %v", err)
	}
}

// serveHome renders the website, fetching the current secret values on demand.
func serveHome(w http.ResponseWriter, c *vaultClient) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")

	secrets, err := c.read()
	if err != nil {
		http.Error(w, fmt.Sprintf("vault unavailable: %v", err), http.StatusBadGateway)
		return
	}

	var b strings.Builder
	b.WriteString(`<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">`)
	b.WriteString(`<meta name="viewport" content="width=device-width, initial-scale=1">`)
	b.WriteString(`<title>nr-bqs-knox</title>`)
	b.WriteString(`<style>body{font-family:system-ui,sans-serif;margin:3rem auto;max-width:40rem;line-height:1.5}
		h1{margin-bottom:0}code{background:#f4f4f4;padding:.1rem .3rem;border-radius:4px}
		.muted{color:#666}table{border-collapse:collapse;margin-top:1rem}
		th,td{text-align:left;padding:.4rem .8rem;border-bottom:1px solid #eee}
		th{color:#333}kbd{background:#eee;padding:.1rem .4rem;border-radius:4px}</style></head><body>`)
	b.WriteString(`<h1>nr-bqs-knox</h1>`)
	b.WriteString(`<p class="muted">Website backend authenticated to ` + escapeHTML(c.addr) +
		` via <strong>AppRole</strong> and read <code>` + escapeHTML(c.path) + `</code>.</p>`)
	b.WriteString(`<table><thead><tr><th>Key</th><th>Value</th></tr></thead><tbody>`)
	for k, v := range secrets {
		b.WriteString(`<tr><td><code>` + escapeHTML(k) + `</code></td><td>` + maskValue(escapeHTML(v)) + `</td></tr>`)
	}
	b.WriteString(`</tbody></table>`)
	b.WriteString(`<p class="muted">Sensitive values are masked. Use <kbd>VAULT_SECRET_ID</kbd> and ` +
		`<kbd>VAULT_ROLE_ID</kbd> to authenticate.</p>`)
	b.WriteString(`</body></html>`)
	_, _ = io.WriteString(w, b.String())
}

// maskValue redacts the middle of a value so the demo page never exposes full
// secrets while still proving retrieval worked.
func maskValue(s string) string {
	if len(s) <= 4 {
		return "****"
	}
	keep := 2
	if len(s)/2 > keep {
		keep = len(s) / 3
	}
	prefix := s[:keep]
	suffix := s[len(s)-keep:]
	return prefix + strings.Repeat("*", max(4, len(s)-keep*2)) + suffix
}

func escapeHTML(s string) string {
	replacer := strings.NewReplacer(
		"&", "&amp;",
		"<", "&lt;",
		">", "&gt;",
		`"`, "&quot;",
		"'", "&#39;",
	)
	return replacer.Replace(s)
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}
