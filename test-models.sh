#!/usr/bin/env bash
# ==============================================================================
# llm-failover-proxy - Model Benchmark & Auto-Configuration Tool
# ==============================================================================
# Inspects models defined in config.yaml BEFORE starting LiteLLM proxy:
# 1) Deterministic Tool-Calling Verification (temperature=0.0, max_tokens=512)
#    to prevent reasoning token truncations and stochastic failures.
# 2) Multi-Probe Averaged Latency to smooth out shared GPU queue cold-starts.
# 3) Optional Rate-Limit Isolation Burst Test (--burst).
# 4) Consolidated Decision Dashboard & Clean Auto-Reordering (--apply / --dry-run).
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.yaml"
APPLY_CONFIG=false
DRY_RUN=false
RUN_BURST=false

if [ ! -x "$SCRIPT_DIR/.venv/bin/python" ]; then
  echo -e "\033[0;31m[ERROR] Project virtualenv not found: $SCRIPT_DIR/.venv\033[0m"
  echo "Create it with: python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt"
  exit 1
fi

PYTHON_BIN="$SCRIPT_DIR/.venv/bin/python"

resolve_api_base_for_model() {
  local model_name="$1"
  "$PYTHON_BIN" - "$CONFIG_FILE" "$model_name" <<'PY'
import os
import sys
import yaml

config_path = sys.argv[1]
model_name = sys.argv[2].replace("openai/", "").strip()

try:
    with open(config_path, "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f) or {}
except Exception:
    print("https://integrate.api.nvidia.com/v1")
    raise SystemExit

for entry in cfg.get("model_list", []):
    params = entry.get("litellm_params", {})
    candidate = str(params.get("model", "")).replace("openai/", "").strip()
    if candidate == model_name:
        print(str(params.get("api_base", "https://integrate.api.nvidia.com/v1")))
        raise SystemExit

print("https://integrate.api.nvidia.com/v1")
PY
}

show_help() {
  cat << 'EOF'
Usage:
  ./test-models.sh [OPTIONS]

Options:
  -c, --config <path>            Path to config.yaml (default: ./config.yaml)
  -a, --apply, --update-config   Automatically reorder config.yaml with verified models by speed
  -d, --dry-run                  Preview proposed config.yaml without modifying files
  -b, --burst                    Run the 10-request concurrency rate-limit isolation test
  -h, --help                     Show this help message

Description:
  Reads models directly from config.yaml (Single Source of Truth) and executes
  multi-sample deterministic probes to ensure 100% stable tool-calling support
  and accurate average latency before configuring the failover pool.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--config)
      CONFIG_FILE="$2"
      shift 2
      ;;
    -a|--apply|--update-config)
      APPLY_CONFIG=true
      shift
      ;;
    -d|--dry-run)
      DRY_RUN=true
      shift
      ;;
    -b|--burst)
      RUN_BURST=true
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      show_help
      exit 1
      ;;
  esac
done

# Load the project-managed environment file as the single source of truth.
if [ -f "$SCRIPT_DIR/llm-failover.env" ]; then
  set -a
  source "$SCRIPT_DIR/llm-failover.env" 2>/dev/null || true
  set +a
fi

if [ -z "${NVIDIA_API_KEY:-}" ]; then
  echo -e "\033[0;31m[ERROR] NVIDIA_API_KEY is not set in llm-failover.env.\033[0m"
  echo "Load your project environment file or export NVIDIA_API_KEY before running this script."
  exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
  echo -e "\033[0;31m[ERROR] Config file not found: $CONFIG_FILE\033[0m"
  exit 1
fi

# ── Pre-flight config.yaml structure validation ──────────────────────────────
# Providers frequently add/remove free models, so a broken entry (missing
# `openai/` prefix, wrong api_base, missing key) must be caught BEFORE the
# benchmark, otherwise LiteLLM will fail at runtime (e.g. "404 page not found").
BOLD="\033[1m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
CYAN="\033[0;36m"
BLUE="\033[0;34m"
DIM="\033[2m"
RESET="\033[0m"

echo -e "${BOLD}${BLUE}[Step 0/2] Validating $CONFIG_FILE structure...${RESET}"

"$PYTHON_BIN" - "$CONFIG_FILE" <<'PY'
import os
import sys
import yaml

config_path = sys.argv[1]
with open(config_path, "r", encoding="utf-8") as f:
    cfg = yaml.safe_load(f) or {}

entries = cfg.get("model_list", [])
issues = []
errors = 0

KNOWN_BASES = {
    "https://integrate.api.nvidia.com/v1": "NVIDIA Build",
    "https://openrouter.ai/api/v1": "OpenRouter",
}

for i, entry in enumerate(entries, 1):
    params = entry.get("litellm_params", {})
    model = str(params.get("model", "") or "")
    api_base = str(params.get("api_base", "") or "")
    api_key = str(params.get("api_key", "") or "")
    group = entry.get("model_name", "")

    if not model:
        errors += 1
        issues.append(f"[ERROR] model_list[{i}]: missing 'model'.")
        continue

    if not model.startswith("openai/"):
        errors += 1
        issues.append(
            f"[ERROR] model_list[{i}]: model '{model}' is missing the required "
            f"'openai/' prefix. Without it LiteLLM routes through the native provider "
            f"handler and IGNORES 'api_base' — breaking mixed NVIDIA+OpenRouter pools "
            f"(runtime symptom: '404 page not found'). Fix: '{model}'.replace -> "
            f"'openai/{model}'."
        )

    if api_base and api_base not in KNOWN_BASES:
        issues.append(
            f"[WARN] model_list[{i}]: api_base '{api_base}' is not a recognized "
            f"free-tier endpoint (known: {', '.join(KNOWN_BASES)})."
        )
    if not api_base:
        errors += 1
        issues.append(f"[ERROR] model_list[{i}]: missing 'api_base'.")

    if api_key.startswith("os.environ/"):
        env_name = api_key.split("/", 1)[1]
        if not os.environ.get(env_name):
            errors += 1
            issues.append(
                f"[ERROR] model_list[{i}]: 'api_key' references os.environ/{env_name} "
                f"which is NOT set. Add it to llm-failover.env."
            )
    elif not api_key:
        errors += 1
        issues.append(f"[ERROR] model_list[{i}]: missing 'api_key'.")

groups = {e.get("model_name", "") for e in entries if e.get("model_name")}
if len(groups) > 1:
    issues.append(
        f"[WARN] model_list mixes {len(groups)} model_name groups "
        f"({sorted(groups)}). Failover only happens between entries sharing the "
        f"SAME model_name."
    )

seen = {}
for e in entries:
    m = str(e.get("litellm_params", {}).get("model", "")).replace("openai/", "").strip()
    seen[m] = seen.get(m, 0) + 1
dups = [m for m, c in seen.items() if c > 1]
if dups:
    issues.append(f"[WARN] duplicate active models in the pool: {dups}")

if issues:
    print("\n  " + "─" * 60)
    for msg in issues:
        print(f"  {msg}")
    print("  " + "─" * 60 + "\n")

if errors:
    print(f"[VALIDATION FAILED] {errors} critical issue(s) in {config_path}. Fix them before benchmarking.", file=sys.stderr)
    sys.exit(1)
print("[OK] config.yaml structure validation passed.")
PY

# ─────────────────────────────────────────────────────────────────────────────

CONNECT_TIMEOUT=8
MAX_TIME=30
SLOW_THRESHOLD=10.0

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Extract active models dynamically from config.yaml as the Single Source of Truth
MODELS=()
while IFS= read -r model_name; do
  [ -n "$model_name" ] && MODELS+=("$model_name")
done < <(CONFIG_FILE="$CONFIG_FILE" "$PYTHON_BIN" - <<'PY'
import os
import sys
import yaml

try:
    with open(os.environ["CONFIG_FILE"], "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f) or {}
    for entry in cfg.get("model_list", []):
        model = entry.get("litellm_params", {}).get("model", "")
        clean_model = model.replace("openai/", "").strip()
        if clean_model:
            print(clean_model)
except Exception:
    sys.exit(1)
PY
)

if [ "${#MODELS[@]}" -eq 0 ]; then
  echo -e "${RED}[ERROR] No active models found in $CONFIG_FILE.${RESET}"
  exit 1
fi

echo -e "${BOLD}${BLUE}================================================================================${RESET}"
echo -e "${BOLD}            llm-failover-proxy - ROBUST MODEL BENCHMARK & AUTO-CONFIG                 ${RESET}"
echo -e "${BOLD}${BLUE}================================================================================${RESET}"
echo -e "Testing models defined in: ${BOLD}$CONFIG_FILE${RESET} (${#MODELS[@]} active candidates)"
echo -e "${DIM}Methodology: 2 deterministic probes (temp=0.0, max_tokens=512) to verify tool-calling & latency.${RESET}\n"

RESULTS_JSON="$TMP_DIR/results.json"
echo "[]" > "$RESULTS_JSON"

echo -e "${BOLD}[Step 1/2] Probing candidate models for stability & response speed...${RESET}\n"

for m in "${MODELS[@]}"; do
  safe_name=$(echo "$m" | tr '/' '_')
  printf "  %-44s " "$m"

  api_base_for_model=$(resolve_api_base_for_model "$m")
  if [[ "$api_base_for_model" == *"openrouter.ai"* ]] || [[ "$m" == openrouter/* ]]; then
    api_base="$api_base_for_model"
    if [ -z "${OPENROUTER_API_KEY:-}" ]; then
      echo -e "\033[0;31m[ERROR] OPENROUTER_API_KEY is not set in llm-failover.env for model: $m\033[0m"
      exit 1
    fi
    api_key="${OPENROUTER_API_KEY}"
  else
    api_base="https://integrate.api.nvidia.com/v1"
    api_key="${NVIDIA_API_KEY}"
  fi

  # Execute 2 deterministic probes with retry on transient 429 via Python helper
  probe_result=$(MODEL="$m" MAX_TIME="$MAX_TIME" API_BASE="$api_base" API_KEY="$api_key" "$PYTHON_BIN" - <<'PY'
import json
import os
import sys
import time

import requests

model = os.environ["MODEL"]
max_time = float(os.environ["MAX_TIME"])
api_base = os.environ["API_BASE"]
api_key = os.environ["API_KEY"]

url = f"{api_base}/chat/completions"
headers = {
    "Authorization": f"Bearer {api_key}",
    "Content-Type": "application/json",
}

payload = {
    "model": model,
    "messages": [{"role": "user", "content": "What is the weather in Porto? Call the get_weather function."}],
    "tools": [{
        "type": "function",
        "function": {
            "name": "get_weather",
            "description": "Get current weather for a city",
            "parameters": {
                "type": "object",
                "properties": {"city": {"type": "string"}},
                "required": ["city"],
            },
        },
    }],
    "temperature": 0.0,
    "max_tokens": 512,
}

latencies = []
statuses = []
tool_successes = 0

for probe in range(2):
    t0 = time.time()
    try:
        r = requests.post(url, headers=headers, json=payload, timeout=max_time)
        elapsed = time.time() - t0
        latencies.append(elapsed)
        statuses.append(r.status_code)
        if r.status_code == 200:
            data = r.json()
            msg = data.get("choices", [{}])[0].get("message", {})
            if msg.get("tool_calls"):
                tool_successes += 1
        elif r.status_code == 429 and probe == 0:
            time.sleep(1.5)
    except Exception:
        latencies.append(99.0)
        statuses.append(0)
    time.sleep(0.3)

avg_latency = sum(latencies) / len(latencies) if latencies else 99.0

if tool_successes == 2:
    status = "OK"
    tool_support = "YES"
    note = "100% stable tool calling"
elif tool_successes == 1:
    status = "UNSTABLE"
    tool_support = "PARTIAL"
    note = "Intermittent tool-calling (50% failure rate)"
elif any(s == 200 for s in statuses):
    status = "NO_TOOL"
    tool_support = "NO"
    note = "Ignored tool calls (pure text response)"
elif all(s == 429 for s in statuses):
    status = "HTTP_429"
    tool_support = "N/A"
    note = "Rate limit reached (429)"
elif any(s in (401, 403) for s in statuses):
    status = f"HTTP_{statuses[0]}"
    tool_support = "N/A"
    note = f"HTTP status {statuses} — API key rejected or model is not in this provider's free tier"
elif statuses[0] == 404:
    status = "HTTP_404"
    tool_support = "N/A"
    note = f"HTTP status {statuses} — model no longer available: removed or renamed by the provider"
else:
    status = f"HTTP_{statuses[0]}"
    tool_support = "N/A"
    note = f"HTTP status {statuses}"

result = {
    "model": model,
    "status": status,
    "tool_support": tool_support,
    "tool_successes": tool_successes,
    "latency": round(avg_latency, 2),
    "statuses": statuses,
    "note": note,
}
print(json.dumps(result))
PY
)

  # Parse result in bash for live status line
  status=$("$PYTHON_BIN" -c "import json, sys; d=json.loads(sys.argv[1]); print(d['status'])" "$probe_result")
  latency=$("$PYTHON_BIN" -c "import json, sys; d=json.loads(sys.argv[1]); print(d['latency'])" "$probe_result")
  tools=$("$PYTHON_BIN" -c "import json, sys; d=json.loads(sys.argv[1]); print(d['tool_support'])" "$probe_result")

  if [ "$status" = "OK" ]; then
    is_slow=$(awk -v lat="$latency" -v slow="$SLOW_THRESHOLD" 'BEGIN {print (lat >= slow) ? "1" : "0"}')
    if [ "$is_slow" = "1" ]; then
      echo -e "${YELLOW}✔ READY [SLOW]${RESET}    ${DIM}(Tools: 2/2 | Avg Latency: ${latency}s)${RESET}"
    else
      echo -e "${GREEN}✔ READY [FAST]${RESET}    ${DIM}(Tools: 2/2 | Avg Latency: ${latency}s)${RESET}"
    fi
  elif [ "$status" = "UNSTABLE" ]; then
    echo -e "${YELLOW}⚠ UNSTABLE [50%]${RESET}  ${DIM}(Tools: 1/2 intermittent | Latency: ${latency}s)${RESET}"
  elif [ "$status" = "NO_TOOL" ]; then
    echo -e "${RED}✘ INCOMPATIBLE${RESET}    ${DIM}(Tools: 0/2 | Ignored function call)${RESET}"
  elif [ "$status" = "HTTP_429" ]; then
    echo -e "${YELLOW}⏳ RATE-LIMITED${RESET}   ${DIM}(HTTP 429 - In cooldown)${RESET}"
  else
    echo -e "${RED}✖ FAILED (${status})${RESET} ${DIM}(Latency: ${latency}s)${RESET}"
  fi

  # Append to results JSON
  "$PYTHON_BIN" - << EOF
import json
with open('$RESULTS_JSON', 'r', encoding='utf-8') as f:
    data = json.load(f)
data.append($probe_result)
with open('$RESULTS_JSON', 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2)
EOF

done

if [ "$RUN_BURST" = true ] && [ "${#MODELS[@]}" -ge 2 ]; then
  echo
  burst_model="${MODELS[0]}"
  probe_model="${MODELS[1]}"
  
  echo -e "${BOLD}[Burst Rate-Limit Test (--burst enabled)]${RESET}"
  printf "  1. Sending 10 concurrent requests to '%s' ... " "$burst_model"
  pids=()
  results_burst="$TMP_DIR/burst.txt"
  > "$results_burst"

  for i in $(seq 1 10); do
    (
      code=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
        https://integrate.api.nvidia.com/v1/chat/completions \
        -H "Authorization: Bearer $NVIDIA_API_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"$burst_model\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":5}" \
        || echo "FAIL")
      echo "$code" >> "$results_burst"
    ) &
    pids+=($!)
  done

  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  count_200=$(grep -c "200" "$results_burst" 2>/dev/null || true)
  count_200="${count_200:-0}"
  count_429=$(grep -c "429" "$results_burst" 2>/dev/null || true)
  count_429="${count_429:-0}"
  echo -e "Done (${GREEN}${count_200}x 200${RESET}, ${YELLOW}${count_429}x 429${RESET})"

  printf "  2. Probing fallback candidate ('%s') immediately after burst ... " "$probe_model"
  alt_code=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
    https://integrate.api.nvidia.com/v1/chat/completions \
    -H "Authorization: Bearer $NVIDIA_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$probe_model\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":5}" \
    || echo "FAIL")

  if [ "$alt_code" = "200" ]; then
    echo -e "${GREEN}HTTP 200 (Responsive)${RESET}"
    echo -e "\n  ${BOLD}${GREEN}✔ Rate-Limit Isolation:${RESET} NVIDIA limits are ${BOLD}PER-MODEL${RESET}."
  else
    echo -e "${YELLOW}HTTP $alt_code (Account Limit or shared cooldown)${RESET}"
  fi
fi

echo
echo -e "${BOLD}[Step 2/2] Consolidated Model Decision Dashboard${RESET}"

# Render formatted table via Python
"$PYTHON_BIN" - << EOF
import json

with open('$RESULTS_JSON', 'r', encoding='utf-8') as f:
    results = json.load(f)

ok_models = [r for r in results if r['status'] == 'OK']
ok_models.sort(key=lambda x: x['latency'])

unstable_models = [r for r in results if r['status'] == 'UNSTABLE']
no_tool_models = [r for r in results if r['status'] == 'NO_TOOL']
rate_limited_models = [r for r in results if r['status'] == 'HTTP_429']
failed_models = [r for r in results if r['status'] not in ['OK', 'UNSTABLE', 'NO_TOOL', 'HTTP_429']]
slow_models = [r for r in ok_models if r['latency'] >= $SLOW_THRESHOLD]

BOLD = "\033[1m"
GREEN = "\033[0;32m"
YELLOW = "\033[0;33m"
RED = "\033[0;31m"
CYAN = "\033[0;36m"
DIM = "\033[2m"
RESET = "\033[0m"

print(f"{BOLD}{'='*88}{RESET}")
print(f"{BOLD}{'ROUTER CANDIDATE MODELS & STATUS SUMMARY':^88}{RESET}")
print(f"{BOLD}{'='*88}{RESET}")
print(f"{BOLD}{'Order':<12} {'Model':<44} {'Tool Calling':<14} {'Avg Latency':<14} {'Verdict'}{RESET}")
print(f"{'-'*88}")

rank = 1
for m in ok_models:
    lat_str = f"{m['latency']:.2f}s"
    if m['latency'] < 3.0:
        verdict = f"{GREEN}TIER 1 (Fast & Stable){RESET}"
        p_badge = f"{GREEN}#{rank:<2} [Active]{RESET}"
    elif m['latency'] < $SLOW_THRESHOLD:
        verdict = f"{CYAN}TIER 2 (Good & Stable){RESET}"
        p_badge = f"{CYAN}#{rank:<2} [Active]{RESET}"
    else:
        verdict = f"{YELLOW}TIER 3 (High Latency){RESET}"
        p_badge = f"{YELLOW}#{rank:<2} [Backup]{RESET}"
    tools_badge = f"{GREEN}100% (2/2){RESET}"
    print(f"{p_badge:<21} {m['model']:<44} {tools_badge:<23} {lat_str:<14} {verdict}")
    rank += 1

for m in unstable_models:
    lat_str = f"{m['latency']:.2f}s"
    print(f"{YELLOW}{'--  [Exclude]':<12}{RESET} {m['model']:<44} {YELLOW}{'50% (1/2)':<14}{RESET} {lat_str:<14} {YELLOW}UNSTABLE (Flaky Tools){RESET}")

for m in no_tool_models:
    lat_str = f"{m['latency']:.2f}s"
    print(f"{RED}{'--  [Exclude]':<12}{RESET} {m['model']:<44} {RED}{'0%  (0/2)':<14}{RESET} {lat_str:<14} {RED}INCOMPATIBLE (No Tools){RESET}")

for m in rate_limited_models:
    print(f"{YELLOW}{'--  [Cooldown]':<12}{RESET} {m['model']:<44} {DIM}{'N/A':<14}{RESET} {'--':<14} {YELLOW}RATE-LIMITED (429){RESET}")

for m in failed_models:
    print(f"{RED}{'--  [Exclude]':<12}{RESET} {m['model']:<44} {DIM}{'N/A':<14}{RESET} {'--':<14} {RED}FAILED ({m['status']}){RESET}")

print(f"{'='*88}\n")

# Recommendations
print(f"{BOLD}AUTOMATED DECISION ANALYSIS:{RESET}")

if ok_models:
    print(f"\n{GREEN}✔ {len(ok_models)} Verified Stable Model(s) Ready for config.yaml Pool:{RESET}")
    for i, m in enumerate(ok_models, 1):
        tier = "Ultra-Fast" if m['latency'] < 2.0 else ("Fast" if m['latency'] < 5.0 else "Queue-Delayed")
        print(f"   {BOLD}{i}. {m['model']}{RESET} — {m['latency']:.2f}s ({tier})")

if unstable_models:
    print(f"\n{YELLOW}⚠ {len(unstable_models)} Flaky Model(s) (Excluded to prevent broken OpenCode sessions):{RESET}")
    for m in unstable_models:
        print(f"   - {BOLD}{m['model']}{RESET}: inconsistent function calling (succeeded only 1 of 2 probes).")

if no_tool_models:
    print(f"\n{RED}✖ {len(no_tool_models)} Incompatible Model(s) (No tool-calling support):{RESET}")
    for m in no_tool_models:
        print(f"   - {BOLD}{m['model']}{RESET}: answered plain text and ignored function-calling parameters.")

if slow_models:
    print(f"\n{YELLOW}⚠ {len(slow_models)} High-Latency Model(s) (> {$SLOW_THRESHOLD:.0f}s):{RESET}")
    for m in slow_models:
        print(f"   - {BOLD}{m['model']}{RESET}: {m['latency']:.2f}s average")
    print(f"   {DIM}Notice: Automatically placed at the bottom of the fallback queue.{RESET}")

if not ok_models:
    print(f"\n{RED}✖ No 100% viable models found in the pool right now.{RESET}")
EOF

echo
echo -e "${BOLD}${BLUE}================================================================================${RESET}"
echo -e "${BOLD}                                CONFIGURATION                                   ${RESET}"
echo -e "${BOLD}${BLUE}================================================================================${RESET}"

if [ "$APPLY_CONFIG" = true ]; then
  echo -e "${GREEN}Applying automated optimal ordering to $CONFIG_FILE...${RESET}"
  "$PYTHON_BIN" "$SCRIPT_DIR/reorder_config.py" --config "$CONFIG_FILE" --results "$RESULTS_JSON" --apply
  echo -e "\n${BOLD}Done! To start the llm-failover-proxy proxy, run:${RESET}"
  echo -e "  ${CYAN}./run.sh start${RESET}"
elif [ "$DRY_RUN" = true ]; then
  echo -e "${CYAN}Previewing proposed config.yaml update (--dry-run)...${RESET}"
  "$PYTHON_BIN" "$SCRIPT_DIR/reorder_config.py" --config "$CONFIG_FILE" --results "$RESULTS_JSON" --dry-run
else
  echo -e "To automatically reorder ${BOLD}$CONFIG_FILE${RESET} with verified models prioritized by speed:"
  echo -e "  ${CYAN}./test-models.sh --apply${RESET}\n"
  echo -e "To preview the proposed configuration without writing to disk:"
  echo -e "  ${CYAN}./test-models.sh --dry-run${RESET}\n"
  echo -e "To run with rate-limit burst test:"
  echo -e "  ${CYAN}./test-models.sh --burst${RESET}\n"
  echo -e "To start the proxy:"
  echo -e "  ${CYAN}./run.sh start${RESET}"
fi
echo
