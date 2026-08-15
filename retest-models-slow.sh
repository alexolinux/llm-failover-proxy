#!/usr/bin/env bash
# Quick latency / responsiveness check for specified slow or large models.
#
# Usage:
#   NVIDIA_API_KEY=nvapi-xxx ./retest-models-slow.sh

set -euo pipefail
: "${NVIDIA_API_KEY:?Error: Set NVIDIA_API_KEY environment variable first (e.g. export NVIDIA_API_KEY=nvapi-...)}"

TMP_FILE="$(mktemp)"
trap 'rm -f "$TMP_FILE"' EXIT

MODELS=(
  "minimaxai/minimax-m3"
  "nvidia/llama-3.3-nemotron-super-49b-v1.5"
  "meta/llama-3.1-8b-instruct"
)

for m in "${MODELS[@]}"; do
  printf "Testing %-45s (up to 90s) ... " "$m"
  start=$(date +%s)
  set +e
  code=$(curl -sS -o "$TMP_FILE" -w "%{http_code}" \
    --connect-timeout 10 --max-time 90 \
    https://integrate.api.nvidia.com/v1/chat/completions \
    -H "Authorization: Bearer $NVIDIA_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$m\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":5}" 2>&1)
  set -e
  elapsed=$(( $(date +%s) - start ))
  echo "[HTTP $code] (${elapsed}s)"
done
