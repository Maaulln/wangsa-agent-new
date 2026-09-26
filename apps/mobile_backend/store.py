"""Durable, tenant-scoped state for the mobile product.

Connections are short lived. Mutations that select and then update state use
BEGIN IMMEDIATE so separate API threads cannot overbook queues or replay jobs.
Provider credentials are encrypted; session bearer tokens are only stored hashed.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import re
import secrets
import sqlite3
import time
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

import yaml
from cryptography.fernet import Fernet, InvalidToken

from .provider_catalog import keyless_providers, mobile_providers

PROVIDERS = frozenset(mobile_providers())
TERMINAL = frozenset({"completed", "failed", "cancelled"})
_USERNAME = re.compile(r"^[a-z0-9][a-z0-9_-]{2,31}$")
_MODEL = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,199}$")
_SECRET = re.compile(
    r"(?:sk-(?:ant-)?[A-Za-z0-9_-]{16,}|\b(?:api[_ -]?key|access[_ -]?token|password)\s*[:=]\s*['\"]?[A-Za-z0-9_-]{12,})",
    re.I,
)


class StoreError(Exception):
    def __init__(self, status: int, code: str, message: str):
        super().__init__(message)
        self.status, self.code, self.message = status, code, message


def _now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _hash(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def _password_hash(password: str, salt: bytes | None = None) -> str:
    salt = salt or secrets.token_bytes(16)
    digest = hashlib.scrypt(password.encode(), salt=salt, n=16384, r=8, p=1, dklen=32)
    return f"{salt.hex()}:{digest.hex()}"


def _check_password(password: str, stored: str) -> bool:
    salt, _ = stored.split(":", 1)
    return hmac.compare_digest(_password_hash(password, bytes.fromhex(salt)), stored)


def validate_skill(content: str) -> None:
    """Reviewable SKILL.md document, without embedded credential values."""
    if not isinstance(content, str) or len(content) > 50000:
        raise StoreError(
            422, "INVALID_SKILL", "Prosedur terlalu besar atau tidak valid."
        )
    if not content.startswith("---\n") or "\n---\n" not in content[4:]:
        raise StoreError(
            422, "INVALID_SKILL", "Prosedur memerlukan metadata name dan description."
        )
    header, body = content[4:].split("\n---\n", 1)
    try:
        metadata = yaml.safe_load(header)
    except yaml.YAMLError:
        metadata = None
    if (
        not isinstance(metadata, dict)
        or not all(
            isinstance(metadata.get(key), str) and metadata[key].strip()
            for key in ("name", "description")
        )
        or len(body.strip()) < 30
    ):
        raise StoreError(
            422, "INVALID_SKILL", "Metadata atau langkah prosedur belum lengkap."
        )
    if _SECRET.search(content):
        raise StoreError(
            422, "INVALID_SKILL", "Prosedur berisi data yang menyerupai kredensial."
        )


class Store:
    def __init__(
        self,
        path: Path,
        encryption_key: str,
        *,
        session_ttl_seconds: int = 2592000,
        max_pending_per_user: int = 5,
        max_jobs_per_day: int = 50,
    ):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        key = encryption_key.encode() if isinstance(encryption_key, str) else encryption_key
        self.cipher = Fernet(key)
        self._idempotency_hmac_key = hashlib.sha256(key).digest()
        self.session_ttl_seconds = session_ttl_seconds
        self.max_pending_per_user = max_pending_per_user
        self.max_jobs_per_day = max_jobs_per_day
        # Create with restrictive permissions before SQLite opens the file.
        self.path.touch(mode=0o600, exist_ok=True)
        self.path.chmod(0o600)
        with self._db() as db:
            db.execute("PRAGMA journal_mode=WAL")
            db.executescript("""
                CREATE TABLE IF NOT EXISTS users (
                    id TEXT PRIMARY KEY, username TEXT NOT NULL UNIQUE,
                    password_hash TEXT NOT NULL, created_at TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS sessions (
                    token_hash TEXT PRIMARY KEY, tenant_id TEXT NOT NULL REFERENCES users(id),
                    expires_at REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS providers (
                    tenant_id TEXT PRIMARY KEY REFERENCES users(id), provider TEXT NOT NULL,
                    model TEXT NOT NULL, secret TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS jobs (
                    id TEXT PRIMARY KEY, tenant_id TEXT NOT NULL REFERENCES users(id),
                    title TEXT NOT NULL, prompt TEXT NOT NULL, status TEXT NOT NULL,
                    report TEXT NOT NULL DEFAULT '', question TEXT NOT NULL DEFAULT '',
                    error TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL, provider TEXT NOT NULL, model TEXT NOT NULL,
                    secret TEXT NOT NULL, history TEXT NOT NULL, input_skill_id TEXT,
                    skill_id TEXT, browser_secrets TEXT NOT NULL DEFAULT '');
                CREATE INDEX IF NOT EXISTS jobs_owner ON jobs(tenant_id, created_at);
                CREATE TABLE IF NOT EXISTS events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    job_id TEXT NOT NULL REFERENCES jobs(id), message TEXT NOT NULL,
                    created_at TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS skills (
                    id TEXT PRIMARY KEY, tenant_id TEXT NOT NULL REFERENCES users(id),
                    name TEXT NOT NULL, description TEXT NOT NULL, content TEXT NOT NULL,
                    status TEXT NOT NULL DEFAULT 'draft', version INTEGER NOT NULL DEFAULT 1,
                    source_job_id TEXT NOT NULL REFERENCES jobs(id));
                CREATE TABLE IF NOT EXISTS idempotency (
                    tenant_id TEXT NOT NULL REFERENCES users(id), key TEXT NOT NULL,
                    request_hash TEXT NOT NULL, job_id TEXT NOT NULL REFERENCES jobs(id),
                    PRIMARY KEY(tenant_id, key));
                CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            """)
            columns = {row[1] for row in db.execute("PRAGMA table_info(jobs)")}
            if "browser_secrets" not in columns:
                db.execute("ALTER TABLE jobs ADD COLUMN browser_secrets TEXT NOT NULL DEFAULT ''")
        with self._db(write=True) as db:
            verifier = db.execute(
                "SELECT value FROM metadata WHERE key='encryption_verifier'"
            ).fetchone()
            if verifier:
                try:
                    self.cipher.decrypt(verifier[0].encode())
                except InvalidToken:
                    raise ValueError(
                        "Kunci enkripsi tidak cocok dengan database yang sudah ada."
                    ) from None
            else:
                db.execute(
                    "INSERT INTO metadata VALUES('encryption_verifier',?)",
                    (self.cipher.encrypt(b"wangsa-mobile").decode(),),
                )

    @contextmanager
    def _db(self, *, write: bool = False):
        db = sqlite3.connect(self.path, timeout=15)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA foreign_keys=ON")
        try:
            if write:
                db.execute("BEGIN IMMEDIATE")
            yield db
            db.commit()
        except BaseException:
            db.rollback()
            raise
        finally:
            db.close()

    def _issue_session(self, db, tenant_id: str) -> str:
        token = secrets.token_urlsafe(32)
        db.execute("DELETE FROM sessions WHERE expires_at <= ?", (time.time(),))
        db.execute(
            "INSERT INTO sessions VALUES(?,?,?)",
            (_hash(token), tenant_id, time.time() + self.session_ttl_seconds),
        )
        return token

    def signup(self, username: str, password: str) -> dict:
        username = username.strip().lower()
        if not _USERNAME.fullmatch(username):
            raise StoreError(
                422,
                "VALIDATION_ERROR",
                "Nama pengguna harus 3–32 huruf kecil, angka, - atau _.",
            )
        if not 10 <= len(password) <= 128:
            raise StoreError(
                422, "VALIDATION_ERROR", "Kata sandi harus berisi 10–128 karakter."
            )
        password_hash = _password_hash(password)
        user = {"id": uuid.uuid4().hex, "username": username}
        try:
            with self._db(write=True) as db:
                db.execute(
                    "INSERT INTO users VALUES(?,?,?,?)",
                    (user["id"], username, password_hash, _now()),
                )
                token = self._issue_session(db, user["id"])
        except sqlite3.IntegrityError:
            raise StoreError(
                409, "USERNAME_TAKEN", "Nama pengguna sudah digunakan."
            ) from None
        return {"token": token, "user": user}

    def login(self, username: str, password: str) -> dict:
        with self._db() as db:
            row = db.execute(
                "SELECT * FROM users WHERE username=?", (username.strip().lower(),)
            ).fetchone()
        # Do the same expensive hash on unknown accounts, without storing a dummy user.
        valid = (
            _check_password(password, row["password_hash"])
            if row
            else bool(_password_hash(password) and False)
        )
        if not valid:
            raise StoreError(
                401, "UNAUTHORIZED", "Nama pengguna atau kata sandi tidak sesuai."
            )
        with self._db(write=True) as db:
            token = self._issue_session(db, row["id"])
        return {"token": token, "user": {"id": row["id"], "username": row["username"]}}

    def authenticate(self, token: str) -> dict:
        with self._db() as db:
            row = db.execute(
                "SELECT u.id,u.username FROM sessions s JOIN users u ON u.id=s.tenant_id WHERE s.token_hash=? AND s.expires_at>?",
                (_hash(token), time.time()),
            ).fetchone()
        if row is None:
            raise StoreError(
                401, "UNAUTHORIZED", "Sesi berakhir. Silakan masuk kembali."
            )
        return dict(row)

    def logout(self, token: str) -> None:
        with self._db(write=True) as db:
            db.execute("DELETE FROM sessions WHERE token_hash=?", (_hash(token),))

    def get_provider(self, tenant_id: str) -> dict:
        with self._db() as db:
            row = db.execute(
                "SELECT provider,model FROM providers WHERE tenant_id=?", (tenant_id,)
            ).fetchone()
        return {
            "configured": row is not None,
            "provider": row["provider"] if row else None,
            "model": row["model"] if row else None,
        }

    def provider_api_key(self, tenant_id: str, provider: str) -> str:
        """Read a tenant's saved key for transient model discovery only."""
        with self._db() as db:
            row = db.execute(
                "SELECT provider,secret FROM providers WHERE tenant_id=?",
                (tenant_id,),
            ).fetchone()
        if row is None or row["provider"] != provider:
            return ""
        return self.cipher.decrypt(row["secret"].encode()).decode()

    def save_provider(
        self, tenant_id: str, provider: str, model: str, api_key: str
    ) -> dict:
        provider, model, api_key = (
            provider.strip().lower(),
            model.strip(),
            api_key.strip(),
        )
        if provider not in PROVIDERS or not _MODEL.fullmatch(model):
            raise StoreError(
                422, "VALIDATION_ERROR", "Provider atau model tidak didukung."
            )
        if (
            (provider not in keyless_providers() and not 8 <= len(api_key) <= 4096)
            or len(api_key) > 4096
            or any(c.isspace() for c in api_key)
        ):
            raise StoreError(422, "VALIDATION_ERROR", "Kunci API tidak valid.")
        with self._db(write=True) as db:
            db.execute(
                "INSERT INTO providers VALUES(?,?,?,?) ON CONFLICT(tenant_id) DO UPDATE SET provider=excluded.provider,model=excluded.model,secret=excluded.secret",
                (
                    tenant_id,
                    provider,
                    model,
                    self.cipher.encrypt(api_key.encode()).decode(),
                ),
            )
        return self.get_provider(tenant_id)

    def delete_provider(self, tenant_id: str) -> list[str]:
        with self._db(write=True) as db:
            db.execute("DELETE FROM providers WHERE tenant_id=?", (tenant_id,))
            rows = db.execute(
                "SELECT id FROM jobs WHERE tenant_id=? AND status IN ('queued','running','needs_input')",
                (tenant_id,),
            ).fetchall()
            for row in rows:
                db.execute(
                    "UPDATE jobs SET status='cancelled',secret='',browser_secrets='',updated_at=? WHERE id=?",
                    (_now(), row["id"]),
                )
                self._event(
                    db,
                    row["id"],
                    "Pekerjaan dibatalkan karena koneksi provider diputuskan.",
                )
            return [row["id"] for row in rows]

    @staticmethod
    def _owned_job(db, tenant_id: str, job_id: str):
        row = db.execute(
            "SELECT * FROM jobs WHERE id=? AND tenant_id=?", (job_id, tenant_id)
        ).fetchone()
        if row is None:
            raise StoreError(404, "NOT_FOUND", "Pekerjaan tidak ditemukan.")
        return row

    @staticmethod
    def _public_job(db, row) -> dict:
        job = {
            key: row[key]
            for key in (
                "id",
                "title",
                "prompt",
                "status",
                "report",
                "question",
                "error",
                "created_at",
                "updated_at",
                "skill_id",
            )
        }
        job["events"] = [
            dict(event)
            for event in db.execute(
                "SELECT id,message,created_at FROM events WHERE job_id=? ORDER BY id",
                (row["id"],),
            )
        ]
        return job

    @staticmethod
    def _event(db, job_id: str, message: str) -> None:
        db.execute(
            "INSERT INTO events(job_id,message,created_at) VALUES(?,?,?)",
            (job_id, message[:2000], _now()),
        )

    def _check_limits(self, db, tenant_id: str) -> None:
        pending = db.execute(
            "SELECT COUNT(*) FROM jobs WHERE tenant_id=? AND status IN ('queued','running','needs_input')",
            (tenant_id,),
        ).fetchone()[0]
        if pending >= self.max_pending_per_user:
            raise StoreError(
                429,
                "QUEUE_FULL",
                "Selesaikan atau batalkan pekerjaan aktif terlebih dahulu.",
            )
        daily = db.execute(
            "SELECT COUNT(*) FROM jobs WHERE tenant_id=? AND created_at>=?",
            (tenant_id, _now()[:10]),
        ).fetchone()[0]
        if daily >= self.max_jobs_per_day:
            raise StoreError(429, "DAILY_LIMIT", "Batas pekerjaan harian tercapai.")

    @staticmethod
    def _replay(db, tenant_id: str, key: str, request_hash: str) -> str | None:
        if not 8 <= len(key) <= 128 or not re.fullmatch(r"[A-Za-z0-9._:-]+", key):
            raise StoreError(
                422, "VALIDATION_ERROR", "Idempotency-Key wajib berisi 8–128 karakter."
            )
        row = db.execute(
            "SELECT request_hash,job_id FROM idempotency WHERE tenant_id=? AND key=?",
            (tenant_id, key),
        ).fetchone()
        if row:
            if row["request_hash"] != request_hash:
                raise StoreError(
                    409,
                    "IDEMPOTENCY_CONFLICT",
                    "Kunci permintaan sudah digunakan untuk isi yang berbeda.",
                )
            return row["job_id"]
        return None

    def create_job(
        self,
        tenant_id: str,
        title: str,
        prompt: str,
        idempotency_key: str,
        skill_id: str | None = None,
        browser_secrets: dict[str, str] | None = None,
    ) -> dict:
        title, prompt = title.strip(), prompt.strip()
        if not prompt or len(prompt) > 16000 or len(title) > 120:
            raise StoreError(
                422, "VALIDATION_ERROR", "Judul atau kebutuhan pekerjaan tidak valid."
            )
        title = title or prompt[:70]
        browser_secrets = browser_secrets or {}
        if (
            not isinstance(browser_secrets, dict)
            or set(browser_secrets) - {"netid", "password"}
            or any(
                not isinstance(value, str) or len(value) > 1024
                for value in browser_secrets.values()
            )
        ):
            raise StoreError(422, "VALIDATION_ERROR", "Kredensial situs tidak valid.")
        browser_secrets = {key: value for key, value in browser_secrets.items() if value}
        canonical_secrets = json.dumps(browser_secrets, sort_keys=True, separators=(",", ":"))
        digest = hmac.new(
            self._idempotency_hmac_key, canonical_secrets.encode(), hashlib.sha256
        ).hexdigest()
        request_hash = _hash(json.dumps(["create", title, prompt, skill_id, digest]))
        with self._db(write=True) as db:
            replay = self._replay(db, tenant_id, idempotency_key, request_hash)
            if replay:
                return self._public_job(db, self._owned_job(db, tenant_id, replay))
            self._check_limits(db, tenant_id)
            provider = db.execute(
                "SELECT * FROM providers WHERE tenant_id=?", (tenant_id,)
            ).fetchone()
            if provider is None:
                raise StoreError(
                    409,
                    "PROVIDER_REQUIRED",
                    "Hubungkan provider dan kunci API terlebih dahulu.",
                )
            if (
                skill_id
                and db.execute(
                    "SELECT id FROM skills WHERE id=? AND tenant_id=? AND status='active'",
                    (skill_id, tenant_id),
                ).fetchone()
                is None
            ):
                raise StoreError(404, "NOT_FOUND", "Prosedur aktif tidak ditemukan.")
            job_id, now = uuid.uuid4().hex, _now()
            db.execute(
                "INSERT INTO jobs(id,tenant_id,title,prompt,status,created_at,updated_at,provider,model,secret,history,input_skill_id,browser_secrets) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (
                    job_id,
                    tenant_id,
                    title,
                    prompt,
                    "queued",
                    now,
                    now,
                    provider["provider"],
                    provider["model"],
                    provider["secret"],
                    json.dumps([{"role": "user", "content": prompt}]),
                    skill_id,
                    self.cipher.encrypt(canonical_secrets.encode()).decode()
                    if browser_secrets
                    else "",
                ),
            )
            db.execute(
                "INSERT INTO idempotency VALUES(?,?,?,?)",
                (tenant_id, idempotency_key, request_hash, job_id),
            )
            self._event(db, job_id, "Pekerjaan masuk antrean.")
            return self._public_job(db, self._owned_job(db, tenant_id, job_id))

    def list_jobs(self, tenant_id: str) -> list[dict]:
        with self._db() as db:
            return [
                self._public_job(db, row)
                for row in db.execute(
                    "SELECT * FROM jobs WHERE tenant_id=? ORDER BY created_at DESC LIMIT 100",
                    (tenant_id,),
                )
            ]

    def get_job(self, tenant_id: str, job_id: str) -> dict:
        with self._db() as db:
            return self._public_job(db, self._owned_job(db, tenant_id, job_id))

    def cancel_job(self, tenant_id: str, job_id: str) -> dict:
        with self._db(write=True) as db:
            row = self._owned_job(db, tenant_id, job_id)
            if row["status"] not in TERMINAL:
                db.execute(
                    "UPDATE jobs SET status='cancelled',updated_at=?,secret='',browser_secrets='' WHERE id=?",
                    (_now(), job_id),
                )
                self._event(db, job_id, "Pekerjaan dibatalkan.")
            return self._public_job(db, self._owned_job(db, tenant_id, job_id))

    def reply_job(
        self, tenant_id: str, job_id: str, message: str, idempotency_key: str
    ) -> dict:
        message = message.strip()
        if not message or len(message) > 16000:
            raise StoreError(
                422,
                "VALIDATION_ERROR",
                "Jawaban tidak boleh kosong atau melebihi 16000 karakter.",
            )
        request_hash = _hash(json.dumps(["reply", job_id, message]))
        with self._db(write=True) as db:
            row = self._owned_job(db, tenant_id, job_id)
            if self._replay(db, tenant_id, idempotency_key, request_hash):
                return self._public_job(db, row)
            if row["status"] != "needs_input":
                raise StoreError(
                    409, "INVALID_STATE", "Pekerjaan ini tidak sedang menunggu jawaban."
                )
            history = json.loads(row["history"])
            if len(history) >= 40:
                raise StoreError(
                    429,
                    "TURN_LIMIT",
                    "Batas klarifikasi tercapai. Buat pekerjaan baru.",
                )
            history.append({"role": "user", "content": message})
            db.execute(
                "UPDATE jobs SET status='queued',question='',history=?,updated_at=? WHERE id=?",
                (json.dumps(history), _now(), job_id),
            )
            db.execute(
                "INSERT INTO idempotency VALUES(?,?,?,?)",
                (tenant_id, idempotency_key, request_hash, job_id),
            )
            self._event(db, job_id, "Jawaban diterima; pekerjaan kembali ke antrean.")
            return self._public_job(db, self._owned_job(db, tenant_id, job_id))

    def claim_next(self, excluded_tenants: tuple[str, ...] = ()) -> dict | None:
        with self._db(write=True) as db:
            exclusion = ""
            if excluded_tenants:
                exclusion = (
                    " AND j.tenant_id NOT IN ("
                    + ",".join("?" for _ in excluded_tenants)
                    + ")"
                )
            row = db.execute(
                "SELECT * FROM jobs j WHERE status='queued' AND NOT EXISTS(SELECT 1 FROM jobs active WHERE active.tenant_id=j.tenant_id AND active.status='running')"
                + exclusion
                + " ORDER BY created_at LIMIT 1",
                excluded_tenants,
            ).fetchone()
            if row is None:
                return None
            db.execute(
                "UPDATE jobs SET status='running',updated_at=? WHERE id=?",
                (_now(), row["id"]),
            )
            self._event(db, row["id"], "Wangsa mulai mengerjakan kebutuhan Anda.")
            result = dict(row)
            result["status"] = "running"
            return result

    def payload_for(self, job: dict) -> dict:
        with self._db() as db:
            row = self._owned_job(db, job["tenant_id"], job["id"])
            if row["status"] != "running":
                raise StoreError(409, "INVALID_STATE", "Pekerjaan tidak lagi berjalan.")
            skill = db.execute(
                "SELECT name,description,content FROM skills WHERE id=? AND tenant_id=? AND status='active'",
                (row["input_skill_id"], row["tenant_id"]),
            ).fetchone()
            return {
                "job_id": row["id"],
                "tenant_id": row["tenant_id"],
                "prompt": row["prompt"],
                "provider": {
                    "provider": row["provider"],
                    "model": row["model"],
                    "api_key": self.cipher.decrypt(row["secret"].encode()).decode(),
                },
                "history": json.loads(row["history"]),
                "skill": dict(skill) if skill else None,
                "browser_secrets": json.loads(
                    self.cipher.decrypt(row["browser_secrets"].encode()).decode()
                ) if row["browser_secrets"] else {},
            }

    def job_status(self, job_id: str) -> str | None:
        with self._db() as db:
            row = db.execute("SELECT status FROM jobs WHERE id=?", (job_id,)).fetchone()
        return row[0] if row else None

    def append_event(self, job_id: str, message: str) -> None:
        with self._db(write=True) as db:
            row = db.execute("SELECT status FROM jobs WHERE id=?", (job_id,)).fetchone()
            if row and row["status"] == "running":
                self._event(db, job_id, message)

    def complete_job(self, job: dict, result: dict) -> None:
        with self._db(write=True) as db:
            row = self._owned_job(db, job["tenant_id"], job["id"])
            if row["status"] != "running":
                return
            secret = self.cipher.decrypt(row["secret"].encode()).decode()
            browser_secrets = (
                json.loads(self.cipher.decrypt(row["browser_secrets"].encode()).decode())
                if row["browser_secrets"]
                else {}
            )
            secret_values = [secret, *browser_secrets.values()]

            def redact(value):
                if isinstance(value, str):
                    for credential in secret_values:
                        if credential:
                            value = value.replace(credential, "[kredensial disembunyikan]")
                    return value
                if isinstance(value, list):
                    return [redact(item) for item in value]
                if isinstance(value, dict):
                    return {key: redact(item) for key, item in value.items()}
                return value

            report = str(result.get("report") or "")[:100000]
            question = str(result.get("question") or "")[:4000]
            report = redact(report)
            question = redact(question)
            if not question and not report.strip():
                raise StoreError(
                    422, "EMPTY_RESULT", "Runtime tidak menghasilkan laporan."
                )
            history = redact(result.get("history"))
            if (
                not isinstance(history, list)
                or not history
                or not all(
                    isinstance(message, dict) and isinstance(message.get("role"), str)
                    for message in history
                )
            ):
                history = json.loads(row["history"])
                history.append({"role": "assistant", "content": question or report})
            status = "needs_input" if question else "completed"
            skill_id = None
            candidate = result.get("skill")
            if not question and isinstance(candidate, dict):
                name, description, content = (
                    str(candidate.get(k) or "").strip()
                    for k in ("name", "description", "content")
                )
                try:
                    validate_skill(content)
                    if any(value and value in content for value in secret_values) or not name or not description:
                        raise StoreError(
                            422,
                            "INVALID_SKILL",
                            "Prosedur mengandung kredensial atau metadata tidak lengkap.",
                        )
                except StoreError:
                    self._event(
                        db,
                        row["id"],
                        "Draft prosedur belum lolos validasi dan tidak disimpan.",
                    )
                else:
                    skill_id = uuid.uuid4().hex
                    db.execute(
                        "INSERT INTO skills(id,tenant_id,name,description,content,source_job_id) VALUES(?,?,?,?,?,?)",
                        (
                            skill_id,
                            row["tenant_id"],
                            name[:100],
                            description[:500],
                            content,
                            row["id"],
                        ),
                    )
            db.execute(
                "UPDATE jobs SET status=?,report=?,question=?,history=?,skill_id=?,secret=?,browser_secrets=?,updated_at=? WHERE id=?",
                (
                    status,
                    report,
                    question,
                    json.dumps(history),
                    skill_id,
                    row["secret"] if question else "",
                    row["browser_secrets"] if question else "",
                    _now(),
                    row["id"],
                ),
            )
            self._event(
                db,
                row["id"],
                "Wangsa membutuhkan informasi tambahan."
                if question
                else "Pekerjaan selesai. Laporan siap dibaca.",
            )

    def fail_job(self, job_id: str, message: str) -> None:
        with self._db(write=True) as db:
            row = db.execute(
                "SELECT status,secret FROM jobs WHERE id=?", (job_id,)
            ).fetchone()
            if row is None or row["status"] != "running":
                return
            if row["secret"]:
                secret = self.cipher.decrypt(row["secret"].encode()).decode()
                if secret:
                    message = message.replace(secret, "[kredensial disembunyikan]")
            db.execute(
                "UPDATE jobs SET status='failed',error=?,secret='',browser_secrets='',updated_at=? WHERE id=?",
                (message[:2000], _now(), job_id),
            )
            self._event(db, job_id, "Pekerjaan berhenti. Lihat pesan kegagalan.")

    def recover_interrupted(self) -> list[str]:
        with self._db(write=True) as db:
            rows = db.execute("SELECT id FROM jobs WHERE status='running'").fetchall()
            for row in rows:
                db.execute(
                    "UPDATE jobs SET status='failed',error=?,secret='',browser_secrets='',updated_at=? WHERE id=?",
                    (
                        "Server berhenti ketika pekerjaan berjalan. Periksa hasil sebelum membuat pekerjaan baru.",
                        _now(),
                        row["id"],
                    ),
                )
                self._event(
                    db,
                    row["id"],
                    "Pekerjaan terputus saat server dimulai ulang; tidak dijalankan ulang otomatis.",
                )
            return [row["id"] for row in rows]

    def list_skills(self, tenant_id: str) -> list[dict]:
        with self._db() as db:
            return [
                dict(row)
                for row in db.execute(
                    "SELECT id,name,description,content,status,version,source_job_id FROM skills WHERE tenant_id=? ORDER BY rowid DESC LIMIT 100",
                    (tenant_id,),
                )
            ]

    def activate_skill(self, tenant_id: str, skill_id: str) -> dict:
        with self._db(write=True) as db:
            row = db.execute(
                "SELECT id,name,description,content,status,version,source_job_id FROM skills WHERE id=? AND tenant_id=?",
                (skill_id, tenant_id),
            ).fetchone()
            if row is None:
                raise StoreError(404, "NOT_FOUND", "Prosedur tidak ditemukan.")
            validate_skill(row["content"])
            db.execute("UPDATE skills SET status='active' WHERE id=?", (skill_id,))
            return {**dict(row), "status": "active"}
