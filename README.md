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

   > [!TIP]
   > **Want Zero-Secret Isolation?**
   > `.env.container` protects your host machine from the agent, but the agent inside Docker can inspect its own environment. For zero-trust isolation where master keys are completely hidden from the agent, see the optional **[Bifrost Gateway Guide](bifrost/README.md)**.

3. **Secure Your Private Key (`app.pem`):**
   Move your downloaded GitHub App private key into the repository and restrict permissions to owner-only:
   ```bash
   mv ~/Downloads/your-app.private-key.pem ~/opencode-docker/app.pem
   chmod 600 ~/opencode-docker/app.pem
   ```

*(Need to create a GitHub App? See the [GitHub App Creation Guide](https://docs.github.com/en/apps/creating-github-apps/about-creating-github-apps)).*

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

## Configuring MCP Servers, Skills & Commands

OpenCode natively supports **Model Context Protocol (MCP)** tools, modular **Skills**, and custom **Slash Commands**. The container maps your local directories so you can configure them globally or per repository.

*(Optional reference templates are provided in `config.example/` if you want to inspect or copy starter configurations; none are enabled by default).*

### 1. Model Context Protocol (MCP) Servers
Configure MCP servers using the `"mcp"` key in your OpenCode configuration:
* **Global Tools (Available across all projects):** Create `~/opencode-docker/data/global/config/opencode.json`
* **Repository Tools (Scoped to this repository only):** Create `<repo>/opencode.json`

Example configuration:
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
      "enabled": true
    }
  }
}
```

* **Tool Credentials (Native Mode):** Define any required API keys (e.g. `BRAVE_API_KEY`, `DATABASE_URL`) in `.env.container`. They are passed to the container via Docker's native `--env-file`.
* **Zero-Secret Mode (Bifrost Gateway):** If you prefer not to expose raw tool keys or LLM master keys inside the container, use the integrated **[Bifrost Gateway](bifrost/README.md)**. The agent connects to tools over SSE without having credentials on disk:
  ```json
  {
    "mcp": {
      "bifrost": {
        "type": "remote",
        "url": "http://host.docker.internal:{env:BIFROST_PORT}/mcp/sse",
        "enabled": true
      }
    }
  }
  ```
  *(See template in `config.example/opencode.json` and run `ocd gateway start`).*
* **npm Cache:** Package downloads for `npx` MCP servers are cached in `data/global/cache/npm` to avoid re-downloading on each run.

### 2. Skills
Skills are modular markdown instructions (`SKILL.md`) that OpenCode loads dynamically when relevant to user prompts:
* **Global Skills:** Place in `~/opencode-docker/data/global/config/skills/<skill-name>/SKILL.md`
* **Project Skills:** Place in `<repo>/.opencode/skills/<skill-name>/SKILL.md`

### 3. Custom Commands (Slash Commands)
Custom slash commands allow you to create reusable prompts in the OpenCode TUI:
* **Global Commands:** Place markdown files in `~/opencode-docker/data/global/config/commands/<command-name>.md`
* **Project Commands:** Place markdown files in `<repo>/.opencode/commands/<command-name>.md`

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

## Gateway Management Commands

When using the optional Bifrost Zero-Secret Gateway, manage the daemon directly from `ocd`:

```bash
ocd gateway start    # Start the Bifrost Gateway daemon (:8080)
ocd gateway stop     # Stop the Bifrost Gateway daemon
ocd gateway status   # Check if Bifrost Gateway is running
ocd gateway logs     # View live streaming logs from Bifrost
ocd gateway ui       # Open http://localhost:8080 in your default browser
```

---

## Security Boundaries & Recommended Safeguards

While `ocd` guarantees complete host machine isolation, autonomous agents with workspace write access still benefit from defense-in-depth safeguards:
* **Zero-Secret Isolation:** Route through the [Bifrost Gateway](bifrost/README.md) to keep master LLM keys and tool credentials off the container filesystem.
* **GitHub Branch Protection:** Enforce PR reviews and block direct pushes to `main`.
* **Disable Force Pushes:** Ensure `Allow force pushes` is disabled in GitHub branch rulesets.
* **Strict App Scoping:** Grant the GitHub App access only to specific target repositories.
* **Provider Spend Limits:** Set monthly hard caps in your LLM provider dashboards to prevent runaway loops.
* **Lockfiles:** Commit package lockfiles (`package-lock.json`, `uv.lock`, etc.) to prevent hallucinated package attacks.
