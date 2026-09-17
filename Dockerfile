# syntax=docker/dockerfile:1
# The Qdrant release tag and commit are resolved by CI from qdrant/qdrant:latest.
ARG QDRANT_SOURCE_REPOSITORY=https://github.com/qdrant/qdrant.git
ARG QDRANT_SOURCE_REF=v1.19.1
ARG QDRANT_SOURCE_REVISION=
ARG UBUNTU_BASE_IMAGE=ubuntu:24.04

# hadolint ignore=DL3006
FROM debian:bookworm-slim AS source
ARG QDRANT_SOURCE_REPOSITORY
ARG QDRANT_SOURCE_REF
ARG QDRANT_SOURCE_REVISION

# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates git \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch "${QDRANT_SOURCE_REF}" \
      "${QDRANT_SOURCE_REPOSITORY}" /qdrant \
    && actual_revision="$(git -C /qdrant rev-parse HEAD)" \
    && if [ -n "${QDRANT_SOURCE_REVISION}" ]; then \
         test "${actual_revision}" = "${QDRANT_SOURCE_REVISION}"; \
       fi \
    && printf '%s\n' "${actual_revision}" > /qdrant-source-revision

# Keep this toolchain aligned with the upstream Qdrant v1.19 build definition.
FROM lukemathwalker/cargo-chef:latest-rust-1.98.0-bookworm AS chef
WORKDIR /qdrant

FROM chef AS planner
COPY --from=source /qdrant /qdrant
RUN cargo chef prepare --recipe-path recipe.json

FROM chef AS builder
ARG QDRANT_SOURCE_REVISION
WORKDIR /qdrant

# hadolint ignore=DL3008
RUN --mount=type=cache,target=/usr/local/cargo/registry,id=qdrant-cargo-registry,sharing=locked \
    apt-get update \
    && apt-get install -y --no-install-recommends \
      clang \
      cmake \
      g++ \
      gcc \
      jq \
      libprotobuf-dev \
      libunwind-dev \
      lld \
      pkg-config \
      protobuf-compiler \
    && rustup component add rustfmt \
    && cargo install cargo-sbom --locked \
    && rm -rf /var/lib/apt/lists/*

COPY --from=planner /qdrant/recipe.json recipe.json
RUN --mount=type=cache,target=/qdrant/target,id=qdrant-cargo-target,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/registry,id=qdrant-cargo-registry,sharing=locked \
    cargo chef cook --release --features stacktrace --recipe-path recipe.json

ARG MOLD_VERSION=2.41.0
# hadolint ignore=DL4006
RUN mkdir -p /opt/mold \
    && curl --fail --silent --show-error --location \
      "https://github.com/rui314/mold/releases/download/v${MOLD_VERSION}/mold-${MOLD_VERSION}-x86_64-linux.tar.gz" \
      | tar -xz --strip-components=1 -C /opt/mold

COPY --from=source /qdrant /qdrant
ENV GIT_COMMIT_ID=${QDRANT_SOURCE_REVISION}
# The release binary is copied out of the cache-mounted target dir before the
# mount is detached, since cache mount contents are not persisted in the layer.
RUN --mount=type=cache,target=/qdrant/target,id=qdrant-cargo-target,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/registry,id=qdrant-cargo-registry,sharing=locked \
    PATH="/opt/mold/bin:${PATH}" \
    RUSTFLAGS="-C link-arg=-fuse-ld=mold" \
    cargo build --release --features stacktrace --bin qdrant \
    && mkdir /static \
    && STATIC_DIR=/static ./tools/sync-web-ui.sh \
    && cargo sbom > /qdrant/qdrant.spdx.json \
    && cp /qdrant/target/release/qdrant /qdrant/qdrant-bin

# The workflow resolves this mutable tag to an immutable manifest digest.
# hadolint ignore=DL3006
FROM ${UBUNTU_BASE_IMAGE} AS runtime

ARG QDRANT_SOURCE_REPOSITORY
ARG QDRANT_SOURCE_REF
ARG QDRANT_SOURCE_REVISION
ARG QDRANT_UPSTREAM_VERSION=unknown
ARG QDRANT_UPSTREAM_DIGEST=unknown
ARG UBUNTU_BASE_IMAGE
ARG UBUNTU_BASE_DIGEST=unknown
ARG SOURCE_REPOSITORY=https://github.com/carvvf/qdrant-docker

LABEL org.opencontainers.image.title="Qdrant custom image"
LABEL org.opencontainers.image.description="Qdrant rebuilt from verified source on Ubuntu 24.04"
LABEL org.opencontainers.image.documentation="${SOURCE_REPOSITORY}"
LABEL org.opencontainers.image.source="${SOURCE_REPOSITORY}"
LABEL org.opencontainers.image.url="${SOURCE_REPOSITORY}"
LABEL io.github.carvvf.qdrant-docker.qdrant.source.repository="${QDRANT_SOURCE_REPOSITORY}"
LABEL io.github.carvvf.qdrant-docker.qdrant.source.ref="${QDRANT_SOURCE_REF}"
LABEL io.github.carvvf.qdrant-docker.qdrant.source.revision="${QDRANT_SOURCE_REVISION}"
LABEL io.github.carvvf.qdrant-docker.qdrant.upstream.version="${QDRANT_UPSTREAM_VERSION}"
LABEL io.github.carvvf.qdrant-docker.qdrant.upstream.digest="${QDRANT_UPSTREAM_DIGEST}"
LABEL io.github.carvvf.qdrant-docker.runtime.base.image="${UBUNTU_BASE_IMAGE}"
LABEL io.github.carvvf.qdrant-docker.runtime.base.digest="${UBUNTU_BASE_DIGEST}"

ENV DEBIAN_FRONTEND=noninteractive
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends ca-certificates libunwind8 tzdata \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

COPY --from=builder /qdrant/qdrant-bin /qdrant/qdrant
COPY --from=builder /qdrant/qdrant.spdx.json /qdrant/qdrant.spdx.json
COPY --from=builder /qdrant/config /qdrant/config
COPY --from=builder /qdrant/tools/entrypoint.sh /qdrant/entrypoint.sh
COPY --from=builder /static /qdrant/static

# Apache-2.0 requires redistributors to provide recipients a copy of the
# license. Ship Qdrant's own license text from the resolved source revision
# (not this repository's LICENSE, which covers this repository's own
# original content) outside the Qdrant runtime paths.
COPY --from=builder /qdrant/LICENSE /licenses/Apache-2.0.txt

# Keep the official image's root runtime contract: Ragtime's TLS guard and
# persistent-volume setup depend on it.
WORKDIR /qdrant
# hadolint ignore=DL3002
USER 0:0

ENV TZ=Etc/UTC \
    RUN_MODE=production

EXPOSE 6333 6334

CMD ["./entrypoint.sh"]
