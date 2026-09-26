"""Deterministic model inside a real sandbox, never shipped in the runtime.

The acceptance test supplies this source as an alternate Docker entrypoint.
Only the model endpoint is replaced; AIAgent, tools, SessionDB and runtime
serialization are real. No paid credentials or external model calls are used.
"""

import contextlib
import json
import shlex
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from apps.mobile_backend import runtime_entry


PROBE = """
import os
from pathlib import Path
assert os.getuid() == 10001
status = Path('/proc/self/status').read_text()
assert int(status.split('CapEff:')[1].split()[0], 16) == 0
assert status.split('NoNewPrivs:')[1].split()[0] == '1'
assert not Path('/var/run/docker.sock').exists()
for target in ('/opt/wangsa/forbidden-write', '/data/home/skills/forbidden-write'):
    try:
        Path(target).write_text('forbidden')
    except OSError:
        pass
    else:
        raise AssertionError('Protected path is writable: ' + target)
sentinel = Path('/data/workspace/acceptance-private.txt')
MODE
print('BOUNDARY_OK')
"""


class Model(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        messages = body.get("messages", [])
        users = [m.get("content", "") for m in messages if m["role"] == "user"]
        latest = users[-1] if users else ""
        last = messages[-1] if messages else {}
        final = None
        call = None
        if "phase-clarify" in latest:
            final = {
                "outcome": "needs_input",
                "report": "Pilih pemeriksaan.",
                "question": "Periksa data sebelumnya?",
                "skill": None,
            }
        elif last.get("role") == "tool":
            final = {
                "outcome": "completed",
                "report": "Deterministic Docker acceptance: " + str(last["content"]),
                "skill": {
                    "name": "check-workspace",
                    "description": "Check a private workspace file.",
                    "content": "---\nname: check-workspace\ndescription: Check a private workspace file.\n---\n"
                    "# Check workspace\nInput: a file path. Read the file and verify its contents. "
                    "Report missing files without inventing data.\n",
                },
            }
        else:
            mode = "assert not sentinel.exists()"
            if "phase-write" in latest:
                mode = (
                    "assert not sentinel.exists(); sentinel.write_text('private-alice')"
                )
            elif "phase-read" in latest:
                mode = "assert sentinel.read_text() == 'private-alice'"
            command = "python -c " + shlex.quote(PROBE.replace("MODE", mode))
            call = {
                "id": "call_boundary",
                "type": "function",
                "function": {
                    "name": "terminal",
                    "arguments": json.dumps({"command": command, "timeout": 15}),
                },
            }
        message = {"role": "assistant", "content": json.dumps(final) if final else None}
        if call:
            message["tool_calls"] = [call]
        finish = "tool_calls" if call else "stop"
        if body.get("stream"):
            if call:
                call["index"] = 0
            response = {
                "id": "docker-fixture",
                "object": "chat.completion.chunk",
                "created": 1,
                "model": "gpt-4o-mini",
                "choices": [{"index": 0, "delta": message, "finish_reason": finish}],
            }
            data = ("data: " + json.dumps(response) + "\n\ndata: [DONE]\n\n").encode()
        else:
            response = {
                "id": "docker-fixture",
                "object": "chat.completion",
                "created": 1,
                "model": "gpt-4o-mini",
                "choices": [{"index": 0, "message": message, "finish_reason": finish}],
                "usage": {
                    "prompt_tokens": 100,
                    "completion_tokens": 30,
                    "total_tokens": 130,
                },
            }
            data = json.dumps(response).encode()
        self.send_response(200)
        self.send_header(
            "Content-Type",
            "text/event-stream" if body.get("stream") else "application/json",
        )
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def main():
    request = json.load(sys.stdin)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Model)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    import wangsa_cli.models

    resolve_free = wangsa_cli.models.opencode_zen_free_runtime

    def fixture_free(provider, model):
        runtime = resolve_free(provider, model)
        if runtime is not None:
            runtime["base_url"] = f"http://127.0.0.1:{server.server_port}/v1"
            runtime["api_mode"] = "chat_completions"
        return runtime

    wangsa_cli.models.opencode_zen_free_runtime = fixture_free
    runtime_entry.PROVIDERS["openai"] = (
        f"http://127.0.0.1:{server.server_port}/v1",
        "chat_completions",
    )
    runtime_entry.PROVIDERS["opencode-free"] = (
        f"http://127.0.0.1:{server.server_port}/v1",
        "chat_completions",
    )
    try:
        with contextlib.redirect_stdout(sys.stderr):
            result = runtime_entry.execute(request)
        print(runtime_entry.RESULT_MARKER + json.dumps(result), flush=True)
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
