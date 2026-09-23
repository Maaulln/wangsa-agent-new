"""
Wangsa Mobile inbound platform adapter — exposes Hermes to the Wangsa Flutter
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
  chat_id (our per-session Hermes thread id), with a FIFO queue per chat_id
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
import json
import logging
import os
import re
import threading
import time
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

_AGENT_ID_RE = re.compile(
    r"^/api/v1/agents/([^/]+)(/(messages(/stream)?|models|sessions(/[^/]+)?))?/?$"
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


def localhost_only() -> bool:
    """True when no bearer token is configured — mirrors a2a.security."""
    return not _bearer_token()


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

    def do_GET(self):  # noqa: N802
        m = _AGENT_ID_RE.match(self.path.split("?", 1)[0])
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
            sessions = self.adapter._list_sessions(agent_id)
            self._json(200, {"success": True, "data": {"sessions": sessions}})
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

    def do_DELETE(self):  # noqa: N802
        m = _AGENT_ID_RE.match(self.path.split("?", 1)[0])
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
            deleted = self.adapter._delete_session(agent_id, session_id)
            self._json(200, {"success": True, "data": {"deleted": deleted}})
            return
        self._json(
            404,
            {"success": False, "error": {"code": "NOT_FOUND", "message": "not found"}},
        )

    def _handle_models(self, agent_id: str) -> None:  # noqa: ARG002
        """Serve the model picker payload for the current provider.

        Uses the same ``build_model_options_payload(load_picker_context())``
        substrate as the dashboard's ``/api/model/options`` and the TUI
        ``ModelPickerDialog`` — no new model-listing logic. Responds with
        the narrow mobile shape: provider, current model, and that
        provider's model ids.
        """
        try:
            from wangsa_cli.inventory import (
                build_model_options_payload,
                load_picker_context,
            )

            payload = build_model_options_payload(load_picker_context())
        except Exception:
            logger.debug("wangsa_mobile: model options build failed", exc_info=True)
            self._error(502, "RUNTIME_ERROR", "failed to list models")
            return
        provider = str(payload.get("provider") or "")
        current = str(payload.get("model") or "")
        models: list = []
        try:
            for row in payload.get("providers") or []:
                if not isinstance(row, dict):
                    continue
                if str(row.get("slug") or "") == provider:
                    models = [str(m) for m in (row.get("models") or [])]
                    break
        except Exception:
            logger.debug("wangsa_mobile: model row extraction failed", exc_info=True)
            models = []
        self._json(
            200,
            {
                "success": True,
                "data": {"provider": provider, "current": current, "models": models},
            },
        )

    def do_POST(self):  # noqa: N802
        adapter = self.adapter
        path = self.path.split("?", 1)[0]
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

        # Bearer auth only on POST /messages; GET /agents/:id stays open.
        token = _bearer_token()
        if token:
            auth = self.headers.get("Authorization", "")
            presented = ""
            parts = auth.split(None, 1)
            if len(parts) == 2 and parts[0].lower() == "bearer":
                presented = parts[1].strip()
            import hmac as _hmac

            if not presented or not _hmac.compare_digest(presented, token):
                self._error(401, "UNAUTHORIZED", "missing or invalid bearer token")
                return

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
        thread_id = f"mobile:{agent_id}:{effective_session_id or 'anon'}"

        if model is not None:
            err = adapter._apply_model_override(thread_id, model, provider)
            if err:
                self._error(400, "VALIDATION_ERROR", err)
                return

        state, reply = adapter._dispatch_and_wait(
            agent_id,
            thread_id,
            message,
            media_urls=media_urls,
            media_types=media_types,
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
            agent_id, effective_session_id, title=title, last_message=reply_text[:60]
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
        self._mobile_sessions: Dict[str, dict] = {}
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

    # ── Sessions ───────────────────────────────────────────────────────────

    def _update_session(
        self,
        agent_id: str,
        session_id: str,
        title: str = "",
        last_message: str = "",
    ) -> None:
        if not session_id:
            return
        with self._pending_lock:
            existing = self._mobile_sessions.get(session_id)
            now_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            if existing is None:
                self._mobile_sessions[session_id] = {
                    "sessionId": session_id,
                    "agentId": agent_id,
                    "title": title or "Percakapan baru",
                    "lastMessage": last_message,
                    "updatedAt": now_iso,
                    "turnCount": 1,
                }
            else:
                if last_message:
                    existing["lastMessage"] = last_message
                existing["updatedAt"] = now_iso
                existing["turnCount"] = existing.get("turnCount", 1) + 1

    def _list_sessions(self, agent_id: str) -> list[dict]:
        with self._pending_lock:
            sessions = [
                dict(s)
                for s in self._mobile_sessions.values()
                if s.get("agentId") == agent_id or not s.get("agentId")
            ]
        sessions.sort(key=lambda s: s.get("updatedAt", ""), reverse=True)
        return sessions

    def _delete_session(self, agent_id: str, session_id: str) -> bool:
        with self._pending_lock:
            removed = self._mobile_sessions.pop(session_id, None)
            return removed is not None

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

    def _apply_model_override(
        self,
        chat_id: str,
        model: str,
        provider: Optional[str] = None,
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
            from wangsa_cli.inventory import build_models_payload, load_picker_context

            payload = build_models_payload(load_picker_context())
        except Exception:
            logger.debug("wangsa_mobile: model catalog unavailable", exc_info=True)
            return "could not validate model"
        rows = [r for r in (payload.get("providers") or []) if isinstance(r, dict)]
        current_provider = str(payload.get("provider") or "")
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

        try:
            from gateway.run import _gateway_runner_ref

            runner = _gateway_runner_ref()
        except Exception:
            runner = None
        if runner is None:
            return None
        try:
            source = self.build_source(
                chat_id=chat_id,
                chat_name="wangsa-mobile:model-override",
                chat_type="dm",
                user_id=chat_id,
                user_name="mobile",
            )
            try:
                session_key = runner._session_key_for_source(source)
            except Exception:
                from gateway.session import build_session_key

                session_key = build_session_key(source)
            override: Dict[str, str] = {"model": model}
            if target_provider:
                override["provider"] = target_provider
            runner._session_state(session_key).conversation.model_override = dict(
                override
            )
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

        event = MessageEvent(
            text=message,
            message_type=MessageType.TEXT,
            source=self.build_source(
                chat_id=chat_id,
                chat_name=f"wangsa-mobile:{agent_id}",
                chat_type="dm",
                user_id=chat_id,
                user_name="mobile",
            ),
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
