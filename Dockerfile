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

ARG USER_UID=1000
ARG USER_GID=1000

# Create non-root opencode user matching build-time UID/GID
RUN GROUP_NAME=$(getent group ${USER_GID} | cut -d: -f1) && \
    if [ -z "$GROUP_NAME" ]; then \
        addgroup -g ${USER_GID} opencode; \
        GROUP_NAME="opencode"; \
    fi && \
    USER_NAME=$(getent passwd ${USER_UID} | cut -d: -f1) && \
    if [ -z "$USER_NAME" ]; then \
        adduser -u ${USER_UID} -G "$GROUP_NAME" -s /bin/bash -D opencode; \
        USER_NAME="opencode"; \
    fi && \
    mkdir -p /home/opencode/go /workspace && \
    chown -R ${USER_UID}:${USER_GID} /home/opencode /workspace

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

USER opencode

ENV HOME="/home/opencode"
ENV GOPATH="/home/opencode/go"
ENV PATH="/home/opencode/go/bin:${PATH}"

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
