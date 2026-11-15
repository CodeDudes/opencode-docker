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
| **Non-Root Execution** | Container runs natively as non-root user `opencode` (matching host UID/GID at build time). | Eliminates container breakout blast radius and ensures seamless file ownership on macOS and Linux. |
| **Runtime Hardening** | `--security-opt=no-new-privileges:true` and `--pids-limit 1024`. | Blocks SUID privilege escalation and protects host against fork-bombs / resource starvation. |
| **Resilient Token Refresher & Trap Safety** | Parent PID liveness checks, retry with backoff, and process isolation via standalone `ocd` CLI. | Eliminates lingering background loops, avoids shell trap pollution, and prevents auth failure on network blips. |

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

### 2. Set Up the Repository Directory on Your Machine
All build files, private keys, and runtime caches are consolidated directly inside `~/opencode-docker`:

```bash
mkdir -p ~/opencode-docker/data/global/{config,state}
mkdir -p ~/opencode-docker/data/projects
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
```

---

### 4. Create .dockerignore (Build Context Protection)
Prevents secrets, keys, and caches from being transferred to the Docker daemon during `docker build`. Create `~/opencode-docker/.dockerignore`:

```dockerignore
# Exclude secrets and private keys
app.pem
*.pem
.env
*.env

# Exclude persistent data, caches, and session history
data/
.data/

# Exclude repository metadata and documentation from build context
.git
.gitignore
*.md
```

---

### 5. Create the Unified Entrypoint Script
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
```

Make the script executable:

```bash
chmod +x ~/opencode-docker/docker-entrypoint.sh
```

---

### 6. Configure Environment (`.env`) & Install `ocd` CLI

Instead of copy-pasting a 150-line shell function into your profile, OpenCode Docker provides a standalone executable CLI (`ocd`) and a `.env` configuration template.

#### Step A: Configure your `.env` file
Copy `.env.example` to `.env` inside `~/opencode-docker/`:

```bash
cp ~/opencode-docker/.env.example ~/opencode-docker/.env
```

Edit `~/opencode-docker/.env` with your GitHub App credentials and API keys:

```dotenv
# GitHub App Configuration
GH_APP_ID="YOUR_APP_ID"
GH_INSTALLATION_ID="YOUR_INSTALLATION_ID"
GH_APP_SLUG="your-org-opencode-bot"

# Optional LLM API keys:
ANTHROPIC_API_KEY="sk-ant-..."
OPENAI_API_KEY="sk-..."
GEMINI_API_KEY="AIzaSy..."
```

*(Note: `.env` is ignored by `.gitignore` and `.dockerignore` so secrets are never committed or transferred to the Docker daemon).*

#### Step B: Install `ocd` to your PATH

Make `ocd` executable and symlink it to your local binary path (e.g. `~/.local/bin` or `/usr/local/bin`):

```bash
chmod +x ~/opencode-docker/ocd
mkdir -p ~/.local/bin
ln -sf ~/opencode-docker/ocd ~/.local/bin/ocd
```

Ensure `~/.local/bin` is in your `$PATH` (standard on modern Linux and macOS):

```bash
# Add to ~/.zshrc or ~/.bashrc if needed:
export PATH="$HOME/.local/bin:$PATH"
```

Alternatively, you can define a one-line alias in your `~/.zshrc` / `~/.bashrc`:

```bash
alias ocd="$HOME/opencode-docker/ocd"
```

#### Step C: The Standalone `ocd` CLI Script (`~/opencode-docker/ocd`)
The complete source of `~/opencode-docker/ocd`:

```bash
#!/usr/bin/env bash
# =============================================================================
# OpenCode Docker CLI (ocd)
# Runs autonomous coding agents in an ephemeral, hardened Docker container
# with GitHub App credentials, non-root execution, and tiered storage.
# =============================================================================

set -e

# -----------------------------------------------------------------------------
# 1. Resolve Script Directory Across Symlinks (macOS & Linux Portable)
# -----------------------------------------------------------------------------
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"

# -----------------------------------------------------------------------------
# 2. Load Configuration (.env file or Environment Variables)
# -----------------------------------------------------------------------------
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/.env"
    set +a
fi

GH_APP_ID="${GH_APP_ID:-${gh_app_id:-}}"
GH_INSTALLATION_ID="${GH_INSTALLATION_ID:-${gh_install_id:-}}"
GH_APP_SLUG="${GH_APP_SLUG:-${gh_app_slug:-opencode-bot}}"
IMAGE_NAME="${OPENCODE_IMAGE:-opencode-dev:latest}"
BOT_KEY_PATH="${GH_APP_KEY_PATH:-$SCRIPT_DIR/app.pem}"
DATA_ROOT="$SCRIPT_DIR/data"
ENTRYPOINT_SCRIPT="$SCRIPT_DIR/docker-entrypoint.sh"

BOT_NAME="${GH_APP_SLUG}[bot]"
BOT_EMAIL="${GH_APP_ID}+${GH_APP_SLUG}[bot]@users.noreply.github.com"
SANDBOX_MODE=false

# -----------------------------------------------------------------------------
# 3. Parse CLI Flags
# -----------------------------------------------------------------------------
show_help() {
    cat << EOF
OpenCode Docker CLI (ocd)

Usage:
  ocd [options] [workspace_dir] [-- <agent args>]

Options:
  --rebuild            Rebuild the Docker image with your host UID/GID
  --sandbox, --isolated Run in disposable sandbox mode (no caches or stored state)
  -h, --help           Show this help message and exit

Examples:
  ocd                      # Launch OpenCode in current directory
  ocd ~/projects/my-repo   # Launch OpenCode in specified directory
  ocd --sandbox .          # Launch isolated session for inspecting untrusted code
  ocd --rebuild            # Rebuild container image with updated dependencies
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --help|-h)
            show_help
            exit 0
            ;;
        --rebuild)
            echo "Rebuilding $IMAGE_NAME..."
            docker build --pull \
                --build-arg USER_UID="$(id -u)" \
                --build-arg USER_GID="$(id -g)" \
                -t "$IMAGE_NAME" -f "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR"
            echo "✅ Successfully rebuilt $IMAGE_NAME."
            shift
            if [ $# -eq 0 ]; then
                exit 0
            fi
            ;;
        --sandbox|--isolated)
            SANDBOX_MODE=true
            echo "🔒 Running in SANDBOX mode: host caches and stored credentials disabled."
            shift
            ;;
        -*)
            echo "Unknown option: $1" >&2
            echo "Run 'ocd --help' for usage." >&2
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

# -----------------------------------------------------------------------------
# 4. Resolve Target Workspace Directory
# -----------------------------------------------------------------------------
TARGET_DIR="${1:-.}"
if [ -d "$TARGET_DIR" ]; then
    WORKSPACE_DIR="$(cd "$TARGET_DIR" && pwd -P)"
    [ $# -gt 0 ] && shift
else
    echo "Error: Directory '$TARGET_DIR' does not exist." >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# 5. Validate GitHub App Configuration & Private Key
# -----------------------------------------------------------------------------
if [ -z "$GH_APP_ID" ] || [ "$GH_APP_ID" = "YOUR_APP_ID" ] || \
   [ -z "$GH_INSTALLATION_ID" ] || [ "$GH_INSTALLATION_ID" = "YOUR_INSTALLATION_ID" ]; then
    echo "Error: GitHub App configuration is missing." >&2
    echo "Please set GH_APP_ID and GH_INSTALLATION_ID in $SCRIPT_DIR/.env" >&2
    echo "See $SCRIPT_DIR/.env.example for guidance." >&2
    exit 1
fi

if [ ! -f "$BOT_KEY_PATH" ]; then
    echo "Error: GitHub App private key not found at '$BOT_KEY_PATH'" >&2
    exit 1
fi
chmod 600 "$BOT_KEY_PATH" 2>/dev/null || true

# -----------------------------------------------------------------------------
# 6. Host-Side Token Minting (OpenSSL + curl + python3)
# -----------------------------------------------------------------------------
mint_gh_token() {
    local now
    now=$(date +%s)
    local iat=$((now - 60))
    local exp=$((now + 540))

    local b64enc="openssl base64 -e -A | tr '+/' '-_' | tr -d '='"
    local header
    header=$(printf '{"alg":"RS256","typ":"JWT"}' | eval "$b64enc")
    local payload
    payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$iat" "$exp" "$GH_APP_ID" | eval "$b64enc")
    local sig
    sig=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$BOT_KEY_PATH" | eval "$b64enc")
    local jwt="${header}.${payload}.${sig}"

    curl -sf -X POST \
        -H "Authorization: Bearer $jwt" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/app/installations/${GH_INSTALLATION_ID}/access_tokens" \
        | python3 -c "import sys, json; print(json.load(sys.stdin)['token'])" 2>/dev/null
}

mint_with_retry() {
    local max_attempts="${1:-3}"
    local delay="${2:-3}"
    local attempt=1
    local token=""
    while [ "$attempt" -le "$max_attempts" ]; do
        token=$(mint_gh_token || true)
        if [ -n "$token" ] && [ "$token" != "null" ]; then
            echo "$token"
            return 0
        fi
        attempt=$((attempt + 1))
        [ "$attempt" -le "$max_attempts" ] && sleep "$delay"
    done
    return 1
}

# -----------------------------------------------------------------------------
# 7. Create Ephemeral Token File & Resilient Background Refresher
# -----------------------------------------------------------------------------
TOKEN_FILE=$(mktemp "${TMPDIR:-/tmp}/opencode_token.XXXXXX")
chmod 600 "$TOKEN_FILE"

INITIAL_TOKEN=$(mint_with_retry 3 2)
if [ -z "$INITIAL_TOKEN" ] || [ "$INITIAL_TOKEN" = "null" ]; then
    echo "Error: Failed to mint GitHub installation token after retries." >&2
    rm -f "$TOKEN_FILE"
    exit 1
fi
echo "$INITIAL_TOKEN" > "$TOKEN_FILE"

# Refresher subshell: checks parent PID liveness every 30s; refreshes every 45m (90 * 30s)
PARENT_PID=$$
(
    while [ -f "$TOKEN_FILE" ]; do
        for _ in $(seq 1 90); do
            sleep 30
            # Parent process liveness check: terminate immediately if parent died
            if ! kill -0 "$PARENT_PID" 2>/dev/null; then
                break 2
            fi
            if [ ! -f "$TOKEN_FILE" ]; then
                break 2
            fi
        done

        # Attempt token refresh with exponential retry
        new_token=$(mint_with_retry 3 5 2>/dev/null || true)
        if [ -n "$new_token" ] && [ "$new_token" != "null" ]; then
            tmp_token="${TOKEN_FILE}.tmp.$$"
            echo "$new_token" > "$tmp_token"
            chmod 600 "$tmp_token"
            mv -f "$tmp_token" "$TOKEN_FILE"
        fi
    done
) &
REFRESH_PID=$!

cleanup() {
    local exit_code=$?
    if [ -n "${REFRESH_PID:-}" ] && kill -0 "$REFRESH_PID" 2>/dev/null; then
        kill "$REFRESH_PID" 2>/dev/null || true
        wait "$REFRESH_PID" 2>/dev/null || true
    fi
    rm -f "$TOKEN_FILE" "${TOKEN_FILE}.tmp"* 2>/dev/null || true
    exit "$exit_code"
}
trap cleanup EXIT INT TERM HUP

# -----------------------------------------------------------------------------
# 8. Assemble Mounts & Environment Variables
# -----------------------------------------------------------------------------
mounts=(
    -v "$WORKSPACE_DIR":/workspace
    -v "$TOKEN_FILE":/run/secrets/github_token:ro
)

if [ -f "$ENTRYPOINT_SCRIPT" ]; then
    mounts+=(-v "$ENTRYPOINT_SCRIPT":/usr/local/bin/docker-entrypoint.sh:ro)
fi

env_args=(
    -e GIT_AUTHOR_NAME="$BOT_NAME"
    -e GIT_AUTHOR_EMAIL="$BOT_EMAIL"
    -e GIT_COMMITTER_NAME="$BOT_NAME"
    -e GIT_COMMITTER_EMAIL="$BOT_EMAIL"
    ${ANTHROPIC_API_KEY:+-e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"}
    ${OPENAI_API_KEY:+-e OPENAI_API_KEY="$OPENAI_API_KEY"}
    ${GEMINI_API_KEY:+-e GEMINI_API_KEY="$GEMINI_API_KEY"}
    ${OPENROUTER_API_KEY:+-e OPENROUTER_API_KEY="$OPENROUTER_API_KEY"}
    ${DEEPSEEK_API_KEY:+-e DEEPSEEK_API_KEY="$DEEPSEEK_API_KEY"}
    ${GROQ_API_KEY:+-e GROQ_API_KEY="$GROQ_API_KEY"}
    ${MISTRAL_API_KEY:+-e MISTRAL_API_KEY="$MISTRAL_API_KEY"}
    ${OLLAMA_API_BASE:+-e OLLAMA_API_BASE="$OLLAMA_API_BASE"}
    ${OPENAI_API_BASE:+-e OPENAI_API_BASE="$OPENAI_API_BASE"}
)

if [ "$SANDBOX_MODE" = false ]; then
    # 1. SHARED: Global settings, commands, MCP servers & model preferences
    mkdir -p "$DATA_ROOT/global"/{config,state}
    mounts+=(
        -v "$DATA_ROOT/global/config":/home/opencode/.config/opencode
        -v "$DATA_ROOT/global/state":/home/opencode/.local/state/opencode
    )

    # 2. ISOLATED: Caches and session histories scoped strictly to this repository
    project_name=$(basename "$WORKSPACE_DIR")
    project_hash=$(python3 -c "import hashlib; print(hashlib.md5('''$WORKSPACE_DIR'''.encode()).hexdigest()[:8])" 2>/dev/null || printf '%s' "$WORKSPACE_DIR" | md5sum 2>/dev/null | cut -c1-8 || printf '%s' "$WORKSPACE_DIR" | md5 2>/dev/null | cut -c1-8)
    project_id="${project_name}-${project_hash}"
    project_data="$DATA_ROOT/projects/$project_id"

    mkdir -p "$project_data"/{cache,go,share}
    mounts+=(
        -v "$project_data/cache":/home/opencode/.cache
        -v "$project_data/go":/home/opencode/go
        -v "$project_data/share":/home/opencode/.local/share/opencode
    )
fi

# -----------------------------------------------------------------------------
# 9. Build Image Automatically on First Run
# -----------------------------------------------------------------------------
if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    echo "Building $IMAGE_NAME..."
    docker build \
        --build-arg USER_UID="$(id -u)" \
        --build-arg USER_GID="$(id -g)" \
        -t "$IMAGE_NAME" -f "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR"
fi

# -----------------------------------------------------------------------------
# 10. Launch Container
# -----------------------------------------------------------------------------
echo "Launching OpenCode in: $WORKSPACE_DIR (as $BOT_NAME)"

docker_tty_args=()
if [ -t 0 ] && [ -t 1 ]; then
    docker_tty_args=(-it)
elif [ -t 0 ]; then
    docker_tty_args=(-i)
fi

docker run "${docker_tty_args[@]}" --rm \
    --init \
    --security-opt=no-new-privileges:true \
    --pids-limit 1024 \
    "${mounts[@]}" \
    "${env_args[@]}" \
    --workdir /workspace \
    "$IMAGE_NAME" "$@"
```

---

## Critical Components Explained

### 1. Shared Global Config vs. Per-Project Isolated Caches
OpenCode's storage is split across two tiers:

* **Global Tier (`~/opencode-docker/data/global/`):**
  * `config`: Stores your `opencode.json`, custom commands, UI themes, and MCP server configurations. This is shared so you configure tools and prompts once and use them everywhere.
  * `state`: Stores `model.json`, remembering your preferred LLM model across all sessions.
* **Per-Project Isolated Tier (`~/opencode-docker/data/projects/<repo-name>-<hash>/`):**
  * `cache`: Caches for `pip`, `uv`, and `npm` are scoped strictly to the repository. This prevents cache-poisoning attacks where a dependency in Repo A tampers with wheels used by Repo B.
  * `go`: Module downloads and `go/bin` binaries are isolated, preventing malicious tools installed in one project from polluting the `$PATH` in another.
  * `share`: SQLite conversation transcripts and history databases remain strictly scoped to the repository, ensuring private discussions from proprietary repos never bleed into open-source repo sessions.
* **Sandbox Mode (`--sandbox`):**
  * For completely untrusted or disposable tasks, `--sandbox` unmounts all project-level persistent storage, leaving zero trace on your host machine when the session ends.

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

### 5. Native Non-Root Execution
* **Blast Radius Reduction:** Autonomous coding agents execute untrusted scripts and test suites. Running natively as non-root (`opencode`, UID 1000) ensures agents cannot alter container system binaries or exploit root-only container breakout vectors.
* **Instant Startup & Zero File Ownership Conflicts:** The container runs directly as the non-root user matching your host UID/GID (passed via build args `USER_UID` and `USER_GID` defaulting to 1000). On macOS (via VM translation) and Linux (matching host UID directly, whether 1000 or custom), files and Git commits created in `/workspace` are owned directly by your host user account—never `root:root`. No root transitions, no runtime `su-exec`, and no startup directory crawling.
* **Strict Package Philosophy:** The container intentionally omits `sudo`. Developer packages (`npm`, `pnpm`, `uv pip`, `go install`) install freely into user/workspace paths without root. If a new OS-level utility (e.g. `ffmpeg`, `ripgrep`) is needed, add it to `Dockerfile` and run `ocd --rebuild` to keep your environment reproducible and auditable.

### 6. Container Runtime Hardening & Stable Builds
* **Deterministic Stable Repositories:** All toolchain packages (`nodejs`, `python3`, `uv`, `go`, `git`, `gh`, `build-base`) are installed from Alpine's official stable repository rather than rolling `edge` branches, guaranteeing reproducible and reliable builds.
* **Build Context Protection (`.dockerignore`):** Blocks `app.pem`, `data/`, and `.git/` from being sent to the Docker build daemon, preventing key leakage and eliminating build slowness.
* **Privilege Escalation Prevention (`--security-opt=no-new-privileges:true`):** Prevents any child processes inside the container from gaining additional privileges via SUID/SGID binaries.
* **Resource Exhaustion & Fork-Bomb Protection (`--pids-limit 1024`):** Limits maximum concurrent processes to 1024, preventing rogue scripts, runaway thread pools, or fork-bombs from freezing the host system.
* **Zombie Process Reaping (`--init`):** Uses Docker's tiny init system (`tini`) to handle process signaling and automatically reap orphaned/zombie processes left behind by compilers, linters, or test runners.

### 7. Resilient Host Token Refresher & Shell Process Isolation
* **Shell Signal Safety:** Defining cleanup traps inside an interactive shell profile (`~/.zshrc`) risks overriding interactive terminal traps or leaking background jobs. Moving `ocd` to a dedicated executable script ensures all signals (`EXIT`, `INT`, `TERM`, `HUP`) are isolated to its own subshell.
* **Parent Process Liveness Detection:** Instead of an un-interruptible 45-minute sleep, the background refresher loop polls every 30 seconds checking `kill -0 "$PARENT_PID"`. If the terminal window is abruptly closed or killed, the background subshell terminates immediately, leaving zero orphaned processes.
* **Transient Network Retry:** Token renewal uses exponential retry with backoff (`mint_with_retry`), ensuring temporary WiFi or GitHub API drops do not invalidate active coding sessions.
* **Atomic Credential Writes:** Refreshed tokens are written to a PID-tagged temporary file before being atomically replaced via `mv`, preventing race conditions where the container reads a partially written token.

---

## Daily Usage & Device Migration

* **Launch in current repo:** `ocd`
* **Launch in a specific repo:** `ocd ~/projects/my-repo`
* **Launch in sandbox mode (untrusted code):** `ocd --sandbox ~/projects/untrusted-repo`
* **Rebuild image to update dependencies:** `ocd --rebuild`
* **Clear cache for a specific repo:** `rm -rf ~/opencode-docker/data/projects/<project-id>/cache`
* **Clear chat history for a specific repo:** `rm -rf ~/opencode-docker/data/projects/<project-id>/share`
* **Migrate to a new machine:** Clone or copy `~/opencode-docker` to your new machine, copy your `app.pem` and `.env`, run `chmod +x ocd && ln -sf ~/opencode-docker/ocd ~/.local/bin/ocd`, and run `ocd`. All chat histories, keys, and configurations will be immediately available.
