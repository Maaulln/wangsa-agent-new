"""
Wangsa Mobile inbound platform adapter — exposes Wangsa to the Wangsa Flutter
mobile app over two simple REST routes (not JSON-RPC/SSE like a2a).

Design (mirrors plugins/platforms/a2a/adapter.py's simpler cousin):
  - Runs a stdlib http.server (ThreadingHTTPServer) in a daemon thread from
    connect(), stopped in disconnect(). Same shape as a2a's server/thread/
    watchdog pattern, minus JSON-RPC/SSE — just two REST routes.
  - GET  /api/v1/agents/{agentId}          -> static identity envelope.
  - POST /api/v1/agents/{agentId}/messages -> routes text into the agent's
    live gateway session via the normal MessageEvent path (same as every
    other inbound platform), blocks on a Future for the reply, and returns
    it synchronously to the mobile app.

  Correlation choice (see ``send()`` below): grepped gateway/platforms/base.py
  for every call site that invokes ``adapter.send(...)`` on a platform
  adapter (lines ~4336, 4355, 4477, 4577, 4721, 4755, 4782, 4822, 5551, 5585,
  5607, 5614, 6881). ``chat_id`` is passed at every call site; ``reply_to``/
  ``message_id`` threading is inconsistent (often None or a different id than
  what we sent in). So — exactly like a2a — we key pending futures by
  chat_id (our per-session Wangsa thread id), with a FIFO queue per chat_id
  to avoid cross-talk if two requests for the same sessionId race.

Outbound images/files/audio (agent -> mobile app): the normal turn
pipeline in gateway/platforms/base.py sends a turn's text and its
attachments as SEPARATE calls — text via ``send()`` first, then each
image via ``send_image_file()``/``send_image()``, each document via
``send_document()``, each voice/TTS clip via ``send_voice()`` — before
finally calling ``on_processing_complete()``. Because this adapter's
whole contract is one synchronous HTTP response per request, none of
those calls can resolve the pending Future on their own: resolving on
the first (text) call would hand the client its response before any
attachment has arrived, orphaning it. So every notify=True call here
BUFFERS into ``_pending_reply_text``/``_pending_reply_images``/
``_pending_reply_files`` instead of resolving, and
``on_processing_complete()`` is what actually flushes the buffer and
resolves the Future with everything the turn produced. Documents and
audio share one ``files`` wire array (distinguished by a ``kind`` field)
since both are "download/play this blob" rather than "preview this
image" — only images get their own array and inline thumbnail treatment.

The one path that does NOT reach ``on_processing_complete()`` is the
/stop, /new, /reset command-bypass in ``_dispatch_active_session_command``
(gateway/platforms/base.py) — it sends its confirmation text directly via
``send()`` and returns. ``_arm_fallback_resolve()`` is the safety net for
that: a short debounced timer that flushes whatever is buffered if nothing
else resolves the Future first. It never fires for a normal agent turn
(``on_processing_complete`` always beats it there); command replies (which
never carry attachments) are the only thing it actually resolves.

Bind safety: with no bearer token configured, the server binds 127.0.0.1 only.
"""

from __future__ import annotations

import asyncio
import inspect
import json
import logging
import os
import re
import threading
import time
import urllib.request
import uuid
from collections import deque
from concurrent.futures import Future
from concurrent.futures import TimeoutError as FuturesTimeout
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, Optional

from gateway.config import Platform
from gateway.platforms.base import (
    BasePlatformAdapter,
    MessageEvent,
    MessageType,
    ProcessingOutcome,
    SendResult,
)

logger = logging.getLogger(__name__)

_DEFAULT_PORT = 9901
_MAX_MESSAGE_LEN = 4000
_MAX_BODY = 1_048_576  # 1MB
_MOBILE_TOOLSETS = frozenset({"web", "vision"})
_OPENCODE_MODELS_URL = "https://opencode.ai/zen/v1/models"
_OPENCODE_FREE_MODELS_CACHE: tuple[str, ...] = ()
_OPENCODE_FREE_MODELS_CACHE_UNTIL = 0.0
_OPENCODE_FREE_MODELS_CACHE_LOCK = threading.Lock()
_OPENCODE_FREE_MODELS_FALLBACK = (
    "mimo-v2.6-flash-free",
    "space-bunny-free",
    "ling-3.0-flash-fin-free",
    "nemotron-3-ultra-free",
    "nemotron-3.5-lightning-free",
)
_OPENCODE_FREE_MODELS_UNUSABLE = frozenset(
    {"deepseek-v4-flash-free", "mimo-v2.5-free"}
)

_AGENT_ID_RE = re.compile(
    r"^/api/v1/agents/([^/]+)(/(messages(/stream)?|models|sessions(/[^/]+(/messages)?)?))?/?$"
)

_THINK_RE = re.compile(
    r"<(?:think|thinking|thought|reasoning|REASONING_SCRATCHPAD)>(.*?)</(?:think|thinking|thought|reasoning|REASONING_SCRATCHPAD)>",
    re.DOTALL | re.IGNORECASE,
)


def _extract_think_blocks(text: str) -> tuple[str, str]:
    """Extract <think>...</think> blocks from text. Returns (thought_text, clean_text)."""
    if not text:
        return "", ""
    thoughts = []
    for m in _THINK_RE.finditer(text):
        content = m.group(1).strip()
        if content:
            thoughts.append(content)
    clean = _THINK_RE.sub("", text).strip()
    return "\n\n".join(thoughts).strip(), clean


def _opencode_free_model_ids() -> list[str]:
    """Return current, Wangsa-compatible OpenCode free models.

    The provider retires anonymous model routes independently of Wangsa
    releases. Query its public catalog with a short cache so the mobile picker
    cannot keep offering retired IDs such as ``hy3-free``. A conservative
    fallback keeps the picker usable during a temporary catalog outage.
    """
    global _OPENCODE_FREE_MODELS_CACHE, _OPENCODE_FREE_MODELS_CACHE_UNTIL

    now = time.monotonic()
    with _OPENCODE_FREE_MODELS_CACHE_LOCK:
        if _OPENCODE_FREE_MODELS_CACHE and now < _OPENCODE_FREE_MODELS_CACHE_UNTIL:
            return list(_OPENCODE_FREE_MODELS_CACHE)

        try:
            try:
                from hermes_cli.model_data_policy_guard import data_training_warning
            except ImportError:
                from wangsa_cli.model_data_policy_guard import data_training_warning
            try:
                from hermes_cli.urllib_security import open_credentialed_url
            except ImportError:
                from wangsa_cli.urllib_security import open_credentialed_url

            request = urllib.request.Request(
                _OPENCODE_MODELS_URL,
                headers={"Accept": "application/json", "User-Agent": "Wangsa/1.0"},
            )
            with open_credentialed_url(request, timeout=8) as response:
                payload = json.loads(response.read().decode("utf-8"))

            discovered: list[str] = []
            entries = payload.get("data", []) if isinstance(payload, dict) else []
            for item in entries if isinstance(entries, list) else []:
                if not isinstance(item, dict) or not isinstance(item.get("id"), str):
                    continue
                model_id = item["id"].strip()
                lowered = model_id.lower()
                if (
                    not lowered.endswith("-free")
                    or lowered.startswith("jev-")
                    or lowered in _OPENCODE_FREE_MODELS_UNUSABLE
                    or data_training_warning(model_id, provider="opencode-free") is not None
                    or model_id in discovered
                ):
                    continue
                discovered.append(model_id)

            if discovered:
                _OPENCODE_FREE_MODELS_CACHE = tuple(discovered)
                _OPENCODE_FREE_MODELS_CACHE_UNTIL = now + 15 * 60
                return list(_OPENCODE_FREE_MODELS_CACHE)
        except Exception:
            logger.debug("wangsa_mobile: OpenCode free model refresh failed", exc_info=True)

        if _OPENCODE_FREE_MODELS_CACHE and now < _OPENCODE_FREE_MODELS_CACHE_UNTIL:
            return list(_OPENCODE_FREE_MODELS_CACHE)
        return list(_OPENCODE_FREE_MODELS_FALLBACK)


def _hermes_cli_module(name: str):
    """Import ``<name>`` from the ``hermes_cli`` package, falling back to
    this fork's ``wangsa_cli`` rename.

    Every provider-auth handler below needs this — without the fallback,
    a bare ``from hermes_cli.x import y`` raises ``ModuleNotFoundError`` on
    any checkout where the package was renamed (this repo included), and
    every one of those endpoints 500s.
    """
    import importlib

    try:
        return importlib.import_module(f"hermes_cli.{name}")
    except ImportError:
        return importlib.import_module(f"wangsa_cli.{name}")


# Providers surfaced to the mobile app's "Setup Provider & Login AI" screen.
# Each non-copilot/custom entry's ``env_var`` is the credential the save/
# delete handlers write/clear directly — this list, not
# ``hermes_cli.auth.PROVIDER_REGISTRY``, is the source of truth for what the
# mobile app can configure, since some providers here (e.g. openrouter) are
# only registered in the separate model-providers plugin catalog and are
# absent from PROVIDER_REGISTRY entirely.
def _get_all_providers_meta():
    try:
        models_mod = _hermes_cli_module("models")
        CANONICAL_PROVIDERS = getattr(models_mod, "CANONICAL_PROVIDERS", [])
    except Exception:
        CANONICAL_PROVIDERS = []
    try:
        auth_mod = _hermes_cli_module("auth")
        PROVIDER_REGISTRY = getattr(auth_mod, "PROVIDER_REGISTRY", {})
    except Exception:
        PROVIDER_REGISTRY = {}

    known_urls = {
        "opencode-free": "https://opencode.ai",
        "opencode-zen": "https://opencode.ai",
        "opencode-go": "https://opencode.ai",
        "copilot": "https://github.com/settings/tokens",
        "anthropic": "https://console.anthropic.com/settings/keys",
        "openai-api": "https://platform.openai.com/api-keys",
        "openai-codex": "https://chatgpt.com",
        "gemini": "https://aistudio.google.com/app/apikey",
        "deepseek": "https://platform.deepseek.com/api_keys",
        "openrouter": "https://openrouter.ai/keys",
        "groq": "https://console.groq.com/keys",
        "nous": "https://portal.nousresearch.com",
        "xai": "https://console.x.ai",
        "xai-oauth": "https://x.ai",
        "nvidia": "https://build.nvidia.com",
        "huggingface": "https://huggingface.co/settings/tokens",
        "fireworks": "https://fireworks.ai/api-keys",
        "novita": "https://novita.ai/settings/key-management",
        "lmstudio": "https://lmstudio.ai",
        "ollama-cloud": "https://ollama.com",
        "alibaba": "https://dashscope.console.aliyun.com",
        "alibaba-coding-plan": "https://dashscope.console.aliyun.com",
        "zai": "https://open.bigmodel.cn",
        "kimi-coding": "https://platform.moonshot.cn/console/api-keys",
        "minimax": "https://platform.minimaxi.com",
        "deepinfra": "https://deepinfra.com/dash/api_keys",
        "upstage": "https://console.upstage.ai/api-keys",
    }

    meta = []
    seen = set()

    for cp in CANONICAL_PROVIDERS:
        pid = cp.slug
        if pid in seen:
            continue
        seen.add(pid)

        label = cp.label
        desc = cp.tui_desc or label
        pconfig = PROVIDER_REGISTRY.get(pid)
        auth_type = "api_key"
        env_var = None

        if pid == "copilot":
            auth_type = "copilot"
            env_var = "COPILOT_GITHUB_TOKEN"
        elif pid == "nous":
            auth_type = "nous"
            env_var = "NOUS_API_KEY"
        elif pid == "custom":
            auth_type = "custom"
            env_var = None
        elif pid == "opencode-free":
            auth_type = "free"
            env_var = None
            desc = "OpenCode Free — model inferensi gratis keyless tanpa akun (hy3-free, laguna-s-2.1-free, dll.)."
        elif pid == "opencode-zen":
            auth_type = "api_key"
            env_var = "OPENCODE_ZEN_API_KEY"
            desc = "OpenCode Zen — inferensi model terkurasi pay-as-you-go."
        elif pid == "opencode-go":
            auth_type = "api_key"
            env_var = "OPENCODE_GO_API_KEY"
            desc = "OpenCode Go — langganan model open-source."
        elif pconfig:
            auth_type = getattr(pconfig, "auth_type", "api_key") or "api_key"
            if getattr(pconfig, "api_key_env_vars", None):
                env_var = pconfig.api_key_env_vars[0]
        elif pid == "openrouter":
            env_var = "OPENROUTER_API_KEY"
        elif pid == "groq":
            env_var = "GROQ_API_KEY"

        url = known_urls.get(pid, getattr(pconfig, "help_url", "") or "")

        meta.append({
            "id": pid,
            "name": label,
            "auth_type": auth_type,
            "env_var": env_var,
            "description": desc,
            "help_url": url,
        })

    # Pastikan custom provider terdaftar
    if "custom" not in seen:
        meta.append({
            "id": "custom",
            "name": "Custom (Ollama / Local / OpenAI)",
            "auth_type": "custom",
            "env_var": None,
            "description": "Hubungkan server lokal atau kustom (Ollama, LM Studio, vLLM).",
            "help_url": "",
        })

    return meta


def _reply_timeout() -> float:
    """Seconds to wait for the agent to answer a POST /messages request.

    120s was too short — a turn with several tool calls (delegation,
    screenshots, multi-step terminal work) routinely runs past it, and the
    mobile app's WangsaApiClient would report "Tidak bisa menghubungi API
    Wangsa" for a request the agent was still actively working on. Mirrors
    A2A_REPLY_TIMEOUT's default (plugins/platforms/a2a/adapter.py) — keep
    this in sync with WangsaApiClient.replyTimeout in the Flutter client.
    """
    try:
        return max(1.0, float(os.getenv("WANGSA_MOBILE_REPLY_TIMEOUT", "300")))
    except (ValueError, TypeError):
        return 300.0


# Fixed-window rate limiter constants for POST /messages.
_RATE_LIMIT_MAX = 30
_RATE_LIMIT_WINDOW = 60  # seconds

# Caps for the mobile contract.
_MAX_MODEL_LEN = 200
_MAX_PROVIDER_LEN = 100
_MAX_IMAGES = 5
_MAX_USER_NAME_LEN = 100
_MAX_USER_BIO_LEN = 500

# Outbound (agent -> mobile) image caps and buffering. See the module
# docstring's "Outbound images" section for why buffering exists at all.
_MAX_OUTBOUND_IMAGE_BYTES = 8 * 1024 * 1024  # 8MB raw, before base64 inflation
_MAX_OUTBOUND_FILE_BYTES = (
    15 * 1024 * 1024
)  # 15MB raw — documents/audio, not previewed inline
_REPLY_COALESCE_SECONDS = 0.4


def _default_agent_name() -> str:
    return os.getenv("WANGSA_MOBILE_AGENT_NAME", "").strip() or "Wangsa"


def _default_agent_purpose() -> str:
    return os.getenv("WANGSA_MOBILE_AGENT_PURPOSE", "").strip() or (
        "Asisten pribadi Wangsa — siap membantu apa saja lewat aplikasi mobile."
    )


def _bearer_token() -> str:
    return os.getenv("WANGSA_MOBILE_BEARER_TOKEN", "").strip()


_PROFILE_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
_MIN_USER_TOKEN_LEN = 16

# Open-signup username rule: 3-32 chars, lowercase. Stricter than the
# profile regex to avoid single-char profile spam via mobile signup.
_SIGNUP_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{2,31}$")
_SIGNUP_RESERVED = frozenset({"default", "hermes", "test", "tmp", "root", "sudo"})
_MOBILE_TOKENS_FILENAME = "wangsa_mobile_tokens.json"
_mobile_tokens_lock = threading.Lock()


def _mobile_tokens_path() -> Path:
    """Process-level token store path (never per-profile).

    Tokens map ``token -> profile`` globally, so the file must live under
    the default root even while a request is scoped to another profile.
    """
    try:
        from wangsa_constants import get_default_hermes_root
    except ImportError:
        try:
            from hermes_constants import get_default_hermes_root
        except ImportError:
            get_default_hermes_root = None  # type: ignore
    try:
        if get_default_hermes_root is not None:
            return get_default_hermes_root() / _MOBILE_TOKENS_FILENAME
    except Exception:
        pass
    try:
        from wangsa_constants import get_process_hermes_home
    except ImportError:
        try:
            from hermes_constants import get_process_hermes_home
        except ImportError:
            get_process_hermes_home = None  # type: ignore
    try:
        if get_process_hermes_home is not None:
            return get_process_hermes_home() / _MOBILE_TOKENS_FILENAME
    except Exception:
        pass
    return Path.home() / ".hermes" / _MOBILE_TOKENS_FILENAME


def _load_mobile_token_store() -> Dict[str, str]:
    """Read the persisted ``{token: profile}`` map. Returns {} on any failure."""
    try:
        path = _mobile_tokens_path()
        if not path.is_file():
            return {}
        raw = json.loads(path.read_text(encoding="utf-8"))
        node = raw.get("tokens") if isinstance(raw, dict) and isinstance(raw.get("tokens"), dict) else raw
        if not isinstance(node, dict):
            return {}
        tokens: Dict[str, str] = {}
        for token, profile in node.items():
            if not isinstance(token, str) or not isinstance(profile, str):
                continue
            profile = profile.strip().lower()
            token = token.strip()
            if len(token) < _MIN_USER_TOKEN_LEN or not _PROFILE_NAME_RE.match(profile):
                continue
            if token in tokens:
                continue
            tokens[token] = profile
        return tokens
    except Exception:
        logger.debug("wangsa_mobile: failed to load token store", exc_info=True)
        return {}


def _save_mobile_token_store(tokens: Dict[str, str]) -> None:
    """Atomically persist the token map with 0600 permissions."""
    path = _mobile_tokens_path()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
    except Exception:
        pass
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps({"tokens": tokens}, indent=2), encoding="utf-8")
    try:
        os.chmod(tmp, 0o600)
    except OSError:
        pass
    os.replace(tmp, path)
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def _revoke_mobile_token(token: str) -> bool:
    """Remove *token* from the file store. Returns True when revoked.

    Env-configured (``WANGSA_MOBILE_USER_TOKENS``) and legacy bearer tokens
    are operator-managed and cannot be revoked at runtime — returns False.
    """
    token = (token or "").strip()
    if not token:
        return False
    with _mobile_tokens_lock:
        tokens = _load_mobile_token_store()
        if token not in tokens:
            return False
        del tokens[token]
        _save_mobile_token_store(tokens)
        return True


def _issue_mobile_token(profile: str) -> str:
    """Mint, persist, and return a fresh bearer token for *profile*."""
    import secrets

    profile = profile.strip().lower()
    with _mobile_tokens_lock:
        tokens = _load_mobile_token_store()
        # One active token per profile: reuse would leak; rotate instead.
        for _ in range(5):
            candidate = secrets.token_urlsafe(32)
            if candidate not in tokens:
                break
        else:
            candidate = secrets.token_urlsafe(32)
        tokens[candidate] = profile
        _save_mobile_token_store(tokens)
        return candidate


def _user_token_map() -> Dict[str, str]:
    """Parse ``WANGSA_MOBILE_USER_TOKENS`` plus the signup store into ``{token: profile}``.

    Format: ``profile=token`` pairs separated by commas or newlines, e.g.
    ``alice=<secret>,bob=<secret>``. Each token identifies exactly one
    profile, so a token that is too short, malformed, or already assigned to
    another profile is dropped (with a warning) rather than guessed at.
    ``default`` maps a token to the gateway's default profile.

    The file store (``wangsa_mobile_tokens.json`` written by open signup)
    is merged first; env entries win on duplicate tokens so an operator can
    always override a leaked file token without editing JSON.
    """
    tokens: Dict[str, str] = {}
    for token, profile in _load_mobile_token_store().items():
        tokens[token] = profile
    raw = os.getenv("WANGSA_MOBILE_USER_TOKENS", "")
    for entry in re.split(r"[,\n]", raw):
        entry = entry.strip()
        if not entry:
            continue
        profile, sep, token = entry.partition("=")
        profile, token = profile.strip().lower(), token.strip()
        if not sep or not _PROFILE_NAME_RE.match(profile):
            logger.warning("wangsa_mobile: ignoring malformed WANGSA_MOBILE_USER_TOKENS entry")
            continue
        if len(token) < _MIN_USER_TOKEN_LEN:
            logger.warning(
                "wangsa_mobile: token for profile %r is shorter than %d characters; ignored",
                profile,
                _MIN_USER_TOKEN_LEN,
            )
            continue
        if token in tokens:
            logger.warning(
                "wangsa_mobile: token for profile %r duplicates another profile's token; ignored",
                profile,
            )
            continue
        tokens[token] = profile
    return tokens


def multi_user_enabled() -> bool:
    """True when per-user tokens are configured (one token per profile)."""
    return bool(_user_token_map())


def _identify_bearer(presented: str) -> tuple[bool, Optional[str]]:
    """Map a presented bearer token to ``(matched, profile)``.

    ``profile`` is ``None`` for the gateway's default profile (the legacy
    ``WANGSA_MOBILE_BEARER_TOKEN`` and any token mapped to ``default``).
    Every configured token is compared, without early exit, so timing does
    not reveal which entry matched.
    """
    import hmac

    candidate = presented.encode("utf-8")
    matched = False
    profile: Optional[str] = None
    for token, name in _user_token_map().items():
        if hmac.compare_digest(candidate, token.encode("utf-8")) and not matched:
            matched = True
            profile = None if name == "default" else name
    legacy = _bearer_token()
    if legacy and hmac.compare_digest(candidate, legacy.encode("utf-8")) and not matched:
        matched = True
    return matched, profile


def localhost_only() -> bool:
    """True when no bearer token is configured — mirrors a2a.security."""
    return not _bearer_token() and not _user_token_map()


def _chat_id(agent_id: str, session_id: str, profile: Optional[str] = None) -> str:
    """Per-session thread id. Non-default profiles get their own namespace so two
    users can never share a pending-reply queue even if they pick the same
    session id; the default profile keeps the historical ``mobile:`` form."""
    prefix = f"mobile.{profile}" if profile else "mobile"
    return f"{prefix}:{agent_id}:{session_id}"


class _ProfileUnavailable(RuntimeError):
    """The caller's profile cannot be served (multiplexing off, not served)."""


def resolve_bind_host() -> str:
    """Localhost unless a bearer token is configured AND a wider host is
    explicitly requested — same rule as a2a.security.resolve_bind_host()."""
    requested = os.getenv("WANGSA_MOBILE_HOST", "").strip() or "127.0.0.1"
    loopback = {"127.0.0.1", "localhost", "::1"}
    if requested in loopback:
        return requested
    allow_insecure = os.getenv("WANGSA_MOBILE_ALLOW_INSECURE_HOST", "").strip().lower() in ("1", "true", "yes")
    if localhost_only() and not allow_insecure:
        logger.warning(
            "wangsa_mobile: WANGSA_MOBILE_HOST=%s ignored — no "
            "WANGSA_MOBILE_BEARER_TOKEN set; binding to 127.0.0.1.",
            requested,
        )
        return "127.0.0.1"
    return requested


class _RateLimiter:
    """Small fixed-window per-key rate limiter (doesn't need a2a's machinery)."""

    def __init__(
        self, max_requests: int = _RATE_LIMIT_MAX, window: float = _RATE_LIMIT_WINDOW
    ):
        self.max_requests = max_requests
        self.window = window
        self._hits: Dict[str, list] = {}
        self._lock = threading.Lock()

    def allow(self, key: str) -> bool:
        now = time.time()
        with self._lock:
            hits = self._hits.setdefault(key, [])
            cutoff = now - self.window
            while hits and hits[0] < cutoff:
                hits.pop(0)
            if len(hits) >= self.max_requests:
                return False
            hits.append(now)
            return True


# Open-signup abuse guard: 5 registrations per IP per hour. Separate from
# the 30/min POST /messages limiter above.
_SIGNUP_RATE_LIMIT_MAX = 5
_SIGNUP_RATE_LIMIT_WINDOW = 3600.0
_signup_limiter = _RateLimiter(
    max_requests=_SIGNUP_RATE_LIMIT_MAX, window=_SIGNUP_RATE_LIMIT_WINDOW
)


def _reset_signup_limiter() -> None:
    """Clear the signup rate limiter (test hook — production never calls this)."""
    try:
        _signup_limiter._hits.clear()
    except Exception:
        pass


def _is_provider_configured() -> bool:
    """True when the current (profile-scoped) home has any non-free LLM credential.

    Must run inside the caller's ``_profile_context`` so ``get_env_value``
    resolves the profile's own ``.env``. ``opencode-free`` is keyless and
    always "configured" — it must NOT count, otherwise every blank profile
    looks ready and the mobile onboarding gate never fires.
    """
    try:
        config_mod = _hermes_cli_module("config")
        auth_mod = _hermes_cli_module("auth")
        get_env_value = config_mod.get_env_value
        get_auth_status = getattr(auth_mod, "get_auth_status", None)
        PROVIDER_REGISTRY = getattr(auth_mod, "PROVIDER_REGISTRY", {})
    except Exception:
        return False
    try:
        # Profile-scoped OAuth pool (auth.json in this profile's home).
        # Counts as configured — unlike ambient machine logins (e.g. `gh
        # auth token`) which are shared across profiles, not per-user.
        try:
            read_pool = getattr(auth_mod, "read_credential_pool", None)
            pool = read_pool() if callable(read_pool) else {}
            if isinstance(pool, dict) and any(
                isinstance(v, list) and v for v in pool.values()
            ):
                return True
        except Exception:
            pass
        for row in _get_all_providers_meta():
            pid = row.get("id", "")
            if pid in ("opencode-free", "custom"):
                continue
            if pid == "copilot":
                for var in ("COPILOT_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN"):
                    try:
                        val = (get_env_value(var) or os.getenv(var) or "").strip()
                    except Exception:
                        val = ""
                    if val:
                        return True
                continue
            if pid == "nous":
                try:
                    val = (get_env_value("NOUS_API_KEY") or os.getenv("NOUS_API_KEY") or "").strip()
                except Exception:
                    val = ""
                if val:
                    return True
                continue
            env_var = row.get("env_var")
            candidates: list[str] = []
            if env_var:
                candidates.append(env_var)
            try:
                pconfig = PROVIDER_REGISTRY.get(pid)
                for alt in getattr(pconfig, "api_key_env_vars", None) or []:
                    if alt not in candidates:
                        candidates.append(alt)
            except Exception:
                pass
            for var in candidates:
                try:
                    val = (get_env_value(var) or os.getenv(var) or "").strip()
                except Exception:
                    val = ""
                if val:
                    return True
        try:
            cfg = config_mod.load_config()
            customs = cfg.get("custom_providers") or []
            if isinstance(customs, list) and customs:
                return True
        except Exception:
            pass
    except Exception:
        logger.debug("wangsa_mobile: is_configured check failed", exc_info=True)
        return False
    return False


def _decode_request_images(body: dict) -> tuple:
    """Decode the request's image attachments into cached media.

    Accepts ``images`` (list of ``{data, mimeType?, filename?}`` objects or
    raw base64/data-URL strings) plus a singular ``image`` convenience alias.
    Each payload is base64-decoded and written through
    ``gateway.platforms.base.cache_media_bytes`` — the same bytes→cache
    helper every other platform adapter uses — so the agent sees real local
    paths via ``MessageEvent.media_urls``/``media_types``.

    Returns ``(media_urls, media_types)``. Raises ``ValueError`` on any
    malformed item (caller maps to 400 VALIDATION_ERROR).
    """
    import base64 as _base64

    raw_items: list = []
    images = body.get("images", None)
    if images is not None:
        if not isinstance(images, list):
            raise ValueError("images must be a list")
        raw_items.extend(images)
    single = body.get("image", None)
    if single is not None:
        raw_items.append(single)

    if len(raw_items) > _MAX_IMAGES:
        raise ValueError(f"at most {_MAX_IMAGES} images per message")

    if not raw_items:
        return [], []

    from gateway.platforms.base import cache_media_bytes

    media_urls: list = []
    media_types: list = []
    for i, item in enumerate(raw_items):
        data_str: str = ""
        mime = ""
        filename = ""
        if isinstance(item, dict):
            data_str = item.get("data", "")
            mime = str(
                item.get(
                    "mimeType",
                    item.get(
                        "mime_type",
                        item.get("contentType", item.get("content_type", "")),
                    ),
                )
                or ""
            ).strip()
            filename = str(item.get("filename", item.get("name", "")) or "").strip()
        elif isinstance(item, str):
            data_str = item
        else:
            raise ValueError(f"images[{i}] must be an object or a base64 string")
        if not isinstance(data_str, str) or not data_str.strip():
            raise ValueError(f"images[{i}].data must be a non-empty base64 string")
        data_str = data_str.strip()
        if data_str.startswith("data:"):
            header, _, payload = data_str.partition(",")
            if not payload:
                raise ValueError(f"images[{i}].data is not a valid data URL")
            data_str = payload.strip()
            header_mime = header[5:].split(";", 1)[0].strip()
            if header_mime and not mime:
                mime = header_mime
        try:
            raw = _base64.b64decode(data_str, validate=True)
        except Exception:
            raise ValueError(f"images[{i}].data is not valid base64")
        if not raw:
            raise ValueError(f"images[{i}].data is empty")
        if not mime:
            mime = "image/jpeg"
        if not filename:
            ext = ".jpg"
            lowered = mime.lower()
            if lowered == "image/png":
                ext = ".png"
            elif lowered == "image/gif":
                ext = ".gif"
            elif lowered == "image/webp":
                ext = ".webp"
            filename = f"mobile-image-{i}{ext}"
        try:
            cached = cache_media_bytes(
                raw, filename=filename, mime_type=mime, default_kind="image"
            )
        except ValueError as e:
            raise ValueError(f"images[{i}] rejected: {e}")
        if cached is None:
            raise ValueError(f"images[{i}] is not a supported image")
        media_urls.append(cached.path)
        media_types.append(cached.media_type)
    return media_urls, media_types


def _encode_local_image(path: str) -> Optional[dict]:
    """Reads a local image file the agent produced and returns a JSON-safe
    base64 payload, or None if it can't be read or exceeds the size cap.

    Mirrors the inbound ``{data, mimeType, filename}`` shape used by
    ``_decode_request_images`` so the wire contract is symmetric in both
    directions — the mobile client's image-decoding path doesn't need to
    know whether the image originated on the phone or the agent.
    """
    import base64 as _base64
    import mimetypes as _mimetypes

    try:
        p = Path(path)
        if not p.is_file():
            return None
        size = p.stat().st_size
        if size <= 0 or size > _MAX_OUTBOUND_IMAGE_BYTES:
            logger.warning(
                "wangsa_mobile: outbound image %s is %d bytes, skipping (cap %d)",
                path,
                size,
                _MAX_OUTBOUND_IMAGE_BYTES,
            )
            return None
        raw = p.read_bytes()
        mime = _mimetypes.guess_type(p.name)[0] or "image/png"
        if not mime.startswith("image/"):
            mime = "image/png"
        return {
            "data": _base64.b64encode(raw).decode("ascii"),
            "mimeType": mime,
            "filename": p.name,
        }
    except Exception:
        logger.debug(
            "wangsa_mobile: failed to encode outbound image %s", path, exc_info=True
        )
        return None


def _encode_local_file(path: str, kind: str) -> Optional[dict]:
    """Reads a local document/audio file the agent produced and returns a
    JSON-safe base64 payload, or None if it can't be read or exceeds the
    size cap. ``kind`` is ``\"document\"`` or ``\"audio\"`` — the client uses it
    to pick a file-chip vs. an audio player, it's opaque to the server.

    Unlike ``_encode_local_image``, the mime type is trusted as-is (falls
    back to ``application/octet-stream``) since documents/audio cover far
    more types than images do, and the client only needs it to decide how
    to open/play the file, not to render it inline.
    """
    import base64 as _base64
    import mimetypes as _mimetypes

    try:
        p = Path(path)
        if not p.is_file():
            return None
        size = p.stat().st_size
        if size <= 0 or size > _MAX_OUTBOUND_FILE_BYTES:
            logger.warning(
                "wangsa_mobile: outbound %s %s is %d bytes, skipping (cap %d)",
                kind,
                path,
                size,
                _MAX_OUTBOUND_FILE_BYTES,
            )
            return None
        raw = p.read_bytes()
        mime = _mimetypes.guess_type(p.name)[0] or "application/octet-stream"
        return {
            "data": _base64.b64encode(raw).decode("ascii"),
            "mimeType": mime,
            "filename": p.name,
            "kind": kind,
        }
    except Exception:
        logger.debug(
            "wangsa_mobile: failed to encode outbound %s %s", kind, path, exc_info=True
        )
        return None


class _WangsaMobileServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, addr, handler_cls, adapter: "WangsaMobileAdapter"):
        super().__init__(addr, handler_cls)
        self.adapter = adapter


def _route_requires_auth(method: str, path: str) -> bool:
    """Whether a recognised route must carry a valid bearer token.

    With per-user tokens every profile-bound route needs one (the token IS the
    identity); only the static agent-identity GET and the open-signup POST
    stay public. With just the legacy shared token, POST /messages and the
    provider-credential routes are gated. Unknown paths return False so they
    fall through to a 404.
    """
    if path == "/api/v1/auth/signup":
        return False
    if path.startswith("/api/v1/auth/"):
        return True
    m = _AGENT_ID_RE.match(path)
    if not m or not (m.group(2) or ""):
        return False
    if multi_user_enabled():
        return True
    return method == "POST" and (m.group(2) or "") in ("/messages", "/messages/stream")


class WangsaMobileRequestHandler(BaseHTTPRequestHandler):
    """HTTP handler for the Wangsa mobile REST routes."""

    @property
    def adapter(self) -> "WangsaMobileAdapter":
        return self.server.adapter  # type: ignore[attr-defined]

    def log_message(self, format, *args):  # noqa: A002,N802
        logger.debug("wangsa_mobile http: " + format, *args)

    def _json(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _error(self, code: int, error_code: str, message: str) -> None:
        self._json(
            code, {"success": False, "error": {"code": error_code, "message": message}}
        )

    def _presented_token(self) -> str:
        parts = self.headers.get("Authorization", "").split(None, 1)
        if len(parts) == 2 and parts[0].lower() == "bearer":
            return parts[1].strip()
        return ""

    def _authenticate(self, required: bool) -> tuple[bool, Optional[str]]:
        """Resolve the caller's profile from the bearer token.

        Returns ``(ok, profile)``; ``profile`` is ``None`` for the default
        profile. On a required-but-bad token the 401 is sent here and
        ``ok`` is False. With no token configured at all the server is
        open (localhost-only or explicitly insecure) and every caller is
        the default profile.
        """
        if not (_bearer_token() or _user_token_map()):
            return True, None
        presented = self._presented_token()
        matched, profile = _identify_bearer(presented) if presented else (False, None)
        if matched:
            return True, profile
        if required:
            self._error(401, "UNAUTHORIZED", "missing or invalid bearer token")
            return False, None
        return True, None

    def _guarded(self, method: str, impl) -> None:
        """Authenticate, then run *impl* inside the caller's profile scope."""
        path = self.path.split("?", 1)[0]
        ok, profile = self._authenticate(_route_requires_auth(method, path))
        if not ok:
            return
        try:
            scope = self.adapter._profile_context(profile)
        except _ProfileUnavailable as e:
            self._error(503, "PROFILE_UNAVAILABLE", str(e))
            return
        self._profile = profile
        with scope:
            impl()

    def do_GET(self):  # noqa: N802
        self._guarded("GET", self._do_get)

    def do_POST(self):  # noqa: N802
        self._guarded("POST", self._do_post)

    def do_DELETE(self):  # noqa: N802
        self._guarded("DELETE", self._do_delete)

    def _do_get(self):
        path = self.path.split("?", 1)[0]
        if path == "/api/v1/auth/providers":
            self._handle_auth_providers_get()
            return
        if path == "/api/v1/auth/me":
            self._handle_me()
            return
        if path == "/api/v1/auth/budget":
            self._handle_budget()
            return
        m = _AGENT_ID_RE.match(path)
        if not m:
            self._json(
                404,
                {
                    "success": False,
                    "error": {"code": "NOT_FOUND", "message": "not found"},
                },
            )
            return
        agent_id = m.group(1)
        suffix = m.group(2) or ""
        if suffix == "/models":
            self._handle_models(agent_id)
            return
        if suffix == "/sessions":
            sessions = self.adapter._list_sessions(agent_id, self._profile)
            self._json(200, {"success": True, "data": {"sessions": sessions}})
            return
        if suffix.startswith("/sessions/") and suffix.endswith("/messages"):
            session_id = suffix[len("/sessions/"):-len("/messages")]
            turns = self.adapter._get_session_messages(agent_id, session_id, self._profile)
            self._json(200, {"success": True, "data": {"turns": turns}})
            return
        if suffix:
            self._json(
                404,
                {
                    "success": False,
                    "error": {"code": "NOT_FOUND", "message": "not found"},
                },
            )
            return
        self._json(
            200,
            {
                "success": True,
                "data": {
                    "id": agent_id,
                    "name": _default_agent_name(),
                    "purpose": _default_agent_purpose(),
                },
            },
        )

    def _do_delete(self):
        path = self.path.split("?", 1)[0]
        if path == "/api/v1/auth/token":
            self._handle_token_revoke()
            return
        if path.startswith("/api/v1/auth/providers/"):
            provider_id = path[len("/api/v1/auth/providers/") :].strip("/")
            self._handle_auth_provider_delete(provider_id)
            return
        m = _AGENT_ID_RE.match(path)
        if not m:
            self._json(
                404,
                {
                    "success": False,
                    "error": {"code": "NOT_FOUND", "message": "not found"},
                },
            )
            return
        agent_id = m.group(1)
        suffix = m.group(2) or ""
        if suffix.startswith("/sessions/"):
            session_id = suffix[len("/sessions/") :]
            deleted = self.adapter._delete_session(agent_id, session_id, self._profile)
            self._json(200, {"success": True, "data": {"deleted": deleted}})
            return
        self._json(
            404,
            {"success": False, "error": {"code": "NOT_FOUND", "message": "not found"}},
        )

    def _handle_models(self, agent_id: str) -> None:  # noqa: ARG002
        """Serve the model picker payload for available providers and models.

        Uses the same ``build_model_options_payload(load_picker_context())``
        substrate as the dashboard's ``/api/model/options`` and the TUI
        ``ModelPickerDialog`` — no new model-listing logic. Responds with
        provider, current model, active provider's models, and full providers list.
        """
        try:
            try:
                from hermes_cli.inventory import (
                    build_model_options_payload,
                    load_picker_context,
                )
            except ImportError:
                from wangsa_cli.inventory import (
                    build_model_options_payload,
                    load_picker_context,
                )

            # Only providers the user actually configured (current provider,
            # config.yaml, or provider-specific env keys) belong in the chat
            # picker; the full provider universe is for the setup screen.
            try:
                payload = build_model_options_payload(load_picker_context(), explicit_only=True)
            except TypeError:
                payload = build_model_options_payload(load_picker_context())
        except Exception:
            logger.debug("wangsa_mobile: model options build failed", exc_info=True)
            self._error(502, "RUNTIME_ERROR", "failed to list models")
            return
        provider = str(payload.get("provider") or "")
        current = str(payload.get("model") or "")
        models: list = []
        providers_out: list = []
        try:
            for row in payload.get("providers") or []:
                if not isinstance(row, dict):
                    continue
                slug = str(row.get("slug") or "")
                name = str(row.get("name") or slug)
                row_models = [str(m) for m in (row.get("models") or [])]
                if slug == "opencode-free":
                    row_models = _opencode_free_model_ids()
                providers_out.append({
                    "id": slug,
                    "slug": slug,
                    "name": name,
                    "models": row_models,
                })
                if slug == provider:
                    models = row_models
        except Exception:
            logger.debug("wangsa_mobile: model row extraction failed", exc_info=True)
            models = []
        self._json(
            200,
            {
                "success": True,
                "data": {
                    "provider": provider,
                    "current": current,
                    "models": models,
                    "providers": providers_out,
                },
            },
        )

    def _handle_budget(self) -> None:
        """Return the caller's spend vs caps.

        Requires a valid bearer token; runs inside the profile scope so the
        ledger (``state.db``) and ``budgets:`` config are the caller's own.
        Shape: ``{enabled, daily_usd, monthly_usd, spent_day, spent_month,
        breached, alert}`` — the mobile app renders progress + banners.
        """
        try:
            from agent.budgets import budget_status as _budget_status
        except ImportError:
            self._error(500, "INTERNAL_ERROR", "budget system unavailable")
            return
        try:
            status = _budget_status()
        except Exception:
            logger.debug("wangsa_mobile: budget status failed", exc_info=True)
            self._error(500, "INTERNAL_ERROR", "could not read budget")
            return
        self._json(200, {"success": True, "data": status})

    def _handle_token_revoke(self) -> None:
        """Revoke the caller's own bearer token (logout).

        Removes file-store tokens issued by open signup. Operator-managed
        env/legacy tokens return 409 — the user must ask the admin to rotate
        them instead of silently keeping a dead session.
        """
        presented = self._presented_token()
        if not presented:
            self._error(401, "UNAUTHORIZED", "missing bearer token")
            return
        if _revoke_mobile_token(presented):
            self._json(200, {"success": True, "data": {"revoked": True}})
            return
        self._error(409, "CONFLICT", "token ini dikelola server dan tidak bisa dicabut dari aplikasi")

    def _handle_me(self) -> None:
        """Return the caller's profile plus whether an LLM is connected.

        Requires a valid bearer token (``_route_requires_auth`` gates
        ``/api/v1/auth/*``). Runs inside the caller's profile scope so
        ``configured`` reflects their own ``.env``, not another user's.
        """
        profile = getattr(self, "_profile", None) or "default"
        try:
            configured = _is_provider_configured()
        except Exception:
            configured = False
        self._json(200, {"success": True, "data": {"profile": profile, "configured": configured}})

    def _handle_signup(self) -> None:
        """Open registration: create a profile and issue its bearer token.

        Public route (no token needed). Body: ``{"username": "<name>"}``.
        Rate-limited per IP (5/hour). Username 3-32 chars, lowercase,
        ``_SIGNUP_NAME_RE``; reserved names and existing profiles rejected
        with 409 CONFLICT so a taken name is distinguishable from bad input.
        """
        try:
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length else b"{}"
            body = json.loads(raw.decode("utf-8"))
        except Exception:
            self._error(400, "VALIDATION_ERROR", "invalid JSON body")
            return
        if not isinstance(body, dict):
            self._error(400, "VALIDATION_ERROR", "body must be a JSON object")
            return
        username = str(body.get("username") or body.get("name") or "").strip().lower()
        if not username:
            self._error(400, "VALIDATION_ERROR", "username is required")
            return
        if len(username) < 3 or len(username) > 32 or not _SIGNUP_NAME_RE.match(username):
            self._error(
                400,
                "VALIDATION_ERROR",
                "username must be 3-32 lowercase letters, digits, - or _",
            )
            return
        if username in _SIGNUP_RESERVED:
            self._error(409, "CONFLICT", f"username {username!r} is reserved")
            return
        client_ip = self.client_address[0] if self.client_address else "unknown"
        if not _signup_limiter.allow(f"signup:{client_ip}"):
            self._error(429, "RATE_LIMITED", "too many registrations from this address, try again later")
            return
        try:
            from wangsa_cli.profiles import create_profile, profile_exists
        except ImportError:
            try:
                from hermes_cli.profiles import create_profile, profile_exists
            except ImportError:
                self._error(500, "INTERNAL_ERROR", "profile system unavailable")
                return
        try:
            if profile_exists(username):
                self._error(409, "CONFLICT", f"username {username!r} is already taken")
                return
        except Exception:
            logger.debug("wangsa_mobile: profile_exists check failed", exc_info=True)
            self._error(500, "INTERNAL_ERROR", "could not check username")
            return
        try:
            create_profile(username, no_alias=True)
        except FileExistsError:
            self._error(409, "CONFLICT", f"username {username!r} is already taken")
            return
        except ValueError as e:
            self._error(400, "VALIDATION_ERROR", str(e) or "invalid username")
            return
        except Exception as e:
            logger.warning("wangsa_mobile: could not create profile %r", username, exc_info=True)
            self._error(500, "INTERNAL_ERROR", "could not create profile")
            return
        try:
            # Validate the new profile is actually served (multiplex allowlist).
            self.adapter._ensure_profile(username)
        except _ProfileUnavailable as e:
            self._error(503, "PROFILE_UNAVAILABLE", str(e))
            return
        try:
            token = _issue_mobile_token(username)
        except Exception:
            logger.warning("wangsa_mobile: could not issue token for %r", username, exc_info=True)
            self._error(500, "INTERNAL_ERROR", "could not issue token")
            return
        self._json(
            201,
            {"success": True, "data": {"profile": username, "token": token, "configured": False}},
        )

    def _handle_auth_providers_get(self) -> None:
        """Return list of supported LLM inference providers and current connection status."""
        try:
            config_mod = _hermes_cli_module("config")
            auth_mod = _hermes_cli_module("auth")
            get_env_value, load_config = config_mod.get_env_value, config_mod.load_config
            get_auth_status, PROVIDER_REGISTRY = auth_mod.get_auth_status, auth_mod.PROVIDER_REGISTRY

            cfg = load_config()
            custom_providers = cfg.get("custom_providers") or []

            providers_meta = _get_all_providers_meta()
            data = []
            for p in providers_meta:
                pid = p["id"]
                configured = False
                preview = None

                if pid == "opencode-free":
                    configured = True
                    preview = "Aktif (Keyless / Gratis)"
                elif pid == "copilot":
                    try:
                        cst = get_auth_status("copilot")
                        if cst.get("configured") or cst.get("logged_in"):
                            configured = True
                            preview = "Aktif (" + str(cst.get("key_source") or "GitHub") + ")"
                    except Exception:
                        pass
                    if not configured:
                        t = (get_env_value("COPILOT_GITHUB_TOKEN") or os.getenv("COPILOT_GITHUB_TOKEN") or "").strip()
                        if t:
                            configured = True
                            preview = t[:6] + "..." + t[-4:] if len(t) > 10 else "Tersimpan"
                elif pid == "nous":
                    try:
                        nst = get_auth_status("nous")
                        if nst.get("logged_in") or nst.get("configured"):
                            configured = True
                            preview = "Aktif (Nous Portal)"
                    except Exception:
                        pass
                    if not configured:
                        k = (get_env_value("NOUS_API_KEY") or os.getenv("NOUS_API_KEY") or "").strip()
                        if k:
                            configured = True
                            preview = k[:6] + "..." + k[-4:] if len(k) > 10 else "Tersimpan"
                elif pid == "custom":
                    if custom_providers and isinstance(custom_providers, list):
                        configured = True
                        preview = f"{len(custom_providers)} endpoint terdaftar"
                else:
                    env_var = p.get("env_var")
                    val = ""
                    if env_var:
                        val = (get_env_value(env_var) or os.getenv(env_var) or "").strip()
                    if not val:
                        pconfig = PROVIDER_REGISTRY.get(pid) if PROVIDER_REGISTRY else None
                        if pconfig and getattr(pconfig, "api_key_env_vars", None):
                            for alt in pconfig.api_key_env_vars:
                                val = (get_env_value(alt) or os.getenv(alt) or "").strip()
                                if val:
                                    break
                    if val:
                        configured = True
                        preview = val[:6] + "..." + val[-4:] if len(val) > 10 else "Tersimpan"

                data.append({
                    "id": pid,
                    "name": p["name"],
                    "authType": p["auth_type"],
                    "configured": configured,
                    "envVar": p.get("env_var"),
                    "keyPreview": preview,
                    "description": p["description"],
                    "helpUrl": p["help_url"],
                })

            self._json(200, {"success": True, "data": {"providers": data}})
        except Exception as e:
            logger.exception("wangsa_mobile: failed to list auth providers")
            self._error(500, "INTERNAL_ERROR", str(e))

    def _handle_auth_provider_save(self, provider_id: str) -> None:
        try:
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length else b"{}"
            body = json.loads(raw.decode("utf-8"))
        except Exception:
            self._error(400, "VALIDATION_ERROR", "invalid JSON body")
            return

        try:
            config_mod = _hermes_cli_module("config")
            auth_mod = _hermes_cli_module("auth")
            save_env_value, load_config, save_config = (
                config_mod.save_env_value,
                config_mod.load_config,
                config_mod.save_config,
            )
            read_credential_pool, write_credential_pool = (
                auth_mod.read_credential_pool,
                auth_mod.write_credential_pool,
            )

            if provider_id == "custom":
                name = str(body.get("name") or "").strip() or "Custom Endpoint"
                base_url = str(body.get("baseUrl") or "").strip()
                api_key = str(body.get("apiKey") or "").strip()
                model = str(body.get("model") or "").strip()
                if not base_url:
                    self._error(400, "VALIDATION_ERROR", "baseUrl is required for custom provider")
                    return
                try:
                    main_mod = _hermes_cli_module("main")
                    main_mod._save_custom_provider(base_url, api_key=api_key, model=model, name=name)
                    self._json(200, {"success": True, "data": {"message": f"Endpoint {name} berhasil disimpan."}})
                except Exception as e:
                    self._error(500, "INTERNAL_ERROR", str(e))
                return

            if provider_id == "copilot":
                token = str(body.get("token") or body.get("apiKey") or "").strip()
                if not token:
                    self._error(400, "VALIDATION_ERROR", "Token diperlukan untuk GitHub Copilot")
                    return
                save_env_value("COPILOT_GITHUB_TOKEN", token)
                os.environ["COPILOT_GITHUB_TOKEN"] = token
                self._json(200, {"success": True, "data": {"message": "Kredensial GitHub Copilot berhasil disimpan."}})
                return

            if provider_id == "opencode-free":
                self._json(200, {"success": True, "data": {"message": "OpenCode Free selalu aktif dan tidak memerlukan kunci API."}})
                return

            all_meta = _get_all_providers_meta()
            meta = next((p for p in all_meta if p["id"] == provider_id), None)
            if meta is None:
                self._error(404, "NOT_FOUND", f"Provider {provider_id} tidak dikenal.")
                return

            api_key = str(body.get("apiKey") or body.get("token") or "").strip()
            if not api_key:
                self._error(400, "VALIDATION_ERROR", f"Kunci API untuk {meta['name']} tidak boleh kosong.")
                return

            env_var = meta.get("env_var") or f"{provider_id.upper()}_API_KEY"
            save_env_value(env_var, api_key)
            os.environ[env_var] = api_key

            try:
                pool = read_credential_pool()
                if provider_id in pool:
                    pool[provider_id] = [it for it in pool[provider_id] if it.get("last_status") != "exhausted"]
                    write_credential_pool(pool)
            except Exception:
                pass

            self._json(200, {"success": True, "data": {"message": f"Kunci API untuk {meta['name']} berhasil disimpan."}})
        except Exception as e:
            logger.exception("wangsa_mobile: failed to save provider auth")
            self._error(500, "INTERNAL_ERROR", str(e))

    def _handle_auth_provider_delete(self, provider_id: str) -> None:
        try:
            config_mod = _hermes_cli_module("config")
            auth_mod = _hermes_cli_module("auth")
            save_env_value, load_config, save_config = (
                config_mod.save_env_value,
                config_mod.load_config,
                config_mod.save_config,
            )
            read_credential_pool, write_credential_pool = (
                auth_mod.read_credential_pool,
                auth_mod.write_credential_pool,
            )

            if provider_id == "custom":
                cfg = load_config()
                cfg["custom_providers"] = []
                save_config(cfg)
                self._json(200, {"success": True, "data": {"message": "Custom provider dibersihkan."}})
                return

            if provider_id == "opencode-free":
                self._json(200, {"success": True, "data": {"message": "OpenCode Free adalah layanan bawaan."}})
                return

            all_meta = _get_all_providers_meta()
            meta = next((p for p in all_meta if p["id"] == provider_id), None)
            env_vars = [meta["env_var"]] if (meta and meta.get("env_var")) else [f"{provider_id.upper().replace('-', '_')}_API_KEY"]
            for ev in env_vars:
                try:
                    save_env_value(ev, "")
                    os.environ.pop(ev, None)
                except Exception:
                    pass

            try:
                pool = read_credential_pool()
                if provider_id in pool:
                    pool.pop(provider_id, None)
                    write_credential_pool(pool)
            except Exception:
                pass

            self._json(200, {"success": True, "data": {"message": f"Kredensial {provider_id} berhasil dihapus."}})
        except Exception as e:
            logger.exception("wangsa_mobile: failed to delete provider auth")
            self._error(500, "INTERNAL_ERROR", str(e))

    def _handle_copilot_device_code(self) -> None:
        try:
            import urllib.request, urllib.parse
            COPILOT_OAUTH_CLIENT_ID = _hermes_cli_module("copilot_auth").COPILOT_OAUTH_CLIENT_ID
            data = urllib.parse.urlencode({
                "client_id": COPILOT_OAUTH_CLIENT_ID,
                "scope": "read:user",
            }).encode()
            req = urllib.request.Request(
                "https://github.com/login/device/code",
                data=data,
                headers={
                    "Accept": "application/json",
                    "Content-Type": "application/x-www-form-urlencoded",
                    "User-Agent": "HermesAgent/1.0",
                },
            )
            with urllib.request.urlopen(req, timeout=15) as resp:
                device_data = json.loads(resp.read().decode())
            self._json(200, {"success": True, "data": device_data})
        except Exception as e:
            logger.exception("wangsa_mobile: copilot device code failed")
            self._error(502, "UPSTREAM_ERROR", f"Gagal memulai otorisasi GitHub: {e}")

    def _handle_copilot_poll(self) -> None:
        try:
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length else b"{}"
            body = json.loads(raw.decode("utf-8"))
        except Exception:
            self._error(400, "VALIDATION_ERROR", "invalid JSON")
            return
        device_code = str(body.get("device_code") or "").strip()
        if not device_code:
            self._error(400, "VALIDATION_ERROR", "device_code is required")
            return

        try:
            import urllib.request, urllib.parse
            COPILOT_OAUTH_CLIENT_ID = _hermes_cli_module("copilot_auth").COPILOT_OAUTH_CLIENT_ID
            save_env_value = _hermes_cli_module("config").save_env_value

            poll_data = urllib.parse.urlencode({
                "client_id": COPILOT_OAUTH_CLIENT_ID,
                "device_code": device_code,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            }).encode()
            poll_req = urllib.request.Request(
                "https://github.com/login/oauth/access_token",
                data=poll_data,
                headers={
                    "Accept": "application/json",
                    "Content-Type": "application/x-www-form-urlencoded",
                    "User-Agent": "HermesAgent/1.0",
                },
            )
            with urllib.request.urlopen(poll_req, timeout=10) as resp:
                result = json.loads(resp.read().decode())

            if result.get("access_token"):
                token = result["access_token"]
                save_env_value("COPILOT_GITHUB_TOKEN", token)
                os.environ["COPILOT_GITHUB_TOKEN"] = token
                self._json(200, {
                    "success": True,
                    "data": {
                        "status": "authorized",
                        "message": "GitHub Copilot berhasil diotorisasi!",
                    },
                })
                return

            err = result.get("error", "authorization_pending")
            self._json(200, {"success": True, "data": {"status": err, "interval": result.get("interval")}})
        except Exception as e:
            logger.exception("wangsa_mobile: copilot poll failed")
            self._error(502, "UPSTREAM_ERROR", f"Poll request failed: {e}")

    def _do_post(self):
        adapter = self.adapter
        profile = getattr(self, "_profile", None)
        path = self.path.split("?", 1)[0]
        if path == "/api/v1/auth/signup":
            self._handle_signup()
            return
        if path.startswith("/api/v1/auth/providers/"):
            provider_id = path[len("/api/v1/auth/providers/") :].strip("/")
            self._handle_auth_provider_save(provider_id)
            return
        if path == "/api/v1/auth/copilot/device-code":
            self._handle_copilot_device_code()
            return
        if path == "/api/v1/auth/copilot/poll":
            self._handle_copilot_poll()
            return
        m = _AGENT_ID_RE.match(path)
        if not m or (m.group(2) or "") not in ("/messages", "/messages/stream"):
            self._json(
                404,
                {
                    "success": False,
                    "error": {"code": "NOT_FOUND", "message": "not found"},
                },
            )
            return
        is_stream = (m.group(2) or "") == "/messages/stream"
        agent_id = m.group(1)

        # Bearer auth (and the caller's profile) was already resolved by
        # _guarded(); GET /agents/:id stays open.
        client_ip = self.client_address[0] if self.client_address else ""
        if not adapter._rate_limiter.allow(client_ip):
            self._error(429, "RATE_LIMITED", "rate limit exceeded")
            return

        try:
            length = int(self.headers.get("Content-Length", 0))
            if length > _MAX_BODY:
                self._error(413, "VALIDATION_ERROR", "payload too large")
                return
            raw = self.rfile.read(length) if length else b"{}"
            body = json.loads(raw.decode("utf-8"))
        except Exception:
            self._error(400, "VALIDATION_ERROR", "invalid JSON body")
            return

        if not isinstance(body, dict):
            self._error(400, "VALIDATION_ERROR", "body must be a JSON object")
            return

        message = str(body.get("message") or "").strip()
        session_id = body.get("sessionId") or None
        if session_id is not None:
            session_id = str(session_id).strip() or None

        # Capabilities are selected before the first message and remain fixed
        # for this mobile session, preserving the tool schema prefix/cache.
        # Older clients omit this field; existing sessions keep their stored
        # selection and new sessions default to no tools.
        raw_toolsets = body.get("toolsets", None)
        requested_toolsets: Optional[list[str]] = None
        if raw_toolsets is not None:
            if not isinstance(raw_toolsets, list) or any(
                not isinstance(item, str) for item in raw_toolsets
            ):
                self._error(400, "VALIDATION_ERROR", "toolsets must be a list of strings")
                return
            normalized_toolsets = {item.strip().lower() for item in raw_toolsets if item.strip()}
            if normalized_toolsets - _MOBILE_TOOLSETS:
                self._error(
                    400,
                    "VALIDATION_ERROR",
                    "mobile chat only supports the web and vision capabilities",
                )
                return
            requested_toolsets = sorted(normalized_toolsets)

        # New per-session model selection (validated against the catalog;
        # persisted like the /model slash command). The legacy BYOK ``llm``
        # object is still silently ignored for back-compat.
        raw_model = body.get("model", None)
        raw_provider = body.get("provider", None)
        model: Optional[str] = None
        provider: Optional[str] = None
        if raw_model is not None:
            if not isinstance(raw_model, str) or not raw_model.strip():
                self._error(400, "VALIDATION_ERROR", "model must be a non-empty string")
                return
            model = raw_model.strip()
            if len(model) > _MAX_MODEL_LEN:
                self._error(
                    400,
                    "VALIDATION_ERROR",
                    f"model exceeds {_MAX_MODEL_LEN} characters",
                )
                return
        if raw_provider is not None:
            if not isinstance(raw_provider, str) or not raw_provider.strip():
                self._error(
                    400, "VALIDATION_ERROR", "provider must be a non-empty string"
                )
                return
            provider = raw_provider.strip()
            if len(provider) > _MAX_PROVIDER_LEN:
                self._error(
                    400,
                    "VALIDATION_ERROR",
                    f"provider exceeds {_MAX_PROVIDER_LEN} characters",
                )
                return

        # Local device profile (name + short preferences the user filled in
        # on the app's Profile screen — see ProfilePage/UserProfileController
        # on the Flutter side). Both optional; absent/blank means "no
        # profile set", not an error. Folded into the session's pinned
        # "Current Session Context" block (SessionSource.user_name/user_bio)
        # rather than the system prompt directly, so an edited profile busts
        # the prompt cache exactly once (same class of event as a rename or
        # topic edit) instead of on every turn.
        raw_user_name = body.get("userName", None)
        raw_user_bio = body.get("userBio", None)
        user_name: Optional[str] = None
        user_bio: Optional[str] = None
        if raw_user_name is not None:
            if not isinstance(raw_user_name, str):
                self._error(400, "VALIDATION_ERROR", "userName must be a string")
                return
            user_name = raw_user_name.strip()[:_MAX_USER_NAME_LEN] or None
        if raw_user_bio is not None:
            if not isinstance(raw_user_bio, str):
                self._error(400, "VALIDATION_ERROR", "userBio must be a string")
                return
            user_bio = raw_user_bio.strip()[:_MAX_USER_BIO_LEN] or None

        try:
            media_urls, media_types = _decode_request_images(body)
        except ValueError as e:
            self._error(400, "VALIDATION_ERROR", str(e) or "invalid images")
            return

        if not message and not media_urls:
            self._error(400, "VALIDATION_ERROR", "message must not be empty")
            return
        if len(message) > _MAX_MESSAGE_LEN:
            self._error(
                400,
                "VALIDATION_ERROR",
                f"message exceeds {_MAX_MESSAGE_LEN} characters",
            )
            return

        effective_session_id = session_id or uuid.uuid4().hex
        stored_toolsets = (
            adapter._session_toolsets(effective_session_id, profile)
            if session_id is not None
            else None
        )
        if stored_toolsets is not None:
            if requested_toolsets is not None and requested_toolsets != stored_toolsets:
                self._error(
                    409,
                    "SESSION_TOOLSETS_LOCKED",
                    "Capabilities are fixed for this conversation. Start a new chat to change them.",
                )
                return
            active_toolsets = stored_toolsets
        else:
            active_toolsets = requested_toolsets or []

        thread_id = _chat_id(agent_id, effective_session_id or "anon", profile)

        # Spend-budget pre-flight (runs inside the caller's profile scope
        # installed by _guarded, so the ledger + config are theirs). Fast
        # reject before a turn slot, queue entry, or agent thread is spent.
        try:
            from agent.budgets import check_budget as _check_budget
        except ImportError:
            _check_budget = None  # type: ignore
        if _check_budget is not None:
            try:
                _allowed, _budget_msg, _ = _check_budget()
            except Exception:
                logger.debug("wangsa_mobile: budget check failed open", exc_info=True)
                _allowed, _budget_msg = True, ""
            if not _allowed:
                self._error(429, "BUDGET_EXCEEDED", _budget_msg or "budget exceeded")
                return

        if model is not None and str(model).strip():
            err = adapter._apply_model_override(thread_id, str(model).strip(), provider, profile=profile)
            if err:
                self._error(400, "VALIDATION_ERROR", err)
                return
        else:
            try:
                adapter._clear_model_override(thread_id, profile)
            except Exception:
                logger.debug("wangsa_mobile: failed to clear model override", exc_info=True)

        state, reply = adapter._dispatch_and_wait(
            agent_id,
            thread_id,
            message,
            media_urls=media_urls,
            media_types=media_types,
            user_name=user_name,
            user_bio=user_bio,
            profile=profile,
            toolsets=active_toolsets,
        )
        reply_text = reply.get("text", "") if isinstance(reply, dict) else (reply or "")
        reply_images = reply.get("images") if isinstance(reply, dict) else None
        reply_files = reply.get("files") if isinstance(reply, dict) else None
        reply_thought = reply.get("thought", "") if isinstance(reply, dict) else ""
        reply_tools = reply.get("tool_calls") if isinstance(reply, dict) else None

        if state == "timeout":
            self._error(504, "RUNTIME_ERROR", "agent did not reply in time")
            return
        if state == "failed":
            self._error(502, "RUNTIME_ERROR", reply_text or "agent processing failed")
            return

        response_data: Dict[str, Any] = {
            "response": reply_text,
            "sessionId": effective_session_id,
        }
        if reply_images:
            response_data["images"] = reply_images
        if reply_files:
            response_data["files"] = reply_files
        if reply_thought:
            response_data["thought"] = reply_thought
        if reply_tools:
            response_data["toolCalls"] = reply_tools

        title = (
            message[:36] + ("..." if len(message) > 36 else "")
            if message
            else "Pesan Media"
        )
        adapter._update_session(
            agent_id,
            effective_session_id,
            title=title,
            last_message=reply_text[:60],
            profile=profile,
            toolsets=active_toolsets,
        )

        if is_stream:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "keep-alive")
            self.end_headers()
            if reply_thought:
                self.wfile.write(
                    f"event: thought\ndata: {json.dumps({'text': reply_thought})}\n\n".encode(
                        "utf-8"
                    )
                )
            for t in reply_tools or []:
                self.wfile.write(
                    f"event: tool\ndata: {json.dumps(t)}\n\n".encode("utf-8")
                )
            self.wfile.write(
                f"event: done\ndata: {json.dumps(response_data)}\n\n".encode("utf-8")
            )
            self.wfile.flush()
            return

        self._json(200, {"success": True, "data": response_data})


class WangsaMobileAdapter(BasePlatformAdapter):
    """Inbound REST adapter for the Wangsa Flutter mobile app."""

    def __init__(self, config, **kwargs):
        platform = Platform("wangsa_mobile")
        super().__init__(config=config, platform=platform)

        extra = getattr(config, "extra", {}) or {}
        self.port = int(
            os.getenv("WANGSA_MOBILE_PORT") or extra.get("port", _DEFAULT_PORT)
        )
        self.host = resolve_bind_host()

        self._httpd: Optional[_WangsaMobileServer] = None
        self._server_thread: Optional[threading.Thread] = None
        self._loop: Optional[asyncio.AbstractEventLoop] = None

        self._rate_limiter = _RateLimiter()

        # Pending reply futures, keyed by chat_id (our per-session thread id).
        # FIFO queue per chat_id mirrors a2a's _pending_order — see module
        # docstring for why we key by chat_id rather than message_id.
        self._pending: Dict[str, Future] = {}
        self._pending_order: Dict[str, deque] = {}
        self._pending_lock = threading.Lock()
        # message_id -> chat_id, so on_processing_complete (which only knows
        # the event, i.e. message_id) can resolve the right chat_id's queue.
        self._message_chat: Dict[str, str] = {}

        # Per-turn reply buffer, keyed by chat_id. send()/send_image_file()/
        # send_image()/send_document()/send_voice() write into this instead
        # of resolving directly — see the module docstring's "Outbound
        # images/files/audio" section for why.
        self._pending_reply_text: Dict[str, str] = {}
        self._pending_reply_images: Dict[str, list] = {}
        self._pending_reply_files: Dict[str, list] = {}
        self._pending_reply_thoughts: Dict[str, list] = {}
        self._pending_reply_tools: Dict[str, list] = {}
        self._mobile_sessions: Dict[tuple, dict] = {}
        self._profile_lock = threading.Lock()
        self._reply_timers: Dict[str, threading.Timer] = {}

    @property
    def name(self) -> str:
        return "Wangsa Mobile"

    @property
    def authorization_is_upstream(self) -> bool:
        """Bearer-token auth (or localhost-only bind) already gates every
        POST in the HTTP handler — identity is authorized upstream, same
        rationale as A2AAdapter.authorization_is_upstream."""
        return True

    # ── Profiles (one gateway, one profile per user token) ─────────────────

    def _source_for(
        self,
        chat_id: str,
        chat_name: str,
        profile: Optional[str],
        **kwargs: Any,
    ):
        """Build the SessionSource for a mobile chat, pinned to *profile*.

        ``build_source`` only resolves a profile from ``profile_routes``, which
        can never match a per-session ``chat_id``; the bearer token is the
        identity here, so stamp it explicitly. The gateway then namespaces the
        session key and runs the turn in that profile's home.
        """
        source_kwargs = {
            "chat_id": chat_id,
            "chat_name": chat_name,
            "chat_type": "dm",
            "user_id": chat_id,
            **kwargs,
        }
        # A mobile app can be newer than the gateway runtime it connects to
        # (for example a desktop-managed ~/.hermes installation). Older
        # BasePlatformAdapter.build_source versions do not accept user_bio;
        # passing it through raises before the message is dispatched, making
        # the client see a dropped connection instead of an API error.
        parameters = inspect.signature(self.build_source).parameters
        accepts_kwargs = any(
            parameter.kind is inspect.Parameter.VAR_KEYWORD
            for parameter in parameters.values()
        )
        supported_kwargs = (
            source_kwargs
            if accepts_kwargs
            else {key: value for key, value in source_kwargs.items() if key in parameters}
        )
        source = self.build_source(**supported_kwargs)
        if "user_bio" in source_kwargs and "user_bio" not in parameters:
            # Newer SessionSource objects can still carry the field even when
            # an older build_source helper has not learned to forward it.
            try:
                source.user_bio = source_kwargs["user_bio"]
            except AttributeError:
                pass
        if profile:
            source.profile = profile
        return source

    def _profile_context(self, profile: Optional[str]):
        """Return a context manager that scopes a request to *profile*.

        Raises :class:`_ProfileUnavailable` (fail closed) when a named profile
        is requested but the gateway is not multiplexing or does not serve it:
        running the request in the default profile instead would silently mix
        one user's data and credentials into another's.
        """
        from contextlib import nullcontext

        from agent.secret_scope import is_multiplex_active

        multiplex = is_multiplex_active()
        if profile is None:
            if not multiplex:
                return nullcontext()
            # Multiplexing makes unscoped credential reads fail closed, so the
            # default profile needs its own scope too.
            from gateway.run import _profile_runtime_scope
            try:
                from wangsa_constants import get_hermes_home
            except ImportError:
                from hermes_constants import get_hermes_home

            return _profile_runtime_scope(get_hermes_home())
        if not multiplex:
            raise _ProfileUnavailable(
                "per-user tokens require gateway.multiplex_profiles: true "
                "(set GATEWAY_MULTIPLEX_PROFILES=1)"
            )
        from gateway.run import _profile_runtime_scope

        return _profile_runtime_scope(self._ensure_profile(profile))

    def _ensure_profile(self, profile: str) -> Path:
        """Return the profile's home, creating an empty profile on first use.

        A new user therefore starts from a blank profile (no keys, no memory)
        and is guided through setup, instead of inheriting anyone's config.
        """
        try:
            from wangsa_cli.profiles import (
                create_profile,
                get_profile_dir,
                profile_exists,
                profiles_to_serve,
            )
        except ImportError:
            from hermes_cli.profiles import (
                create_profile,
                get_profile_dir,
                profile_exists,
                profiles_to_serve,
            )

        with self._profile_lock:
            if not profile_exists(profile):
                try:
                    create_profile(profile, no_alias=True)
                except FileExistsError:
                    pass
                except Exception as e:
                    logger.warning(
                        "wangsa_mobile: could not create profile %r", profile, exc_info=True
                    )
                    raise _ProfileUnavailable(f"could not create profile {profile!r}") from e
            try:
                from gateway.run import _gateway_runner_ref

                runner = _gateway_runner_ref()
            except Exception as e:
                runner = None
            if runner is None:
                # No live gateway runner (unit tests, standalone HTTP harness):
                # profile was just created/verified above, served-set check is
                # deferred to first use under _profile_context.
                return get_profile_dir(profile)
            try:
                cfg = getattr(runner, "config", None)
                served = {
                    name
                    for name, _home in profiles_to_serve(
                        multiplex=True,
                        profile_allowlist=getattr(cfg, "multiplex_profile_allowlist", None),
                    )
                }
            except Exception as e:
                raise _ProfileUnavailable("could not determine served profiles") from e
            if profile not in served:
                raise _ProfileUnavailable(f"profile {profile!r} is not served by this gateway")
            return get_profile_dir(profile)

    # ── Sessions ───────────────────────────────────────────────────────────

    def _update_session(
        self,
        agent_id: str,
        session_id: str,
        title: str = "",
        last_message: str = "",
        profile: Optional[str] = None,
        toolsets: Optional[list[str]] = None,
    ) -> None:
        if not session_id:
            return
        key = (profile or "", session_id)
        with self._pending_lock:
            existing = self._mobile_sessions.get(key)
            now_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            if existing is None:
                self._mobile_sessions[key] = {
                    "sessionId": session_id,
                    "agentId": agent_id,
                    "title": title or "Percakapan baru",
                    "lastMessage": last_message,
                    "updatedAt": now_iso,
                    "turnCount": 1,
                    "toolsets": sorted(set(toolsets or [])),
                }
            else:
                if last_message:
                    existing["lastMessage"] = last_message
                existing["updatedAt"] = now_iso
                existing["turnCount"] = existing.get("turnCount", 1) + 1
                if toolsets is not None:
                    existing.setdefault("toolsets", sorted(set(toolsets)))

    def _session_toolsets(
        self, session_id: str, profile: Optional[str] = None
    ) -> Optional[list[str]]:
        with self._pending_lock:
            session = self._mobile_sessions.get((profile or "", session_id))
            if session is None or "toolsets" not in session:
                return None
            return list(session["toolsets"])

    def _list_sessions(self, agent_id: str, profile: Optional[str] = None) -> list[dict]:
        owner = profile or ""
        with self._pending_lock:
            sessions = [
                dict(s)
                for (session_owner, _sid), s in self._mobile_sessions.items()
                if session_owner == owner
                and (s.get("agentId") == agent_id or not s.get("agentId"))
            ]
        sessions.sort(key=lambda s: s.get("updatedAt", ""), reverse=True)
        return sessions

    def _delete_session(
        self, agent_id: str, session_id: str, profile: Optional[str] = None
    ) -> bool:
        with self._pending_lock:
            removed = self._mobile_sessions.pop((profile or "", session_id), None)
            return removed is not None

    def _get_session_messages(
        self, agent_id: str, session_id: str, profile: Optional[str] = None
    ) -> list:
        """Load the persisted transcript for a mobile session as
        ``[{"role": "user"|"agent", "content": "..."}, ...]``.

        ``_mobile_sessions`` only ever held a lightweight title/last-message
        summary for the drawer list — it was never the transcript, so
        switching to a past session in the app showed an empty chat even
        though the server-side conversation was intact and the app kept
        replying into it. The real transcript lives in the gateway's
        SessionDB under the same ``mobile:{agent_id}:{session_id}`` routing
        key every other handler here uses (``_dispatch_and_wait``,
        ``_apply_model_override``) — resolve that key the same way, then
        read the messages back. Returns ``[]`` (never raises/404s) on any
        resolution failure — a session the client already knows about from
        ``GET /sessions`` must not look like it vanished just because
        history couldn't be read back.
        """
        try:
            from gateway.run import _gateway_runner_ref

            runner = _gateway_runner_ref()
        except Exception:
            runner = None
        if runner is None:
            return []

        chat_id = _chat_id(agent_id, session_id, profile)
        try:
            source = self._source_for(
                chat_id, f"wangsa-mobile:{agent_id}", profile, user_name="mobile"
            )
            try:
                session_key = runner._session_key_for_source(source)
            except Exception:
                from gateway.session import build_session_key

                session_key = build_session_key(source)

            store = getattr(runner, "session_store", None)
            if store is None:
                return []
            db_session_id = store.peek_session_id(session_key)
            if not db_session_id:
                return []

            db = store._db
            if db is None:
                return []
            rows = db.get_messages_as_conversation(db_session_id)
        except Exception:
            logger.debug(
                "wangsa_mobile: failed to load session history for %s", session_id, exc_info=True
            )
            return []

        turns = []
        for row in rows:
            role = row.get("role")
            if role not in ("user", "assistant"):
                continue
            content = row.get("content")
            if isinstance(content, list):
                text = "\n".join(
                    str(part.get("text") or "")
                    for part in content
                    if isinstance(part, dict) and part.get("type") == "text"
                ).strip()
            else:
                text = str(content or "").strip()
            if not text:
                continue
            turns.append({"role": "user" if role == "user" else "agent", "content": text})
        return turns

    # ── Lifecycle ─────────────────────────────────────────────────────────

    async def connect(self, **_kwargs) -> bool:
        try:
            self._loop = asyncio.get_running_loop()
        except RuntimeError:
            self._loop = None

        try:
            self._httpd = _WangsaMobileServer(
                (self.host, self.port), WangsaMobileRequestHandler, self
            )
        except OSError as e:
            logger.error(
                "wangsa_mobile: could not bind %s:%s — %s", self.host, self.port, e
            )
            self._set_fatal_error(
                "bind_failed", f"wangsa_mobile bind failed: {e}", retryable=True
            )
            return False

        self._server_thread = threading.Thread(
            target=self._httpd.serve_forever,
            name="wangsa-mobile-http",
            daemon=True,
        )
        self._server_thread.start()

        self._mark_connected()

        exposure = "localhost-only" if localhost_only() else "REMOTE (bearer auth)"
        logger.info(
            "wangsa_mobile: serving REST API on http://%s:%s (%s)",
            self.host,
            self.port,
            exposure,
        )
        return True

    async def disconnect(self) -> None:
        self._mark_disconnected()
        if self._httpd is not None:
            try:
                self._httpd.shutdown()
                self._httpd.server_close()
            except Exception:
                pass
            self._httpd = None
        with self._pending_lock:
            for fut in self._pending.values():
                if not fut.done():
                    fut.set_result((
                        "failed",
                        {
                            "text": "[agent shutting down]",
                            "images": [],
                            "files": [],
                            "thought": "",
                            "tool_calls": [],
                        },
                    ))
            self._pending.clear()
            self._pending_order.clear()
            self._message_chat.clear()
            timers = list(self._reply_timers.values())
            self._reply_timers.clear()
            self._pending_reply_text.clear()
            self._pending_reply_images.clear()
            self._pending_reply_files.clear()
            self._pending_reply_thoughts.clear()
            self._pending_reply_tools.clear()
        for timer in timers:
            timer.cancel()

    # ── Pending reply plumbing ────────────────────────────────────────────

    def _add_pending(self, message_id: str, chat_id: str) -> Future:
        fut: Future = Future()
        with self._pending_lock:
            self._pending[message_id] = fut
            self._pending_order.setdefault(chat_id, deque()).append(message_id)
            self._message_chat[message_id] = chat_id
        return fut

    def _pop_pending(self, message_id: str) -> None:
        with self._pending_lock:
            chat_id = self._message_chat.pop(message_id, None)
            self._pending.pop(message_id, None)
            if chat_id is not None:
                order = self._pending_order.get(chat_id)
                if order:
                    try:
                        order.remove(message_id)
                    except ValueError:
                        pass
                    if not order:
                        self._pending_order.pop(chat_id, None)

    def _resolve_message(self, message_id: str, state: str, payload: dict) -> bool:
        with self._pending_lock:
            fut = self._pending.get(message_id)
            if fut and not fut.done():
                fut.set_result((state, payload))
                return True
        return False

    def _resolve_oldest_for_chat(self, chat_id: str, state: str, payload: dict) -> bool:
        with self._pending_lock:
            for message_id in self._pending_order.get(chat_id, ()):
                fut = self._pending.get(message_id)
                if fut and not fut.done():
                    fut.set_result((state, payload))
                    return True
        return False

    # ── Outbound reply buffering (see module docstring) ───────────────────

    def _buffer_text(self, chat_id: str, content: str) -> None:
        if not content:
            return
        with self._pending_lock:
            existing = self._pending_reply_text.get(chat_id, "")
            self._pending_reply_text[chat_id] = (
                f"{existing}\n{content}" if existing else content
            )
        self._arm_fallback_resolve(chat_id)

    def _buffer_image(self, chat_id: str, image: dict) -> None:
        with self._pending_lock:
            self._pending_reply_images.setdefault(chat_id, []).append(image)
        self._arm_fallback_resolve(chat_id)

    def _buffer_file(self, chat_id: str, file: dict) -> None:
        with self._pending_lock:
            self._pending_reply_files.setdefault(chat_id, []).append(file)
        self._arm_fallback_resolve(chat_id)

    def _buffer_thought(self, chat_id: str, thought: str) -> None:
        if not thought:
            return
        with self._pending_lock:
            self._pending_reply_thoughts.setdefault(chat_id, []).append(thought)
        self._arm_fallback_resolve(chat_id)

    def _buffer_tool(self, chat_id: str, tool_info: dict) -> None:
        with self._pending_lock:
            self._pending_reply_tools.setdefault(chat_id, []).append(tool_info)
        self._arm_fallback_resolve(chat_id)

    def _pop_reply_buffer(self, chat_id: str) -> tuple:
        with self._pending_lock:
            text = self._pending_reply_text.pop(chat_id, "")
            images = self._pending_reply_images.pop(chat_id, [])
            files = self._pending_reply_files.pop(chat_id, [])
            thoughts = self._pending_reply_thoughts.pop(chat_id, [])
            tools = self._pending_reply_tools.pop(chat_id, [])
            timer = self._reply_timers.pop(chat_id, None)
        if timer is not None:
            timer.cancel()
        extracted_thought, clean_text = _extract_think_blocks(text)
        if extracted_thought:
            thoughts.insert(0, extracted_thought)
        thought_str = "\n\n".join(t for t in thoughts if t.strip()).strip()
        return clean_text, images, files, thought_str, tools

    def _arm_fallback_resolve(self, chat_id: str) -> None:
        """Safety net for reply paths that never reach on_processing_complete
        — see the module docstring's "Outbound images" section. Debounced:
        each buffered send/image re-arms the timer, so a turn that keeps
        producing output (several images, or HERMES_HUMAN_DELAY_MODE pacing
        between them) keeps pushing the deadline out instead of firing
        mid-turn. A normal agent turn always reaches on_processing_complete
        well within this window, at which point the timer firing later is a
        harmless no-op — the Future is already resolved and popped.
        """
        with self._pending_lock:
            old = self._reply_timers.get(chat_id)
            if old is not None:
                old.cancel()
            timer = threading.Timer(
                _REPLY_COALESCE_SECONDS, self._fallback_resolve, args=(chat_id,)
            )
            timer.daemon = True
            self._reply_timers[chat_id] = timer
        timer.start()

    def _fallback_resolve(self, chat_id: str) -> None:
        text, images, files, thought, tools = self._pop_reply_buffer(chat_id)
        if not text and not images and not files and not thought and not tools:
            return
        self._resolve_oldest_for_chat(
            chat_id,
            "completed",
            {
                "text": text,
                "images": images,
                "files": files,
                "thought": thought,
                "tool_calls": tools,
            },
        )

    # ── Dispatch ──────────────────────────────────────────────────────────

    def _clear_model_override(self, chat_id: str, profile: Optional[str] = None) -> None:
        """Clear per-session model override and evict cached agent."""
        try:
            from gateway.run import _gateway_runner_ref

            runner = _gateway_runner_ref()
        except Exception:
            runner = None
        if runner is None:
            return
        try:
            source = self._source_for(
                chat_id, "wangsa-mobile:model-override", profile, user_name="mobile"
            )
            try:
                session_key = runner._session_key_for_source(source)
            except Exception:
                from gateway.session import build_session_key

                session_key = build_session_key(source)
            if hasattr(runner, "_session_model_overrides") and isinstance(runner._session_model_overrides, dict):
                runner._session_model_overrides.pop(session_key, None)
                runner._session_model_overrides.pop(chat_id, None)
            try:
                if hasattr(runner, "_session_state"):
                    s = runner._session_state(session_key)
                    if s and hasattr(s, "conversation") and hasattr(s.conversation, "model_override"):
                        s.conversation.model_override = None
            except Exception:
                pass
            try:
                if hasattr(runner, "_session_store") and runner._session_store:
                    runner._session_store.clear_model_override(session_key)
            except Exception:
                pass
            if hasattr(runner, "_evict_cached_agent"):
                runner._evict_cached_agent(session_key)
        except Exception:
            logger.debug("wangsa_mobile: _clear_model_override failed", exc_info=True)

    def _apply_model_override(
        self,
        chat_id: str,
        model: str,
        provider: Optional[str] = None,
        profile: Optional[str] = None,
    ) -> Optional[str]:
        """Validate *model* against the catalog and persist a per-session
        override (same mechanism as the ``/model`` slash command).

        Returns an error string on validation failure, else None. The
        override holds only non-secret keys (model/provider); credentials
        are re-resolved at runtime like every other session override].
        Without a live gateway runner (unit tests) validation is skipped
        and the choice is accepted so dispatch can proceed.
        """
        target_provider: Optional[str] = provider
        try:
            try:
                from hermes_cli.inventory import build_models_payload, load_picker_context
            except ImportError:
                from wangsa_cli.inventory import build_models_payload, load_picker_context

            try:
                payload = build_models_payload(load_picker_context(), include_unconfigured=True)
            except TypeError:
                payload = build_models_payload(load_picker_context())
        except Exception:
            logger.debug("wangsa_mobile: model catalog unavailable", exc_info=True)
            return "could not validate model"
        rows = [r for r in (payload.get("providers") or []) if isinstance(r, dict)]
        for row in rows:
            if str(row.get("slug") or "") == "opencode-free":
                row["models"] = _opencode_free_model_ids()
        current_provider = str(payload.get("provider") or "")
        current_model = str(payload.get("model") or "")
        if provider:
            row = next(
                (
                    r
                    for r in rows
                    if str(r.get("slug") or "").lower() == provider.lower()
                ),
                None,
            )
            if row is None:
                return f"unknown provider '{provider}'"
            if model not in (row.get("models") or []):
                return f"model '{model}' is not available from provider '{provider}'"
            target_provider = str(row.get("slug") or provider)
        else:
            if current_provider:
                cur_row = next(
                    (r for r in rows if str(r.get("slug") or "") == current_provider),
                    None,
                )
                if cur_row is not None and model in (cur_row.get("models") or []):
                    target_provider = current_provider
            if target_provider is None:
                for r in rows:
                    if model in (r.get("models") or []):
                        target_provider = str(r.get("slug") or "")
                        break
            if target_provider is None:
                return f"unknown model '{model}'"

        override: Dict[str, Any] = {"model": model}
        if target_provider:
            override["provider"] = target_provider

        try:
            try:
                from hermes_cli.model_switch import switch_model
            except ImportError:
                try:
                    from wangsa_cli.model_switch import switch_model
                except ImportError:
                    switch_model = None

            if switch_model is not None:
                res = switch_model(
                    model,
                    current_provider=current_provider,
                    current_model=current_model,
                    explicit_provider=target_provider,
                )
                if res.success:
                    if res.new_model:
                        override["model"] = res.new_model
                    if res.target_provider:
                        override["provider"] = res.target_provider
                    if res.api_key:
                        override["api_key"] = res.api_key
                    if res.base_url:
                        override["base_url"] = res.base_url
                    if res.api_mode:
                        override["api_mode"] = res.api_mode
        except Exception:
            logger.debug("wangsa_mobile: switch_model resolution failed", exc_info=True)

        try:
            from gateway.run import _gateway_runner_ref

            runner = _gateway_runner_ref()
        except Exception:
            runner = None
        if runner is None:
            return None
        try:
            source = self._source_for(
                chat_id, "wangsa-mobile:model-override", profile, user_name="mobile"
            )
            try:
                session_key = runner._session_key_for_source(source)
            except Exception:
                from gateway.session import build_session_key

                session_key = build_session_key(source)

            if not hasattr(runner, "_session_model_overrides"):
                runner._session_model_overrides = {}
            runner._session_model_overrides[session_key] = dict(override)

            sess_state = runner._session_state(session_key)
            if sess_state and hasattr(sess_state, "conversation"):
                sess_state.conversation.model_override = dict(override)

            try:
                store = getattr(runner, "session_store", None)
                if store is not None:
                    try:
                        store.get_or_create_session(source)
                    except Exception:
                        pass
                    store.set_model_override(session_key, override)
            except Exception:
                logger.debug(
                    "wangsa_mobile: persist model override failed", exc_info=True
                )
            try:
                runner._evict_cached_agent(session_key)
            except Exception:
                pass
        except Exception:
            logger.debug("wangsa_mobile: apply model override failed", exc_info=True)
            return "could not apply model"
        return None

    def _dispatch_and_wait(
        self,
        agent_id: str,
        chat_id: str,
        message: str,
        media_urls: Optional[list] = None,
        media_types: Optional[list] = None,
        user_name: Optional[str] = None,
        user_bio: Optional[str] = None,
        profile: Optional[str] = None,
        toolsets: Optional[list[str]] = None,
    ) -> tuple:
        """Runs on an HTTP worker thread. Returns (state, payload_dict)."""
        if self._loop is None or self._message_handler is None:
            return "failed", {
                "text": "agent gateway not ready",
                "images": [],
                "files": [],
                "thought": "",
                "tool_calls": [],
            }

        message_id = uuid.uuid4().hex
        fut = self._add_pending(message_id, chat_id)

        source = self._source_for(
            chat_id,
            f"wangsa-mobile:{agent_id}",
            profile,
            user_name=user_name or "mobile",
            user_bio=user_bio,
        )
        # Transport-only metadata: the gateway consumes it before AIAgent
        # construction; it is intentionally excluded from session identity.
        source._wangsa_mobile_toolsets = sorted(set(toolsets or []))
        event = MessageEvent(
            text=message,
            message_type=MessageType.TEXT,
            source=source,
            message_id=message_id,
            media_urls=list(media_urls or []),
            media_types=list(media_types or []),
        )

        try:
            asyncio.run_coroutine_threadsafe(self.handle_message(event), self._loop)
        except Exception as e:
            self._pop_pending(message_id)
            return "failed", {
                "text": f"dispatch failed: {e}",
                "images": [],
                "files": [],
                "thought": "",
                "tool_calls": [],
            }

        try:
            state, payload = fut.result(timeout=_reply_timeout())
        except FuturesTimeout:
            # Leave the pending future registered — on_processing_complete()
            # or a late send() may still resolve it once the agent finishes;
            # disconnect()/normal GC will eventually clean it up if not.
            return "timeout", {
                "text": "",
                "images": [],
                "files": [],
                "thought": "",
                "tool_calls": [],
            }
        finally:
            pass
        self._pop_pending(message_id)
        if not isinstance(payload, dict):
            payload = {
                "text": str(payload or ""),
                "images": [],
                "files": [],
                "thought": "",
                "tool_calls": [],
            }
        return state, payload

    # ── Sending (the agent's reply path) ──────────────────────────────────

    async def send(
        self,
        chat_id: str,
        content: str,
        reply_to: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
    ):
        """Buffer this turn's text — only sends carrying the gateway's
        final-reply marker (``metadata['notify']``) count, same rule as
        A2AAdapter.send(). Does NOT resolve the pending Future directly; see
        the module docstring's "Outbound images" section for why.
        """
        message_id = uuid.uuid4().hex
        if not (metadata or {}).get("notify"):
            logger.debug("wangsa_mobile: ignoring non-final send for chat %s", chat_id)
            return SendResult(success=True, message_id=message_id)
        self._buffer_text(chat_id, content or "")
        return SendResult(success=True, message_id=message_id)

    async def send_image_file(
        self,
        chat_id: str,
        image_path: str,
        caption: Optional[str] = None,
        reply_to: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
        **kwargs,
    ) -> SendResult:
        """Buffer a local image (screenshot, image_gen output, ...) the
        agent produced this turn, base64-encoded for the JSON reply. See
        the module docstring's "Outbound images" section."""
        message_id = uuid.uuid4().hex
        if not (metadata or {}).get("notify"):
            return SendResult(success=True, message_id=message_id)
        image = _encode_local_image(image_path)
        if image is None:
            logger.warning(
                "wangsa_mobile: could not read outbound image %s", image_path
            )
            if caption:
                self._buffer_text(chat_id, caption)
            return SendResult(
                success=False, message_id=message_id, error="image unreadable"
            )
        if caption:
            image["caption"] = caption
        self._buffer_image(chat_id, image)
        return SendResult(success=True, message_id=message_id)

    async def send_image(
        self,
        chat_id: str,
        image_url: str,
        caption: Optional[str] = None,
        reply_to: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> SendResult:
        """Buffer a remote image URL (e.g. markdown ``![alt](https://...)``
        in the agent's response) for the JSON reply — the client fetches it
        directly rather than the server downloading and re-embedding it."""
        message_id = uuid.uuid4().hex
        if not (metadata or {}).get("notify"):
            return SendResult(success=True, message_id=message_id)
        image: Dict[str, str] = {"url": image_url}
        if caption:
            image["caption"] = caption
        self._buffer_image(chat_id, image)
        return SendResult(success=True, message_id=message_id)

    async def send_document(
        self,
        chat_id: str,
        file_path: str,
        caption: Optional[str] = None,
        file_name: Optional[str] = None,
        reply_to: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
        **kwargs,
    ) -> SendResult:
        """Buffer a local document (PDF, CSV, generic MEDIA: output, ...)
        the agent produced this turn, base64-encoded for the JSON reply's
        ``files`` array with ``kind: \"document\"``."""
        message_id = uuid.uuid4().hex
        if not (metadata or {}).get("notify"):
            return SendResult(success=True, message_id=message_id)
        file = _encode_local_file(file_path, kind="document")
        if file is None:
            logger.warning(
                "wangsa_mobile: could not read outbound document %s", file_path
            )
            if caption:
                self._buffer_text(chat_id, caption)
            return SendResult(
                success=False, message_id=message_id, error="file unreadable"
            )
        if file_name:
            file["filename"] = file_name
        if caption:
            file["caption"] = caption
        self._buffer_file(chat_id, file)
        return SendResult(success=True, message_id=message_id)

    async def send_voice(
        self,
        chat_id: str,
        audio_path: str,
        caption: Optional[str] = None,
        reply_to: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
        **kwargs,
    ) -> SendResult:
        """Buffer a local audio clip (TTS output, voice reply, ...) the
        agent produced this turn, base64-encoded for the JSON reply's
        ``files`` array with ``kind: \"audio\"``."""
        message_id = uuid.uuid4().hex
        if not (metadata or {}).get("notify"):
            return SendResult(success=True, message_id=message_id)
        file = _encode_local_file(audio_path, kind="audio")
        if file is None:
            logger.warning(
                "wangsa_mobile: could not read outbound audio %s", audio_path
            )
            if caption:
                self._buffer_text(chat_id, caption)
            return SendResult(
                success=False, message_id=message_id, error="audio unreadable"
            )
        if caption:
            file["caption"] = caption
        self._buffer_file(chat_id, file)
        return SendResult(success=True, message_id=message_id)

    def format_tool_event(
        self,
        event: Any,
        *,
        mode: str = "all",
        preview_max_len: int = 40,
    ) -> Optional[str]:
        from gateway.stream_events import ToolCallChunk

        if isinstance(event, ToolCallChunk):
            tool_name = getattr(event, "tool_name", "") or ""
            preview = getattr(event, "preview", "") or ""
            args = getattr(event, "args", {}) or {}
            if not preview and args:
                preview = f"{tool_name}({list(args.keys())})"
            tool_entry = {
                "tool": tool_name,
                "preview": preview,
                "status": "completed",
            }
            with self._pending_lock:
                for c_id in list(self._pending_order.keys()):
                    self._buffer_tool(c_id, tool_entry)
                    break
        return super().format_tool_event(
            event, mode=mode, preview_max_len=preview_max_len
        )

    def render_message_event(self, event: Any, sink: Any) -> None:
        from gateway.stream_events import Commentary

        chat_id = getattr(sink, "chat_id", None)
        if chat_id is None:
            with self._pending_lock:
                for c_id in list(self._pending_order.keys()):
                    chat_id = c_id
                    break
        if isinstance(event, Commentary) and getattr(event, "text", "") and chat_id:
            self._buffer_thought(chat_id, event.text)
        super().render_message_event(event, sink)

    async def on_processing_complete(
        self, event: MessageEvent, outcome: ProcessingOutcome
    ) -> None:
        """Flush this turn's buffered text/images/files and resolve the Future.

        This is the actual resolution point for a normal agent turn (see
        the module docstring) — ``send()``/``send_image_file()``/
        ``send_image()``/``send_document()``/``send_voice()`` only buffer,
        they never resolve directly.
        """
        message_id = str(getattr(event, "message_id", "") or "")
        if not message_id:
            return
        with self._pending_lock:
            chat_id = self._message_chat.get(message_id)
        if outcome == ProcessingOutcome.FAILURE:
            if chat_id:
                self._pop_reply_buffer(chat_id)
            self._resolve_message(
                message_id,
                "failed",
                {
                    "text": "[agent processing failed]",
                    "images": [],
                    "files": [],
                    "thought": "",
                    "tool_calls": [],
                },
            )
        elif outcome == ProcessingOutcome.CANCELLED:
            if chat_id:
                self._pop_reply_buffer(chat_id)
            self._resolve_message(
                message_id,
                "failed",
                {
                    "text": "[cancelled]",
                    "images": [],
                    "files": [],
                    "thought": "",
                    "tool_calls": [],
                },
            )
        else:
            text, images, files, thought, tools = (
                self._pop_reply_buffer(chat_id) if chat_id else ("", [], [], "", [])
            )
            self._resolve_message(
                message_id,
                "completed",
                {
                    "text": text,
                    "images": images,
                    "files": files,
                    "thought": thought,
                    "tool_calls": tools,
                },
            )

    async def send_typing(self, chat_id: str, metadata=None) -> None:
        return None

    async def get_chat_info(self, chat_id: str) -> Dict[str, Any]:
        return {"name": chat_id, "type": "dm"}

    def toolsets_for_source(self, source: Any) -> list[str]:
        """Return capabilities fixed at the start of this mobile session."""
        return list(getattr(source, "_wangsa_mobile_toolsets", []) or [])
