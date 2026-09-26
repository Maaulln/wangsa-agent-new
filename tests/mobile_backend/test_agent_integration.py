"""Real AIAgent/SessionDB/provider-wire path with a local deterministic model."""

import json
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from apps.mobile_backend import runtime_entry


def test_real_agent_resume_keeps_prompt_and_does_not_duplicate_user_turn(
    tmp_path, monkeypatch
):
    requests = []
    free_requests = []

    class Model(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_POST(self):
            request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            main_request = any(
                m.get("content")
                in ("Buat laporan singkat.", "September.", "Tes OpenCode Free.")
                for m in request.get("messages", [])
                if isinstance(m.get("content"), str)
            )
            if main_request:
                requests.append(request)
            if any(
                m.get("content") == "Tes OpenCode Free."
                for m in request.get("messages", [])
                if isinstance(m.get("content"), str)
            ):
                free_requests.append(
                    {
                        "request": request,
                        "authorization": self.headers.get("Authorization", ""),
                        "user_agent": self.headers.get("User-Agent", ""),
                        "referer": self.headers.get("HTTP-Referer", ""),
                    }
                )
            final = (
                {
                    "outcome": "needs_input",
                    "report": "Saya perlu periode laporan.",
                    "question": "Periode mana?",
                    "skill": None,
                }
                if not any(
                    m.get("content") == "September."
                    for m in request.get("messages", [])
                )
                else {
                    "outcome": "completed",
                    "report": "Laporan September selesai.",
                    "question": None,
                    "skill": None,
                }
            )
            data = json.dumps({
                "id": "local-completion",
                "object": "chat.completion",
                "created": 1,
                "model": "gpt-4o-mini",
                "choices": [
                    {
                        "index": 0,
                        "finish_reason": "stop",
                        "message": {"role": "assistant", "content": json.dumps(final)},
                    }
                ],
                "usage": {
                    "prompt_tokens": 100,
                    "completion_tokens": 30,
                    "total_tokens": 130,
                },
            }).encode()
            if request.get("stream"):
                chunk = {
                    "id": "local-completion",
                    "object": "chat.completion.chunk",
                    "created": 1,
                    "model": "gpt-4o-mini",
                    "choices": [
                        {
                            "index": 0,
                            "finish_reason": "stop",
                            "delta": {
                                "role": "assistant",
                                "content": json.dumps(final),
                            },
                        }
                    ],
                }
                data = ("data: " + json.dumps(chunk) + "\n\ndata: [DONE]\n\n").encode()
            self.send_response(200)
            self.send_header(
                "Content-Type",
                "text/event-stream" if request.get("stream") else "application/json",
            )
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Model)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "home"))
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.chdir(tmp_path)
    monkeypatch.setitem(
        runtime_entry.PROVIDERS,
        "openai",
        (f"http://127.0.0.1:{server.server_port}/v1", "chat_completions"),
    )
    request = {
        "job_id": uuid.uuid4().hex,
        "tenant_id": uuid.uuid4().hex,
        "prompt": "Buat laporan singkat.",
        "provider": {
            "provider": "openai",
            "model": "gpt-4o-mini",
            "api_key": "local-fixture-key",
        },
        "history": [{"role": "user", "content": "Buat laporan singkat."}],
    }
    try:
        first = runtime_entry.execute(request, workspace=tmp_path / "workspace")
        assert first["outcome"] == "needs_input"
        request["history"] = first["history"] + [
            {"role": "user", "content": "September."}
        ]
        second = runtime_entry.execute(request, workspace=tmp_path / "workspace")
        assert second["report"] == "Laporan September selesai."
        assert len(requests) == 2
        first_messages, second_messages = (
            requests[0]["messages"],
            requests[1]["messages"],
        )
        assert first_messages[0] == second_messages[0]
        assert [m["content"] for m in first_messages if m["role"] == "user"] == [
            "Buat laporan singkat."
        ]
        assert [m["content"] for m in second_messages if m["role"] == "user"] == [
            "Buat laporan singkat.",
            "September.",
        ]

        # Mobile must use Hermes' OpenCode Free resolver: the keyless
        # placeholder triggers the same empty-Authorization and attribution
        # headers as the CLI instead of sending an ordinary empty API key.
        import wangsa_cli.models

        real_free_runtime = wangsa_cli.models.opencode_zen_free_runtime

        def local_free_runtime(provider, model):
            resolved = real_free_runtime(provider, model)
            if resolved:
                resolved["base_url"] = f"http://127.0.0.1:{server.server_port}/v1"
                resolved["api_mode"] = "chat_completions"
            return resolved

        monkeypatch.setattr(
            wangsa_cli.models, "opencode_zen_free_runtime", local_free_runtime
        )
        free_request = {
            "job_id": uuid.uuid4().hex,
            "tenant_id": uuid.uuid4().hex,
            "prompt": "Tes OpenCode Free.",
            "provider": {
                "provider": "opencode-free",
                "model": "nemotron-3.5-lightning-free",
                "api_key": "",
            },
            "history": [{"role": "user", "content": "Tes OpenCode Free."}],
        }
        runtime_entry.execute(free_request, workspace=tmp_path / "workspace")
        assert len(free_requests) == 1
        free_wire = free_requests[0]
        assert free_wire["authorization"] != "Bearer opencode-zen-free-keyless"
        assert "HermesAgent/" in free_wire["user_agent"]
        assert free_wire["referer"] == "https://hermes-agent.nousresearch.com"
        assert free_wire["request"]["model"] == "nemotron-3.5-lightning-free"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
