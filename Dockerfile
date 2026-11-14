FROM ghcr.io/anomalyco/opencode:latest

USER root

# Install development toolchains and utilities from stable repositories
RUN apk add --no-cache \
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

# Create non-root opencode user (UID 1000)
RUN addgroup -g 1000 opencode && \
    adduser -u 1000 -G opencode -s /bin/bash -D opencode && \
    mkdir -p /home/opencode/go /workspace && \
    chown -R opencode:opencode /home/opencode /workspace

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

USER opencode

ENV HOME="/home/opencode"
ENV GOPATH="/home/opencode/go"
ENV PATH="/home/opencode/go/bin:${PATH}"

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
