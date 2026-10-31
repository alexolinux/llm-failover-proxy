"""Minimal LiteLLM callback for provider/model and failure visibility."""

from litellm.integrations.custom_logger import CustomLogger
from scripts.provider_config import provider_from_api_base


PROVIDER_LABELS = {
    "nvidia": "NVIDIA Build",
    "openrouter": "OpenRouter",
}


def event_details(kwargs: dict) -> tuple[str, str, str, str]:
    standard = kwargs.get("standard_logging_object") or {}
    params = kwargs.get("litellm_params") or {}
    model_info = params.get("model_info") or {}
    model = (
        standard.get("model")
        or params.get("model")
        or kwargs.get("model")
        or "unknown"
    )
    api_base = standard.get("api_base") or params.get("api_base") or "unknown"
    configured_provider = provider_from_api_base(str(api_base))
    provider = PROVIDER_LABELS.get(configured_provider) or standard.get("api_provider") or "unknown"
    deployment_id = standard.get("model_id") or model_info.get("id") or "unknown"
    return str(model), str(provider), str(api_base), str(deployment_id)


def failure_details(kwargs: dict) -> tuple[int | None, str]:
    exception = kwargs.get("exception") or kwargs.get("traceback_exception")
    response = getattr(exception, "response", None)
    status = (
        getattr(exception, "status_code", None)
        or getattr(response, "status_code", None)
    )
    message = str(exception or "").lower()

    if status in (401, 403):
        category = "API_KEY_OR_PERMISSION"
    elif status == 429 and any(
        marker in message for marker in ("quota", "credit", "billing", "insufficient")
    ):
        category = "QUOTA_OR_CREDITS_LIMIT"
    elif status == 429:
        category = "RATE_LIMIT"
    elif status and status >= 500:
        category = "PROVIDER_SERVER_ERROR"
    else:
        category = "PROVIDER_API_ERROR"
    return status, category


class ProxyEventLogger(CustomLogger):
    async def async_log_success_event(
        self, kwargs, response_obj, start_time, end_time
    ):
        model, provider, api_base, deployment_id = event_details(kwargs)
        print(
            f"LLM_UPSTREAM_SUCCESS provider={provider} model={model} "
            f"api_base={api_base} deployment_id={deployment_id}",
            flush=True,
        )

    async def async_log_failure_event(
        self, kwargs, response_obj, start_time, end_time
    ):
        model, provider, api_base, deployment_id = event_details(kwargs)
        status, category = failure_details(kwargs)
        print(
            f"LLM_UPSTREAM_FAILURE provider={provider} model={model} "
            f"api_base={api_base} deployment_id={deployment_id} "
            f"status={status or 'unknown'} category={category}",
            flush=True,
        )


proxy_logger = ProxyEventLogger()