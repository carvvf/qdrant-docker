#!/usr/bin/env bash
set -euo pipefail

IMAGE_REF="${IMAGE_REF:-qdrant-custom:local}"
API_KEY="${QDRANT_TEST_API_KEY:-qdrant-ci-api-key-please-replace}"
RUN_ID="${GITHUB_RUN_ID:-local}-$$"
CONTAINER_NAME="${CONTAINER_NAME:-qdrant-image-test-${RUN_ID}}"
STORAGE_VOLUME="${STORAGE_VOLUME:-qdrant-image-test-storage-${RUN_ID}}"
SNAPSHOTS_VOLUME="${SNAPSHOTS_VOLUME:-qdrant-image-test-snapshots-${RUN_ID}}"
COLLECTION_NAME="${COLLECTION_NAME:-ci_smoke}"
HOST_PORT=""

cleanup() {
  local exit_status=$?
  if [ "${exit_status}" -ne 0 ]; then
    echo "Qdrant container logs after test failure:" >&2
    docker logs --tail 200 "${CONTAINER_NAME}" >&2 || true
  fi
  docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  docker volume rm "${STORAGE_VOLUME}" "${SNAPSHOTS_VOLUME}" >/dev/null 2>&1 || true
  exit "${exit_status}"
}

start_container() {
  docker run -d \
    --name "${CONTAINER_NAME}" \
    --read-only \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --pids-limit 256 \
    --memory 1g \
    --cpus 1.0 \
    --ulimit nofile=65535:65535 \
    --tmpfs /tmp:rw,noexec,nosuid,nodev,size=128m \
    --mount "type=volume,src=${STORAGE_VOLUME},dst=/qdrant/storage" \
    --mount "type=volume,src=${SNAPSHOTS_VOLUME},dst=/qdrant/snapshots" \
    -e "QDRANT__SERVICE__API_KEY=${API_KEY}" \
    -e "QDRANT_INIT_FILE_PATH=/qdrant/storage/.qdrant-initialized" \
    -e "QDRANT__STORAGE__COLLECTION__STRICT_MODE__ENABLED=true" \
    -e "QDRANT__STORAGE__COLLECTION__STRICT_MODE__UNINDEXED_FILTERING_RETRIEVE=false" \
    -e "QDRANT__STORAGE__COLLECTION__STRICT_MODE__UNINDEXED_FILTERING_UPDATE=false" \
    -p 127.0.0.1::6333 \
    "${IMAGE_REF}" >/dev/null

  resolve_host_port
}

resolve_host_port() {
  HOST_PORT="$(docker port "${CONTAINER_NAME}" 6333/tcp | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p')"
  if [[ -z "${HOST_PORT}" ]]; then
    echo "Could not determine the Qdrant HTTP host port." >&2
    return 1
  fi
}

wait_for_endpoint() {
  local endpoint="$1"
  local response=""

  for _ in $(seq 1 60); do
    if response="$(curl --fail --silent --max-time 3 "http://127.0.0.1:${HOST_PORT}${endpoint}" 2>/dev/null)"; then
      printf '%s\n' "${response}"
      return 0
    fi
    sleep 1
  done

  echo "Qdrant endpoint ${endpoint} did not become ready in time." >&2
  return 1
}

qdrant_api() {
  curl --fail --silent --show-error \
    -H "api-key: ${API_KEY}" \
    "$@"
}

trap cleanup EXIT

docker volume create "${STORAGE_VOLUME}" >/dev/null
docker volume create "${SNAPSHOTS_VOLUME}" >/dev/null
start_container

wait_for_endpoint /healthz | grep -qx 'healthz check passed'
wait_for_endpoint /readyz | grep -qx 'all shards are ready'

qdrant_api \
  -X PUT "http://127.0.0.1:${HOST_PORT}/collections/${COLLECTION_NAME}" \
  -H 'Content-Type: application/json' \
  --data '{"vectors":{"size":4,"distance":"Cosine"}}' \
  | jq -e '.status == "ok" and .result == true' >/dev/null

qdrant_api \
  -X PUT "http://127.0.0.1:${HOST_PORT}/collections/${COLLECTION_NAME}/points?wait=true" \
  -H 'Content-Type: application/json' \
  --data '{"points":[{"id":1,"vector":[0.1,0.2,0.3,0.4],"payload":{"source":"ci"}}]}' \
  | jq -e '.status == "ok"' >/dev/null

docker stop "${CONTAINER_NAME}" >/dev/null
docker start "${CONTAINER_NAME}" >/dev/null
resolve_host_port
wait_for_endpoint /readyz | grep -qx 'all shards are ready'

qdrant_api \
  -X POST "http://127.0.0.1:${HOST_PORT}/collections/${COLLECTION_NAME}/points/count" \
  -H 'Content-Type: application/json' \
  --data '{"exact":true}' \
  | jq -e '.status == "ok" and .result.count == 1' >/dev/null

qdrant_api \
  -X DELETE "http://127.0.0.1:${HOST_PORT}/collections/${COLLECTION_NAME}?timeout=10" \
  | jq -e '.status == "ok" and .result == true' >/dev/null

echo "Qdrant image smoke test passed for ${IMAGE_REF}."
