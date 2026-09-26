"""Real SQLite queue lifecycle without paid provider calls or a Docker daemon."""

import asyncio
import threading

import pytest

from apps.mobile_backend.config import Settings, initialize, load_settings
from apps.mobile_backend.scheduler import Scheduler
from apps.mobile_backend.store import Store


@pytest.fixture
def settings(tmp_path):
    return load_settings(initialize(tmp_path / "deployment"))


def make_store(settings):
    return Store(settings.data_dir / "mobile.db", settings.encryption_key)


def create_job(store, username="alice", key="unique-request-1"):
    user = store.signup(username, "long-password-123")["user"]
    store.save_provider(user["id"], "openai", "test-model", "secret-key-example")
    return user, store.create_job(
        user["id"], "Laporan", "Susun laporan dari kebutuhan ini.", key
    )


class Runtime:
    def __init__(self):
        self.started = threading.Event()
        self.release = threading.Event()
        self.cancelled = []
        self.payloads = []

    def run(self, job_id, tenant_id, payload, on_progress, cancelled):
        self.payloads.append((tenant_id, payload))
        on_progress("Menyusun hasil.")
        self.started.set()
        if not self.release.wait(5):
            raise RuntimeError("Test did not release worker")
        if cancelled():
            raise RuntimeError("Cancelled")
        return {"outcome": "completed", "report": "Hasil pekerjaan terverifikasi."}

    def cancel(self, job_id):
        self.cancelled.append(job_id)
        self.release.set()


async def wait_status(store, job_id, expected):
    for _ in range(200):
        if store.job_status(job_id) == expected:
            return
        await asyncio.sleep(0.025)
    raise AssertionError(f"Expected {expected}, got {store.job_status(job_id)}")


def test_initialization_preserves_key_and_state(settings, monkeypatch):
    monkeypatch.delenv("WANGSA_MOBILE_ENCRYPTION_KEY", raising=False)
    config = settings.data_dir.parent / "mobile.yaml"
    assert load_settings(config).encryption_key == settings.encryption_key
    with pytest.raises(ValueError, match="already contains"):
        initialize(config.parent)
    assert load_settings(config).encryption_key == settings.encryption_key


def test_configuration_rejects_inline_secrets_and_unbounded_workers(settings):
    config = settings.data_dir.parent / "mobile.yaml"
    config.write_text("encryption_key: do-not-put-secrets-in-yaml\n")
    with pytest.raises(ValueError, match="inline"):
        load_settings(config)
    with pytest.raises(ValueError, match="max_workers"):
        Settings(settings.data_dir, settings.encryption_key, max_workers=10000)


@pytest.mark.asyncio
async def test_job_finishes_without_http_client_and_survives_reload(settings):
    store, runtime = make_store(settings), Runtime()
    user, job = create_job(store)
    scheduler = Scheduler(store, settings, runtime)
    await scheduler.start()
    try:
        assert await asyncio.to_thread(runtime.started.wait, 5)
        assert runtime.payloads[0][0] == user["id"]
        runtime.release.set()
        await wait_status(store, job["id"], "completed")
    finally:
        await scheduler.stop()
    reloaded = make_store(settings)
    saved = reloaded.get_job(user["id"], job["id"])
    assert saved["report"] == "Hasil pekerjaan terverifikasi."
    assert any(event["message"] == "Menyusun hasil." for event in saved["events"])


@pytest.mark.asyncio
async def test_restart_does_not_replay_interrupted_side_effects(settings):
    store, runtime = make_store(settings), Runtime()
    _, job = create_job(store)
    assert store.claim_next()["id"] == job["id"]
    scheduler = Scheduler(store, settings, runtime)
    await scheduler.start()
    try:
        assert store.job_status(job["id"]) == "failed"
        assert runtime.cancelled == [job["id"]]
        assert runtime.payloads == []
    finally:
        await scheduler.stop()


@pytest.mark.asyncio
async def test_shutdown_cancels_runtime_and_releases_supervisor_lock(settings):
    store, runtime = make_store(settings), Runtime()
    _, job = create_job(store)
    scheduler = Scheduler(store, settings, runtime)
    await scheduler.start()
    assert await asyncio.to_thread(runtime.started.wait, 5)
    rival = Scheduler(store, settings, Runtime())
    with pytest.raises(RuntimeError, match="already has"):
        await rival.start()
    await scheduler.stop()
    assert job["id"] in runtime.cancelled
    assert store.job_status(job["id"]) == "failed"
    await rival.start()
    await rival.stop()


def test_claims_serialize_same_tenant_without_blocking_other_tenants(settings):
    store = make_store(settings)
    user, first = create_job(store)
    second = store.create_job(
        user["id"], "Berikutnya", "Buat laporan kedua.", "unique-request-2"
    )
    _, other = create_job(store, "bob", "unique-request-3")
    claimed = store.claim_next()
    assert claimed["id"] == first["id"]
    assert store.claim_next()["id"] == other["id"]
    assert store.claim_next() is None
    store.complete_job(claimed, {"report": "Selesai."})
    assert store.claim_next()["id"] == second["id"]
