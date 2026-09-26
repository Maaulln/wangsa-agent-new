"""Docker-only boundary between the mobile control plane and tenant agents.

Only the Docker client runs on the control-plane host. Agent code, tools and
persistent state live inside a tenant volume. Provider credentials travel over
stdin, never Docker arguments, environment, bind mounts or diagnostic output.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import threading
import time
from collections.abc import Callable
from typing import Any
from uuid import UUID

from .provider_catalog import keyless_providers

RESULT_MARKER = "WANGSA_MOBILE_RESULT:"
ERROR_MARKER = "WANGSA_MOBILE_ERROR:"
MAX_PAYLOAD_BYTES = 4 * 1024 * 1024
MAX_OUTPUT_BYTES = 8 * 1024 * 1024


class RuntimeExecutionError(RuntimeError):
    """Safe, credential-free error suitable for a job event."""


class RuntimeUnavailable(RuntimeExecutionError):
    pass


class RuntimeCancelled(RuntimeExecutionError):
    pass


class RuntimeTimedOut(RuntimeExecutionError):
    pass


def _resolve_docker_binary(binary: str) -> str:
    if binary != "docker":
        return binary
    found = shutil.which(binary)
    if found and os.path.exists(found):
        return found
    # Desktop app launchers may inherit a PATH with an obsolete symlink (for
    # example after removing OrbStack). Docker Desktop ships its own CLI.
    bundled = "/Applications/Docker.app/Contents/Resources/bin/docker"
    return bundled if os.path.isfile(bundled) else (found or binary)


def _uuid(value: str) -> str:
    """Reject paths, options and noncanonical identifiers before spawning."""
    try:
        parsed = UUID(value)
    except (ValueError, AttributeError, TypeError):
        raise ValueError("Runtime identifiers must be canonical UUIDs") from None
    if value not in (str(parsed), parsed.hex):
        raise ValueError("Runtime identifiers must be canonical UUIDs")
    return parsed.hex


class DockerRuntime:
    """Synchronous worker driver; one instance can execute different tenants.

    The scheduler must serialize jobs within a tenant because its memory and
    workspace are shared. Cancellation is safe from another scheduler thread.
    Image/network/limits are operator settings, never request-controlled values.
    """

    def __init__(
        self,
        *,
        image: str = "wangsa-mobile-runtime:local",
        docker_binary: str = "docker",
        timeout_seconds: float = 900,
        cpus: float = 1.0,
        memory: str = "1g",
        pids_limit: int = 128,
    ) -> None:
        if not image or image.startswith("-") or any(c.isspace() for c in image):
            raise ValueError("Invalid runtime image")
        if timeout_seconds <= 0 or cpus <= 0 or pids_limit < 16:
            raise ValueError("Runtime limits must be positive")
        if not re.fullmatch(r"[1-9][0-9]*[bkmgBKMG]?", memory):
            raise ValueError("Invalid runtime memory limit")
        self.image = image
        self.docker_binary = _resolve_docker_binary(docker_binary)
        self.timeout_seconds = timeout_seconds
        self.cpus = cpus
        self.memory = memory
        self.pids_limit = pids_limit
        self._lock = threading.Lock()
        self._active: dict[str, threading.Event] = {}

    def _env(self) -> dict[str, str]:
        # Docker routing/config belongs to the operator. No model key or other
        # application environment is inherited even by the host Docker client.
        allowed = (
            "PATH",
            "HOME",
            "DOCKER_HOST",
            "DOCKER_CONTEXT",
            "DOCKER_CONFIG",
            "DOCKER_TLS_VERIFY",
            "DOCKER_CERT_PATH",
            "XDG_RUNTIME_DIR",
        )
        return {name: os.environ[name] for name in allowed if name in os.environ}

    def readiness(self) -> dict[str, Any]:
        """Check daemon and locally built image, without pulling or executing."""
        for command in (
            ("info", "--format", "{{.ServerVersion}}"),
            ("image", "inspect", self.image),
        ):
            try:
                result = subprocess.run(
                    [self.docker_binary, *command],
                    env=self._env(),
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=10,
                    check=False,
                )
            except (OSError, subprocess.TimeoutExpired):
                return {"available": False, "message": "Docker runtime is unavailable"}
            if result.returncode:
                return {
                    "available": False,
                    "message": "Docker daemon or mobile runtime image is unavailable",
                }
        return {"available": True, "message": "Docker runtime is ready"}

    def _command(self, job_id: str, tenant_id: str) -> list[str]:
        job = _uuid(job_id)
        tenant = _uuid(tenant_id)
        return [
            self.docker_binary,
            "run",
            "--rm",
            "--interactive",
            "--init",
            "--pull=never",
            "--name",
            f"wangsa-mobile-job-{job}",
            "--label",
            "wangsa.mobile.runtime=true",
            "--user",
            "10001:10001",
            "--cap-drop=ALL",
            "--security-opt=no-new-privileges:true",
            "--read-only",
            "--cpus",
            str(self.cpus),
            "--memory",
            self.memory,
            "--memory-swap",
            self.memory,
            "--pids-limit",
            str(self.pids_limit),
            "--ulimit",
            "nofile=1024:1024",
            "--network",
            f"wangsa-mobile-net-{job}",
            "--log-driver=none",
            "--stop-timeout=5",
            "--mount",
            f"type=volume,source=wangsa-mobile-{tenant},target=/data",
            "--tmpfs",
            "/tmp:rw,nosuid,nodev,size=128m,mode=1777",
            "--tmpfs",
            "/data/home/skills:ro,nosuid,nodev,size=1m,mode=0555",
            "--workdir",
            "/data/workspace",
            self.image,
        ]

    def _remove(self, job_id: str) -> None:
        try:
            subprocess.run(
                [
                    self.docker_binary,
                    "rm",
                    "--force",
                    f"wangsa-mobile-job-{_uuid(job_id)}",
                ],
                env=self._env(),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=10,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            # The timeout still bounds the request when a Docker daemon fails.
            # Operators reconcile labelled containers after daemon recovery.
            pass
        try:
            subprocess.run(
                [
                    self.docker_binary,
                    "network",
                    "rm",
                    f"wangsa-mobile-net-{_uuid(job_id)}",
                ],
                env=self._env(),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=10,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            pass

    def cancel(self, job_id: str) -> None:
        _uuid(job_id)
        with self._lock:
            event = self._active.get(job_id)
            if event:
                event.set()
        # Also reconciles a named container left by a previous worker process.
        self._remove(job_id)

    def run(
        self,
        job_id: str,
        tenant_id: str,
        payload: dict[str, Any],
        on_progress: Callable[[str], None] | None = None,
        cancelled: Callable[[], bool] | None = None,
    ) -> dict[str, Any]:
        command = self._command(job_id, tenant_id)
        request = dict(payload, job_id=job_id, tenant_id=tenant_id)
        provider = request.get("provider")
        if not isinstance(provider, dict) or not isinstance(
            provider.get("api_key"), str
        ):
            raise ValueError("An explicit provider credential is required")
        api_key = provider["api_key"].strip()
        if not api_key and provider.get("provider") not in keyless_providers():
            raise ValueError("An explicit provider credential is required")
        encoded = json.dumps(request, ensure_ascii=False).encode("utf-8")
        if len(encoded) > MAX_PAYLOAD_BYTES:
            raise ValueError("Runtime request is too large")
        event = threading.Event()
        with self._lock:
            if job_id in self._active:
                raise RuntimeExecutionError("This job already has an active runtime")
            self._active[job_id] = event
        process = None
        reader = writer = None
        output = bytearray()
        overflow = threading.Event()
        write_failed = threading.Event()
        try:
            if cancelled and cancelled():
                raise RuntimeCancelled("Job was cancelled")
            try:
                network = subprocess.run(
                    [
                        self.docker_binary,
                        "network",
                        "create",
                        "--driver",
                        "bridge",
                        "--label",
                        "wangsa.mobile.runtime=true",
                        "--opt",
                        "com.docker.network.bridge.enable_icc=false",
                        f"wangsa-mobile-net-{_uuid(job_id)}",
                    ],
                    env=self._env(),
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=15,
                    check=False,
                )
            except (OSError, subprocess.TimeoutExpired):
                raise RuntimeUnavailable("Docker runtime is unavailable") from None
            if network.returncode:
                raise RuntimeUnavailable(
                    "Isolated runtime network could not be created"
                )
            if on_progress:
                on_progress("Menyiapkan ruang kerja agent yang terisolasi.")
            started = time.monotonic()
            try:
                process = subprocess.Popen(
                    command,
                    env=self._env(),
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                )
            except OSError:
                raise RuntimeUnavailable("Docker runtime is unavailable") from None

            def read_output() -> None:
                try:
                    while chunk := process.stdout.read(65536):
                        if len(output) + len(chunk) > MAX_OUTPUT_BYTES:
                            overflow.set()
                            return
                        output.extend(chunk)
                except OSError:
                    write_failed.set()

            def write_request() -> None:
                try:
                    process.stdin.write(encoded)
                    process.stdin.close()
                except (BrokenPipeError, OSError):
                    write_failed.set()

            reader = threading.Thread(target=read_output, daemon=True)
            writer = threading.Thread(target=write_request, daemon=True)
            reader.start()
            writer.start()
            while process.poll() is None:
                if event.is_set() or (cancelled and cancelled()):
                    raise RuntimeCancelled("Job was cancelled")
                if time.monotonic() - started > self.timeout_seconds:
                    raise RuntimeTimedOut("Job exceeded its execution time limit")
                if overflow.is_set():
                    raise RuntimeExecutionError("Agent output exceeded the size limit")
                event.wait(0.1)
            reader.join(timeout=5)
            writer.join(timeout=5)
            if event.is_set() or (cancelled and cancelled()):
                raise RuntimeCancelled("Job was cancelled")
            if overflow.is_set() or reader.is_alive() or writer.is_alive():
                raise RuntimeExecutionError("Agent output exceeded runtime limits")
            text = output.decode("utf-8", errors="replace")
            if api_key:
                text = text.replace(api_key, "[REDACTED]")
            error_code = next(
                (
                    line[len(ERROR_MARKER) :]
                    for line in reversed(text.splitlines())
                    if line.startswith(ERROR_MARKER)
                ),
                None,
            )
            if error_code == "provider_policy":
                raise RuntimeExecutionError(
                    "OpenCode Free membatasi model gratis agar hanya digunakan di aplikasi OpenCode. "
                    "Pilih provider lain, atau gunakan OpenCode Zen dengan API key dan model berbayar."
                )
            if error_code == "provider_model_unavailable":
                raise RuntimeExecutionError(
                    "Provider menolak model OpenCode Free yang dipilih. Pilih model OpenCode Free lain "
                    "yang masih tersedia, lalu buat job baru."
                )
            if process.returncode != 0 or write_failed.is_set():
                raise RuntimeExecutionError(
                    "Agent execution failed; check provider credentials and model"
                )
            # Redact the known credential defensively before any result reaches
            # the store. Raw stderr/exception details are never surfaced.
            result_line = next(
                (
                    line[len(RESULT_MARKER) :]
                    for line in reversed(text.splitlines())
                    if line.startswith(RESULT_MARKER)
                ),
                None,
            )
            try:
                result = json.loads(result_line) if result_line else None
            except (ValueError, TypeError):
                result = None
            if (
                not isinstance(result, dict)
                or result.get("outcome") not in {"completed", "needs_input"}
                or not isinstance(result.get("report"), str)
                or not isinstance(result.get("history"), list)
            ):
                raise RuntimeExecutionError("Agent returned an invalid result")
            if on_progress:
                on_progress(
                    "Agent membutuhkan jawaban Anda."
                    if result["outcome"] == "needs_input"
                    else "Agent selesai mengerjakan tugas."
                )
            return result
        finally:
            if process is not None and process.poll() is None:
                self._remove(job_id)
                process.kill()
                process.wait(timeout=5)
            for thread in (reader, writer):
                if thread:
                    thread.join(timeout=1)
            if process is not None:
                for pipe in (process.stdin, process.stdout):
                    if pipe:
                        pipe.close()
            with self._lock:
                self._active.pop(job_id, None)
            self._remove(job_id)
