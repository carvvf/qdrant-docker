# Qdrant custom image

This repository publishes a hardened `linux/amd64` Qdrant image compiled from
the verified upstream source release corresponding to `qdrant/qdrant:latest`.
Its final runtime base is `ubuntu:24.04`.

Its daily GitHub Actions workflow resolves the official-image manifest digest,
the matching Qdrant source tag and commit, and the Ubuntu runtime manifest
digest. It rebuilds when either immutable input changes, scans the candidate
with Trivy, and publishes it to GHCR only if HIGH and CRITICAL OS or library
findings are absent.

The runtime interface intentionally remains compatible with the official image
and with Ragtime's Qdrant deployment:

- HTTP on port `6333` and gRPC on port `6334`
- `./entrypoint.sh` from `/qdrant`
- root runtime user, required by Ragtime's current TLS guard
- persistent data at `/qdrant/storage` and snapshots at `/qdrant/snapshots`

The image is intentionally amd64-only. It does not publish an arm64 manifest.

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

Build Qdrant v1.19.1 from source on Ubuntu 24.04. This can take several
minutes on the first build because Rust dependencies and the Qdrant binary are
compiled locally:

```bash
docker build --pull --no-cache \
  --build-arg QDRANT_SOURCE_REF=v1.19.1 \
  -t qdrant-custom:local .
```

CI additionally resolves the immutable commit for this tag and fails the build
when the checked-out source does not match it. OCI labels record the Qdrant
source ref and revision, the official-image digest used as a release signal,
and the Ubuntu runtime-base digest.

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

- `Docker: build local image` compiles `qdrant-custom:local` from the default
  Qdrant source release on Ubuntu 24.04.
- `Test: Qdrant runtime` builds the image and runs the Ragtime-compatible
  smoke test.
- `Trivy: scan CVE` builds the image, runs a pinned Trivy container against
  the repository and local image, writes reports under `reports/trivy`, and
  fails on HIGH or CRITICAL findings.
- `Test: all` runs Dockerfile, shell, and workflow linting and the runtime
  test in sequence. Run `Trivy: scan CVE` separately.

The first Trivy run downloads the vulnerability database into
`reports/trivy/cache`; later runs reuse it. Delete that directory to force a
fresh database download.

## Security scope and limitations

Rebuilding on Ubuntu can remediate fixable Ubuntu packages before an official
Qdrant image is refreshed. It does not make Qdrant, Rust, JavaScript, or other
upstream dependencies safe by itself. The image retains Qdrant's SPDX document
and the Trivy gate scans OS and library findings, including dependencies
reported by that document. A candidate with unresolved HIGH or CRITICAL
findings is not published.

## License and third-party components

This repository is licensed under Apache-2.0, matching Qdrant's license. The
published image includes a copy of the Apache-2.0 text at
`/licenses/Apache-2.0.txt`.

The image also contains Qdrant and operating-system packages with their own
licensing and attribution requirements. BuildKit publishes an SBOM attestation
for each release; do not represent the complete container as exclusively
Apache-2.0 without reviewing that SBOM and the upstream SPDX documents.
