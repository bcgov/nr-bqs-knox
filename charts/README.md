# nr-bqs-knox OpenShift deployment chart

OpenShift/Helm deployment for the **nr-bqs-knox** website backend. The
application authenticates to the BC Gov **Knox Vault** using the **AppRole**
authentication method and serves a small web page.

The container image lives on **GitHub Container Registry (GHCR)**:

    ghcr.io/bcgov-nr/nr-bqs-knox:<tag>

## How the AppRole auth works

- **role_id** is baked into the image at build time via the Dockerfile
  `--build-arg ROLE_ID`. It normally does **not** need to be set at runtime;
  override it only with `image.vaultRoleID` if required.
- **secret_id** is short-lived and is injected at runtime from a Kubernetes
  secret (`image.vaultSecretIDSecretName`, key `VAULT_SECRET_ID`). Create that
  secret before installing the chart.

## Prerequisites

1. A Knox Vault AppRole **secret_id** for this service, stored in a Kubernetes
   secret named `nr-bqs-knox-vault` with key `VAULT_SECRET_ID` (override via
   `image.vaultSecretIDSecretName` / `image.vaultSecretIDKey`).
2. Access to pull the image from GHCR. Either create an `ImagePullSecret`
   (the chart creates one for you — see below) or set
   `imagePullSecret.create: false` and point `image.imagePullSecretName` at an
   existing secret.

## Install

Set the image tag to the version produced by the build/release pipeline and
provide the GHCR pull credentials:

    helm install nr-bqs-knox ./dc \
      --namespace oscar \
      --create-namespace \
      --set image.tag=<version> \
      --set imagePullSecret.dockerConfigJSON="$(cat .dockerconfigjson | base64 -w0)"

If the image is public or the pull secret already exists in the namespace:

    helm install nr-bqs-knox ./dc \
      --namespace oscar --create-namespace \
      --set image.tag=<version> \
      --set imagePullSecret.create=false

## Resources

| File | Description |
|------|-------------|
| `templates/serviceaccount.yaml` | ServiceAccount (+ optional `imagePullSecrets`) |
| `templates/secret.yaml` | GHCR `ImagePullSecret` (when `imagePullSecret.create`) |
| `templates/deployment.yaml` | Deployment running the `nr-bqs-knox` container |
| `templates/service.yaml` | `ClusterIP` Service exposing port 8080 |
| `templates/route.yaml` | OpenShift `Route` for HTTPS ingress (when `route.enabled`) |

## Key values

| Value | Default | Description |
|-------|---------|-------------|
| `image.registry` | `ghcr.io` | Container registry host |
| `image.repository` | `bcgov-nr/nr-bqs-knox` | Image repository on the registry |
| `image.tag` | `0.0.0` | Image tag (set to the pipeline version) |
| `image.vaultSecretIDSecretName` | `nr-bqs-knox-vault` | Secret holding `VAULT_SECRET_ID` |
| `image.vaultSecretIDKey` | `VAULT_SECRET_ID` | Key inside that secret |
| `image.vaultRoleID` | `""` | Override the baked-in role_id |
| `image.vaultAddr` | `https://knox.io.nrs.gov.bc.ca` | Knox Vault endpoint |
| `image.vaultSecretPath` | `secret/data/nr-bqs-knox` | Secret path to read (KV v2) |
| `image.vaultNamespace` | `""` | Vault namespace (optional) |
| `image.vaultInsecure` | `false` | Skip TLS verification (non-prod only) |
| `image.port` | `8080` | HTTP listen port |
| `service.type` | `ClusterIP` | Service type |
| `route.enabled` | `true` | Create an OpenShift `Route` |
| `route.tls.termination` | `edge` | TLS termination mode |
| `imagePullSecret.create` | `true` | Create the GHCR `ImagePullSecret` |
| `imagePullSecret.dockerConfigJSON` | `""` | Base64-encoded `.dockerconfigjson` |

## Validate locally

    helm lint ./dc
    helm template nr-bqs-knox ./dc --set image.tag=v1.0.0 \
      --set imagePullSecret.dockerConfigJSON="$(echo -n '{"auths":{"ghcr.io":{"auth":"x"}}}' | base64 -w0)"
