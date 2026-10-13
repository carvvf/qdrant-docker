#!/usr/bin/env bash
# Shared resolution of official release signals and immutable build inputs.

build_input_error() {
  printf 'Build input error: %s\n' "$1" >&2
  return 1
}

pull_image_digest() {
  local reference="$1"
  local digest
  docker pull --platform linux/amd64 "${reference}" >&2 || return
  if [[ "${reference}" == *@* ]]; then
    digest="${reference##*@}"
  else
    digest="$(docker image inspect "${reference}" --format '{{index .RepoDigests 0}}')" || return
    digest="${digest##*@}"
  fi
  if [[ ! "${digest}" =~ ^sha256:[a-f0-9]{64}$ ]]; then
    build_input_error "Invalid manifest digest for ${reference}: ${digest}"
    return 1
  fi
  printf '%s\n' "${digest}"
}

resolve_build_inputs() {
  local required
  for required in docker git awk; do
    command -v "${required}" >/dev/null || { build_input_error "${required} is required."; return 1; }
  done

  local requested_version="${QDRANT_UPSTREAM_VERSION:-}"
  local requested_source="${QDRANT_SOURCE_REF:-}"
  local requested_digest="${QDRANT_UPSTREAM_DIGEST:-}"
  local tag_revisions
  if [ -z "${requested_version}" ] && [ -n "${requested_source}" ]; then
    requested_version="${requested_source#v}"
  fi
  requested_version="${requested_version#v}"
  if [ -n "${requested_version}" ] && [[ ! "${requested_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z._-]+)?$ ]]; then
    build_input_error "Unsupported Qdrant version: ${requested_version}"
    return 1
  fi
  if [ -n "${requested_digest}" ] && [[ ! "${requested_digest}" =~ ^sha256:[a-f0-9]{64}$ ]]; then
    build_input_error "Invalid requested Qdrant digest: ${requested_digest}"
    return 1
  fi

  upstream_ref="${QDRANT_UPSTREAM_REF:-}"
  if [ -z "${upstream_ref}" ]; then
    if [ -n "${requested_digest}" ]; then
      upstream_ref="qdrant/qdrant@${requested_digest}"
    else
      upstream_ref="qdrant/qdrant:${requested_version:-latest}"
    fi
  fi
  if [[ ! "${upstream_ref}" =~ ^qdrant/qdrant(:[A-Za-z0-9_][A-Za-z0-9_.-]*|@sha256:[a-f0-9]{64})$ ]]; then
    build_input_error "An official qdrant/qdrant reference is required: ${upstream_ref}"
    return 1
  fi
  upstream_digest="$(pull_image_digest "${upstream_ref}")"
  if [ -n "${requested_digest}" ] && [ "${requested_digest}" != "${upstream_digest}" ]; then
    build_input_error 'The requested Qdrant digest does not match the official image.'
    return 1
  fi
  upstream_ref="qdrant/qdrant@${upstream_digest}"
  upstream_version="$(docker image inspect "${upstream_ref}" --format '{{index .Config.Labels "org.opencontainers.image.version"}}')"
  upstream_version="${upstream_version#v}"
  if [[ ! "${upstream_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z._-]+)?$ ]]; then
    build_input_error "Unsupported official Qdrant version: ${upstream_version}"
    return 1
  fi
  if [ -n "${requested_version}" ] && [ "${requested_version}" != "${upstream_version}" ]; then
    build_input_error 'The requested Qdrant version does not match the official image.'
    return 1
  fi
  source_ref="v${upstream_version}"
  if [ -n "${requested_source}" ] && [ "${requested_source}" != "${source_ref}" ]; then
    build_input_error 'The Qdrant source tag must match the official image version.'
    return 1
  fi
  tag_revisions="$(git ls-remote --tags --exit-code https://github.com/qdrant/qdrant.git "refs/tags/${source_ref}" "refs/tags/${source_ref}^{}")"
  source_revision="$(awk '$2 ~ /\^\{\}$/ { print $1; exit }' <<<"${tag_revisions}")"
  if [ -z "${source_revision}" ]; then
    source_revision="$(awk 'NR == 1 { print $1 }' <<<"${tag_revisions}")"
  fi
  if [[ ! "${source_revision}" =~ ^[a-f0-9]{40}$ ]]; then
    build_input_error "Could not resolve Qdrant source tag: ${source_ref}"
    return 1
  fi
  if [ -n "${QDRANT_SOURCE_REVISION:-}" ] && [ "${QDRANT_SOURCE_REVISION}" != "${source_revision}" ]; then
    build_input_error "The requested Qdrant commit does not match ${source_ref}."
    return 1
  fi

  requested_digest="${UBUNTU_BASE_DIGEST:-}"
  if [ -n "${requested_digest}" ] && [[ ! "${requested_digest}" =~ ^sha256:[a-f0-9]{64}$ ]]; then
    build_input_error "Invalid requested Ubuntu digest: ${requested_digest}"
    return 1
  fi
  ubuntu_base_ref="${UBUNTU_BASE_IMAGE:-}"
  if [ -z "${ubuntu_base_ref}" ]; then
    ubuntu_base_ref="ubuntu:24.04"
    if [ -n "${requested_digest}" ]; then
      ubuntu_base_ref="ubuntu@${requested_digest}"
    fi
  fi
  if [[ ! "${ubuntu_base_ref}" =~ ^ubuntu(:24\.04|@sha256:[a-f0-9]{64})$ ]]; then
    build_input_error "An official Ubuntu 24.04 reference is required: ${ubuntu_base_ref}"
    return 1
  fi
  ubuntu_base_digest="$(pull_image_digest "${ubuntu_base_ref}")"
  if [ -n "${requested_digest}" ] && [ "${requested_digest}" != "${ubuntu_base_digest}" ]; then
    build_input_error 'The requested Ubuntu digest does not match the runtime image.'
    return 1
  fi
  ubuntu_base_ref="ubuntu@${ubuntu_base_digest}"
  local ubuntu_version
  ubuntu_version="$(docker image inspect "${ubuntu_base_ref}" --format '{{index .Config.Labels "org.opencontainers.image.version"}}')"
  if [ "${ubuntu_version}" != '24.04' ]; then
    build_input_error "Ubuntu 24.04 is required; resolved ${ubuntu_version}."
    return 1
  fi
  printf 'Resolved Qdrant %s at %s; Ubuntu %s.\n' "${upstream_version}" "${source_revision}" "${ubuntu_base_digest}" >&2
}

write_build_inputs() {
  printf '%s\n' \
    "upstream_ref=${upstream_ref}" \
    "upstream_version=${upstream_version}" \
    "upstream_digest=${upstream_digest}" \
    "source_ref=${source_ref}" \
    "source_revision=${source_revision}" \
    "ubuntu_base_ref=${ubuntu_base_ref}" \
    "ubuntu_base_digest=${ubuntu_base_digest}"
}
