import json
import sqlite3
import threading
import time
from concurrent.futures import ThreadPoolExecutor

import pytest
from cryptography.fernet import Fernet
from fastapi.testclient import TestClient

from apps.mobile_backend.api import PREFIX, create_app
from apps.mobile_backend.config import Settings
from apps.mobile_backend.store import Store, StoreError
from apps.mobile_backend.planner import plan_request


@pytest.fixture
def app(tmp_path):
    return create_app(Settings(tmp_path, Fernet.generate_key().decode()))


def account(client, name):
    response = client.post(
        PREFIX + "/auth/signup",
        json={"username": name, "password": "a-private-password"},
    )
    assert response.status_code == 201, response.text
    return response.json()["data"]


def headers(user):
    return {"Authorization": "Bearer " + user["token"]}


def provider(client, user, secret="sk-private-provider-key-123456"):
    response = client.put(
        PREFIX + "/provider",
        headers=headers(user),
        json={"provider": "openai", "model": "test-model", "api_key": secret},
    )
    assert response.status_code == 200
    assert secret not in response.text


def job(client, user, key="request-key-1", **body):
    return client.post(
        PREFIX + "/jobs",
        headers={**headers(user), "Idempotency-Key": key},
        json={"title": "Laporan", "prompt": "Susun laporan dari input ini.", **body},
    )


def test_external_session_exchange_provisions_local_product_session(app, monkeypatch):
    client = TestClient(app)
    user = account(client, "alice")
    token = user["token"]

    class Response:
        def read(self):
            return json.dumps({"data": {"profile": "alice"}}).encode()

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return False

    monkeypatch.setattr("apps.mobile_backend.api.urllib.request.urlopen", lambda *args, **kwargs: Response())
    exchanged = client.post(PREFIX + "/auth/exchange", headers=headers(user))
    assert exchanged.status_code == 200, exchanged.text
    local = exchanged.json()["data"]
    assert local["user"]["username"] == "alice"
    assert client.get(PREFIX + "/auth/me", headers=headers(local)).status_code == 200


def test_two_accounts_cannot_access_each_others_jobs_or_provider(app):
    client = TestClient(app)
    alice, bob = account(client, "alice"), account(client, "bob")
    provider(client, alice)
    response = job(client, alice)
    assert response.status_code == 202
    created = response.json()["data"]
    assert client.get(PREFIX + "/jobs", headers=headers(bob)).json()["data"] == []
    assert (
        client.get(PREFIX + "/provider", headers=headers(bob)).json()["data"][
            "configured"
        ]
        is False
    )
    for method, suffix, body in (
        ("GET", "", None),
        ("POST", "/cancel", None),
        ("POST", "/reply", {"message": "steal"}),
    ):
        denied = client.request(
            method,
            PREFIX + "/jobs/" + created["id"] + suffix,
            headers={**headers(bob), "Idempotency-Key": "reply-key-1"},
            json=body,
        )
        assert denied.status_code == 404
    assert client.get(PREFIX + "/jobs").status_code == 401
    assert (
        "tenant_id" not in created
        and "secret" not in created
        and "history" not in created
    )


def test_mobile_teacher_and_student_accounts_are_tenant_isolated(app):
    """Mobile API keeps provider settings and jobs private to each account."""
    client = TestClient(app)
    teacher = account(client, "user-1")
    student = account(client, "user-2")
    teacher_id = teacher["user"]["id"]
    student_id = student["user"]["id"]
    teacher_key = "sk-teacher-private-key-123456"
    student_key = "sk-student-private-key-123456"

    for user, model, api_key in (
        (teacher, "teacher-model", teacher_key),
        (student, "student-model", student_key),
    ):
        response = client.put(
            PREFIX + "/provider",
            headers=headers(user),
            json={"provider": "openai", "model": model, "api_key": api_key},
        )
        assert response.status_code == 200, response.text
        assert api_key not in response.text

    teacher_job = job(client, teacher, "teacher-job-key").json()["data"]
    student_job = job(client, student, "student-job-key").json()["data"]

    teacher_jobs = client.get(PREFIX + "/jobs", headers=headers(teacher)).json()[
        "data"
    ]
    student_jobs = client.get(PREFIX + "/jobs", headers=headers(student)).json()[
        "data"
    ]
    assert [item["id"] for item in teacher_jobs] == [teacher_job["id"]]
    assert [item["id"] for item in student_jobs] == [student_job["id"]]

    teacher_provider = client.get(
        PREFIX + "/provider", headers=headers(teacher)
    ).json()["data"]
    student_provider = client.get(
        PREFIX + "/provider", headers=headers(student)
    ).json()["data"]
    assert teacher_provider["model"] == "teacher-model"
    assert student_provider["model"] == "student-model"
    assert teacher_key not in str(teacher_provider)
    assert student_key not in str(student_provider)
    assert app.state.store.provider_api_key(teacher_id, "openai") == teacher_key
    assert app.state.store.provider_api_key(student_id, "openai") == student_key

    for user, foreign_job in ((teacher, student_job), (student, teacher_job)):
        denied = client.get(
            PREFIX + "/jobs/" + foreign_job["id"], headers=headers(user)
        )
        assert denied.status_code == 404


def test_authenticated_provider_catalog_uses_supported_keyed_transports(app):
    client = TestClient(app)
    user = account(client, "alice")
    response = client.get(PREFIX + "/provider/catalog", headers=headers(user))
    assert response.status_code == 200
    catalog = response.json()["data"]
    ids = {entry["id"] for entry in catalog}
    assert {"openai", "anthropic", "openrouter", "deepseek", "gemini"} <= ids
    assert len(ids) > 20
    assert all(set(entry) == {"id", "name", "requires_api_key"} for entry in catalog)
    assert next(item for item in catalog if item["id"] == "opencode-free") == {
        "id": "opencode-free",
        "name": "OpenCode Free",
        "requires_api_key": False,
    }
    assert client.get(PREFIX + "/provider/catalog").status_code == 401


def test_keyless_provider_is_saved_without_credential(app):
    client = TestClient(app)
    user = account(client, "alice")
    response = client.put(
        PREFIX + "/provider",
        headers=headers(user),
        json={"provider": "opencode-free", "model": "free-model"},
    )
    assert response.status_code == 200, response.text
    assert response.json()["data"]["configured"] is True
    created = job(client, user, "free-provider-result-key").json()["data"]
    claimed = app.state.store.claim_next()
    app.state.store.complete_job(claimed, {"report": "OpenCode Free result."})
    result = client.get(PREFIX + "/jobs/" + created["id"], headers=headers(user))
    assert result.json()["data"]["report"] == "OpenCode Free result."
    assert (
        client.put(
            PREFIX + "/provider",
            headers=headers(user),
            json={"provider": "openai", "model": "gpt-test"},
        ).status_code
        == 422
    )


def test_model_discovery_refreshes_free_models_without_saving_keys(app, monkeypatch):
    client = TestClient(app)
    user = account(client, "alice")
    auth = headers(user)

    class Response:
        def __enter__(self):
            return self

        def __exit__(self, *_args):
            return False

        def read(self):
            return json.dumps(
                {
                    "data": [
                        {"id": "current-free-model-free"},
                        {"id": "paid-model"},
                        {"id": "muse-spark-1.2-contributor-free"},
                        {"id": "jev-1.13-free"},
                        {"id": "another-safe-model-free"},
                    ]
                }
            ).encode()

    requested = {}

    def open_models(request, *, timeout):
        requested["url"] = request.full_url
        requested["headers"] = dict(request.header_items())
        requested["timeout"] = timeout
        return Response()

    monkeypatch.setattr("wangsa_cli.urllib_security.open_credentialed_url", open_models)
    models = client.post(
        PREFIX + "/provider/models",
        headers=auth,
        json={"provider": "opencode-free"},
    )
    assert models.status_code == 200
    assert models.json()["data"] == {
        "models": ["current-free-model-free", "another-safe-model-free"],
        "source": "live",
    }
    assert requested["url"] == "https://opencode.ai/zen/v1/models"
    assert "Authorization" not in requested["headers"]
    assert requested["timeout"] == 8

    monkeypatch.setattr(
        "apps.mobile_backend.api.discover_provider_models",
        lambda provider, api_key="": {
            "models": ["gpt-live"],
            "source": "live" if api_key else "curated",
        },
    )
    live = client.post(
        PREFIX + "/provider/models",
        headers=auth,
        json={"provider": "openai", "api_key": "transient-discovery-key"},
    )
    assert live.json()["data"] == {"models": ["gpt-live"], "source": "live"}
    assert app.state.store.provider_api_key(user["user"]["id"], "openai") == ""


def test_auth_restore_revoke_and_secret_storage(app):
    client = TestClient(app)
    user = account(client, "alice")
    secret = "sk-private-provider-key-123456"
    provider(client, user, secret)
    assert (
        client.get(PREFIX + "/auth/me", headers=headers(user)).json()["data"]
        == user["user"]
    )
    assert (
        client.post(
            PREFIX + "/auth/login",
            json={"username": "alice", "password": "wrong-password"},
        ).status_code
        == 401
    )
    login = client.post(
        PREFIX + "/auth/login",
        json={"username": "alice", "password": "a-private-password"},
    ).json()["data"]
    assert login["user"] == user["user"]
    assert login["token"] != user["token"]
    db = sqlite3.connect(app.state.store.path)
    dump = "\n".join(db.iterdump())
    db.close()
    for sensitive in (secret, user["token"], login["token"], "a-private-password"):
        assert sensitive not in dump
    assert (
        client.post(PREFIX + "/auth/logout", headers=headers(user)).status_code == 200
    )
    assert client.get(PREFIX + "/auth/me", headers=headers(user)).status_code == 401
    assert client.get(PREFIX + "/auth/me", headers=headers(login)).status_code == 200


def test_approved_job_payload_contains_approved_blueprint_not_only_prompt(app):
    client = TestClient(app)
    user = account(client, "planner")
    provider(client, user)
    response = job(client, user, "blueprint-job-key", approval_required=True)
    assert response.status_code == 202
    created = response.json()["data"]
    assert created["status"] == "awaiting_approval"
    approved = client.post(
        PREFIX + f"/jobs/{created['id']}/approve",
        headers={**headers(user), "Idempotency-Key": "blueprint-approval-1"},
        json={"blueprint_hash": created["blueprint_hash"]},
    )
    assert approved.status_code == 200
    claimed = app.state.store.claim_next()
    payload = app.state.store.payload_for(claimed)
    assert payload["blueprint"]["goal"] == created["blueprint"]["goal"]
    assert payload["approved_blueprint_hash"] == created["blueprint_hash"]
    assert created["blueprint"]["version"] == 1
    assert created["blueprint"]["required_access"] == []
    assert created["blueprint"]["steps"][0]["side_effect"] is True


def test_planner_requests_missing_anamnesis_for_vague_request():
    result = plan_request("Bantu dong")
    assert result["outcome"] == "needs_info"
    assert result["questions"]
    assert result["blueprint"] is None


def test_planner_returns_schema_valid_blueprint_for_actionable_request():
    result = plan_request("Kirim laporan penjualan ke Telegram setiap Jumat")
    assert result["outcome"] == "blueprint_ready"
    assert result["questions"] == []
    assert result["blueprint"]["version"] == 1
    assert result["blueprint"]["steps"]


def test_blueprint_rejects_unknown_step_action():
    from apps.mobile_backend.store import validate_blueprint
    blueprint = {
        "version": 1,
        "goal": "Test",
        "steps": [{"id": "step-1", "action": "run_shell_as_root"}],
        "execution_mode": "subagent",
    }
    with pytest.raises(StoreError, match="action blueprint"):
        validate_blueprint(blueprint)


def test_vague_job_enters_anamnesis_then_reply_creates_blueprint(app):
    client = TestClient(app)
    user = account(client, "anamnesis")
    provider(client, user)
    created = job(client, user, "anamnesis-create-key", prompt="Bantu dong").json()["data"]
    assert created["status"] == "needs_input"
    assert created["question"]
    resumed = client.post(
        PREFIX + f"/jobs/{created['id']}/reply",
        headers={**headers(user), "Idempotency-Key": "anamnesis-reply-key"},
        json={"message": "Kirim laporan penjualan ke Telegram setiap Jumat"},
    )
    assert resumed.status_code == 202
    assert resumed.json()["data"]["status"] == "awaiting_approval"
    assert resumed.json()["data"]["blueprint"]
    blueprint = client.get(
        PREFIX + f"/jobs/{created['id']}/blueprint", headers=headers(user)
    )
    assert blueprint.status_code == 200
    assert blueprint.json()["data"]["current"]["hash"]
    assert blueprint.json()["data"]["current"]["content"]["version"] == 1


def test_approval_is_idempotent_and_hash_conflicts_are_rejected(app):
    client = TestClient(app)
    user = account(client, "approval-idempotent")
    provider(client, user)
    created = job(client, user, "approval-create-key", approval_required=True).json()["data"]
    endpoint = PREFIX + f"/jobs/{created['id']}/approve"
    first = client.post(endpoint, headers={**headers(user), "Idempotency-Key": "approval-key-1"}, json={"blueprint_hash": created["blueprint_hash"]})
    assert first.status_code == 200
    replay = client.post(endpoint, headers={**headers(user), "Idempotency-Key": "approval-key-1"}, json={"blueprint_hash": created["blueprint_hash"]})
    assert replay.status_code == 200
    assert replay.json()["data"]["id"] == created["id"]
    conflict = client.post(endpoint, headers={**headers(user), "Idempotency-Key": "approval-key-1"}, json={"blueprint_hash": "0" * 64})
    assert conflict.status_code == 409
    db = sqlite3.connect(app.state.store.path)
    assert db.execute("SELECT COUNT(*) FROM blueprints WHERE job_id=?", (created["id"],)).fetchone()[0] == 1
    assert db.execute("SELECT COUNT(*) FROM approvals WHERE job_id=?", (created["id"],)).fetchone()[0] == 1
    db.close()


def test_idempotency_prevents_duplicate_jobs_and_conflicts(app):
    client = TestClient(app)
    user = account(client, "alice")
    provider(client, user)
    first = job(client, user).json()["data"]
    assert job(client, user).json()["data"]["id"] == first["id"]
    assert job(client, user, prompt="different").status_code == 409
    assert len(client.get(PREFIX + "/jobs", headers=headers(user)).json()["data"]) == 1
    assert (
        client.post(
            PREFIX + "/jobs", headers=headers(user), json={"prompt": "x"}
        ).status_code
        == 422
    )


def test_mobile_site_credentials_are_encrypted_scoped_and_removed_at_completion(app):
    client = TestClient(app)
    user = account(client, "alice")
    bob = account(client, "bob")
    provider(client, user)
    netid, password = "student@example.edu", "site-login-password"
    response = job(
        client,
        user,
        "site-job-key-1",
        browser_secrets={"netid": netid, "password": password},
    )
    assert response.status_code == 202, response.text
    created = response.json()["data"]
    assert netid not in response.text and password not in response.text
    assert (
        client.get(PREFIX + "/jobs/" + created["id"], headers=headers(bob)).status_code
        == 404
    )
    claimed = app.state.store.claim_next()
    payload = app.state.store.payload_for(claimed)
    assert payload["browser_secrets"] == {"netid": netid, "password": password}
    db = sqlite3.connect(app.state.store.path)
    dump = "\n".join(db.iterdump())
    db.close()
    assert netid not in dump and password not in dump

    app.state.store.complete_job(
        claimed,
        {
            "report": f"Completed for {netid}; entered {password}.",
            "history": [{"role": "assistant", "content": f"{password} {netid}"}],
            "skill": {
                "name": "site-login",
                "description": "Reusable site procedure",
                "content": f"---\nname: site-login\ndescription: Reusable site procedure\n---\n{password}",
            },
        },
    )
    saved = client.get(PREFIX + "/jobs/" + created["id"], headers=headers(user))
    serialized = saved.text
    assert netid not in serialized and password not in serialized
    db = sqlite3.connect(app.state.store.path)
    row = db.execute(
        "SELECT browser_secrets FROM jobs WHERE id=?", (created["id"],)
    ).fetchone()
    db.close()
    assert row[0] == ""


def test_concurrent_idempotency_and_queue_limit(app):
    store = app.state.store
    user = store.signup("alice", "a-private-password")["user"]
    store.save_provider(user["id"], "openai", "test-model", "private-secret")

    def create(_):
        return store.create_job(user["id"], "same", "same task", "same-request-key")[
            "id"
        ]

    with ThreadPoolExecutor(max_workers=8) as executor:
        assert len(set(executor.map(create, range(8)))) == 1
    for i in range(4):
        store.create_job(user["id"], "next", "more work", f"unique-request-{i}")
    with pytest.raises(StoreError) as error:
        store.create_job(user["id"], "excess", "more work", "over-limit-request")
    assert error.value.code == "QUEUE_FULL"


def test_skill_draft_review_reuse_and_clarification(app):
    client, store = TestClient(app), app.state.store
    alice, bob = account(client, "alice"), account(client, "bob")
    provider(client, alice)
    created = job(client, alice).json()["data"]
    claimed = store.claim_next()
    store.complete_job(
        claimed, {"report": "Perlu data.", "question": "Periode yang mana?"}
    )
    reply_path = PREFIX + f"/jobs/{created['id']}/reply"
    reply = client.post(
        reply_path,
        headers={**headers(alice), "Idempotency-Key": "clarify-request"},
        json={"message": "September"},
    )
    assert reply.status_code == 202
    assert (
        client.post(
            reply_path,
            headers={**headers(alice), "Idempotency-Key": "clarify-request"},
            json={"message": "September"},
        ).status_code
        == 202
    )
    claimed = store.claim_next()
    history = store.payload_for(claimed)["history"]
    assert [m["role"] for m in history] == ["user", "assistant", "user"]
    content = "---\nname: laporan\ndescription: Susun laporan dengan input baru.\n---\n# Laporan\nPeriksa input, susun hasil, lalu verifikasi dengan sumber."
    store.complete_job(
        claimed,
        {
            "report": "Laporan selesai.",
            "skill": {
                "name": "laporan",
                "description": "Susun laporan dengan input baru.",
                "content": content,
            },
        },
    )
    skill = client.get(PREFIX + "/skills", headers=headers(alice)).json()["data"][0]
    assert skill["status"] == "draft"
    assert (
        job(client, alice, "reuse-before-active", skill_id=skill["id"]).status_code
        == 404
    )
    assert (
        client.post(
            PREFIX + f"/skills/{skill['id']}/activate", headers=headers(bob)
        ).status_code
        == 404
    )
    assert (
        client.post(
            PREFIX + f"/skills/{skill['id']}/activate", headers=headers(alice)
        ).status_code
        == 200
    )
    assert (
        job(client, alice, "reuse-active-key", skill_id=skill["id"]).status_code == 202
    )
    assert store.payload_for(store.claim_next())["skill"]["content"] == content


def test_provider_disconnect_cancels_active_jobs_and_removes_snapshots(app):
    client, store = TestClient(app), app.state.store
    user = account(client, "alice")
    provider(client, user)
    created = job(client, user).json()["data"]
    assert client.delete(PREFIX + "/provider", headers=headers(user)).status_code == 200
    assert store.job_status(created["id"]) == "cancelled"
    assert store.claim_next() is None
    assert job(client, user, "new-request-key").status_code == 409


def test_invalid_requests_never_echo_secrets(app):
    client = TestClient(app)
    user = account(client, "alice")
    secret = "sk-DO-NOT-ECHO-123456789"
    invalid = client.put(
        PREFIX + "/provider",
        headers=headers(user),
        json={
            "provider": "custom",
            "model": "model",
            "api_key": secret,
            "base_url": "http://127.0.0.1",
        },
    )
    assert invalid.status_code == 422 and secret not in invalid.text
    huge = client.post(
        PREFIX + "/auth/signup", content=json.dumps({"password": secret * 5000})
    )
    assert huge.status_code == 413 and secret not in huge.text
    assert invalid.headers["cache-control"] == "no-store"


def test_wrong_encryption_key_fails_closed_and_expired_token_is_rejected(app):
    store = app.state.store
    user = store.signup("alice", "a-private-password")
    with pytest.raises(ValueError):
        Store(store.path, Fernet.generate_key().decode())
    with store._db(write=True) as db:
        db.execute("UPDATE sessions SET expires_at=0")
    with pytest.raises(StoreError) as error:
        store.authenticate(user["token"])
    assert error.value.status == 401


class CompletionRuntime:
    def run(self, job_id, tenant_id, payload, on_progress, cancelled):
        on_progress("Memverifikasi hasil.")
        return {
            "outcome": "completed",
            "report": "Pekerjaan benar-benar diselesaikan oleh runtime uji.",
        }

    def cancel(self, job_id):
        pass


def test_real_api_lifespan_dispatch_and_persisted_result(tmp_path):
    settings = Settings(tmp_path, Fernet.generate_key().decode())
    app = create_app(settings, runtime=CompletionRuntime())
    with TestClient(app) as client:
        user = account(client, "alice")
        provider(client, user)
        created = job(client, user).json()["data"]
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            result = client.get(
                PREFIX + f"/jobs/{created['id']}", headers=headers(user)
            ).json()["data"]
            if result["status"] == "completed":
                break
            threading.Event().wait(0.025)
        assert result["status"] == "completed"
    with TestClient(create_app(settings, runtime=CompletionRuntime())) as client:
        assert (
            client.get(PREFIX + f"/jobs/{created['id']}", headers=headers(user)).json()[
                "data"
            ]["report"]
            == result["report"]
        )
