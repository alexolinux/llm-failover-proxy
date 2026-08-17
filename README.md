# llm-failover-proxy

---

**opencode + NVIDIA Build + OpenRouter** free tier automatic 429/503 failover

## Why a proxy, not an opencode setting?

OpenCode (and similar AI coding tools) doesn't natively support "try model B if model A rate-limits or fails" in a single session. The standard solution is to run a lightweight local proxy in front of the provider that does, and point OpenCode at the proxy as if it were a single model.

We use [LiteLLM Proxy](https://docs.litellm.ai/docs/proxy/reliability) for this:

- Automatic failover: On `429 Too Many Requests` or `503 Service Unavailable`, LiteLLM puts the active deployment on cooldown and retries with the next deployment in the fallback pool inside the **same** request — OpenCode never sees the error.
- Lightweight & Portable: Runs locally under your user account without requiring root privileges or complex daemon setups.
- **Multi-provider**: The pool can mix NVIDIA Build free-tier models and OpenRouter free models in one fallback group. `test-models.sh` detects the provider per model — entries whose model name starts with `openrouter/` are probed against `https://openrouter.ai/api/v1` with `OPENROUTER_API_KEY`; everything else is probed against NVIDIA's endpoint with `NVIDIA_API_KEY`.

---

## File Structure

- `config.yaml.example` - Template for `config.yaml`
- `llm-failover.env.example` - Template for `llm-failover.env` (Required API Key variables)
- `opencode.provider.jsonc.example` - Template for the above `opencode.provider.jsonc` content
- `test-models.sh` - Validation script to benchmark latency, tool-calling support, issue warnings, and reorder `config.yaml`
- `reorder_config.py` - Helper script to safely reorder `config.yaml` prioritizing fastest responsive models
- `retest-models-slow.sh` - Quick latency probe for large models
- `run.sh` - Entrypoint script that auto-detects your virtualenv and runs LiteLLM

---

## Setup & Quickstart

Clone this project:

```shell
https://github.com/alexolinux/llm-failover-proxy.git
cd llm-failover-proxy
```

### Environment Configuration

Configure Environment Keys, creating your `llm-failover.env`

```shell
cp llm-failover.env.example llm-failover.env
# Edit NVIDIA_API_KEY, OPENROUTER_API_KEY and LITELLM_MASTER_KEY in llm-failover.env with your API Keys.
chmod 600 llm-failover.env
```

### Adding a model to the pool

Create your `config.yaml`

```shell
cp config.yaml.example config.yaml
```

Add your LLM Models as below:

```shell
model_list:
  # NVB
  - model_name: opencode-main
    litellm_params:
      model: <llm_model_1> # Replace to the LLM Model
      api_base: https://integrate.api.nvidia.com/v1
      api_key: os.environ/NVIDIA_API_KEY
      order: 1

  - model_name: opencode-main
    litellm_params:
      model: <llm_model_2> # Replace to the LLM Model
      api_base: https://openrouter.ai/api/v1
      api_key: os.environ/OPENROUTER_API_KEY
      order: 2
```

Each entry in `model_list` shares `model_name: "opencode-main"` (that's what groups them for failover) and sets its own `litellm_params`:

```yaml
  - model_name: opencode-main
    litellm_params:
      model: openrouter/anthropic/claude-3.5-haiku    # openrouter/ prefix -> OpenRouter endpoint
      api_base: https://openrouter.ai/api/v1
      api_key: os.environ/OPENROUTER_API_KEY
      order: 3
```

- NVIDIA models: `api_base: https://integrate.api.nvidia.com/v1` + `api_key: os.environ/NVIDIA_API_KEY` (the `model` may or may not carry an `openai/` prefix).
- OpenRouter models: `model` must start with `openrouter/`, use `api_base: https://openrouter.ai/api/v1` and `api_key: os.environ/OPENROUTER_API_KEY`.
- `test-models.sh` inspects this list as the single source of truth and probes each entry against the matching endpoint.

### Point OpenCode at the Proxy

Edit and merge the contents of `opencode.provider.jsonc` into your OpenCode configuration (`~/.config/opencode/opencode.jsonc` or local `opencode.jsonc`):

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "model": "nvidia-pool/opencode-main",
  "provider": {
    "nvidia-pool": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "NVIDIA Build (auto-failover)",
      "options": {
        "baseURL": "http://127.0.0.1:4000/v1",
        "apiKey": "{env:LITELLM_MASTER_KEY}" //Or replace for your Key value
      },
      "models": {
        "opencode-main": {
          "name": "NVIDIA free pool",
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
    },
    "openrouter-pool": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "OpenRouter Build (auto-failover)",
      "options": {
        "baseURL": "http://127.0.0.1:4000/v1",
        "apiKey": "{env:LITELLM_MASTER_KEY}" //Or replace for your Key value
      },
      "models": {
        "opencode-main": {
          "name": "OpenRouter free pool",
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

Both pools point at the same local proxy, so either `nvidia-pool/opencode-main` or `openrouter-pool/opencode-main` works as the top-level `model` — the proxy routes across the whole fallback group underneath.

### Python Virtual Environment

```shell
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

### Benchmark Models & Auto-Reorder `config.yaml`

Run the followin commands to prepare your custom OpenCode LLM Proxy

```shell
source llm-failover.env
```

```shell
# Preview ranking and proposed config without writing:
./test-models.sh --dry-run
```

```shell
# Run test and automatically update config.yaml with the fastest viable models:
./test-models.sh --apply
```

Flags: `-c, --config <path>` (default `./config.yaml`), `-a, --apply`, `-d, --dry-run`, `-b, --burst` (10-request concurrency rate-limit isolation test), `-h, --help`.

This script:

1. **Verifies Tool-Calling Support**: Identifies models that properly support OpenAI-compatible function calling (crucial for OpenCode editing/terminal tools).
2. **Measures Precise Latency**: Measures decimal response time and ranks models from fastest to slowest.
3. **Issues Usability Warnings**:
   - 🔴 **Incompatible (`NO-TOOL`)**: Models that return text but ignore tool calls are flagged for exclusion.
   - 🔴 **Inaccessible / Error (`HTTP 4xx/5xx`)**: Offline or failing models.
   - 🟡 **High Latency Alert (`> 10s`)**: Warns about sluggish models and demotes them to lower priority.
4. **Auto-Reorders `config.yaml`** (with `--apply`): Automatically creates a backup (`config.yaml.bak`) and updates `order: 1..N` prioritizing the most responsive verified models. Rate-limited models (`429`) are kept active at the end of the pool; unstable/incompatible models are commented out with a diagnostic note — **commented-out models are never deleted**, they stay in the file ready to be un-commented or re-tested later.

### 5. Start & Control the Proxy

You can control the proxy using `./run.sh` directly or load the `llmfailoverproxy` shell function into your terminal session:

#### Direct CLI

```shell
./run.sh start    # Start in background
./run.sh status   # Check status and health
./run.sh logs     # Follow logs in real time
./run.sh stop     # Stop background proxy
./run.sh restart  # Restart proxy
./run.sh          # Run in foreground
```

#### Shell Function (Optional)

Source `run.sh` in your shell (or add `source /path/to/llm-failover-proxy/run.sh` to your `~/.bashrc` / `~/.zshrc`):

```shell
source ./run.sh

# Now manage llm-failover-proxy from any directory:
llmfailoverproxy start
llmfailoverproxy status
llmfailoverproxy logs
llmfailoverproxy stop
```

`run.sh` automatically detects any virtual environment in the project directory, loads `llm-failover.env`, and starts LiteLLM proxy on `127.0.0.1:4000`.

### 6. Monitor Proxy & Failovers

Logs stream directly in foreground mode or via `./run.sh logs`.
When a rate-limit (429) or overload (503) occurs, LiteLLM logs the cooldown and routes the prompt to the next deployment seamlessly.

---

## Tuning Knobs in `config.yaml`

- `routing_strategy: simple-shuffle`: Respects the `order: 1`, `order: 2` fallback priority and balances requests across active deployments. Switch to `latency-based-routing` or `least-busy` if desired.
- `cooldown_time: 60`: Number of seconds a rate-limited model is benched before retry.
- `allowed_fails_policy.RateLimitErrorAllowedFails: 1`: Immediately bench a model on the first 429/503 rather than wasting retries on a struggling backend.
- `request_timeout: 45`: Fail over from a hung or lagging model before the client times out.

## Author

https://alexolinux.com
