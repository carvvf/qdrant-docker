#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tools/lib/build_inputs.sh
source "${SCRIPT_DIR}/lib/build_inputs.sh"

resolve_build_inputs
docker build --platform linux/amd64 --pull --no-cache \
  --build-arg "QDRANT_SOURCE_REF=${source_ref}" \
  --build-arg "QDRANT_SOURCE_REVISION=${source_revision}" \
  --build-arg "QDRANT_UPSTREAM_VERSION=${upstream_version}" \
  --build-arg "QDRANT_UPSTREAM_DIGEST=${upstream_digest}" \
  --build-arg "QDRANT_IMAGE_VERSION=${upstream_version}-local" \
  --build-arg "UBUNTU_BASE_IMAGE=${ubuntu_base_ref}" \
  --build-arg "UBUNTU_BASE_DIGEST=${ubuntu_base_digest}" \
  --build-arg "CACHEBUST=$(date -u +%s)" \
  -t "${IMAGE_REF:-qdrant-custom:local}" "${REPO_ROOT}"
