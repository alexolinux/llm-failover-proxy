# llm-failover-proxy

---

**opencode + NVIDIA Build** free tier automatic 429/503 failover

## Why a proxy, not an opencode setting?

OpenCode (and similar AI coding tools) doesn't natively support "try model B if model A rate-limits or fails" in a single session. The standard solution is to run a lightweight local proxy in front of the provider that does, and point OpenCode at the proxy as if it were a single model.

We use [LiteLLM Proxy](https://docs.litellm.ai/docs/proxy/reliability) for this:

- Automatic failover: On `429 Too Many Requests` or `503 Service Unavailable`, LiteLLM puts the active deployment on cooldown and retries with the next deployment in the fallback pool inside the **same** request — OpenCode never sees the error.
- Lightweight & Portable: Runs locally under your user account without requiring root privileges or complex daemon setups.

---

## File Structure

- `config.yaml` - Model pool definitions, retry policies, and fallback order
- `nvidia-failover.env.example` - Template for your API keys
- `nvidia-failover.env` - Your actual local environment file (`chmod 600`)
- `run.sh` - Entrypoint script that auto-detects your virtualenv and runs LiteLLM
- `opencode.provider.jsonc` - Configuration snippet to merge into `opencode.json`
- `test-models.sh` - Validation script to benchmark latency, tool-calling support, issue warnings, and reorder `config.yaml`
- `reorder_config.py` - Helper script to safely reorder `config.yaml` prioritizing fastest responsive models
- `retest-models-slow.sh` - Quick latency probe for large models

---

## Setup & Quickstart

### 1. Environment Configuration

Configure Environment Keys, creating your `nvidia-failover.env`

```shell
cp nvidia-failover.env.example nvidia-failover.env
# Edit NVIDIA_API_KEY and LITELLM_MASTER_KEY in nvidia-failover.env
chmod 600 nvidia-failover.env
```

### 2 Point OpenCode at the Proxy

Copy/Create `opencode.provider.jsonc`

```shell
cp opencode.provider.jsonc.example opencode.provider.jsonc
```

Merge the contents of `opencode.provider.jsonc` into your OpenCode configuration (`~/.config/opencode/opencode.jsonc` or local `opencode.jsonc`):

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
        "apiKey": "YOUR_LITELLM_MASTER_KEY"
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
    }
  }
}
```

### 2. Install LiteLLM into a Virtual Environment

```shell
git clone https://github.com/alexolinux/llm-failover-proxy.git
cd llm-failover-proxy
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

### 3. Benchmark Models & Auto-Reorder `config.yaml`

```shell
# Preview ranking and proposed config without writing:
NVIDIA_API_KEY=nvapi-... ./test-models.sh --dry-run

# Run test and automatically update config.yaml with the fastest viable models:
NVIDIA_API_KEY=nvapi-... ./test-models.sh --apply
```

This script:

1. **Verifies Tool-Calling Support**: Identifies models that properly support OpenAI-compatible function calling (crucial for OpenCode editing/terminal tools).
2. **Measures Precise Latency**: Measures decimal response time and ranks models from fastest to slowest.
3. **Issues Usability Warnings**:
   - 🔴 **Incompatible (`NO-TOOL`)**: Models that return text but ignore tool calls are flagged for exclusion.
   - 🔴 **Inaccessible / Error (`HTTP 4xx/5xx`)**: Offline or failing models.
   - 🟡 **High Latency Alert (`> 10s`)**: Warns about sluggish models and demotes them to lower priority.
4. **Auto-Reorders `config.yaml`** (with `--apply`): Automatically creates a backup (`config.yaml.bak`) and updates `order: 1..N` prioritizing the most responsive verified models.

### 4. Start & Control the Proxy

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

`run.sh` automatically detects any virtual environment in the project directory, loads `nvidia-failover.env`, and starts LiteLLM proxy on `127.0.0.1:4000`.

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
