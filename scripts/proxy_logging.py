"""Minimal LiteLLM callback for provider/model and failure visibility."""

import logging

from litellm.integrations.custom_logger import CustomLogger


logger = logging.getLogger("llm-failover-proxy")


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
    provider = standard.get("api_provider") or "unknown"
    api_base = standard.get("api_base") or params.get("api_base") or "unknown"
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
        logger.info(
            "LLM_UPSTREAM_SUCCESS provider=%s model=%s api_base=%s deployment_id=%s",
            provider,
            model,
            api_base,
            deployment_id,
        )

    async def async_log_failure_event(
        self, kwargs, response_obj, start_time, end_time
    ):
        model, provider, api_base, deployment_id = event_details(kwargs)
        status, category = failure_details(kwargs)
        logger.warning(
            "LLM_UPSTREAM_FAILURE provider=%s model=%s api_base=%s "
            "deployment_id=%s status=%s category=%s",
            provider,
            model,
            api_base,
            deployment_id,
            status or "unknown",
            category,
        )


proxy_logger = ProxyEventLogger()