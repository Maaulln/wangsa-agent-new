"""Live model catalog for OpenCode's anonymous free tier."""

from __future__ import annotations

import json
import time
import urllib.request

_MODELS_URL = "https://opencode.ai/zen/v1/models"
_CACHE_TTL_SECONDS = 15 * 60
_UNUSABLE_FREE_MODELS = frozenset(
    {
        # These IDs have appeared in the public catalog while the anonymous
        # relay rejects Wangsa's honest client identity (401/429 respectively).
        "deepseek-v4-flash-free",
        "mimo-v2.5-free",
    }
)
_SAFE_FALLBACK_MODELS = (
    "mimo-v2.6-flash-free",
    "space-bunny-free",
    "ling-3.0-flash-fin-free",
    "nemotron-3-ultra-free",
    "nemotron-3.5-lightning-free",
)

_cached_models: tuple[str, ...] = ()
_cached_until = 0.0


def opencode_free_model_ids(*, refresh: bool = False) -> list[str]:
    """Return currently advertised, Wangsa-compatible free model IDs.

    OpenCode's anonymous catalog changes independently of Wangsa releases.
    Refresh it periodically so a retired model cannot remain selectable after
    its relay route starts returning 401. If the catalog is temporarily
    unreachable, use a conservative current fallback rather than resurrecting
    the old, larger static list.
    """
    global _cached_models, _cached_until

    now = time.monotonic()
    if not refresh and _cached_models and now < _cached_until:
        return list(_cached_models)

    discovered: list[str] = []
    try:
        from wangsa_cli.model_data_policy_guard import data_training_warning
        from wangsa_cli.urllib_security import open_credentialed_url

        request = urllib.request.Request(
            _MODELS_URL,
            headers={
                "Accept": "application/json",
                "User-Agent": "Wangsa/1.0",
            },
        )
        with open_credentialed_url(request, timeout=8) as response:
            payload = json.loads(response.read().decode("utf-8"))
        entries = payload.get("data", []) if isinstance(payload, dict) else []
        if isinstance(entries, list):
            for item in entries:
                if not isinstance(item, dict):
                    continue
                model_id = item.get("id")
                if not isinstance(model_id, str):
                    continue
                model_id = model_id.strip()
                lowered = model_id.lower()
                if (
                    not model_id.endswith("-free")
                    or lowered.startswith("jev-")
                    or lowered in _UNUSABLE_FREE_MODELS
                    or data_training_warning(model_id, provider="opencode-free")
                    is not None
                    or model_id in discovered
                ):
                    continue
                discovered.append(model_id)
    except Exception:
        discovered = []

    if discovered:
        _cached_models = tuple(discovered)
        _cached_until = now + _CACHE_TTL_SECONDS
        return list(_cached_models)

    if _cached_models and now < _cached_until:
        return list(_cached_models)
    return list(_SAFE_FALLBACK_MODELS)

