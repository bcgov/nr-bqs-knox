package main

import (
	"crypto/tls"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

// newHTTPClient returns an *http.Client whose transport honors VAULT_INSECURE.
// TLS verification is only skipped for explicitly non-production test Vault
// servers; in production VAULT_INSECURE must remain unset.
func newHTTPClient(timeout time.Duration) *http.Client {
	transport := &http.Transport{}
	if strings.EqualFold(os.Getenv("VAULT_INSECURE"), "true") {
		transport.TLSClientConfig = &tls.Config{InsecureSkipVerify: true} //nolint:gosec // opt-in for test Vault only
		log.Printf("WARNING: TLS verification disabled (VAULT_INSECURE=true)")
	}
	return &http.Client{Transport: transport, Timeout: timeout}
}
