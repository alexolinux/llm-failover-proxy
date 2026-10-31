"""Canonical provider endpoints used by config generation and model probes."""

from urllib.parse import urlsplit


PROVIDERS = {
    "nvidia": {
        "label": "NVIDIA",
        "api_base": "https://integrate.api.nvidia.com/v1",
        "api_key_env": "NVIDIA_API_KEY",
    },
    "openrouter": {
        "label": "OPENROUTER",
        "api_base": "https://openrouter.ai/api/v1",
        "api_key_env": "OPENROUTER_API_KEY",
    },
}


def provider_from_api_base(api_base: str) -> str | None:
    """Return the supported provider key for an endpoint host."""
    parsed = urlsplit(str(api_base).strip())
    hostname = (parsed.hostname or "").lower()

    if hostname == "integrate.api.nvidia.com":
        return "nvidia"
    if hostname == "openrouter.ai" or hostname.endswith(".openrouter.ai"):
        return "openrouter"
    return None


def normalize_api_base(api_base: str) -> str:
    """Normalize known provider URLs to their OpenAI-compatible API roots."""
    provider = provider_from_api_base(api_base)
    if provider is None:
        raise ValueError(f"Unsupported provider API base: {api_base!r}")
    return PROVIDERS[provider]["api_base"]