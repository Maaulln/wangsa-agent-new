"""Safe BYOK provider catalog for the isolated mobile runtime.

The catalog follows Wangsa's built-in provider profiles but exposes supported
providers with fixed public HTTPS endpoints. User-supplied endpoint URLs are
deliberately not accepted, so a tenant cannot turn the worker into an SSRF proxy.
"""

from __future__ import annotations

from urllib.parse import urlsplit


def mobile_providers() -> dict[str, tuple[str, str, str]]:
    """Return provider id -> (display name, fixed base URL, API mode)."""
    from providers import list_providers
    from wangsa_cli.models import CANONICAL_PROVIDERS
    from wangsa_cli.provider_catalog import provider_catalog_by_slug

    labels = {entry.slug: entry.label for entry in CANONICAL_PROVIDERS}
    descriptors = provider_catalog_by_slug()
    result: dict[str, tuple[str, str, str]] = {}
    for profile in list_providers():
        endpoint = (profile.base_url or "").strip()
        parsed = urlsplit(endpoint)
        descriptor = descriptors.get(profile.name)
        if (
            descriptor is None
            or descriptor.tab != "keys"
            or profile.auth_type != "api_key"
            or profile.api_mode not in {"chat_completions", "anthropic_messages"}
            or parsed.scheme != "https"
            or not parsed.hostname
            or parsed.username
            or parsed.password
            or parsed.port not in (None, 443)
            or parsed.hostname in {"localhost", "127.0.0.1", "::1"}
        ):
            continue
        result[profile.name] = (
            profile.display_name or labels.get(profile.name) or profile.name,
            endpoint.rstrip("/"),
            profile.api_mode,
        )

    # OpenAI's profile is represented by the core's `openai-api` entry on
    # setup surfaces, while old mobile accounts used the short `openai` id.
    result.setdefault(
        "openai", ("OpenAI", "https://api.openai.com/v1", "codex_responses")
    )
    result.setdefault(
        "openai-api", ("OpenAI API", "https://api.openai.com/v1", "chat_completions")
    )
    return result


def keyless_providers() -> frozenset[str]:
    """Provider ids that intentionally run without a user credential."""
    from wangsa_cli.provider_catalog import provider_catalog_by_slug

    descriptors = provider_catalog_by_slug()
    return frozenset(
        provider
        for provider in mobile_providers()
        if (descriptor := descriptors.get(provider)) is not None and descriptor.keyless
    )


def discover_provider_models(provider: str, api_key: str = "") -> dict[str, object]:
    """Return curated models and, when credentials permit, live model IDs.

    Requests use only the fixed endpoint for a registered provider. The API
    credential is transient and never written by this function.
    """
    from providers import get_provider_profile
    from wangsa_cli.models import _PROVIDER_MODELS, fetch_api_models

    configured = mobile_providers().get(provider)
    if configured is None:
        raise ValueError("Unsupported provider")
    _label, base_url, api_mode = configured
    curated = list(_PROVIDER_MODELS.get(provider, ()))
    profile = get_provider_profile(provider)
    if profile and profile.fallback_models:
        curated = list(dict.fromkeys([*curated, *profile.fallback_models]))

    live: list[str] | None = None
    source = "curated"
    if provider == "opencode-free":
        try:
            from wangsa_cli.opencode_free_catalog import opencode_free_model_ids

            discovered = opencode_free_model_ids(refresh=True)
            if discovered:
                live = discovered
                source = "live"
        except Exception:
            # Preserve a bundled fallback for temporary offline setup. When the
            # live catalog responds, it always replaces potentially stale IDs.
            live = None
    elif api_key:
        if provider == "gemini":
            # Google AI Studio uses x-goog-api-key rather than Bearer auth.
            import json
            import urllib.request

            from wangsa_cli.urllib_security import open_credentialed_url

            request = urllib.request.Request(base_url.rstrip("/") + "/models")
            request.add_header("x-goog-api-key", api_key)
            request.add_header("Accept", "application/json")
            request.add_header("User-Agent", "WangsaMobile/1.0")
            try:
                with open_credentialed_url(request, timeout=8) as response:
                    payload = json.loads(response.read().decode("utf-8"))
                live = [
                    item["name"].removeprefix("models/")
                    for item in payload.get("models", [])
                    if isinstance(item, dict)
                    and isinstance(item.get("name"), str)
                    and "generateContent" in item.get("supportedGenerationMethods", [])
                ]
            except Exception:
                live = None
        elif profile is not None:
            live = profile.fetch_models(api_key=api_key or None, base_url=base_url)
        else:
            live = fetch_api_models(api_key, base_url, timeout=8, api_mode=api_mode)
        if live:
            source = "live"

    selected = live if live else curated
    models: list[str] = []
    seen: set[str] = set()
    for value in selected:
        if (
            isinstance(value, str)
            and value.strip()
            and len(value) <= 200
            and value not in seen
        ):
            models.append(value)
            seen.add(value)
        if len(models) >= 500:
            break
    return {"models": models, "source": source}
