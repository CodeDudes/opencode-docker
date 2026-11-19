# Bifrost AI & MCP Gateway for `opencode-docker`

This directory provides an optional, hardened **Zero-Secret Gateway** powered by [Bifrost OSS](https://github.com/maximhq/bifrost) (Apache 2.0).

---

## Why Use Bifrost Mode?

By default, `opencode-docker` isolates your host filesystem (`~/.ssh`, host files). However, any API keys placed in `.env.container` are readable by the agent running inside Docker.

Running with the **Bifrost Gateway** upgrades your sandbox to a **Zero-Secret Sandbox**:
1. **Master Keys Stay Outside Docker:** Real `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, and `BRAVE_API_KEY` live exclusively in `bifrost/.env.bifrost` on the host sidecar.
2. **Disposable Virtual Keys:** OpenCode in Docker receives only spend-capped virtual keys or an internal proxy URL (`http://host.docker.internal:8080/v1`).
3. **Prompt Injection Defense:** Even if an agent is tricked by indirect prompt injection and dumps all environment variables (`printenv`), there are no master secrets to steal.
4. **Live Observability:** A local web dashboard at `http://localhost:8080` provides real-time token tracking, latency, and tool invocation audits.

---

## Quick Start (3 Steps)

### Step 1: Configure Master Credentials
Copy the example environment file and add your provider keys:
```bash
cp bifrost/.env.bifrost.example bifrost/.env.bifrost
```

### Step 2: Start the Gateway
You can start the gateway using `ocd`:
```bash
ocd gateway start
```
*(Or manually via `docker compose -f bifrost/docker-compose.yml up -d`)*

Verify it is running:
* **Web Dashboard:** Open `http://localhost:8080` in your browser (or run `ocd gateway ui`).

### Step 3: Configure OpenCode to Use Bifrost
1. In your `.env.container`, comment out raw master keys and point to Bifrost:
   ```dotenv
   OPENAI_API_BASE="http://host.docker.internal:8080/v1"
   OPENAI_API_KEY="dummy-virtual-key"
   ANTHROPIC_BASE_URL="http://host.docker.internal:8080/v1"
   ```
2. Enable remote MCP in your project or global `opencode.json` (see `config.example/opencode.bifrost.json`):
   ```json
   {
     "mcp": {
       "bifrost": {
         "type": "remote",
         "url": "http://host.docker.internal:8080/mcp/sse",
         "enabled": true
       }
     }
   }
   ```

Now run `ocd` as normal:
```bash
ocd
```

---

## Gateway Management Commands

```bash
ocd gateway start    # Start the Bifrost gateway daemon
ocd gateway stop     # Stop the Bifrost gateway daemon
ocd gateway status   # Check if gateway is running on port 8080
ocd gateway logs     # View live gateway logs
ocd gateway ui       # Open web dashboard in default browser
```
