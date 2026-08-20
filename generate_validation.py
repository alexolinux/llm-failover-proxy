#!/usr/bin/env python3
"""
Generates validation rules dynamically from config.yaml
Single source of truth: if it's in config.yaml, it's valid
"""

import yaml
import json
import sys
import os
from collections import defaultdict

def generate_validation_rules(config_path):
    """Extracts unique providers from config.yaml and generates validation rules"""
    
    with open(config_path, 'r', encoding='utf-8') as f:
        config = yaml.safe_load(f)
    
    # Groups models by provider (based on api_base)
    providers = defaultdict(set)
    
    for entry in config.get('model_list', []):
        params = entry.get('litellm_params', {})
        model_name = params.get('model', '').replace('openai/', '').strip()
        api_base = params.get('api_base', '')
        
        if not model_name or not api_base:
            continue
            
        # Extracts the provider name from the model (first segment)
        provider_key = model_name.split('/')[0] if '/' in model_name else 'unknown'
        
        # Maps api_base to known provider
        if 'integrate.api.nvidia.com' in api_base:
            provider = 'nvidia'
        elif 'openrouter.ai' in api_base:
            provider = 'openrouter'
        else:
            provider = provider_key  # fallback to model name
        
        # Stores the pattern for this provider
        # Escapes special characters for regex safety
        safe_provider = provider.replace('.', r'\.').replace('-', r'\-')
        pattern = f'^{safe_provider}/[a-zA-Z0-9\\-_.]+(:free)?$'
        providers[provider].add(pattern)
    
    # Builds the validation section
    validation_rules = {
        "allow": [],
        "disallow": [
            {"pattern": "^openai/.*$", "reason": "OpenAI direct not supported in free tier"}
        ],
        "provider_map": {
            "nvidia": {"api_base": "https://integrate.api.nvidia.com/v1", "api_key_env": "NVIDIA_API_KEY"},
            "openrouter": {"api_base": "https://openrouter.ai/api/v1", "api_key_env": "OPENROUTER_API_KEY"}
        }
    }
    
    # Adds allow rules for each found provider
    priority = 1
    for provider, patterns in providers.items():
        # Priority: 1 for known providers (nvidia/openrouter), 2+ for others
        current_priority = 1 if provider in ['nvidia', 'openrouter'] else 2
        for pattern in sorted(patterns):  # sort for consistency
            validation_rules["allow"].append({
                "pattern": pattern,
                "provider": provider,
                "priority": current_priority
            })
    
    return validation_rules

def main():
    config_path = sys.argv[1] if len(sys.argv) > 1 else 'config.yaml'
    output_path = sys.argv[2] if len(sys.argv) > 2 else 'opencode.provider.jsonc'
    
    # Reads the current file to preserve the existing structure
    if os.path.exists(output_path):
        with open(output_path, 'r', encoding='utf-8') as f:
            current_content = f.read()
    else:
        # Base content if file does not exist
        current_content = '''{
  "$schema": "https://opencode.ai/config.json",
  "model": "llm-free-pool/opencode-main",
  "provider": {
    "llm-free-pool": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "LLM Free Pool (auto-failover)",
      "options": {
        "baseURL": "http://127.0.0.1:4000/v1",
        "apiKey": "sk-litellm-479cbb6d8cecdbf8efa132b68548fac2"
      },
      "models": {
        "opencode-main": {
          "name": "LLM free pool",
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
}'''
    
    # Parses the current content to insert the validation
    try:
        config_json = json.loads(current_content)
    except json.JSONDecodeError:
        # If not valid JSON, start from scratch
        config_json = {"model": "llm-free-pool/opencode-main", "provider": {}}
    
    # Generates the validation rules
    validation_rules = generate_validation_rules(config_path)
    
    # Inserts/updates the validation section
    config_json["validation"] = {"registry": {"rules": validation_rules}}
    
    # Writes back with readable formatting
    with open(output_path, 'w', encoding='utf-8') as f:
        json.dump(config_json, f, indent=2, ensure_ascii=False)
    
    print(f"[OK] Validacao gerada dinamicamente a partir de {config_path}")
    print(f"[OK] {len(validation_rules['allow'])} regras de provedor criadas")
    for rule in validation_rules['allow']:
        print(f"    - {rule['provider']}: {rule['pattern']} (priority {rule['priority']})")

if __name__ == "__main__":
    main()
