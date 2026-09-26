"""Real Docker acceptance; skips when the locally built runtime is unavailable.

Run via scripts/run_tests.sh tests/mobile_backend/test_docker_acceptance.py -q.
Only a deterministic model endpoint is substituted. The production container
flags, tenant volume, agent loop, terminal tool, API and scheduler are exercised.
"""

import json
import shutil
import subprocess
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from apps.mobile_backend.api import PREFIX, create_app
from apps.mobile_backend.config import initialize, load_settings
from apps.mobile_backend.runtime import DockerRuntime, RuntimeCancelled, RuntimeTimedOut


class FixtureRuntime(DockerRuntime):
    def _command(self, job_id, tenant_id):
        command = super()._command(job_id, tenant_id)
        source = Path(__file__).with_name("docker_model_fixture.py").read_text()
        return [*command[:-1], "--entrypoint", "python", command[-1], "-c", source]


@pytest.fixture
def docker():
    binary = shutil.which("docker")
    if not binary or not Path(binary).exists():
        desktop = Path("/Applications/Docker.app/Contents/Resources/bin/docker")
        binary = str(desktop) if desktop.is_file() else None
    if not binary or not DockerRuntime(docker_binary=binary).readiness()["available"]:
        pytest.skip("Build Dockerfile.mobile-runtime and start Docker first")
    return binary


def wait_job(client, headers, identifier, expected="completed"):
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        response = client.get(f"{PREFIX}/jobs/{identifier}", headers=headers)
        assert response.status_code == 200
        job = response.json()["data"]
        if job["status"] in ("completed", "failed", "cancelled", "needs_input"):
            assert job["status"] == expected, job
            return job
        time.sleep(0.25)
    raise AssertionError("Docker job did not finish within 120 seconds")


def assert_probe(job):
    prefix = "Deterministic Docker acceptance: "
    assert job["report"].startswith(prefix), job
    terminal = json.loads(job["report"][len(prefix) :])
    assert terminal["exit_code"] == 0, terminal
    assert terminal["output"].strip() == "BOUNDARY_OK", terminal


def test_real_docker_two_tenants_resume_and_review(tmp_path, docker):
    settings = load_settings(initialize(tmp_path / "deployment"))
    runtime = FixtureRuntime(docker_binary=docker, timeout_seconds=120)
    app = create_app(settings, runtime=runtime)
    tenants = []
    try:
        with TestClient(app) as client:
            accounts = []
            for name in ("alice", "bob", "carol"):
                response = client.post(
                    PREFIX + "/auth/signup",
                    json={"username": name, "password": "docker-acceptance-password"},
                )
                assert response.status_code == 201
                account = response.json()["data"]
                tenants.append(account["user"]["id"])
                auth = {"Authorization": "Bearer " + account["token"]}
                provider_config = {
                    "provider": "opencode-free" if name == "carol" else "openai",
                    "model": "free-model" if name == "carol" else "gpt-4o-mini",
                }
                if name != "carol":
                    provider_config["api_key"] = "deterministic-fixture-key-" + name
                response = client.put(
                    PREFIX + "/provider", headers=auth, json=provider_config
                )
                assert response.status_code == 200
                accounts.append(auth)
            alice, bob, carol = accounts

            def submit(auth, prompt, skill_id=None):
                body = {"prompt": prompt, "title": "Docker acceptance"}
                if skill_id:
                    body["skill_id"] = skill_id
                response = client.post(
                    PREFIX + "/jobs",
                    headers={**auth, "Idempotency-Key": uuid.uuid4().hex},
                    json=body,
                )
                assert response.status_code == 202, response.text
                return response.json()["data"]["id"]

            a = submit(alice, "phase-write")
            b = submit(bob, "phase-empty")
            c = submit(carol, "phase-empty")
            for auth, job_id in ((alice, a), (bob, b)):
                assert_probe(wait_job(client, auth, job_id))
            assert_probe(wait_job(client, carol, c))
            assert client.get(f"{PREFIX}/jobs/{a}", headers=bob).status_code == 404
            assert (
                client.post(f"{PREFIX}/jobs/{a}/cancel", headers=bob).status_code == 404
            )

            skills = client.get(PREFIX + "/skills", headers=alice).json()["data"]
            assert len(skills) == 1 and skills[0]["status"] == "draft"
            skill_id = skills[0]["id"]
            assert (
                client.post(
                    f"{PREFIX}/skills/{skill_id}/activate", headers=bob
                ).status_code
                == 404
            )
            assert (
                client.post(
                    f"{PREFIX}/skills/{skill_id}/activate", headers=alice
                ).status_code
                == 200
            )
            reuse = submit(alice, "phase-read", skill_id)
            assert_probe(wait_job(client, alice, reuse))
            clarify = submit(alice, "phase-clarify")
            wait_job(client, alice, clarify, "needs_input")
            reply = client.post(
                f"{PREFIX}/jobs/{clarify}/reply",
                headers={**alice, "Idempotency-Key": uuid.uuid4().hex},
                json={"message": "phase-read"},
            )
            assert reply.status_code == 202
            assert_probe(wait_job(client, alice, clarify))
    finally:
        for tenant in tenants:
            subprocess.run(
                [docker, "volume", "rm", f"wangsa-mobile-{tenant}"],
                capture_output=True,
                timeout=20,
                check=True,
            )


@pytest.mark.parametrize("stop", ["timeout", "cancel"])
def test_real_docker_stop_removes_container_and_network(docker, stop):
    class SleepingRuntime(DockerRuntime):
        def _command(self, job_id, tenant_id):
            command = super()._command(job_id, tenant_id)
            return [
                *command[:-1],
                "--entrypoint",
                "python",
                command[-1],
                "-c",
                "import json,sys,time; json.load(sys.stdin); time.sleep(60)",
            ]

    job, tenant = uuid.uuid4().hex, uuid.uuid4().hex
    runtime = SleepingRuntime(
        docker_binary=docker, timeout_seconds=3 if stop == "timeout" else 30
    )
    try:
        with ThreadPoolExecutor(max_workers=1) as executor:
            future = executor.submit(
                runtime.run, job, tenant, {"provider": {"api_key": "fixture-key"}}
            )
            if stop == "cancel":
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline:
                    inspected = subprocess.run(
                        [docker, "container", "inspect", f"wangsa-mobile-job-{job}"],
                        capture_output=True,
                        timeout=10,
                    )
                    if inspected.returncode == 0:
                        container = json.loads(inspected.stdout)[0]
                        if container["State"]["Running"]:
                            assert container["HostConfig"]["ReadonlyRootfs"]
                            assert container["HostConfig"]["Memory"] == 1024**3
                            assert container["HostConfig"]["PidsLimit"] == 128
                            assert container["HostConfig"]["NanoCpus"] == 10**9
                            assert container["Config"]["User"] == "10001:10001"
                            assert not container["HostConfig"]["Binds"]
                            assert not container["HostConfig"]["PortBindings"]
                            break
                    time.sleep(0.1)
                else:
                    raise AssertionError("Runtime container did not start")
                runtime.cancel(job)
            with pytest.raises(
                RuntimeTimedOut if stop == "timeout" else RuntimeCancelled
            ):
                future.result(timeout=20)
        for kind, name in [
            ("container", f"wangsa-mobile-job-{job}"),
            ("network", f"wangsa-mobile-net-{job}"),
        ]:
            result = subprocess.run(
                [docker, kind, "inspect", name], capture_output=True, timeout=10
            )
            assert result.returncode != 0
    finally:
        subprocess.run(
            [docker, "volume", "rm", f"wangsa-mobile-{tenant}"],
            capture_output=True,
            timeout=20,
            check=True,
        )
