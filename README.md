# Qdrant custom image

> [!NOTE]
> **Written with AI assistance.** This document was generated with the help of an AI
> assistant and may contain inaccuracies. Verify anything critical against the source code.

This repository publishes a hardened `linux/amd64` Qdrant image compiled from
the verified upstream source release corresponding to `qdrant/qdrant:latest`.
Its final runtime base is `ubuntu:24.04`.

Its daily GitHub Actions workflow resolves the official-image manifest digest,
the matching Qdrant source tag and commit, and the Ubuntu runtime manifest
digest. It rebuilds when either immutable input changes or when the active
image was built from another commit of this repository, scans the candidate
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

Build the Qdrant release currently identified by `qdrant/qdrant:latest` from
source on Ubuntu 24.04, using the same input resolver as GitHub Actions:

```bash
bash tools/build_local_image.sh
```

The VS Code `Docker: build local image` task invokes this entrypoint. It resolves
and pulls the official `linux/amd64` Qdrant image as a release signal, verifies
its version, resolves the matching source tag and commit, and pins the Ubuntu
24.04 runtime manifest digest. The official Qdrant image is not used as the
runtime base. All resolved values are passed explicitly to the Dockerfile;
the source checkout must match the expected commit. The first build can take
several minutes because Rust dependencies and the Qdrant binary are compiled.
The entrypoint requires Bash, Docker, and Git, with access to Docker Hub and
GitHub; no Python environment is needed.

To select a specific release while retaining the same verification:

```bash
QDRANT_SOURCE_REF=v1.19.2 bash tools/build_local_image.sh
```

`tools/lib/build_inputs.sh` owns the shared resolver used by the local build,
the standalone build workflow, daily scan, and publication preflight.
`bash tools/resolve_build_inputs.sh` prints its resolved `key=value` outputs
without compiling or publishing an image. Optional environment inputs are
`QDRANT_UPSTREAM_REF`, `QDRANT_UPSTREAM_VERSION`, `QDRANT_UPSTREAM_DIGEST`,
`QDRANT_SOURCE_REF`, `QDRANT_SOURCE_REVISION`, `UBUNTU_BASE_IMAGE`, and
`UBUNTU_BASE_DIGEST`. Version, tag, commit, or digest mismatches abort resolution.
Explicit digest references retain their recorded release signal rather than
resolving `latest` again. Ubuntu inputs must identify the official 24.04 image.

Local OCI versions use `<qdrant-version>-local`; published images retain
`<qdrant-version>-custom.<N>`. OCI labels record the source ref and revision,
official-image digest, and Ubuntu runtime digest in both paths. The image
version label is set explicitly instead of inheriting Ubuntu's `24.04` label.
Direct Dockerfile builds require verified source arguments; there is no stale
Qdrant release fallback. This aligns input selection and provenance, not binary
reproducibility across different build times. Publication still requires the
existing vulnerability and runtime gates.

Run the resolver regression tests with Python 3's standard library. Docker and
Git are simulated; these tests require no daemon, network, or package installs:

```bash
python3 -m unittest discover -s tests -p test_build_inputs.py
```

The three build/scan/publish workflows run this check before resolving inputs.

Run the compatibility smoke test. It applies the relevant Ragtime container
restrictions, checks the running server version against its upstream label,
creates a collection and point, restarts Qdrant, verifies persistence, and removes
the test resources:

```bash
IMAGE_REF=qdrant-custom:local bash tests/test-qdrant-image.sh
```

Local and CI scans use the newest published patch release of Trivy 0.76.
`scripts/trivy/resolve-version.sh` resolves it from GitHub's release list,
ignoring drafts, pre-releases, and other minor series, so scanner fixes arrive
without a repository change; moving to another minor series is a deliberate
edit to `TRIVY_SERIES` in that script. Each workflow scan records the resolved
version in its job summary. `TRIVY_VERSION` selects an explicit 0.76 release.
The resolver requires curl and jq; it uses `GH_TOKEN`, `GITHUB_TOKEN`, or an
authenticated GitHub CLI when available to avoid anonymous API rate limits.

For a local Trivy filesystem, Dockerfile, and image scan, use the same
Trivy container as CI; no host Trivy installation is required:

```bash
IMAGE_REF=qdrant-custom:local bash tools/dev_trivy_scan.sh
```

Alternatively, install any Trivy 0.76.x release on the host and run
`IMAGE_REF=qdrant-custom:local scripts/trivy/scan-image.sh`.
This entrypoint rejects other minor series to keep scans aligned with CI.

## Telemetry policy

The runtime image sets `QDRANT__TELEMETRY_DISABLED=true`, so Qdrant's
anonymous reporting is disabled by default for local builds and GHCR releases,
even without a Compose override. This uses Qdrant's native configuration;
an explicit runtime override can re-enable reporting. Local metrics remain
available. The shared runtime smoke test checks the image environment and the
startup confirmation without setting a telemetry override in `docker run`.

All repository Trivy entrypoints disable anonymous usage reporting with
`TRIVY_DISABLE_TELEMETRY=true` and announcement/version requests with
`TRIVY_SKIP_VERSION_CHECK=true`. Workflows using `trivy-action` receive these
settings through workflow environment variables; Docker invocations pass them
explicitly into the scanner container. The native local script exports both
settings before invoking Trivy. Scans use the newest Trivy 0.76.x by default.
Vulnerability database downloads, security checks, JSON reports, and the
HIGH/CRITICAL publication gate remain active. These opt-outs do not make
builds or scans network-free.

Image defaults take effect only after rebuilding and redeploying.

Every push to `master` starts `rebuild-on-push.yml`, which runs the daily
workflow with the same gates. The image records the commit of this repository it
was built from (`io.github.carvvf.qdrant-docker.repository.revision`), and both
workflows rebuild when the active image carries another commit, also when the
upstream version and runtime base are unchanged. Documentation-only commits are
included. Daily, manual and push-triggered runs of `scan-active-image.yml` are
serialized, so two of them never both rebuild the same commit: a run started
while another is in progress waits, and GitHub keeps only the most recent waiting
run. A waiting manual `force_rebuild` replaced this way must be requested again.
A `publish-custom.yml` run started directly is serialized only with other
publications. To rebuild without a new commit, request one manually:

```bash
gh workflow run scan-active-image.yml --repo carvvf/qdrant-docker -f force_rebuild=true
```

The workflow runs the existing build, scan, runtime-test, and publication gates.
After publication, follow the downstream update procedure above, retaining the
data volumes. The deliberate failure notification after a clean rebuild remains
part of that procedure.

## VS Code tasks

The workspace provides these tasks without requiring locally installed lint or
scanner binaries:

- `Docker: build local image` compiles `qdrant-custom:local` from the
  verified official Qdrant release signal on Ubuntu 24.04.
- `Test: Qdrant runtime` builds the image and runs the Ragtime-compatible
  smoke test.
- `Trivy: scan CVE` builds the image, runs a pinned Trivy container against
  the repository and local image, writes reports under `reports/trivy`, and
  fails on HIGH or CRITICAL findings.
- `Test: build inputs` checks release resolution and mismatch failures using
  simulated infrastructure.
- `Test: all` runs resolver regression tests, Dockerfile, shell, and workflow
  linting, and the runtime test in sequence. Run `Trivy: scan CVE` separately.

The first Trivy run downloads the vulnerability database into
`reports/trivy/cache`; later runs reuse it. Delete that directory to force a
fresh database download.

## Security scope and limitations

Rebuilding on Ubuntu can remediate fixable Ubuntu packages before an official
Qdrant image is refreshed. It does not make Qdrant, Rust, JavaScript, or other
upstream dependencies safe by itself. The image retains Qdrant's SPDX document
and the Trivy gate scans OS and library findings, including dependencies
reported by that document: it lists the Rust crates compiled into the server,
which Trivy cannot identify in the binary itself. The gate measures the server:
the Web UI's SPDX document (`/qdrant/static/qdrant-web-ui.spdx.json`) is excluded,
because the dashboard's JavaScript runs in the operator's browser. The Web UI
remains in the image. A candidate with unresolved HIGH or CRITICAL findings is
not published.

## License and third-party components

This repository's own original content (the Dockerfile, CI workflows,
scripts, and documentation) is licensed under Apache-2.0; see `LICENSE`.
That license is separate from Qdrant's: the published image embeds Qdrant's
own license text, copied from the resolved source revision at build time, at
`/licenses/Apache-2.0.txt`. This split matters now that the image is compiled
from Qdrant source rather than repackaged from the official binary.

The image also contains Qdrant and operating-system packages with their own
licensing and attribution requirements. BuildKit publishes an SBOM attestation
for each release; do not represent the complete container as exclusively
Apache-2.0 without reviewing that SBOM and the upstream SPDX documents.
