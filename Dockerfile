# syntax=docker/dockerfile:1

# ============================================================================
# nr-bqs-knox — website backend
#
# Authenticates to Knox Vault using the AppRole authentication method and
# serves a small web page. The AppRole role_id is baked into the image at build
# time; the short-lived secret_id is injected at runtime (never committed).
#
# Build:  docker build --build-arg ROLE_ID=<approle-role-id> -t nr-bqs-knox .
# Run:    VAULT_SECRET_ID=<secret-id> docker run -p 8080:8080 nr-bqs-knox
#
# The application uses only the Go standard library, so the image is tiny and
# contains no vault client dependencies.
# ============================================================================

# --- Build stage -------------------------------------------------------------
FROM golang:1.23-alpine AS build

WORKDIR /src

# Copy the Go module files first so the module cache layer can be cached.
COPY app/go.mod ./go.mod

# The application has no external dependencies (standard library only), so no
# go.sum download step is required. Build the static, stripped binary.
COPY app/ .

ARG ROLE_ID=""
# Bake the AppRole role_id into the binary as a build-time default. It can
# always be overridden at runtime via the VAULT_ROLE_ID environment variable.
RUN CGO_ENABLED=0 GOOS=linux go build \
    -trimpath \
    -ldflags="-s -w -X main.roleID=${ROLE_ID}" \
    -o /out/nr-bqs-knox ./

# --- Runtime stage -----------------------------------------------------------
# scratch keeps the image minimal and, combined with a static binary, requires
# no libc at runtime.
FROM scratch

COPY --from=build /out/nr-bqs-knox /usr/local/bin/nr-bqs-knox

# Default environment. Override at runtime as needed:
#   VAULT_SECRET_ID  required — inject via a Kubernetes secret
#   VAULT_ROLE_ID    optional — overrides the baked-in role_id
#   VAULT_ADDR       optional — defaults to the Knox Vault endpoint
#   VAULT_SECRET_PATH optional — secret path to read
ENV VAULT_ADDR="https://knox.io.nrs.gov.bc.ca" \
    VAULT_SECRET_PATH="secret/data/nr-bqs-knox" \
    PORT="8080"

EXPOSE 8080

# Run as the unprivileged user that Alpine/golang images provision by default.
USER 65532:65532

ENTRYPOINT ["/usr/local/bin/nr-bqs-knox"]
