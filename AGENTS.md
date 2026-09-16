# AGENTS.md

## Purpose and scope

This repository builds and publishes a custom, hardened Qdrant container image.
The image is derived from `qdrant/qdrant:latest` and is published to GitHub
Container Registry (GHCR).

The primary purpose is to reduce the exposure window when the official Qdrant
image contains fixable operating-system vulnerabilities that have not yet been
addressed upstream. Daily GitHub Actions workflows build a candidate with
current operating-system packages, scan it, and publish it only when it meets
the configured security policy.

This is **not** a fork of the Qdrant source repository. Do not introduce Git
upstream-alignment, branch-synchronization, or source-fork assumptions from
other container repositories.

## Language policy

- Chat and discussion with the user: Italian.
- Repository content: English only, including code, comments, documentation,
  configuration, workflow summaries, operator-facing errors, test names, and
  suggested commit messages.

Translate Italian requirements before writing repository content. Before
finalizing a change, check that no Italian text was introduced outside fixtures
or test data where it is the subject of the test.

## Image and downstream compatibility contract

The image replaces the Qdrant image used by
`../ragtime-rag-orch/docker/services/docker-compose.yml`. Compatibility with
that deployment is mandatory.

Unless a coordinated downstream change has been requested and validated, keep
the upstream Qdrant runtime contract unchanged:

- `WORKDIR /qdrant`
- `CMD ["./entrypoint.sh"]`
- no replacement `ENTRYPOINT`
- runtime user `0:0`
- ports `6333` (HTTP) and `6334` (gRPC)
- writable paths `/qdrant/storage` and `/qdrant/snapshots`
- configuration through the `QDRANT__...` environment variables

Ragtime runs Qdrant with a read-only root filesystem, `cap_drop: ALL`, a
temporary `/tmp`, named volumes for storage and snapshots, and an optional TLS
guard. The TLS tooling relies on the runtime user and command above. Do not
switch to a non-root user, replace the command, change working directories, or
move writable paths without changing and validating Ragtime's Compose, TLS,
and AppArmor integration in the same coordinated work.

Do not add runtime packages merely to implement a health check. The downstream
Compose health check intentionally uses Bash TCP probing because the official
image does not contain `curl` or `openssl`.

## Security and update policy

- Keep `qdrant/qdrant:latest` as the declared base, but resolve its manifest
  digest during CI and record that immutable digest in OCI labels and workflow
  output. This makes a published build traceable and reproducible.
- Apply package-manager updates only in the custom image build. Keep the
  Dockerfile small, avoid unnecessary packages, clean package metadata, and do
  not embed credentials.
- Operating-system package upgrades can remediate fixable Debian CVEs. They do
  not remediate Qdrant binary vulnerabilities, Rust dependency vulnerabilities,
  or findings without an available fix. Never conceal such findings or publish
  a candidate that violates the security policy.
- Scan image vulnerabilities with Trivy. HIGH and CRITICAL findings are the
  default publication gate for OS and library vulnerabilities unless the user
  explicitly changes that policy.
- Produce and retain JSON scan reports as GitHub Actions artifacts. A report
  is evidence, not a reason to weaken the gate.
- Use immutable release tags in the form
  `<qdrant-version>-custom.<N>` and update the mutable `latest` tag only after
  the candidate has passed build, scan, and runtime checks.
- The daily workflow intentionally fails after a successful rebuild and final
  scan to notify downstream operators that they must pull and redeploy the new
  `latest` image. Preserve this behavior unless the user requests another
  notification mechanism.
- Serialize scan/publish runs with a shared GitHub Actions concurrency group.
  This prevents competing runs from racing on `latest` or the custom sequence
  number.

## CI expectations

Use the workflow structure in `../unoserver-docker` as a reference, adapting
it to the Qdrant image workflow rather than copying its Unoserver-specific
preflight logic.

The expected checks are:

1. Resolve the official Qdrant version and multi-architecture base digest.
2. Scan the active GHCR `latest` image and retain the report.
3. Build a custom candidate when the base digest has changed, the active image
   has findings, or a manual workflow explicitly requests a rebuild.
4. Build and scan both `linux/amd64` and `linux/arm64` candidates with Trivy.
5. On `linux/amd64`, start the candidate using constraints equivalent to the
   Ragtime Compose service, then verify `/healthz`, `/readyz`, collection CRUD,
   and persistence across a restart using the storage volume.
6. Publish the versioned tag and `latest` only after every required check
   passes; inspect the published manifest to confirm both architectures.
7. Re-scan the published mutable `latest` tag and intentionally signal the
   downstream-update notification only when a rebuilt image is clean.

Local developer tooling may provide filesystem, Dockerfile configuration, and
image scans. Keep generated reports out of image build contexts and version
control unless the user explicitly requests otherwise.

Use `hadolint` for Dockerfiles and `shellcheck` for shell scripts when those
files are introduced or changed. Consider SBOM generation, provenance, and
keyless signing when their operational ownership is defined; do not add signing
requirements that would prevent emergency vulnerability remediation.

## Downstream delivery and operations

The GHCR package must either be public or the Ragtime hosts must receive and
manage pull credentials. Do not silently turn a public Docker Hub dependency
into an inaccessible private GHCR dependency.

The downstream update procedure is:

```bash
docker compose pull qdrant
docker compose up -d qdrant
```

The existing named volumes must be retained. Do not recommend `docker compose
down -v` for an image update because it deletes Qdrant data.

For development, `latest` is acceptable. For controlled production rollouts,
prefer an explicit immutable `-custom.N` tag so rollback and provenance are
unambiguous.

## Working principles

- Prefer small, additive, clearly documented changes.
- Explain security, runtime, and downstream operational impact whenever a
  change affects them.
- Do not disable, suppress, or downgrade security checks to make a workflow
  pass. State the root cause and whether a finding is fixable.
- Do not add services, change the Qdrant API surface, or alter the Ragtime
  deployment as a side effect of image hardening.
- Before commits or remote changes, inspect the working tree and current
  branch. Use a dedicated feature branch and obtain explicit user authorization
  before committing, pushing, merging, or changing remote state.

## Deliverables

For each meaningful change, report:

1. What changed.
2. Why it supports the image's security and update goal.
3. How to validate it locally or in GitHub Actions.
4. Downstream compatibility and rollout implications.
5. Any remaining vulnerabilities, limitations, or required operator action.
