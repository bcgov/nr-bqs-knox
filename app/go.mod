module github.com/bcgov-nr/nr-bqs-knox/app

go 1.23

// This module intentionally uses only the Go standard library so the build
// needs no external module downloads and no go.sum, keeping the image tiny and
// the build hermetic. Vault is reached over its HTTP API using net/http.
