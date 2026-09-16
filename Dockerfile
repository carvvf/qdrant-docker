ARG QDRANT_BASE_IMAGE=qdrant/qdrant:latest
# `latest` is intentionally resolved to a digest by the daily workflow.
# hadolint ignore=DL3006
FROM ${QDRANT_BASE_IMAGE}

ARG QDRANT_BASE_IMAGE
ARG QDRANT_UPSTREAM_VERSION=unknown
ARG QDRANT_UPSTREAM_DIGEST=unknown
ARG SOURCE_REPOSITORY=https://github.com/carvvf/qdrant-docker

LABEL org.opencontainers.image.title="Qdrant custom image"
LABEL org.opencontainers.image.description="Hardened Qdrant image with refreshed operating-system packages"
LABEL org.opencontainers.image.documentation="${SOURCE_REPOSITORY}"
LABEL org.opencontainers.image.source="${SOURCE_REPOSITORY}"
LABEL org.opencontainers.image.url="${SOURCE_REPOSITORY}"
LABEL io.github.carvvf.qdrant-docker.base.image="${QDRANT_BASE_IMAGE}"
LABEL io.github.carvvf.qdrant-docker.base.version="${QDRANT_UPSTREAM_VERSION}"
LABEL io.github.carvvf.qdrant-docker.base.digest="${QDRANT_UPSTREAM_DIGEST}"

# The upstream image already runs as 0:0. Preserve that contract because the
# Ragtime TLS guard and its persistent-volume setup depend on it.
# hadolint ignore=DL3002
USER 0:0

# hadolint ignore=DL3005
RUN export DEBIAN_FRONTEND=noninteractive \
    && apt-get update \
    && apt-get upgrade -y \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# Apache-2.0 requires redistributors to provide recipients a copy of the
# license. Keep it outside the Qdrant runtime paths.
COPY LICENSE /licenses/Apache-2.0.txt

# Intentionally inherit the upstream WORKDIR, CMD, and lack of ENTRYPOINT.
