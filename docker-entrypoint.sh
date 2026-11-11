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

# 2. Apply initial token
apply_token

# 3. If a token file is mounted, watch for updates from host (refreshed every 45 min)
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

# 4. Hand over PID 1 to opencode and forward any CLI arguments
exec opencode "$@"
