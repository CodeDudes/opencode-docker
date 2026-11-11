FROM ghcr.io/anomalyco/opencode:latest

USER root

# Install development toolchains and utilities
RUN apk add --no-cache \
    --repository=https://dl-cdn.alpinelinux.org/alpine/edge/main \
    --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community \
    git \
    github-cli \
    openssh-client \
    go \
    nodejs \
    npm \
    python3 \
    python3-dev \
    py3-pip \
    uv \
    bash \
    curl \
    jq \
    openssl \
    build-base \
    ca-certificates

ENV PATH="/root/go/bin:${PATH}"

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]