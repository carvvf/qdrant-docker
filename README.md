# Qdrant custom image

This repository publishes a hardened Qdrant image derived from
`qdrant/qdrant:latest`.

Its daily GitHub Actions workflow resolves the upstream manifest digest,
rebuilds the image with current operating-system packages when required, scans
the candidate with Trivy, and publishes it to GHCR only if HIGH and CRITICAL
OS or library findings are absent.

The runtime interface intentionally remains compatible with the official image
and with Ragtime's Qdrant deployment:

- HTTP on port `6333` and gRPC on port `6334`
- `./entrypoint.sh` from `/qdrant`
- root runtime user, required by Ragtime's current TLS guard
- persistent data at `/qdrant/storage` and snapshots at `/qdrant/snapshots`

## Image tags

Published images use two tags:

- `<qdrant-version>-custom.<N>` is immutable and records the custom rebuild.
- `latest` moves only after the candidate has passed the build, Trivy, and
  runtime test gates.

The daily workflow deliberately reports failure after a clean rebuild. This is
the downstream update signal: an operator should pull and redeploy the new
image rather than treating the notification as a failed publication.

For a controlled rollout, use an immutable tag. For example:

```yaml
image: ghcr.io/carvvf/qdrant-docker:1.19.1-custom.2
```

For a development deployment that tracks verified daily updates:

```yaml
image: ghcr.io/carvvf/qdrant-docker:latest
```

The GHCR package must be public or the deployment host must authenticate before
pulling it.

## Downstream update

The image is intended to replace the Qdrant service image in Ragtime. Retain
the existing storage and snapshots volumes while updating:

```bash
docker compose pull qdrant
docker compose up -d qdrant
```

Do not use `docker compose down -v` for an image update because it removes the
Qdrant volumes.

## Local build and validation

Build an image using the current official base:

```bash
docker build --pull --no-cache -t qdrant-custom:local .
```

Run the compatibility smoke test. It applies the relevant Ragtime container
restrictions, creates a collection and point, restarts Qdrant, verifies
persistence, and removes the test resources:

```bash
IMAGE_REF=qdrant-custom:local bash tests/test-qdrant-image.sh
```

For a local Trivy filesystem, Dockerfile, and image scan, install Trivy and
run:

```bash
IMAGE_REF=qdrant-custom:local scripts/trivy/scan-image.sh
```

## VS Code tasks

The workspace provides these tasks without requiring locally installed lint or
scanner binaries:

- `Docker: build local image` rebuilds `qdrant-custom:local` from the current
  upstream image and package repositories.
- `Test: Qdrant runtime` builds the image and runs the Ragtime-compatible
  smoke test.
- `Trivy: scan CVE` builds the image, runs a pinned Trivy container against
  the repository and local image, writes reports under `reports/trivy`, and
  fails on HIGH or CRITICAL findings.
- `Test: all` runs Dockerfile, shell, and workflow linting, the runtime test,
  and the Trivy CVE gate in sequence.

The first Trivy run downloads the vulnerability database into
`reports/trivy/cache`; later runs reuse it. Delete that directory to force a
fresh database download.

## License and third-party components

This repository is licensed under Apache-2.0, matching Qdrant's license. The
published image includes a copy of the Apache-2.0 text at
`/licenses/Apache-2.0.txt`.

The image also contains Qdrant and operating-system packages with their own
licensing and attribution requirements. BuildKit publishes an SBOM attestation
for each release; do not represent the complete container as exclusively
Apache-2.0 without reviewing that SBOM and the upstream SPDX documents.
