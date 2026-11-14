#!/usr/bin/env bash
set -e

TOKEN_FILE="/run/secrets/github_token"
USER_NAME="opencode"
USER_HOME="/home/opencode"

# 1. Match host user UID and GID if /workspace is mounted
if [ -d "/workspace" ]; then
    WORKSPACE_UID=$(stat -c '%u' /workspace 2>/dev/null || stat -f '%u' /workspace 2>/dev/null || echo 0)
    WORKSPACE_GID=$(stat -c '%g' /workspace 2>/dev/null || stat -f '%g' /workspace 2>/dev/null || echo 0)

    # If workspace is owned by a non-root host user, match opencode's UID/GID
    if [ "$WORKSPACE_UID" -ne 0 ] && [ "$WORKSPACE_UID" -ne "$(id -u $USER_NAME)" ]; then
        groupmod -o -g "$WORKSPACE_GID" "$USER_NAME" 2>/dev/null || true
        usermod -o -u "$WORKSPACE_UID" "$USER_NAME" 2>/dev/null || true
    fi
fi

# Ensure user owns top-level home directories without slow recursive traversal
mkdir -p "$USER_HOME"/{.config,.local,.cache,go} 2>/dev/null || true
chown "$USER_NAME:$USER_NAME" "$USER_HOME" "$USER_HOME"/{.config,.local,.cache,go} 2>/dev/null || true

get_current_token() {
    if [ -f "$TOKEN_FILE" ]; then
        cat "$TOKEN_FILE"
    elif [ -n "$GITHUB_TOKEN" ]; then
        echo "$GITHUB_TOKEN"
    fi
}

apply_token() {
    local token
    token=$(get_current_token)

    if [ -z "$token" ] || [ "$token" = "null" ]; then
        return 0
    fi

    # 1. Update Git credential store for opencode user
    echo "https://x-access-token:${token}@github.com" > "${USER_HOME}/.git-credentials"
    chmod 600 "${USER_HOME}/.git-credentials"
    chown "$USER_NAME:$USER_NAME" "${USER_HOME}/.git-credentials"

    # 2. Update GitHub CLI (gh) configuration
    mkdir -p "${USER_HOME}/.config/gh"
    cat << YAML > "${USER_HOME}/.config/gh/hosts.yml"
github.com:
    oauth_token: ${token}
    user: ${GIT_AUTHOR_NAME:-opencode-bot}
    git_protocol: https
YAML
    chown -R "$USER_NAME:$USER_NAME" "${USER_HOME}/.config"
}

# 2. Configure Git globals for the opencode user
su-exec "$USER_NAME" git config --global --add safe.directory /workspace
su-exec "$USER_NAME" git config --global credential.helper "store --file ${USER_HOME}/.git-credentials"
su-exec "$USER_NAME" git config --global url."https://github.com/".insteadOf "git@github.com:"
su-exec "$USER_NAME" git config --global --add url."https://github.com/".insteadOf "ssh://git@github.com/"

# 3. Apply initial token
apply_token

# 4. If a token file is mounted, watch for updates from host in background
if [ -f "$TOKEN_FILE" ]; then
    (
        last_token="$(get_current_token)"
        while true; do
            sleep 30
            curr_token="$(get_current_token)"
            if [ "$curr_token" != "$last_token" ]; then
                apply_token
                last_token="$curr_token"
            fi
        done
    ) &
fi

# 5. Drop root privileges and hand over to opencode (or shell if specified)
if [ "$1" = "bash" ] || [ "$1" = "sh" ]; then
    exec su-exec "$USER_NAME" "$@"
else
    exec su-exec "$USER_NAME" opencode "$@"
fi
