import hashlib
import json
import os
import sys
import textwrap
import uuid

import pytest

from apps.mobile_backend.runtime import (
    DockerRuntime,
    RuntimeExecutionError,
    _resolve_docker_binary,
)
from apps.mobile_backend.runtime_entry import execute, parse_result, validate_payload


def payload():
    return {
        "job_id": uuid.uuid4().hex,
        "tenant_id": uuid.uuid4().hex,
        "provider": {
            "provider": "openai",
            "model": "test-model",
            "api_key": "sk-private-test-key",
        },
        "prompt": "Buat laporan.",
        "history": [{"role": "user", "content": "Buat laporan."}],
        "skill": None,
        "blueprint": {"goal": "Buat laporan.", "steps": [{"id": "step-1", "action": "agent_execute"}]},
        "approved_blueprint_hash": hashlib.sha256(json.dumps({"goal": "Buat laporan.", "steps": [{"id": "step-1", "action": "agent_execute"}]}, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()).hexdigest(),
    }


def test_runtime_command_isolates_tenant_and_never_contains_credentials():
    request = payload()
    command = DockerRuntime()._command(request["job_id"], request["tenant_id"])
    assert command[command.index("--user") + 1] == "10001:10001"
    assert "--cap-drop=ALL" in command and "--read-only" in command
    assert (
        command[command.index("--mount") + 1]
        == f"type=volume,source=wangsa-mobile-{request['tenant_id']},target=/data"
    )
    assert command[command.index("--network") + 1].endswith(request["job_id"])
    assert not any("docker.sock" in value or "type=bind" in value for value in command)
    assert request["provider"]["api_key"] not in " ".join(command)
    other = DockerRuntime()._command(uuid.uuid4().hex, uuid.uuid4().hex)
    assert other[other.index("--mount") + 1] != command[command.index("--mount") + 1]
    with pytest.raises(ValueError):
        DockerRuntime()._command("../../host", request["tenant_id"])


def test_docker_cli_resolution_ignores_broken_path_symlink(tmp_path, monkeypatch):
    broken = tmp_path / "old-docker"
    broken.symlink_to(tmp_path / "removed-installation")
    monkeypatch.setattr(
        "apps.mobile_backend.runtime.shutil.which", lambda _name: str(broken)
    )
    resolved = _resolve_docker_binary("docker")
    assert resolved != str(broken)
    assert resolved == "docker" or os.path.isfile(resolved)
    assert _resolve_docker_binary(str(broken)) == str(broken)


@pytest.mark.macos_only
def test_real_subprocess_protocol_uses_stdin_and_clean_environment(
    tmp_path, monkeypatch
):
    # This is a real executable protocol test, not a Docker/LLM isolation claim.
    binary = tmp_path / "docker-fixture"
    binary.write_text(
        f"#!{sys.executable}\n"
        + textwrap.dedent("""
        import json, os, sys
        if sys.argv[1] != 'run':
            raise SystemExit(0)
        assert 'UNRELATED_PRIVATE_KEY' not in os.environ
        request = json.load(sys.stdin)
        assert request['provider']['api_key'] not in ' '.join(sys.argv)
        print('WANGSA_MOBILE_RESULT:' + json.dumps({
            'outcome':'completed', 'report':'Hasil ' + request['provider']['api_key'],
            'history':[{'role':'assistant','content':'Selesai'}]}))
    """)
    )
    binary.chmod(0o700)
    monkeypatch.setenv("UNRELATED_PRIVATE_KEY", "must-not-inherit")
    request = payload()
    result = DockerRuntime(docker_binary=str(binary)).run(
        request["job_id"], request["tenant_id"], request
    )
    assert result["report"] == "Hasil [REDACTED]"


@pytest.mark.parametrize(
    ("error_code", "expected"),
    [
        ("provider_policy", "OpenCode Free membatasi"),
        ("provider_model_unavailable", "Provider menolak model"),
    ],
)
def test_provider_error_markers_are_safe_and_actionable(
    tmp_path, error_code, expected
):
    binary = tmp_path / "docker-fixture"
    binary.write_text(
        f"#!{sys.executable}\n"
        + textwrap.dedent(f"""
        import sys
        if sys.argv[1] == 'run':
            sys.stdin.read()
            print('WANGSA_MOBILE_ERROR:{error_code}')
            raise SystemExit(1)
    """)
    )
    binary.chmod(0o700)
    request = payload()
    with pytest.raises(RuntimeExecutionError, match=expected) as err:
        DockerRuntime(docker_binary=str(binary)).run(
            request["job_id"], request["tenant_id"], request
        )
    assert "HTTP 403" not in str(err.value)
    assert "hy3-free is not supported" not in str(err.value)
    assert "free tier can only be used from within OpenCode" not in str(err.value)


def test_validate_payload_rejects_unapproved_blueprint():
    request = payload()
    request["approved_blueprint_hash"] = "0" * 64
    with pytest.raises(ValueError, match="hash mismatch"):
        validate_payload(request)


def test_runtime_prompt_lists_approved_steps_and_forbids_extra_steps(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "home"))
    monkeypatch.chdir(tmp_path)
    prompts = []
    systems = []

    class Agent:
        def __init__(self, **_kwargs): pass
        def run_conversation(self, prompt, **kwargs):
            prompts.append(prompt)
            systems.append(kwargs["system_message"])
            return {"final_response": json.dumps({"outcome": "completed", "report": "ok"}), "messages": []}
        def close(self): pass

    request = payload()
    execute(request, agent_factory=Agent, workspace=tmp_path / "workspace")
    assert "Execute only this approved automation blueprint" in systems[0]
    assert '"action": "agent_execute"' in systems[0]
    assert "Do not add steps" in systems[0]


def test_invalid_results_and_credentials_are_rejected():
    request = payload()
    request["provider"]["provider"] = "custom"
    with pytest.raises(ValueError):
        validate_payload(request)
    with pytest.raises(ValueError):
        parse_result('{"outcome":"completed","report":""}', "secret")
    result = parse_result(
        json.dumps({
            "outcome": "completed",
            "report": "Done",
            "skill": {
                "name": "private-procedure",
                "description": "Steps",
                "content": "credential " + "the-private-key",
            },
        }),
        "the-private-key",
    )
    assert result["skill"] is None


def test_keyless_provider_accepts_empty_key_but_paid_provider_does_not():
    request = payload()
    request["provider"] = {
        "provider": "opencode-free",
        "model": "free-model",
        "api_key": "",
    }
    assert validate_payload(request)["provider"]["api_key"] == ""
    request["provider"]["provider"] = "openai"
    with pytest.raises(ValueError, match="requires an API key"):
        validate_payload(request)
    assert parse_result('{"outcome":"completed","report":"Done"}', "") ["report"] == "Done"


def test_mobile_browser_secret_tool_never_echoes_supplied_value(monkeypatch):
    from tools import browser_tool, mobile_browser_secrets

    secret = "site-password-without-token-shape"
    mobile_browser_secrets.set_active_secrets({"password": secret})
    monkeypatch.setattr(
        browser_tool,
        "browser_type_secret",
        lambda ref, text, task_id=None: json.dumps(
            {"success": True, "typed": text, "element": ref}
        ),
    )
    try:
        result = mobile_browser_secrets._fill(
            {"name": "password", "ref": "@e4"}, task_id="job-1"
        )
        assert secret not in result
        assert json.loads(result) == {
            "success": True,
            "credential": "password",
            "element": "@e4",
        }
    finally:
        mobile_browser_secrets.clear_active_secrets()


def test_browser_secret_fill_passes_value_only_over_stdin(monkeypatch):
    from tools import browser_tool

    secret = "raw-secret-value"
    captured = {}

    def run(task_id, command, args=None, **kwargs):
        captured.update(task_id=task_id, command=command, args=args, **kwargs)
        return {"success": True}

    monkeypatch.setattr(browser_tool, "_run_browser_command", run)
    assert json.loads(
        browser_tool.browser_type_secret("@e3", secret, task_id="job-123")
    ) == {"success": True}
    assert secret not in repr(captured["args"])
    assert secret.encode() in captured["stdin_data"]
    assert captured["secure_output"] is True
    assert captured["json_output"] is False


def test_mobile_runtime_enables_scoped_browser_toolsets():
    from apps.mobile_backend import runtime_entry
    from tools.registry import registry

    import tools.browser_tool  # noqa: F401
    import tools.mobile_browser_secrets  # noqa: F401
    from toolsets import resolve_toolset

    assert "mobile_browser" in runtime_entry.TOOLSETS
    assert "browser_navigate" in resolve_toolset("mobile_browser")
    assert "browser_type" in resolve_toolset("mobile_browser")
    assert "browser_vision" not in resolve_toolset("mobile_browser")
    assert resolve_toolset("mobile_browser_secrets") == ["browser_fill_secret"]

    entry = registry.get_entry("browser_type")
    original = entry.handler
    secret = "private-site-password"
    entry.handler = lambda args, **_kwargs: args["text"]
    try:
        wrapped = runtime_entry._install_mobile_browser_secret_boundary(
            registry, {"password": secret}
        )
        result = entry.handler({"text": secret})
        assert secret not in result
        assert "browser_fill_secret" in result
    finally:
        for name, handler in wrapped.items():
            registry.get_entry(name).handler = handler
        entry.handler = original


def test_runtime_entry_preserves_turns_and_selected_skill(tmp_path, monkeypatch):
    home, workspace = tmp_path / "home", tmp_path / "workspace"
    monkeypatch.setenv("HERMES_HOME", str(home))
    # execute changes its runtime working directory; fixture restores host cwd.
    monkeypatch.chdir(tmp_path)
    calls = []

    class Agent:
        def __init__(self, **kwargs):
            calls.append(kwargs)

        def run_conversation(self, prompt, **kwargs):
            calls.append((prompt, kwargs))
            return {
                "final_response": json.dumps({
                    "outcome": "completed",
                    "report": "Laporan selesai.",
                }),
                "messages": [
                    *(kwargs.get("conversation_history") or []),
                    {"role": "user", "content": prompt},
                    {"role": "assistant", "content": "Laporan selesai."},
                ],
            }

        def close(self):
            pass

    request = payload()
    request["skill"] = {
        "name": "laporan",
        "description": "Buat laporan.",
        "content": "PERIKSA_SUMBER_SEBELUM_MENULIS",
    }
    first = execute(request, agent_factory=Agent, workspace=workspace)
    runtime_config = json.loads((home / "config.yaml").read_text())
    assert runtime_config["security"]["allow_lazy_installs"] is False
    assert "PERIKSA_SUMBER_SEBELUM_MENULIS" in calls[1][0]
    assert calls[1][1]["conversation_history"] is None
    request["history"] = first["history"] + [
        {"role": "user", "content": "Gunakan periode September."}
    ]
    execute(request, agent_factory=Agent, workspace=workspace)
    assert calls[3][0] == "Gunakan periode September."
    assert calls[3][1]["conversation_history"] == first["history"]
    assert calls[0]["api_key"] == request["provider"]["api_key"]
    assert calls[0]["credential_pool"] is None
    assert calls[0]["enabled_toolsets"] == calls[2]["enabled_toolsets"]
