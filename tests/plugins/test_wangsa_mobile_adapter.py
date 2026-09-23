"""Tests for the Wangsa Mobile platform plugin (REST adapter for the Flutter app).

Modeled on tests/plugins/test_a2a_plugin.py's end-to-end round trip: spins up
the real adapter with a mocked agent handler on a free port, and drives it
with urllib.request against the two real REST routes.
"""

from __future__ import annotations

import asyncio
import json
import socket
import urllib.error
import urllib.request
import base64

from gateway.config import PlatformConfig
from gateway.platforms.base import ProcessingOutcome
from plugins.platforms.wangsa_mobile.adapter import WangsaMobileAdapter


def _free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def _make_live_adapter(monkeypatch, reply_fn=None, port=None):
    """Create an adapter on a free port with a mocked agent handler.

    ``reply_fn(event) -> Optional[str]`` returns the agent's reply text
    (None = never reply, used for the timeout test). Returns (adapter, base_url).
    """
    port = port or _free_port()
    monkeypatch.setenv("WANGSA_MOBILE_PORT", str(port))

    adapter = WangsaMobileAdapter(PlatformConfig(enabled=True))

    async def fake_handle_message(event):
        if reply_fn is None:
            reply = "ECHO: " + event.text
        else:
            reply = reply_fn(event)
        if reply is not None:
            await adapter.send(event.source.chat_id, reply, metadata={"notify": True})

    adapter.handle_message = fake_handle_message  # type: ignore
    adapter._message_handler = object()  # non-None so dispatch proceeds
    return adapter, f"http://127.0.0.1:{port}"


def _get_json(url, headers=None):
    req = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(req, timeout=10) as r:
        return r.status, json.loads(r.read().decode())


def _post_json(url, body, headers=None, timeout=15):
    req = urllib.request.Request(
        url, data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", **(headers or {})}, method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode())


class TestWangsaMobileRoutes:
    def test_get_agent_identity(self, monkeypatch):
        monkeypatch.delenv("WANGSA_MOBILE_BEARER_TOKEN", raising=False)
        monkeypatch.setenv("WANGSA_MOBILE_AGENT_NAME", "Test Agent")
        monkeypatch.setenv("WANGSA_MOBILE_AGENT_PURPOSE", "Testing purposes")
        adapter, base = _make_live_adapter(monkeypatch)

        async def run():
            assert await adapter.connect() is True
            status, data = await asyncio.to_thread(_get_json, base + "/api/v1/agents/abc123")
            assert status == 200
            assert data["success"] is True
            assert data["data"]["id"] == "abc123"
            assert data["data"]["name"] == "Test Agent"
            assert data["data"]["purpose"] == "Testing purposes"

            # Any agentId works — no lookup/validation.
            status2, data2 = await asyncio.to_thread(_get_json, base + "/api/v1/agents/whatever-else")
            assert status2 == 200
            assert data2["data"]["id"] == "whatever-else"

            await adapter.disconnect()

        asyncio.run(run())

    def test_post_message_happy_path(self, monkeypatch):
        monkeypatch.delenv("WANGSA_MOBILE_BEARER_TOKEN", raising=False)
        adapter, base = _make_live_adapter(monkeypatch)

        async def run():
            assert await adapter.connect() is True
            status, data = await asyncio.to_thread(
                _post_json, base + "/api/v1/agents/agent1/messages",
                {"message": "hello there"},
            )
            assert status == 200
            assert data["success"] is True
            assert "ECHO: hello there" in data["data"]["response"]
            assert data["data"]["sessionId"]  # server-generated
            await adapter.disconnect()

        asyncio.run(run())

    def test_post_message_reuses_session_thread_id(self, monkeypatch):
        """Same sessionId across two calls maps to the same internal thread id."""
        monkeypatch.delenv("WANGSA_MOBILE_BEARER_TOKEN", raising=False)
        seen_chat_ids = []

        def reply_fn(event):
            seen_chat_ids.append(event.source.chat_id)
            return "ok: " + event.text

        adapter, base = _make_live_adapter(monkeypatch, reply_fn=reply_fn)

        async def run():
            assert await adapter.connect() is True
            _, d1 = await asyncio.to_thread(
                _post_json, base + "/api/v1/agents/agentX/messages",
                {"message": "first", "sessionId": "sess-abc"},
            )
            _, d2 = await asyncio.to_thread(
                _post_json, base + "/api/v1/agents/agentX/messages",
                {"message": "second", "sessionId": "sess-abc"},
            )
            assert d1["data"]["sessionId"] == "sess-abc"
            assert d2["data"]["sessionId"] == "sess-abc"
            assert len(seen_chat_ids) == 2
            assert seen_chat_ids[0] == seen_chat_ids[1] == "mobile:agentX:sess-abc"
            await adapter.disconnect()

        asyncio.run(run())

    def test_post_message_empty_rejected(self, monkeypatch):
        monkeypatch.delenv("WANGSA_MOBILE_BEARER_TOKEN", raising=False)
        adapter, base = _make_live_adapter(monkeypatch)

        async def run():
            assert await adapter.connect() is True
            status, data = await asyncio.to_thread(
                _post_json, base + "/api/v1/agents/a/messages", {"message": ""},
            )
            assert status == 400
            assert data["success"] is False
            assert data["error"]["code"] == "VALIDATION_ERROR"
            await adapter.disconnect()

        asyncio.run(run())

    def test_post_message_too_long_rejected(self, monkeypatch):
        monkeypatch.delenv("WANGSA_MOBILE_BEARER_TOKEN", raising=False)
        adapter, base = _make_live_adapter(monkeypatch)

        async def run():
            assert await adapter.connect() is True
            status, data = await asyncio.to_thread(
                _post_json, base + "/api/v1/agents/a/messages",
                {"message": "x" * 4001},
            )
            assert status == 400
            assert data["error"]["code"] == "VALIDATION_ERROR"
            await adapter.disconnect()

        asyncio.run(run())

    def test_post_message_ignores_llm_field(self, monkeypatch):
        """The legacy BYOK ``llm`` object is silently ignored (back-compat)."""
        monkeypatch.delenv("WANGSA_MOBILE_BEARER_TOKEN", raising=False)
        adapter, base = _make_live_adapter(monkeypatch)

        async def run():
            assert await adapter.connect() is True
            status, data = await asyncio.to_thread(
                _post_json, base + "/api/v1/agents/a/messages",
                {"message": "hi", "llm": {
                    "baseURL": "https://api.example.com/v1",
                    "apiKey": "kunci",
                    "model": "m/model",
                }},
            )
            assert status == 200
            assert data["success"] is True
            await adapter.disconnect()

        asyncio.run(run())

    def test_post_message_unknown_model_rejected(self, monkeypatch):
        monkeypatch.delenv("WANGSA_MOBILE_BEARER_TOKEN", raising=False)
        import wangsa_cli.inventory as inventory

        monkeypatch.setattr(inventory, "load_picker_context", lambda: object())
        monkeypatch.setattr(inventory, "build_models_payload", lambda ctx: {
            "providers": [{"slug": "testprov", "models": ["model-a"]}],
            "provider": "testprov",
            "model": "model-a",
        })
        adapter, base = _make_live_adapter(monkeypatch)

        async def run():
            assert await adapter.connect() is True
            status, data = await asyncio.to_thread(
                _post_json, base + "/api/v1/agents/a/messages",
                {"message": "hi", "model": "no-such-model-xyz"},
            )
            assert status == 400
            assert data["success"] is False
            assert data["error"]["code"] == "VALIDATION_ERROR"
            await adapter.disconnect()

        asyncio.run(run())

    def test_bearer_token_enforced_on_post(self, monkeypatch):
        monkeypatch.setenv("WANGSA_MOBILE_BEARER_TOKEN", "secret-tok")
        adapter, base = _make_live_adapter(monkeypatch)

        async def run():
            assert await adapter.connect() is True

            # No token -> 401.
            status, data = await asyncio.to_thread(
                _post_json, base + "/api/v1/agents/a/messages", {"message": "hi"},
            )
            assert status == 401
            assert data["success"] is False

            # Wrong token -> 401.
            status2, _ = await asyncio.to_thread(
                _post_json, base + "/api/v1/agents/a/messages", {"message": "hi"},
                headers={"Authorization": "Bearer wrong"},
            )
            assert status2 == 401

            # Correct token -> 200.
            status3, data3 = await asyncio.to_thread(
                _post_json, base + "/api/v1/agents/a/messages", {"message": "hi"},
                headers={"Authorization": "Bearer secret-tok"},
            )
            assert status3 == 200
            assert data3["success"] is True

            # GET route stays open without a token.
            status4, _ = await asyncio.to_thread(_get_json, base + "/api/v1/agents/a")
            assert status4 == 200

            await adapter.disconnect()

        asyncio.run(run())

    def test_get_models_returns_current_provider_row(self, monkeypatch):
        monkeypatch.delenv("WANGSA_MOBILE_BEARER_TOKEN", raising=False)
        import wangsa_cli.inventory as inventory

        monkeypatch.setattr(inventory, "load_picker_context", lambda: object())
        monkeypatch.setattr(
            inventory, "build_model_options_payload",
            lambda ctx: {
                "providers": [
                    {"slug": "testprov", "models": ["model-a", "model-b"]},
                    {"slug": "other", "models": ["model-z"]},
                ],
                "provider": "testprov",
                "model": "model-a",
            },
        )
        adapter, base = _make_live_adapter(monkeypatch)

        async def run():
            assert await adapter.connect() is True
            status, data = await asyncio.to_thread(
                _get_json, base + "/api/v1/agents/agent1/models",
            )
            assert status == 200
            assert data["success"] is True
            assert data["data"]["provider"] == "testprov"
            assert data["data"]["current"] == "model-a"
            assert data["data"]["models"] == ["model-a", "model-b"]

            # Identity route still works; /messages is not a GET route.
            status_id, data_id = await asyncio.to_thread(
                _get_json, base + "/api/v1/agents/agent1",
            )
            assert status_id == 200
            assert data_id["data"]["id"] == "agent1"
            await adapter.disconnect()

        asyncio.run(run())

    def test_models_rejects_post_and_messages_rejects_get(self, monkeypatch):
        monkeypatch.delenv("WANGSA_MOBILE_BEARER_TOKEN", raising=False)
        adapter, base = _make_live_adapter(monkeypatch)

        async def run():
            assert await adapter.connect() is True
            # POST is messages-only.
            status, data = await asyncio.to_thread(
                _post_json, base + "/api/v1/agents/agent1/models",
                {"message": "hi"},
            )
            assert status == 404
            assert data["success"] is False
            # GET is identity/models-only.
            try:
                await asyncio.to_thread(
                    _get_json, base + "/api/v1/agents/agent1/messages",
                )
            except urllib.error.HTTPError as e:
                assert e.code == 404
            else:
                raise AssertionError("expected HTTP 404")
            await adapter.disconnect()

        asyncio.run(run())

    def test_get_models_failure_returns_502(self, monkeypatch):
        monkeypatch.delenv("WANGSA_MOBILE_BEARER_TOKEN", raising=False)
        import wangsa_cli.inventory as inventory

        monkeypatch.setattr(inventory, "load_picker_context", lambda: object())

        def _boom(ctx):
            raise RuntimeError("catalog exploded")

        monkeypatch.setattr(inventory, "build_model_options_payload", _boom)
        adapter, base = _make_live_adapter(monkeypatch)

        async def run():
            assert await adapter.connect() is True
            try:
                await asyncio.to_thread(
                    _get_json, base + "/api/v1/agents/agent1/models",
                )
            except urllib.error.HTTPError as e:
                status = e.code
                data = json.loads(e.read().decode())
            else:
                raise AssertionError("expected HTTP 502")
            assert status == 502
            assert data["success"] is False
            assert data["error"]["code"] == "RUNTIME_ERROR"
            await adapter.disconnect()

        asyncio.run(run())

    def test_post_message_valid_model_accepted(self, monkeypatch):
        monkeypatch.delenv("WANGSA_MOBILE_BEARER_TOKEN", raising=False)
        import wangsa_cli.inventory as inventory

        monkeypatch.setattr(inventory, "load_picker_context", lambda: object())
        monkeypatch.setattr(inventory, "build_models_payload", lambda ctx: {
            "providers": [{"slug": "testprov", "models": ["model-a", "model-b"]}],
            "provider": "testprov",
            "model": "model-a",
        })
        seen = []

        def reply_fn(event):
            seen.append(event.text)
            return "ok: " + event.text

        adapter, base = _make_live_adapter(monkeypatch, reply_fn=reply_fn)

        async def run():
            assert await adapter.connect() is True
            status, data = await asyncio.to_thread(
                _post_json, base + "/api/v1/agents/agent1/messages",
                {"message": "halo", "model": "model-b"},
            )
            assert status == 200
            assert data["success"] is True
            assert "ok: halo" in data["data"]["response"]
            assert seen == ["halo"]
            await adapter.disconnect()

        asyncio.run(run())

    def test_post_message_wrong_provider_rejected(self, monkeypatch):
        monkeypatch.delenv("WANGSA_MOBILE_BEARER_TOKEN", raising=False)
        import wangsa_cli.inventory as inventory

        monkeypatch.setattr(inventory, "load_picker_context", lambda: object())
        monkeypatch.setattr(inventory, "build_models_payload", lambda ctx: {
            "providers": [{"slug": "testprov", "models": ["model-a"]}],
            "provider": "testprov",
            "model": "model-a",
        })
        adapter, base = _make_live_adapter(monkeypatch)

        async def run():
            assert await adapter.connect() is True
            status, data = await asyncio.to_thread(
                _post_json, base + "/api/v1/agents/agent1/messages",
                {"message": "hi", "model": "model-a", "provider": "nope"},
            )
            assert status == 400
            assert data["error"]["code"] == "VALIDATION_ERROR"
            await adapter.disconnect()

        asyncio.run(run())

    _TINY_PNG_B64 = (
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )

    def test_post_message_with_image_reaches_agent(self, monkeypatch):
        monkeypatch.delenv("WANGSA_MOBILE_BEARER_TOKEN", raising=False)
        seen_urls = []
        seen_types = []

        def reply_fn(event):
            seen_urls.extend(event.media_urls)
            seen_types.extend(event.media_types)
            return "saw %d image(s)" % len(event.media_urls)

        adapter, base = _make_live_adapter(monkeypatch, reply_fn=reply_fn)

        async def run():
            assert await adapter.connect() is True
            status, data = await asyncio.to_thread(
                _post_json, base + "/api/v1/agents/agent1/messages",
                {"message": "apa ini?", "images": [
                    {"data": self._TINY_PNG_B64, "mimeType": "image/png",
                     "filename": "t.png"},
                ]},
            )
            assert status == 200
            assert data["success"] is True
            assert "saw 1 image(s)" in data["data"]["response"]
            assert len(seen_urls) == 1
            assert seen_types == ["image/png"]
            await adapter.disconnect()

        asyncio.run(run())

    def test_post_message_image_only_ok_invalid_rejected(self, monkeypatch):
        monkeypatch.delenv("WANGSA_MOBILE_BEARER_TOKEN", raising=False)
        adapter, base = _make_live_adapter(monkeypatch)

        async def run():
            assert await adapter.connect() is True
            # Image with no text is a valid photo message.
            status, data = await asyncio.to_thread(
                _post_json, base + "/api/v1/agents/agent1/messages",
                {"message": "", "images": [{"data": self._TINY_PNG_B64}]},
            )
            assert status == 200
            assert data["success"] is True

            # Garbage base64 is a 400, not a silent drop.
            status2, data2 = await asyncio.to_thread(
                _post_json, base + "/api/v1/agents/agent1/messages",
                {"message": "hi", "images": [{"data": "!!!not-base64!!!"}]},
            )
            assert status2 == 400
            assert data2["error"]["code"] == "VALIDATION_ERROR"

            # Non-image bytes decoded fine but rejected as an image.
            import base64
            text_b64 = base64.b64encode(b"hello, this is plain text").decode()
            status3, data3 = await asyncio.to_thread(
                _post_json, base + "/api/v1/agents/agent1/messages",
                {"message": "hi", "images": [{"data": text_b64}]},
            )
            assert status3 == 400
            assert data3["error"]["code"] == "VALIDATION_ERROR"

            # More than the per-message cap is rejected.
            status4, data4 = await asyncio.to_thread(
                _post_json, base + "/api/v1/agents/agent1/messages",
                {"message": "hi", "images": [{"data": self._TINY_PNG_B64}] * 6},
            )
            assert status4 == 400
            assert data4["error"]["code"] == "VALIDATION_ERROR"
            await adapter.disconnect()

        asyncio.run(run())

    def test_timeout_returns_504(self, monkeypatch):
        monkeypatch.delenv("WANGSA_MOBILE_BEARER_TOKEN", raising=False)
        monkeypatch.setenv("WANGSA_MOBILE_REPLY_TIMEOUT", "0.2")

        # reply_fn returns None -> agent never replies -> future never resolves.
        adapter, base = _make_live_adapter(monkeypatch, reply_fn=lambda event: None)

        async def run():
            assert await adapter.connect() is True
            status, data = await asyncio.to_thread(
                _post_json, base + "/api/v1/agents/a/messages", {"message": "hi"},
                timeout=5,
            )
            assert status == 504
            assert data["success"] is False
            assert data["error"]["code"] == "RUNTIME_ERROR"
            await adapter.disconnect()

        asyncio.run(run())


class TestWangsaMobileOutboundImages:
    """Covers the agent -> mobile image path: send()/send_image_file()/
    send_image() buffer into the turn, and on_processing_complete() is what
    actually flushes the buffer and resolves the HTTP response — see the
    adapter module docstring's "Outbound images" section for why."""

    def _connected_adapter(self, monkeypatch, fake_handle_message):
        monkeypatch.delenv("WANGSA_MOBILE_BEARER_TOKEN", raising=False)
        port = _free_port()
        monkeypatch.setenv("WANGSA_MOBILE_PORT", str(port))
        adapter = WangsaMobileAdapter(PlatformConfig(enabled=True))
        adapter.handle_message = fake_handle_message  # type: ignore
        adapter._message_handler = object()
        return adapter, f"http://127.0.0.1:{port}"

    def test_local_image_included_as_base64(self, tmp_path, monkeypatch):
        img_path = tmp_path / "shot.png"
        img_path.write_bytes(b"\x89PNG\r\n\x1a\nfake-png-bytes")

        async def fake_handle_message(event):
            await adapter.send(event.source.chat_id, "here's the screenshot", metadata={"notify": True})
            await adapter.send_image_file(event.source.chat_id, str(img_path), metadata={"notify": True})
            await adapter.on_processing_complete(event, ProcessingOutcome.SUCCESS)

        adapter, base = self._connected_adapter(monkeypatch, fake_handle_message)

        async def run():
            assert await adapter.connect() is True
            status, data = await asyncio.to_thread(
                _post_json, base + "/api/v1/agents/a/messages", {"message": "screenshot"},
            )
            assert status == 200
            assert data["data"]["response"] == "here's the screenshot"
            images = data["data"]["images"]
            assert len(images) == 1
            assert images[0]["filename"] == "shot.png"
            assert images[0]["mimeType"] == "image/png"
            assert base64.b64decode(images[0]["data"]) == img_path.read_bytes()
            await adapter.disconnect()

        asyncio.run(run())

    def test_remote_image_url_passed_through_without_download(self, monkeypatch):
        async def fake_handle_message(event):
            await adapter.send(event.source.chat_id, "found this online", metadata={"notify": True})
            await adapter.send_image(
                event.source.chat_id, "https://example.com/pic.png",
                caption="a caption", metadata={"notify": True},
            )
            await adapter.on_processing_complete(event, ProcessingOutcome.SUCCESS)

        adapter, base = self._connected_adapter(monkeypatch, fake_handle_message)

        async def run():
            assert await adapter.connect() is True
            status, data = await asyncio.to_thread(
                _post_json, base + "/api/v1/agents/a/messages", {"message": "find a pic"},
            )
            assert status == 200
            images = data["data"]["images"]
            assert images == [{"url": "https://example.com/pic.png", "caption": "a caption"}]
            await adapter.disconnect()

        asyncio.run(run())

    def test_multiple_images_all_delivered_in_one_reply(self, tmp_path, monkeypatch):
        paths = []
        for i in range(3):
            p = tmp_path / f"img{i}.png"
            p.write_bytes(f"bytes-{i}".encode())
            paths.append(p)

        async def fake_handle_message(event):
            await adapter.send(event.source.chat_id, "three pictures", metadata={"notify": True})
            for p in paths:
                await adapter.send_image_file(event.source.chat_id, str(p), metadata={"notify": True})
            await adapter.on_processing_complete(event, ProcessingOutcome.SUCCESS)

        adapter, base = self._connected_adapter(monkeypatch, fake_handle_message)

        async def run():
            assert await adapter.connect() is True
            status, data = await asyncio.to_thread(
                _post_json, base + "/api/v1/agents/a/messages", {"message": "give me three"},
            )
            assert status == 200
            images = data["data"]["images"]
            assert [img["filename"] for img in images] == ["img0.png", "img1.png", "img2.png"]
            await adapter.disconnect()

        asyncio.run(run())

    def test_oversized_image_skipped_not_leaked_as_garbage(self, tmp_path, monkeypatch):
        import plugins.platforms.wangsa_mobile.adapter as adapter_mod
        monkeypatch.setattr(adapter_mod, "_MAX_OUTBOUND_IMAGE_BYTES", 10)
        img_path = tmp_path / "too_big.png"
        img_path.write_bytes(b"this is more than ten bytes for sure")

        async def fake_handle_message(event):
            await adapter.send(event.source.chat_id, "oops too big", metadata={"notify": True})
            await adapter.send_image_file(event.source.chat_id, str(img_path), metadata={"notify": True})
            await adapter.on_processing_complete(event, ProcessingOutcome.SUCCESS)

        adapter, base = self._connected_adapter(monkeypatch, fake_handle_message)

        async def run():
            assert await adapter.connect() is True
            status, data = await asyncio.to_thread(
                _post_json, base + "/api/v1/agents/a/messages", {"message": "too big"},
            )
            assert status == 200
            assert data["data"]["response"] == "oops too big"
            assert "images" not in data["data"] or data["data"]["images"] == []
            await adapter.disconnect()

        asyncio.run(run())

    def test_failed_turn_does_not_leak_buffered_image_into_next_turn(self, tmp_path, monkeypatch):
        img_path = tmp_path / "shot.png"
        img_path.write_bytes(b"first-turn-image-bytes")
        calls = {"n": 0}

        async def fake_handle_message(event):
            calls["n"] += 1
            if calls["n"] == 1:
                # First turn buffers an image, then the pipeline reports
                # FAILURE (as it would on an unhandled exception) instead of
                # SUCCESS — the buffered image must not survive into turn 2.
                await adapter.send_image_file(event.source.chat_id, str(img_path), metadata={"notify": True})
                await adapter.on_processing_complete(event, ProcessingOutcome.FAILURE)
            else:
                await adapter.send(event.source.chat_id, "second turn, no images", metadata={"notify": True})
                await adapter.on_processing_complete(event, ProcessingOutcome.SUCCESS)

        adapter, base = self._connected_adapter(monkeypatch, fake_handle_message)

        async def run():
            assert await adapter.connect() is True
            status1, data1 = await asyncio.to_thread(
                _post_json, base + "/api/v1/agents/a/messages",
                {"message": "first", "sessionId": "same-session"},
            )
            assert status1 == 502

            status2, data2 = await asyncio.to_thread(
                _post_json, base + "/api/v1/agents/a/messages",
                {"message": "second", "sessionId": "same-session"},
            )
            assert status2 == 200
            assert data2["data"]["response"] == "second turn, no images"
            assert "images" not in data2["data"] or data2["data"]["images"] == []
            await adapter.disconnect()

        asyncio.run(run())


class TestWangsaMobileOutboundFiles:
    """Covers the agent -> mobile document/audio path: send_document()/
    send_voice() buffer into the turn's ``files`` array (kind: "document"
    or "audio"), same resolution mechanism as outbound images."""

    def _connected_adapter(self, monkeypatch, fake_handle_message):
        monkeypatch.delenv("WANGSA_MOBILE_BEARER_TOKEN", raising=False)
        port = _free_port()
        monkeypatch.setenv("WANGSA_MOBILE_PORT", str(port))
        adapter = WangsaMobileAdapter(PlatformConfig(enabled=True))
        adapter.handle_message = fake_handle_message  # type: ignore
        adapter._message_handler = object()
        return adapter, f"http://127.0.0.1:{port}"

    def test_document_included_as_base64_with_kind(self, tmp_path, monkeypatch):
        doc_path = tmp_path / "report.pdf"
        doc_path.write_bytes(b"%PDF-1.4 fake pdf bytes")

        async def fake_handle_message(event):
            await adapter.send(event.source.chat_id, "berikut dokumennya", metadata={"notify": True})
            await adapter.send_document(event.source.chat_id, str(doc_path), metadata={"notify": True})
            await adapter.on_processing_complete(event, ProcessingOutcome.SUCCESS)

        adapter, base = self._connected_adapter(monkeypatch, fake_handle_message)

        async def run():
            assert await adapter.connect() is True
            status, data = await asyncio.to_thread(
                _post_json, base + "/api/v1/agents/a/messages", {"message": "kirim dokumen"},
            )
            assert status == 200
            assert data["data"]["response"] == "berikut dokumennya"
            files = data["data"]["files"]
            assert len(files) == 1
            assert files[0]["kind"] == "document"
            assert files[0]["filename"] == "report.pdf"
            assert base64.b64decode(files[0]["data"]) == doc_path.read_bytes()
            await adapter.disconnect()

        asyncio.run(run())

    def test_voice_included_as_base64_with_kind(self, tmp_path, monkeypatch):
        audio_path = tmp_path / "reply.mp3"
        audio_path.write_bytes(b"fake-mp3-bytes")

        async def fake_handle_message(event):
            await adapter.send_voice(
                event.source.chat_id, str(audio_path), caption="Halo suara",
                metadata={"notify": True},
            )
            await adapter.on_processing_complete(event, ProcessingOutcome.SUCCESS)

        adapter, base = self._connected_adapter(monkeypatch, fake_handle_message)

        async def run():
            assert await adapter.connect() is True
            status, data = await asyncio.to_thread(
                _post_json, base + "/api/v1/agents/a/messages", {"message": "bacakan"},
            )
            assert status == 200
            files = data["data"]["files"]
            assert len(files) == 1
            assert files[0]["kind"] == "audio"
            assert files[0]["caption"] == "Halo suara"
            assert base64.b64decode(files[0]["data"]) == audio_path.read_bytes()
            await adapter.disconnect()

        asyncio.run(run())

    def test_oversized_file_skipped_falls_back_to_caption_text(self, tmp_path, monkeypatch):
        import plugins.platforms.wangsa_mobile.adapter as adapter_mod
        monkeypatch.setattr(adapter_mod, "_MAX_OUTBOUND_FILE_BYTES", 10)
        doc_path = tmp_path / "too_big.pdf"
        doc_path.write_bytes(b"this document is way more than ten bytes long")

        async def fake_handle_message(event):
            await adapter.send_document(
                event.source.chat_id, str(doc_path), caption="dokumennya terlalu besar",
                metadata={"notify": True},
            )
            await adapter.on_processing_complete(event, ProcessingOutcome.SUCCESS)

        adapter, base = self._connected_adapter(monkeypatch, fake_handle_message)

        async def run():
            assert await adapter.connect() is True
            status, data = await asyncio.to_thread(
                _post_json, base + "/api/v1/agents/a/messages", {"message": "kirim dokumen besar"},
            )
            assert status == 200
            assert data["data"]["response"] == "dokumennya terlalu besar"
            assert "files" not in data["data"] or data["data"]["files"] == []
            await adapter.disconnect()

        asyncio.run(run())

    def test_document_and_image_both_delivered_same_turn(self, tmp_path, monkeypatch):
        img_path = tmp_path / "chart.png"
        img_path.write_bytes(b"fake-png-bytes")
        doc_path = tmp_path / "data.csv"
        doc_path.write_bytes(b"a,b,c\n1,2,3\n")

        async def fake_handle_message(event):
            await adapter.send(event.source.chat_id, "ini grafik dan datanya", metadata={"notify": True})
            await adapter.send_image_file(event.source.chat_id, str(img_path), metadata={"notify": True})
            await adapter.send_document(event.source.chat_id, str(doc_path), metadata={"notify": True})
            await adapter.on_processing_complete(event, ProcessingOutcome.SUCCESS)

        adapter, base = self._connected_adapter(monkeypatch, fake_handle_message)

        async def run():
            assert await adapter.connect() is True
            status, data = await asyncio.to_thread(
                _post_json, base + "/api/v1/agents/a/messages", {"message": "grafik dan data"},
            )
            assert status == 200
            assert len(data["data"]["images"]) == 1
            assert len(data["data"]["files"]) == 1
            assert data["data"]["files"][0]["filename"] == "data.csv"
            await adapter.disconnect()

        asyncio.run(run())
