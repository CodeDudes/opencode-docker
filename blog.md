This guide walks through containerizing **OpenCode** on macOS and Linux (x86_64 and Apple Silicon/ARM64) with a full developer toolchain (Go, Node, Python/uv, Git, GitHub CLI), automated GitHub App bot authentication, cross-project sandbox isolation, and single-folder persistence for seamless backups and device migrations.

---

## Architecture & Security Overview

Running an autonomous coding agent directly on your host machine gives it access to your personal SSH keys, cloud credentials (`~/.aws`, `~/.kube`), and the entire filesystem. This architecture enforces strict boundaries through four mechanisms:

| Security Layer | Implementation | What It Prevents |
| --- | --- | --- |
| **Filesystem Isolation** | Mounts only the target directory (`$absolute_path:/workspace`) rather than `~`. | Blocks the agent from reading or modifying sibling repositories, host dotfiles, or system directories. |
| **Zero Personal Credentials** | Replaces personal SSH keys (`~/.ssh`) and personal access tokens with a dedicated **GitHub App**. | Scopes access strictly to authorized repositories and specific permissions. All commits and PRs are clearly audited under `your-app[bot]`. |
| **Short-Lived Ephemeral Tokens** | Mints 1-hour GitHub installation tokens via a 9-minute RS256 JWT; refreshed by the host every 45 minutes. | Eliminates long-lived static tokens. If a token is leaked in logs, it expires within an hour. |
| **Zero Private Key Exposure** | Keeps `app.pem` strictly on the host. Mounts only an ephemeral token to `/run/secrets/github_token:ro`. | Prevents the GitHub App private key from being stolen by prompt injection, malicious packages, or agent tools. |

---

## Step-by-Step Setup Guide

### 1. Create the GitHub App and Gather Credentials
Replaces personal SSH keys with scoped bot access.
Create a dedicated GitHub App in your GitHub Organization or personal account settings (**Settings - Developer settings - GitHub Apps - New GitHub App**):

1. **Homepage URL:** Set to your organization URL or `https://opencode.ai`.
2. **Webhook:** Uncheck **Active** (not needed for local CLI usage).
3. **Repository Permissions:**
   * **Contents:** `Read and write` (for cloning, branching, and pushing code)
   * **Pull requests:** `Read and write` (for creating PRs via `gh pr create`)
   * **Issues:** `Read and write` (optional, if interacting with issues)
   * **Metadata:** `Read-only` (selected automatically)
4. **Install the App:** After creation, click **Install App** in the left sidebar and grant it access to only the specific repositories you want OpenCode to work on.
5. **Collect your 4 required values:**
   * **App Slug:** The URL-friendly name of your app (e.g., `acme-opencode-bot`), visible in the app's URL.
   * **App ID:** Found on the App's **General** settings page (e.g., `123456`).
   * **Installation ID:** Found in the URL after clicking **Configure** on your installed app: `https://github.com/settings/installations/87654321` (the number at the end is your Installation ID).
   * **Private Key (`app.pem`):** Scroll down on the **General** page and click **Generate a private key**. A `.pem` file will download to your machine.

---

### 2. Create the Directory Structure on Your Machine
Consolidates build files and persistent state into two folders:

```bash
mkdir -p ~/opencode-docker
mkdir -p ~/opencode-data/{config,share,state,go,cache}
```

Move your downloaded GitHub App private key into `~/opencode-docker/app.pem` and restrict its permissions to owner-read-only:

```bash
mv ~/Downloads/your-downloaded-key.pem ~/opencode-docker/app.pem
chmod 600 ~/opencode-docker/app.pem
```

---

### 3. Create the Dockerfile
Installs toolchains without baking secrets into image layers. Create `~/opencode-docker/Dockerfile`:

```dockerfile
FROM ghcr.io/anomalyco/opencode:latest

USER root

# Install Go, Node, Python/uv, Git, GitHub CLI, and developer tools
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

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
```

---

### 4. Create the Unified Entrypoint Script
Create `~/opencode-docker/docker-entrypoint.sh`:

```bash
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

# 1. Configure Git globals (scoped safe directory for /workspace)
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

# 4. Hand over PID 1 to opencode
exec opencode "$@"
```

Make the script executable:

```bash
chmod +x ~/opencode-docker/docker-entrypoint.sh
```

---

### 5. Add the `ocd` Launcher Function to your Shell (`~/.zshrc` or `~/.bashrc`)
Add the `ocd` function to the bottom of your `~/.zshrc` (macOS) or `~/.bashrc` (Linux), replacing the three placeholder variables with your GitHub App details:

```bash
ocd () {
	# ================= CONFIGURATION =================
	local image_name="opencode-dev:latest"
	local dockerfile_dir="$HOME/opencode-docker"
	local bot_key_path="$HOME/opencode-docker/app.pem"
	local entrypoint_script="$HOME/opencode-docker/docker-entrypoint.sh"
	local data_root="$HOME/opencode-data"

	local gh_app_id="YOUR_APP_ID"                          # <-- Replace with App ID
	local gh_install_id="YOUR_INSTALLATION_ID"              # <-- Replace with Installation ID
	local gh_app_slug="your-org-opencode-bot"               # <-- Replace with App Slug
	# =================================================

	local bot_name="${gh_app_slug}[bot]"
	local bot_email="${gh_app_id}+${gh_app_slug}[bot]@users.noreply.github.com"
	local sandbox_mode=false

	# 1. Parse optional flags
	while [ $# -gt 0 ]; do
		case "$1" in
			--rebuild)
				echo "Rebuilding $image_name..."
				docker build --pull -t "$image_name" -f "$dockerfile_dir/Dockerfile" "$dockerfile_dir" || return 1
				shift
				;;
			--sandbox|--isolated)
				sandbox_mode=true
				echo "🔒 Running in SANDBOX mode: host caches and stored credentials disabled."
				shift
				;;
			-*)
				echo "Unknown option: $1" >&2
				return 1
				;;
			*)
				break
				;;
		esac
	done

	# 2. Resolve target workspace directory
	local target_dir="${1:-.}"
	local absolute_path
	if [ -d "$target_dir" ]; then
		absolute_path=$(cd "$target_dir" && pwd)
		[ $# -gt 0 ] && shift
	else
		echo "Error: Directory '$target_dir' does not exist." >&2
		return 1
	fi

	# 3. Validate host files
	if [ ! -f "$bot_key_path" ]; then
		echo "Error: GitHub App private key not found at '$bot_key_path'" >&2
		return 1
	fi
	chmod 600 "$bot_key_path"

	# 4. Host-side token minting (OpenSSL + curl + python3/jq)
	_mint_gh_token() {
		local now=$(date +%s)
		local iat=$((now - 60))
		local exp=$((now + 540))

		local b64enc="openssl base64 -e -A | tr '+/' '-_' | tr -d '='"
		local header=$(printf '{"alg":"RS256","typ":"JWT"}' | eval "$b64enc")
		local payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$iat" "$exp" "$gh_app_id" | eval "$b64enc")
		local sig=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$bot_key_path" | eval "$b64enc")
		local jwt="${header}.${payload}.${sig}"

		curl -sf -X POST \
			-H "Authorization: Bearer $jwt" \
			-H "Accept: application/vnd.github+json" \
			"https://api.github.com/app/installations/${gh_install_id}/access_tokens" \
			| python3 -c "import sys, json; print(json.load(sys.stdin)['token'])"
	}

	# 5. Create secure per-session token file in $TMPDIR
	local token_file=$(mktemp "${TMPDIR:-/tmp}/opencode_token.XXXXXX")
	chmod 600 "$token_file"

	local initial_token
	initial_token=$(_mint_gh_token)
	if [ -z "$initial_token" ]; then
		echo "Error: Failed to mint GitHub installation token." >&2
		rm -f "$token_file"
		return 1
	fi
	echo "$initial_token" > "$token_file"

	# 6. Background token refresher on host (refreshes every 45 min)
	(
		while [ -f "$token_file" ]; do
			sleep 2700
			local new_token
			new_token=$(_mint_gh_token 2>/dev/null)
			if [ -n "$new_token" ]; then
				echo "$new_token" > "${token_file}.tmp" && mv "${token_file}.tmp" "$token_file"
			fi
		done
	) &
	local refresh_pid=$!

	# Cleanup handler when container exits
	cleanup() {
		kill "$refresh_pid" 2>/dev/null || true
		rm -f "$token_file" "${token_file}.tmp" 2>/dev/null || true
	}
	trap cleanup EXIT INT TERM

	# 7. Assemble volume mounts and environment flags
	local mounts=(
		-v "$absolute_path":/workspace
		-v "$token_file":/run/secrets/github_token:ro
	)

	# If entrypoint script exists on host, mount it (allows live script edits without image rebuild)
	if [ -f "$entrypoint_script" ]; then
		mounts+=(-v "$entrypoint_script":/usr/local/bin/docker-entrypoint.sh:ro)
	fi

	local env_args=(
		-e GIT_AUTHOR_NAME="$bot_name"
		-e GIT_AUTHOR_EMAIL="$bot_email"
		-e GIT_COMMITTER_NAME="$bot_name"
		-e GIT_COMMITTER_EMAIL="$bot_email"
		${ANTHROPIC_API_KEY:+-e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"}
		${OPENAI_API_KEY:+-e OPENAI_API_KEY="$OPENAI_API_KEY"}
		${GEMINI_API_KEY:+-e GEMINI_API_KEY="$GEMINI_API_KEY"}
		${OPENROUTER_API_KEY:+-e OPENROUTER_API_KEY="$OPENROUTER_API_KEY"}
	)

	if [ "$sandbox_mode" = false ]; then
		# Trusted Mode: mount persistent directories
		mkdir -p "$data_root"/{config,share,state,go,cache}
		mounts+=(
			-v "$data_root/go":/root/go
			-v "$data_root/cache":/root/.cache
			-v "$data_root/config":/root/.config/opencode
			-v "$data_root/share":/root/.local/share/opencode
			-v "$data_root/state":/root/.local/state/opencode
		)
	fi

	# 8. Build image automatically on first run
	if ! docker image inspect "$image_name" >/dev/null 2>&1; then
		echo "Building $image_name..."
		docker build -t "$image_name" -f "$dockerfile_dir/Dockerfile" "$dockerfile_dir" || { cleanup; return 1; }
	fi

	echo "Launching OpenCode in: $absolute_path (as $bot_name)"
	docker run -it --rm \
		"${mounts[@]}" \
		"${env_args[@]}" \
		--workdir /workspace \
		"$image_name" "$@"

	cleanup
	trap - EXIT INT TERM
}
```

Reload your shell configuration:

```bash
# On macOS (zsh):
source ~/.zshrc

# On Linux (bash):
source ~/.bashrc
```

---

## Critical Components Explained

### 1. Trusted Mode vs. `--sandbox` Mode
* **Standard `ocd` (Trusted Projects):** Mounts `~/opencode-data` for convenient chat history persistence, model selection memory, and shared Go/pip caches.
* **`ocd --sandbox` (Untrusted / Third-Party Repos):** Does not mount `auth.json` or shared caches. Prevents untrusted repositories from stealing stored LLM API keys or poisoning your build caches.

### 2. Transparent SSH-to-HTTPS Git Rewriting
On your host, repositories are often cloned using SSH (`git@github.com:org/repo.git`). GitHub Apps authenticate over HTTPS using `x-access-token`. The entrypoint runs:

```bash
git config --global url."https://github.com/".insteadOf "git@github.com:"
```

This intercepts any `git pull`, `git fetch`, or `git push` inside the container and transparently routes it over HTTPS using the bot's token—without altering the `.git/config` file in your mounted host workspace.

### 3. Host-Side Token Minting & Background Rotation
GitHub App installation tokens expire after **60 minutes**. 
* The host mints the token using host `openssl` and writes it to a temporary file (`$TMPDIR/opencode_token.XXXXXX`).
* A host background process wakes up every 45 minutes to refresh this file.
* The container watches `/run/secrets/github_token` and updates Git and GitHub CLI configurations automatically.
* **Your private key (`app.pem`) is never mounted into Docker**, ensuring that coding agents or malicious dependencies cannot exfiltrate the master signing key.

### 4. Cross-Platform Compatibility (macOS & Linux)
* Works on Apple Silicon (`arm64`), Intel Macs (`x86_64`), and Linux servers/workstations (`x86_64` / `arm64`).
* POSIX-compatible shell code runs identically in both `zsh` and `bash`.
* Dynamic path detection works with both BSD and GNU coreutils.

---

## Daily Usage & Device Migration

* **Launch in current repo:** `ocd`
* **Launch in a specific repo:** `ocd ~/projects/my-repo`
* **Launch in sandbox mode (untrusted code):** `ocd --sandbox ~/projects/untrusted-repo`
* **Rebuild image to update dependencies:** `ocd --rebuild`
* **Migrate to a new machine:** Copy `~/opencode-docker` and `~/opencode-data` to your new machine, add the `ocd` function to your `~/.zshrc` or `~/.bashrc`, and run `ocd`.
