# llm-failover-proxy

---

**opencode + NVIDIA Build + OpenRouter** free tier automatic 429/503 failover

## Why a proxy, not an opencode setting?

OpenCode (and similar AI coding tools) doesn't natively support "try model B if model A rate-limits or fails" in a single session. The standard solution is to run a lightweight local proxy in front of the provider that does, and point OpenCode at the proxy as if it were a single model.

We use [LiteLLM Proxy](https://docs.litellm.ai/docs/proxy/reliability) for this:

- Automatic failover: On `429 Too Many Requests` or `503 Service Unavailable`, LiteLLM puts the active deployment on cooldown and retries with the next deployment in the fallback pool inside the **same** request — OpenCode never sees the error.
- Lightweight & Portable: Runs locally under your user account without requiring root privileges or complex daemon setups.
- **Multi-provider**: The pool can mix NVIDIA Build free-tier models and OpenRouter free models in one fallback group. `test-models.sh` resolves the provider from each entry's `api_base`, then probes the correct endpoint with the matching `OPENROUTER_API_KEY` or `NVIDIA_API_KEY`.

---

## File Structure

- `config.yaml.example` - Template for `config.yaml`
- `llm-failover.env.example` - Template for `llm-failover.env` (Required API Key variables)
- `opencode.provider.jsonc.example` - OpenCode provider configuration template
- `test-models.sh` - Validation script to benchmark latency, tool-calling support, issue warnings, and reorder `config.yaml`
- `reorder_config.py` - Helper script to safely reorder `config.yaml` prioritizing fastest responsive models
- `generate_validation.py` - Generates provider validation rules from `config.yaml`
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

```yaml
model_list:
  # NVIDIA Build free tier
  - model_name: opencode-main
    litellm_params:
      model: openai/<llm_model_1> # Replace with the LLM Model (must keep the openai/ prefix)
      api_base: https://integrate.api.nvidia.com/v1
      api_key: os.environ/NVIDIA_API_KEY
      order: 1

  # OpenRouter free tier
  - model_name: opencode-main
    litellm_params:
      model: openai/<llm_model_2> # Replace with the LLM Model (must keep the openai/ prefix)
      api_base: https://openrouter.ai/api/v1
      api_key: os.environ/OPENROUTER_API_KEY
      order: 2
```

Each entry in `model_list` shares `model_name: "opencode-main"` (that's what groups them into ONE failover pool covering both providers) and sets its own `litellm_params`:

```yaml
  - model_name: opencode-main
    litellm_params:
      model: openai/anthropic/claude-3.5-haiku    # openai/ prefix -> honors api_base -> OpenRouter
      api_base: https://openrouter.ai/api/v1
      api_key: os.environ/OPENROUTER_API_KEY
      order: 3
```

- **For this repository, every `model:` value must be prefixed with `openai/`** (for example, `openai/nvidia/llama-3.3-nemotron-super-49b-v1` or `openai/cohere/north-mini-code:free`). This is a LiteLLM routing convention for this mixed-provider setup, not a requirement for the model itself or for every LiteLLM deployment. The prefix tells LiteLLM to use its OpenAI-compatible handler and honor the entry's `api_base`; LiteLLM strips the prefix before sending the model ID to NVIDIA or OpenRouter. Without it, provider-shaped IDs such as `nvidia/...` or `cohere/...` may select a native handler and ignore `api_base`, which can send an OpenRouter model to the wrong service and produce errors such as `404 page not found`.
- If you use a single provider with LiteLLM's native handler, that provider may not need the prefix. Do not copy that pattern into this project unless you also change the validation and routing design.
- NVIDIA models: `api_base: https://integrate.api.nvidia.com/v1` + `api_key: os.environ/NVIDIA_API_KEY`.
- OpenRouter models: set `api_base: https://openrouter.ai/api/v1` and `api_key: os.environ/OPENROUTER_API_KEY`.
- `test-models.sh` inspects this list as the single source of truth and probes each entry against the matching endpoint.

### Point OpenCode at the Proxy

Edit and merge the contents of `opencode.provider.jsonc.example` into your OpenCode configuration (`~/.config/opencode/opencode.json` or local `opencode.json`):

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
        "apiKey": "{env:LITELLM_MASTER_KEY}" //Or replace for your Key value
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

A single pool `llm-failover-proxy` covers both NVIDIA Build and OpenRouter free models — the proxy routes across the whole fallback group (all `model_list` entries sharing `model_name: opencode-main`) underneath.

### Python Virtual Environment

```shell
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

### Benchmark Models & Auto-Reorder `config.yaml`

Run the following commands to prepare your custom OpenCode LLM proxy.

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

Flags: `-c, --config <path>` (default `./config.yaml`), `-a, --apply` (alias: `--update-config`), `-d, --dry-run`, `-b, --burst` (10-request concurrency rate-limit isolation test), `-h, --help`.

This script:

0. **Validates `config.yaml` structure** (before benchmarking): checks every active entry for the required `openai/` prefix, a known free-tier `api_base`, and a set `api_key` env var — and fails fast with a diagnostic if the pool would break LiteLLM at runtime (e.g. the `404 page not found` caused by a missing `openai/` prefix on an OpenRouter entry).
1. **Verifies Tool-Calling Support**: Identifies models that properly support OpenAI-compatible function calling (crucial for OpenCode editing/terminal tools).
2. **Measures Precise Latency**: Measures decimal response time and ranks models from fastest to slowest.
3. **Issues Usability Warnings**:
   - 🔴 **Incompatible (`NO-TOOL`)**: Models that return text but ignore tool calls are flagged for exclusion.
   - 🔴 **Inaccessible / Error (`HTTP 4xx/5xx`)**: Offline or failing models — a `404` notes the model may have been removed or renamed by the provider (free model lists change often), and a `401/403` notes the key was rejected or the model left the free tier.
   - 🟡 **High Latency Alert (`> 10s`)**: Warns about sluggish models and demotes them to lower priority.
4. **Auto-Reorders `config.yaml`** (with `--apply`): Automatically creates a backup (`config.yaml.bak`) and updates `order: 1..N` prioritizing the most responsive verified models. Rate-limited models (`429`) are kept active at the end of the pool; unstable/incompatible models are commented out with a diagnostic note — **commented-out models are never deleted**, they stay in the file ready to be un-commented or re-tested later. The `openai/` prefix is preserved on every reorder.

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

`run.sh` automatically finds a LiteLLM executable, loads `llm-failover.env`, and starts the proxy on `127.0.0.1:4000`. Set `HOST` or `PORT` to override the bind address. The default command is foreground `run`; `start` runs it in the background.

### 6. Monitor Proxy & Failovers

Logs stream directly in foreground mode or via `./run.sh logs`.
When a rate-limit (429) or overload (503) occurs, LiteLLM logs the cooldown and routes the prompt to the next deployment seamlessly.

---

## Tuning Knobs in `config.yaml`

- `routing_strategy: simple-shuffle`: Respects the `order: 1`, `order: 2` fallback priority and balances requests across active deployments. Switch to `latency-based-routing` or `least-busy` if desired.
- `cooldown_time: 60`: Number of seconds a rate-limited model is benched before retry.
- `allowed_fails: 1` and `allowed_fails_policy.*AllowedFails: 1`: Bench a model after the first rate-limit, server, or timeout failure rather than repeatedly using a struggling backend.
- `num_retries` and `retry_policy`: Control how many retries LiteLLM makes for rate limits, server errors, and timeouts.
- `request_timeout: 45`: Fail over from a hung or lagging model before the client times out.

## Author

https://alexolinux.com
