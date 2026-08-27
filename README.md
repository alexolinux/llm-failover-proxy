# llm-failover-proxy

---

**opencode + NVIDIA Build + OpenRouter** free tier automatic 429/503 failover proxy.

## Why a proxy, not an opencode setting?

OpenCode (and similar AI coding tools) doesn't natively support "try model B if model A rate-limits or fails" in a single session. The standard solution is to run a lightweight local proxy in front of the provider that does, and point OpenCode at the proxy as if it were a single model.

We use [LiteLLM Proxy](https://docs.litellm.ai/docs/proxy/reliability) for this:

- **Automatic failover**: On `429 Too Many Requests` or `503 Service Unavailable`, LiteLLM puts the active deployment on cooldown and retries with the next deployment in the fallback pool inside the **same** request — OpenCode never sees the error.
- **Lightweight & Portable**: Runs inside Docker or locally without requiring root privileges or complex daemon setups.
- **Multi-provider**: The pool mixes NVIDIA Build free-tier models and OpenRouter free models in one fallback group. `test-models.sh` resolves the provider from each entry's `api_base`, then probes the correct endpoint with the matching `OPENROUTER_API_KEY` or `NVIDIA_API_KEY`.

---

## File Structure

```shell
llm-failover-proxy/
├── docker-compose.yml          # Docker Compose orchestration
├── .dockerignore               # Docker build exclusions
├── requirements.txt            # Python dependencies (local & container runtime)
├── run.sh                      # Universal CLI entrypoint (local & Docker management)
├── config.yaml                 # Active proxy model configuration (mounted in container)
├── llm-failover.env            # Active API keys and secrets (loaded by Docker & local runner)
│
├── docker/                     # Container build definitions
│   └── Dockerfile              # Container image definition
│
├── scripts/                    # Utility and maintenance scripts
│   ├── test-models.sh          # Benchmark and latency probe tool
│   ├── reorder_config.py       # Safe YAML reordering helper
│   └── generate_validation.py  # Validation rule generator
│
└── templates/                  # Configuration templates
    ├── config.yaml.template
    ├── llm-failover.env.template
    └── opencode.provider.jsonc.template
```

---

## Step-by-Step Setup & Usage Guide

Follow these steps in order to configure, benchmark, and run your failover proxy.

---

### Step 1: Environment & API Keys

1. Clone the repository:

   ```shell
   git clone https://github.com/alexolinux/llm-failover-proxy.git
   cd llm-failover-proxy
   ```

2. Create your `llm-failover.env` from the template:

   ```shell
   cp templates/llm-failover.env.template llm-failover.env
   chmod 600 llm-failover.env
   ```

3. Open `llm-failover.env` and fill in your keys:

   - `NVIDIA_API_KEY`: Get from [NVIDIA Build](https://build.nvidia.com/).
   - `OPENROUTER_API_KEY`: Get from [OpenRouter Settings](https://openrouter.ai/settings/keys).
   - `LITELLM_MASTER_KEY`: Any secret string you choose (e.g. `sk-litellm-...`). OpenCode uses this key to authenticate with your local proxy.

---

### Step 2: Configure Models in `config.yaml`

1. Create your active `config.yaml` from the template:

   ```shell
   cp templates/config.yaml.template config.yaml
   ```

2. Understand how models are structured in `config.yaml`:

   ```yaml
   model_list:
     # NVIDIA Build free tier model
     - model_name: opencode-main
       litellm_params:
         model: openai/nvidia/llama-3.3-nemotron-super-49b-v1
         api_base: https://integrate.api.nvidia.com/v1
         api_key: os.environ/NVIDIA_API_KEY
         order: 1

     # OpenRouter free tier model
     - model_name: opencode-main
       litellm_params:
         model: openai/cohere/north-mini-code:free
         api_base: https://openrouter.ai/api/v1
         api_key: os.environ/OPENROUTER_API_KEY
         order: 2
   ```

3. **Critical Rules for Models**:
   - **Shared `model_name`**: Every entry in `model_list` must share the same `model_name: "opencode-main"`. This groups all models into a single failover pool across providers.
   - **The `openai/` Prefix**: Every `model:` value **must** start with `openai/` (e.g. `openai/nvidia/...` or `openai/meta/...`). This tells LiteLLM to use its OpenAI-compatible handler and honor the specified `api_base`.
   - **`order: N`**: Defines the initial fallback priority (1 = first attempted, 2 = second fallback, etc.).

---

### Step 3: Benchmark Models & Auto-Reorder `config.yaml`

Before starting the proxy, run the benchmark tool to test model availability, tool-calling compatibility, and latency:

```shell
# 1. Load your API keys for the test
source llm-failover.env

# 2. Preview benchmark ranking without modifying config.yaml (Dry Run):
./scripts/test-models.sh --dry-run

# 3. Benchmark and automatically reorder config.yaml with the fastest viable models:
./scripts/test-models.sh --apply
```

#### What `test-models.sh` does:
- **Validates `config.yaml`**: Checks that all entries have the `openai/` prefix, valid endpoints, and environment variables.
- **Verifies Tool-Calling Support**: Tests OpenAI function calling (crucial for OpenCode editing/terminal tools) and automatically comments out incompatible models (`NO-TOOL`).
- **Measures Precise Latency**: Ranks responsive models from fastest to slowest.
- **Auto-Reorders `config.yaml`** (with `--apply`): Automatically backs up (`config.yaml.bak`) and updates `order: 1..N` so that the fastest, most reliable models are prioritized first in the failover pool.

---

### Step 4: Start the Proxy

Choose how you want to run the proxy:

#### Option A: Run with Docker Compose (Recommended)

Run portably in an isolated container with zero host dependencies:

```shell
# Start proxy in background
docker compose up -d

# View live logs
docker compose logs -f

# Check container status and healthcheck
docker compose ps

# Stop proxy
docker compose down
```

> **Tip**: You can also use the CLI helper `./run.sh docker <up|down|logs|status|restart|build>`.

#### Option B: Run Locally with Python Virtualenv

If you prefer running directly on your host system:

```shell
# Create virtual environment and install requirements
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

# Manage the local proxy
./run.sh start    # Start in background
./run.sh logs     # Follow live logs
./run.sh status   # Check status and health
./run.sh stop     # Stop proxy
./run.sh          # Run in foreground
```

---

### Step 5: Point OpenCode at the Proxy

Configure OpenCode to route requests through your local proxy instead of directly to a single provider.

Merge the template from `templates/opencode.provider.jsonc.template` into your OpenCode configuration (`~/.config/opencode/opencode.json` or local `opencode.json`):

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "model": "llm-failover-proxy/opencode-main",
  "provider": {
    "llm-failover-proxy": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "LLM Free Proxy (auto-failover)",
      "options": {
        "baseURL": "http://127.0.0.1:4000/v1",
        "apiKey": "{env:LITELLM_MASTER_KEY}" // Or replace with your LITELLM_MASTER_KEY string
      },
      "models": {
        "opencode-main": {
          "name": "LLM failover proxy",
          "capabilities": {
            "tools": true,
            "input": ["text"],
            "output": ["text"]
          },
          "limit": {
            "context": 65536,
            "output": 8192
          }
        }
      }
    }
  }
}
```

---

### Step 6: Monitor Proxy & Automatic Failovers

Follow proxy logs to see routing and automatic failover in action:

- **Docker**: `docker compose logs -f`
- **Local**: `./run.sh logs`

When a provider returns `429 Too Many Requests` or `503 Service Unavailable`, LiteLLM puts that model on cooldown and immediately forwards the request to the next deployment in the pool within the same request.

---

## Tuning Knobs in `config.yaml`

- `routing_strategy: simple-shuffle`: Respects the `order: 1`, `order: 2` fallback priority and balances requests across active deployments. Switch to `latency-based-routing` or `least-busy` if desired.
- `cooldown_time: 60`: Number of seconds a rate-limited model is benched before retry.
- `allowed_fails: 1` and `allowed_fails_policy.*AllowedFails: 1`: Bench a model after the first rate-limit, server, or timeout failure rather than repeatedly using a struggling backend.
- `num_retries` and `retry_policy`: Control how many retries LiteLLM makes for rate limits, server errors, and timeouts.
- `request_timeout: 45`: Fail over from a hung or lagging model before the client times out.

## Author

https://alexolinux.com

