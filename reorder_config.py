#!/usr/bin/env python3
"""
Helper script to reorder models in config.yaml based on test-models.sh benchmark results.

Reordering logic:
  - OK (100% stable, 2/2 tool probes): Included as active entries, ordered by latency.
  - HTTP_429 (rate-limited at test time): Preserved as active entries at the end of the pool.
    Rate limits are transient — the model may be fully functional when the proxy starts.
  - UNSTABLE (flaky, 1/2 tool probes): Commented out with an explanatory note.
  - NO_TOOL (0/2 tool probes): Commented out with an incompatibility note.
  - CURL_FAIL / other failures: Commented out with a connectivity note.
"""

import sys
import os
import json
import shutil
import argparse
import yaml
from datetime import datetime


def load_config(config_path: str) -> dict:
    with open(config_path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f)


def load_results(results_path: str) -> list:
    with open(results_path, "r", encoding="utf-8") as f:
        return json.load(f)


def reorder_models(config: dict, results: list) -> tuple[dict, list, list, list]:
    """
    Reorders model_list in config based on benchmark results.
    Returns: (updated_config, approved_models, preserved_models, excluded_models)
    """
    ok_models = [r for r in results if r.get("status") == "OK"]
    ok_models.sort(key=lambda x: float(x.get("latency", 999.0)))

    # Rate-limited models: transient 429s — keep them active but at the end
    rate_limited = [r for r in results if r.get("status") == "HTTP_429"]

    # Genuinely excluded: UNSTABLE (flaky tools), NO_TOOL, CURL_FAIL, or unknown errors
    excluded = [r for r in results if r.get("status") not in ("OK", "HTTP_429")]

    # Map existing config entries by normalized model name
    existing_entries = {}
    for entry in config.get("model_list", []):
        raw_model = entry.get("litellm_params", {}).get("model", "")
        clean_model = raw_model.replace("openai/", "").strip()
        existing_entries[clean_model] = entry

    new_model_list = []
    order_idx = 1
    approved = []

    # 1. Add verified stable models ordered by latency
    for r in ok_models:
        model_name = r["model"]
        entry = existing_entries.get(model_name)
        if entry:
            entry["litellm_params"]["order"] = order_idx
            new_model_list.append(entry)
        else:
            new_model_list.append({
                "model_name": "opencode-main",
                "litellm_params": {
                    "model": f"openai/{model_name}",
                    "api_base": "https://integrate.api.nvidia.com/v1",
                    "api_key": "os.environ/NVIDIA_API_KEY",
                    "order": order_idx
                }
            })
        approved.append({"model": model_name, "order": order_idx, "latency": r["latency"], "status": r["status"]})
        order_idx += 1

    # 2. Append rate-limited models at the end of the active pool (transient status)
    preserved = []
    for r in rate_limited:
        model_name = r["model"]
        entry = existing_entries.get(model_name)
        if entry:
            entry["litellm_params"]["order"] = order_idx
            new_model_list.append(entry)
        else:
            new_model_list.append({
                "model_name": "opencode-main",
                "litellm_params": {
                    "model": f"openai/{model_name}",
                    "api_base": "https://integrate.api.nvidia.com/v1",
                    "api_key": "os.environ/NVIDIA_API_KEY",
                    "order": order_idx
                }
            })
        preserved.append({"model": model_name, "order": order_idx, "status": r["status"], "note": r.get("note", "")})
        order_idx += 1

    config["model_list"] = new_model_list
    return config, approved, preserved, excluded


def format_commented_block(entry: dict, status: str, note: str) -> str:
    """Renders a model entry as a YAML comment block with a diagnostic note."""
    params = entry.get("litellm_params", {})
    lines = [
        f"  # [EXCLUDED: {status}] {note}",
        f"  # - model_name: {entry.get('model_name', 'opencode-main')}",
        f"  #   litellm_params:",
        f"  #     model: {params.get('model', '')}",
        f"  #     api_base: {params.get('api_base', 'https://integrate.api.nvidia.com/v1')}",
        f"  #     api_key: {params.get('api_key', 'os.environ/NVIDIA_API_KEY')}",
    ]
    return "\n".join(lines)


def generate_clean_yaml(config: dict, excluded: list, existing_entries: dict) -> str:
    """Generates formatted YAML with active entries and excluded models as annotated comments."""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M")
    header = f"""# litellm proxy config — pools NVIDIA Build free-tier models behind one
# OpenAI-compatible endpoint, with automatic failover on 429 / 503 / timeout.
#
# All entries share model_name: "opencode-main" — that's what makes them
# a fallback *group*. `order` sets priority. On a 429/503, litellm cools down
# that deployment and retries the next ordered model inside the SAME request —
# opencode never sees the failure.
#
# Auto-reordered by test-models.sh on {timestamp}
# Reorder / trim this list based on what you observe in test-models.sh.

model_list:
"""

    body_models = []
    for entry in config.get("model_list", []):
        params = entry.get("litellm_params", {})
        body_models.append(
            f"  - model_name: {entry.get('model_name', 'opencode-main')}\n"
            f"    litellm_params:\n"
            f"      model: {params.get('model', '')}\n"
            f"      api_base: {params.get('api_base', 'https://integrate.api.nvidia.com/v1')}\n"
            f"      api_key: {params.get('api_key', 'os.environ/NVIDIA_API_KEY')}\n"
            f"      order: {params.get('order', 1)}"
        )

    models_block = "\n\n".join(body_models)

    # Append excluded models as commented-out blocks
    excluded_block = ""
    if excluded:
        excluded_comments = []
        for r in excluded:
            model_name = r["model"]
            status = r.get("status", "EXCLUDED")
            note = r.get("note", "")
            entry = existing_entries.get(model_name, {
                "model_name": "opencode-main",
                "litellm_params": {
                    "model": f"openai/{model_name}",
                    "api_base": "https://integrate.api.nvidia.com/v1",
                    "api_key": "os.environ/NVIDIA_API_KEY",
                }
            })
            excluded_comments.append(format_commented_block(entry, status, note))

        excluded_block = "\n\n  # --- Excluded by test-models.sh (uncomment to re-add to pool) ---\n\n"
        excluded_block += "\n\n".join(excluded_comments)

    router_settings = yaml.dump(
        {"router_settings": config.get("router_settings", {})},
        sort_keys=False, default_flow_style=False
    )
    litellm_settings = yaml.dump(
        {"litellm_settings": config.get("litellm_settings", {})},
        sort_keys=False, default_flow_style=False
    )
    general_settings = yaml.dump(
        {"general_settings": config.get("general_settings", {})},
        sort_keys=False, default_flow_style=False
    )

    return (
        f"{header}\n{models_block}"
        f"{excluded_block}\n\n"
        f"{router_settings}\n{litellm_settings}\n{general_settings}"
    )


def main():
    parser = argparse.ArgumentParser(
        description="Reorder models in config.yaml based on benchmark results from test-models.sh."
    )
    parser.add_argument("--config", default="config.yaml", help="Path to config.yaml")
    parser.add_argument("--results", required=True, help="Path to results JSON file from test-models.sh")
    parser.add_argument("--apply", action="store_true", help="Apply changes directly to config.yaml (with .bak backup)")
    parser.add_argument("--dry-run", action="store_true", help="Display the updated YAML without saving")

    args = parser.parse_args()

    if not os.path.exists(args.config):
        print(f"Error: config file '{args.config}' not found.", file=sys.stderr)
        sys.exit(1)

    if not os.path.exists(args.results):
        print(f"Error: results file '{args.results}' not found.", file=sys.stderr)
        sys.exit(1)

    config = load_config(args.config)
    results = load_results(args.results)

    # Build lookup before reorder mutates config
    existing_entries = {}
    for entry in config.get("model_list", []):
        raw = entry.get("litellm_params", {}).get("model", "")
        existing_entries[raw.replace("openai/", "").strip()] = entry

    updated_config, approved, preserved, excluded = reorder_models(config, results)
    new_yaml = generate_clean_yaml(updated_config, excluded, existing_entries)

    if args.dry_run or (not args.apply):
        print("=== PROPOSED config.yaml ===")
        print(new_yaml)
        print("============================")
        if excluded:
            print(f"\n[INFO] {len(excluded)} model(s) commented out (UNSTABLE / NO_TOOL / CURL_FAIL):")
            for r in excluded:
                print(f"  - {r['model']}: {r.get('status')} — {r.get('note', '')}")
        if preserved:
            print(f"\n[INFO] {len(preserved)} model(s) preserved as active despite 429 (transient rate-limit):")
            for r in preserved:
                print(f"  - {r['model']}: order {r['order']}")

    if args.apply:
        backup_path = f"{args.config}.bak"
        shutil.copyfile(args.config, backup_path)
        with open(args.config, "w", encoding="utf-8") as f:
            f.write(new_yaml)
        print(f"\n[SUCCESS] Backup saved to {backup_path}")
        print(f"[SUCCESS] {args.config} updated:")
        print(f"  - {len(approved)} model(s) active and ordered by verified latency")
        if preserved:
            print(f"  - {len(preserved)} model(s) preserved active (were rate-limited during test)")
        if excluded:
            print(f"  - {len(excluded)} model(s) commented out with diagnostic notes:")
            for r in excluded:
                print(f"      {r['model']} [{r.get('status')}]: {r.get('note', '')}")


if __name__ == "__main__":
    main()
