# OpenCode in Docker (`ocd`)

Run autonomous AI coding agents in a production-hardened, non-root Docker container with automated GitHub App bot authentication, transparent SSH-to-HTTPS credential rewriting, and tiered project isolation.

Works seamlessly on **macOS (Apple Silicon & Intel)** and **Linux (x86_64 & ARM64)**.

---

## Why Run OpenCode in Docker?

Running an autonomous coding agent directly on your host machine gives untrusted model-generated code access to your personal SSH keys (`~/.ssh`), cloud tokens (`~/.aws`, `~/.kube`), browser cookies, and your entire home directory.

**OpenCode Docker (`ocd`)** enforces strict defense-in-depth isolation:

| Security Layer | Implementation | What It Prevents |
| :--- | :--- | :--- |
| **Filesystem Isolation** | Mounts only the target workspace directory (`$absolute_path:/workspace`) rather than `~`. | Prevents the agent from reading or modifying sibling repositories, host dotfiles, or system files. |
| **Zero Personal Credentials** | Replaces personal SSH keys and personal access tokens (PATs) with a dedicated **GitHub App**. | Scopes bot access strictly to authorized repositories. Commits and PRs are clearly audited under `your-app[bot]`. |
| **Ephemeral Tokens** | Mints 1-hour GitHub installation tokens via host RS256 JWTs; auto-refreshed every 45 minutes. | Eliminates long-lived static tokens. If a token is leaked in logs, it expires automatically within an hour. |
| **Zero Private Key Exposure** | Keeps `app.pem` strictly on the host. Mounts only an ephemeral token to `/run/secrets/github_token:ro`. | Prevents the master GitHub App private key from being exfiltrated by prompt injection or malicious dependencies. |
| **Native Non-Root Execution** | Container runs natively as non-root user `opencode` (matching host UID/GID at build time). | Eliminates container breakout blast radius and guarantees host user file ownership without slow startup `chown` crawling. |
| **Runtime Hardening** | `--security-opt=no-new-privileges:true` and `--pids-limit 1024`. | Blocks SUID privilege escalation and protects the host system against fork-bombs and resource exhaustion. |
| **Zombie Process Reaping** | Docker `--init` (`tini`) process supervisor. | Ensures compiler, linter, and runtime sub-processes (`npm`, `python`, `go`) are cleanly reaped on exit. |

---

## ⚡ 2-Minute Quickstart

### 1. Clone the Repository
```bash
git clone https://github.com/CodeDudes/opencode-docker.git ~/opencode-docker
cd ~/opencode-docker
```

### 2. Configure Credentials

We enforce strict defense-in-depth isolation by separating host runner secrets from container agent credentials:

1. **Configure Host Runner (`.env`):**
   Copy the host configuration template and fill in your GitHub App details:
   ```bash
   cp .env.example .env
   ```
   *(These secrets are used strictly by the host `ocd` runner to mint short-lived tokens and are **never** mounted or exposed to the Docker container).*
   ```dotenv
   GH_APP_ID="123456"
   GH_INSTALLATION_ID="87654321"
   GH_APP_SLUG="your-org-opencode-bot"
   ```

2. **Configure Container Agent (`.env.container`):**
   Copy the container environment template and set the API keys your OpenCode agent will use:
   ```bash
   cp .env.container.example .env.container
   ```
   *(Variables in this file are passed directly to the container via `docker run --env-file .env.container`).*
   ```dotenv
   ANTHROPIC_API_KEY="sk-ant-..."
   OPENAI_API_KEY="sk-..."
   GEMINI_API_KEY="AIzaSy..."
   ```

3. **Secure Your Private Key (`app.pem`):**
   Move your downloaded GitHub App private key into the repository and restrict permissions to owner-only:
   ```bash
   mv ~/Downloads/your-app.private-key.pem ~/opencode-docker/app.pem
   chmod 600 ~/opencode-docker/app.pem
   ```

*(Need to create a GitHub App? See the [Step-by-Step GitHub App Guide](blog.md#1-create-the-github-app-and-gather-credentials) in `blog.md`).*

### 3. Add the `ocd` Alias to Your Shell
Make `ocd` executable and add the alias to your shell profile:

```bash
chmod +x ~/opencode-docker/ocd

# On macOS (zsh):
echo 'alias ocd="$HOME/opencode-docker/ocd"' >> ~/.zshrc
source ~/.zshrc

# On Linux (bash):
echo 'alias ocd="$HOME/opencode-docker/ocd"' >> ~/.bashrc
source ~/.bashrc
```

*(Alternatively, you can symlink `ocd` into `~/.local/bin` or `/usr/local/bin` if preferred).*

### 4. Launch OpenCode
```bash
# Launch in the current repository:
ocd

# Or launch in a specific repository:
ocd ~/projects/my-repo
```
*On first run, `ocd` automatically builds the Docker image tailored to your host UID/GID.*

---

## Daily Usage Cheat Sheet

| Command | Description |
| :--- | :--- |
| `ocd` | Launch OpenCode in current directory |
| `ocd ~/projects/my-app` | Launch OpenCode in a specific project directory |
| `ocd --sandbox .` | Launch in disposable sandbox mode (zero host persistence) |
| `ocd --rebuild` | Rebuild the container image with your host UID/GID |
| `ocd -- <command>` | Run arbitrary commands or pass flags directly to container tools (e.g. `ocd -- git status`, `ocd -- gh pr list`) |
| `ocd --help` | Display CLI options and usage |

---

## Storage & Project Isolation

All runtime data is consolidated inside `~/opencode-docker/data/` (automatically git-ignored):

```
~/opencode-docker/data/
├── global/                         <-- Shared across all repositories
│   ├── config/                     <-- opencode.json, custom commands, MCP servers, skills
│   ├── state/                      <-- model.json, preferred LLM preferences
│   └── cache/npm/                  <-- Global npm cache for npx MCP tools & plugins
└── projects/                       <-- Scoped strictly per-repository
    └── <repo-name>-<hash>/
        ├── cache/                  <-- Isolated pip, uv caches (prevents cross-repo cache poisoning)
        ├── go/                     <-- Isolated Go module caches and binaries
        └── share/                  <-- Scoped SQLite conversation histories
```

* **Sandbox Mode (`--sandbox`):** Disables all project persistent mounts, running an ephemeral session that leaves zero trace on your machine when exited.

---

## Extending OpenCode: MCP Servers & Skills

`ocd` provides first-class support for **Model Context Protocol (MCP)** tools, modular **Skills**, and custom **Slash Commands**. On your first run, starter templates from `config.example/` are automatically seeded into `~/opencode-docker/data/global/config/`.

### 1. Model Context Protocol (MCP) Servers
Configure MCP servers in `~/opencode-docker/data/global/config/opencode.json` (or in `<repo>/opencode.json` for repository-specific tools):

```json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "fetch": {
      "command": ["uvx", "mcp-server-fetch"],
      "enabled": true
    },
    "filesystem": {
      "command": ["npx", "-y", "@modelcontextprotocol/server-filesystem", "/workspace"],
      "enabled": false
    },
    "brave-search": {
      "command": ["npx", "-y", "@modelcontextprotocol/server-brave-search"],
      "enabled": false,
      "env": {
        "BRAVE_API_KEY": "{env:BRAVE_API_KEY}"
      }
    }
  }
}
```

* **Arbitrary Tool Secrets:** Define any tool credentials directly in `.env.container` (e.g. `BRAVE_API_KEY`, `DATABASE_URL`, or `STRIPE_KEY`). Because `ocd` passes `.env.container` via Docker's native `--env-file`, tools receive their variables with zero code changes or whitelisting.
* **Instant Startup:** The `~/.npm` directory is persisted under `data/global/cache/npm`, ensuring `npx` MCP servers launch in milliseconds without re-downloading packages.

### 2. Skills (On-Demand Knowledge Injection)
Skills are modular markdown instructions that OpenCode dynamically loads when your prompt requires them:
* **Global Skills:** Place in `~/opencode-docker/data/global/config/skills/<skill-name>/SKILL.md` (e.g. standard `git-workflow`).
* **Project Skills:** Place in `<repo>/.opencode/skills/<skill-name>/SKILL.md`.

### 3. Custom Commands (Slash Commands)
Create reusable prompts and slash commands with live shell integration (`!command`):
* Place markdown files in `~/opencode-docker/data/global/config/commands/` (e.g., `/review-pr` in `commands/review-pr.md` which inspects `!git diff --staged`).

---

## Pre-Installed Toolchains

The container image includes comprehensive developer toolchains installed from official stable Alpine repositories:

* **Languages & Package Managers:** Node.js, `npm`, Python 3, `pip`, `uv`, Go
* **Version Control & Collaboration:** Git, GitHub CLI (`gh`), OpenSSH client
* **Build Essentials & Utilities:** `build-base` (gcc/g++, make), `curl`, `jq`, `openssl`, `ca-certificates`

To add additional system packages (e.g. `ffmpeg`, `ripgrep`), add them to `Dockerfile` and run `ocd --rebuild`.

---

## Device Migration

To move your entire OpenCode setup to a new machine:
1. Clone this repository to `~/opencode-docker`.
2. Copy your `app.pem` and `.env` into `~/opencode-docker/`.
3. (Optional) Copy `~/opencode-docker/data/global/` to preserve your custom commands and model preferences.
4. Make `ocd` executable (`chmod +x ocd`), add the alias `alias ocd="$HOME/opencode-docker/ocd"` to your shell profile, and start coding with `ocd`.

---

## Security Boundaries & Recommended Safeguards

While `ocd` guarantees complete host machine isolation, autonomous agents with workspace write access still require codebase-level safeguards:
* **GitHub Branch Protection:** Enforce PR reviews and block direct pushes to `main`.
* **Disable Force Pushes:** Ensure `Allow force pushes` is disabled in GitHub branch rulesets.
* **Strict App Scoping:** Grant the GitHub App access only to specific target repositories.
* **Provider Spend Limits:** Set monthly hard caps in your LLM provider dashboards to prevent runaway loops.
* **Lockfiles:** Commit package lockfiles (`package-lock.json`, `uv.lock`, etc.) to prevent hallucinated package attacks.

For a full breakdown of agent threat vectors, see [blog.md](blog.md).

---

## In-Depth Documentation

For the full architectural deep dive, security threat model, and line-by-line script walkthrough, read [blog.md](blog.md).
