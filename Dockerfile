FROM ghcr.io/anomalyco/opencode:latest

USER root

# Install development toolchains, utilities, and su-exec for privilege dropping
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
    ca-certificates \
    su-exec \
    shadow

# Create non-root opencode user and configure environment
RUN addgroup -g 1000 opencode && \
    adduser -u 1000 -G opencode -s /bin/bash -D opencode && \
    mkdir -p /home/opencode/go && \
    chown -R opencode:opencode /home/opencode

ENV HOME="/home/opencode"
ENV GOPATH="/home/opencode/go"
ENV PATH="/home/opencode/go/bin:${PATH}"

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
