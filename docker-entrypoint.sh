#!/usr/bin/env bash
set -e

TOKEN_FILE="/run/secrets/github_token"

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

    # 1. Update Git credential store
    echo "https://x-access-token:${token}@github.com" > "${HOME}/.git-credentials"
    chmod 600 "${HOME}/.git-credentials"

    # 2. Update GitHub CLI (gh) configuration
    mkdir -p "${HOME}/.config/gh"
    cat << YAML > "${HOME}/.config/gh/hosts.yml"
github.com:
    oauth_token: ${token}
    user: ${GIT_AUTHOR_NAME:-opencode-bot}
    git_protocol: https
YAML
}

# 1. Configure Git globals
git config --global --add safe.directory /workspace
git config --global credential.helper "store --file ${HOME}/.git-credentials"
git config --global url."https://github.com/".insteadOf "git@github.com:"
git config --global --add url."https://github.com/".insteadOf "ssh://git@github.com/"

if [ -n "$GIT_AUTHOR_NAME" ]; then
    git config --global user.name "$GIT_AUTHOR_NAME"
fi
if [ -n "$GIT_AUTHOR_EMAIL" ]; then
    git config --global user.email "$GIT_AUTHOR_EMAIL"
fi

# 2. Apply initial token
apply_token

# 3. If a token file is mounted, watch for updates from host in background
if [ -f "$TOKEN_FILE" ]; then
    (
        last_token="$(get_current_token)"
        while true; do
            sleep 30
            curr_token="$(get_current_token)"
            if [ -n "$curr_token" ] && [ "$curr_token" != "$last_token" ]; then
                apply_token
                last_token="$curr_token"
            fi
        done
    ) &
fi

# 4. Hand over execution:
# - If no arguments or flags (-*, --*), launch opencode
# - If 'opencode' command explicitly specified, execute directly
# - If command exists in PATH (e.g. bash, sh, git, gh, python3), execute directly
# - Otherwise, pass arguments through to opencode
if [ $# -eq 0 ] || [ "${1#-}" != "$1" ]; then
    exec opencode "$@"
elif [ "$1" = "opencode" ]; then
    exec "$@"
elif command -v "$1" >/dev/null 2>&1; then
    exec "$@"
else
    exec opencode "$@"
fi
