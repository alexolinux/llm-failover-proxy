#!/usr/bin/env python3
"""
Gera regras de validação dinamicamente a partir do config.yaml
Single source of truth: se está no config.yaml, é válido
"""

import yaml
import json
import sys
import os
from collections import defaultdict

def generate_validation_rules(config_path):
    """Extrai provedores únicos do config.yaml e gera regras de validação"""
    
    with open(config_path, 'r', encoding='utf-8') as f:
        config = yaml.safe_load(f)
    
    # Agrupa modelos por provedor (baseado no api_base)
    providers = defaultdict(set)
    
    for entry in config.get('model_list', []):
        params = entry.get('litellm_params', {})
        model_name = params.get('model', '').replace('openai/', '').strip()
        api_base = params.get('api_base', '')
        
        if not model_name or not api_base:
            continue
            
        # Extrai o nome do provedor do modelo (primeiro segmento)
        provider_key = model_name.split('/')[0] if '/' in model_name else 'unknown'
        
        # Mapeia api_base para provedor conhecido
        if 'integrate.api.nvidia.com' in api_base:
            provider = 'nvidia'
        elif 'openrouter.ai' in api_base:
            provider = 'openrouter'
        else:
            provider = provider_key  # fallback para nome do modelo
        
        # Armazena o pattern para este provedor
        # Escapa caracteres especiais para regex safe
        safe_provider = provider.replace('.', r'\.').replace('-', r'\-')
        pattern = f'^{safe_provider}/[a-zA-Z0-9\\-_.]+(:free)?$'
        providers[provider].add(pattern)
    
    # Constrói a seção de validação
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
    
    # Adiciona regras allow para cada provedor encontrado
    priority = 1
    for provider, patterns in providers.items():
        # Prioridade: 1 para provedores conhecidos (nvidia/openrouter), 2+ para outros
        current_priority = 1 if provider in ['nvidia', 'openrouter'] else 2
        for pattern in sorted(patterns):  # ordena para consistência
            validation_rules["allow"].append({
                "pattern": pattern,
                "provider": provider,
                "priority": current_priority
            })
    
    return validation_rules

def main():
    config_path = sys.argv[1] if len(sys.argv) > 1 else 'config.yaml'
    output_path = sys.argv[2] if len(sys.argv) > 2 else 'opencode.provider.jsonc'
    
    # Lê o arquivo atual para preservar a estrutura existente
    if os.path.exists(output_path):
        with open(output_path, 'r', encoding='utf-8') as f:
            current_content = f.read()
    else:
        # Conteúdo base se arquivo não existir
        current_content = '''{
  "$schema": "https://opencode.ai/config.json",
  "model": "nvidia-pool/opencode-main",
  "provider": {
    "nvidia-pool": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "NVIDIA Build (auto-failover)",
      "options": {
        "baseURL": "http://127.0.0.1:4000/v1",
        "apiKey": "sk-litellm-479cbb6d8cecdbf8efa132b68548fac2"
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
        "apiKey": "sk-litellm-479cbb6d8cecdbf8efa132b68548fac2"
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
}'''
    
    # Faz parse do conteúdo atual para inserir a validation
    try:
        config_json = json.loads(current_content)
    except json.JSONDecodeError:
        # Se não for JSON válido, começa do zero
        config_json = {"model": "nvidia-pool/opencode-main", "provider": {}}
    
    # Gera as regras de validação
    validation_rules = generate_validation_rules(config_path)
    
    # Insere/atualiza a seção de validation
    config_json["validation"] = {"registry": {"rules": validation_rules}}
    
    # Escreve de volta com formatação legível
    with open(output_path, 'w', encoding='utf-8') as f:
        json.dump(config_json, f, indent=2, ensure_ascii=False)
    
    print(f"[OK] Validacao gerada dinamicamente a partir de {config_path}")
    print(f"[OK] {len(validation_rules['allow'])} regras de provedor criadas")
    for rule in validation_rules['allow']:
        print(f"    - {rule['provider']}: {rule['pattern']} (priority {rule['priority']})")

if __name__ == "__main__":
    main()
