"""Authenticated Android-facing API; agent execution belongs to isolated workers."""

from __future__ import annotations

import asyncio
import time
from collections import OrderedDict, deque
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, Header, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field
from starlette.exceptions import HTTPException

from .store import Store, StoreError
from .provider_catalog import (
    discover_provider_models,
    keyless_providers,
    mobile_providers,
)

PREFIX = "/api/mobile/v1"
_MAX_BODY_BYTES = 65536


class _Body(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)


class Credentials(_Body):
    username: str = Field(min_length=3, max_length=32)
    password: str = Field(min_length=10, max_length=128)


class ProviderInput(_Body):
    provider: str = Field(min_length=1, max_length=40)
    model: str = Field(min_length=1, max_length=200)
    api_key: str = Field(default="", max_length=4096)


class ModelDiscoveryInput(_Body):
    provider: str = Field(min_length=1, max_length=40)
    api_key: str = Field(default="", max_length=4096)


class JobInput(_Body):
    title: str = Field(default="", max_length=120)
    prompt: str = Field(min_length=1, max_length=16000)
    skill_id: str | None = Field(default=None, max_length=64)
    browser_secrets: dict[str, str] = Field(default_factory=dict)


class ReplyInput(_Body):
    message: str = Field(min_length=1, max_length=16000)


def _error(status: int, code: str, message: str) -> JSONResponse:
    return JSONResponse(
        status_code=status,
        content={"error": {"code": code, "message": message}},
        headers={"Cache-Control": "no-store"},
    )


class RequestLimits:
    """Bound chunked and fixed-length requests before JSON parsing or hashing."""

    def __init__(self, app):
        self.app = app
        self.windows: OrderedDict[str, deque] = OrderedDict()

    def allow(self, key: str, limit: int) -> bool:
        now = time.monotonic()
        window = self.windows.pop(key, deque())
        while window and window[0] <= now - 60:
            window.popleft()
        allowed = len(window) < limit
        if allowed:
            window.append(now)
        self.windows[key] = window
        while len(self.windows) > 10000:
            self.windows.popitem(last=False)
        return allowed

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        path = scope.get("path", "")
        client = (scope.get("client") or ("unknown",))[0]
        is_auth = path in (f"{PREFIX}/auth/signup", f"{PREFIX}/auth/login")
        limit = 15 if is_auth else 240
        if path != "/health" and not self.allow(
            f"{client}:{'auth' if is_auth else 'api'}", limit
        ):
            return await _error(
                429, "RATE_LIMITED", "Terlalu banyak permintaan. Coba lagi sebentar."
            )(scope, receive, send)
        if scope["method"] in {"POST", "PUT", "PATCH"}:
            headers = dict(scope.get("headers", []))
            try:
                length = int(headers.get(b"content-length", b"0"))
            except ValueError:
                return await _error(
                    400, "VALIDATION_ERROR", "Content-Length tidak valid."
                )(scope, receive, send)
            if length < 0 or length > _MAX_BODY_BYTES:
                return await _error(
                    413, "PAYLOAD_TOO_LARGE", "Permintaan terlalu besar."
                )(scope, receive, send)
            chunks, size = [], 0
            while True:
                event = await receive()
                if event["type"] == "http.disconnect":
                    return
                chunk = event.get("body", b"")
                size += len(chunk)
                if size > _MAX_BODY_BYTES:
                    return await _error(
                        413, "PAYLOAD_TOO_LARGE", "Permintaan terlalu besar."
                    )(scope, receive, send)
                chunks.append(chunk)
                if not event.get("more_body", False):
                    break
            body = b"".join(chunks)
            consumed = False

            async def bounded_receive():
                nonlocal consumed
                if not consumed:
                    consumed = True
                    return {"type": "http.request", "body": body, "more_body": False}
                return await receive()

            return await self.app(scope, bounded_receive, send)
        return await self.app(scope, receive, send)


def create_app(settings, runtime=None) -> FastAPI:
    store = Store(
        settings.data_dir / "mobile.sqlite3",
        settings.encryption_key,
        session_ttl_seconds=settings.session_ttl_seconds,
        max_pending_per_user=settings.max_pending_per_user,
        max_jobs_per_day=settings.max_jobs_per_day,
    )

    @asynccontextmanager
    async def lifespan(app):
        from .scheduler import Scheduler

        scheduler = Scheduler(store, settings, runtime=runtime)
        app.state.scheduler = scheduler
        await scheduler.start()
        try:
            yield
        finally:
            await scheduler.stop()

    app = FastAPI(
        title="Wangsa Mobile",
        version="1.0.0",
        lifespan=lifespan,
        docs_url=None,
        redoc_url=None,
    )
    app.state.store = store
    app.add_middleware(RequestLimits)

    @app.exception_handler(StoreError)
    async def store_error(_request, exc):
        return _error(exc.status, exc.code, exc.message)

    @app.exception_handler(RequestValidationError)
    async def validation_error(_request, _exc):
        # Pydantic's default error includes submitted input (possibly a key/password).
        return _error(
            422,
            "VALIDATION_ERROR",
            "Isi permintaan tidak valid. Periksa kolom yang wajib diisi.",
        )

    @app.exception_handler(HTTPException)
    async def http_error(_request, exc):
        return _error(
            exc.status_code,
            "NOT_FOUND" if exc.status_code == 404 else "REQUEST_ERROR",
            "Rute tidak ditemukan."
            if exc.status_code == 404
            else "Permintaan tidak dapat diproses.",
        )

    def bearer(authorization: str | None = Header(default=None)) -> str:
        scheme, _, token = (authorization or "").partition(" ")
        if scheme.lower() != "bearer" or not token or len(token) > 256:
            raise StoreError(401, "UNAUTHORIZED", "Silakan masuk terlebih dahulu.")
        return token

    def user(token: str = Depends(bearer)) -> dict:
        return store.authenticate(token)

    def idempotency(
        value: str | None = Header(default=None, alias="Idempotency-Key"),
    ) -> str:
        if value is None:
            raise StoreError(
                422,
                "IDEMPOTENCY_REQUIRED",
                "Idempotency-Key diperlukan agar pekerjaan tidak berjalan dua kali.",
            )
        return value

    @app.get("/health")
    def health():
        return {"data": {"status": "ok"}}

    @app.post(f"{PREFIX}/auth/signup", status_code=201)
    def signup(body: Credentials):
        return {"data": store.signup(body.username, body.password)}

    @app.post(f"{PREFIX}/auth/login")
    def login(body: Credentials):
        return {"data": store.login(body.username, body.password)}

    @app.get(f"{PREFIX}/auth/me")
    def me(current=Depends(user)):
        return {"data": current}

    @app.post(f"{PREFIX}/auth/logout")
    def logout(_current=Depends(user), token=Depends(bearer)):
        store.logout(token)
        return {"data": {"logged_out": True}}

    @app.get(f"{PREFIX}/provider")
    def provider(current=Depends(user)):
        return {"data": store.get_provider(current["id"])}

    @app.get(f"{PREFIX}/provider/catalog")
    def provider_catalog(_current=Depends(user)):
        keyless = keyless_providers()
        return {
            "data": [
                {
                    "id": provider,
                    "name": label,
                    "requires_api_key": provider not in keyless,
                }
                for provider, (label, _base_url, _api_mode) in sorted(
                    mobile_providers().items(), key=lambda item: item[1][0].casefold()
                )
            ]
        }

    @app.post(f"{PREFIX}/provider/models")
    async def provider_models(body: ModelDiscoveryInput, current=Depends(user)):
        if body.provider not in mobile_providers():
            raise StoreError(422, "UNSUPPORTED_PROVIDER", "Provider tidak didukung.")
        keyless = body.provider in keyless_providers()
        api_key = body.api_key.strip() or store.provider_api_key(
            current["id"], body.provider
        )
        if not keyless and not api_key:
            return {
                "data": discover_provider_models(body.provider),
            }
        try:
            result = await asyncio.to_thread(
                discover_provider_models, body.provider, api_key
            )
        except Exception:
            # Do not expose provider errors, request URLs, or credential details.
            result = discover_provider_models(body.provider)
        return {"data": result}

    @app.put(f"{PREFIX}/provider")
    def save_provider(body: ProviderInput, current=Depends(user)):
        return {
            "data": store.save_provider(
                current["id"], body.provider, body.model, body.api_key
            )
        }

    @app.delete(f"{PREFIX}/provider")
    async def delete_provider(current=Depends(user)):
        jobs = await asyncio.to_thread(store.delete_provider, current["id"])
        scheduler = getattr(app.state, "scheduler", None)
        if scheduler is not None:
            await asyncio.gather(*(scheduler.cancel(job_id) for job_id in jobs))
        return {"data": {"configured": False, "provider": None, "model": None}}

    @app.get(f"{PREFIX}/jobs")
    def jobs(current=Depends(user)):
        return {"data": store.list_jobs(current["id"])}

    @app.post(f"{PREFIX}/jobs", status_code=202)
    def create_job(body: JobInput, current=Depends(user), key=Depends(idempotency)):
        return {
            "data": store.create_job(
                current["id"], body.title, body.prompt, key, body.skill_id,
                body.browser_secrets,
            )
        }

    @app.get(f"{PREFIX}/jobs/{{job_id}}")
    def get_job(job_id: str, current=Depends(user)):
        return {"data": store.get_job(current["id"], job_id)}

    @app.post(f"{PREFIX}/jobs/{{job_id}}/cancel")
    async def cancel_job(job_id: str, current=Depends(user)):
        result = await asyncio.to_thread(store.cancel_job, current["id"], job_id)
        scheduler = getattr(app.state, "scheduler", None)
        if scheduler is not None:
            await scheduler.cancel(job_id)
        return {"data": result}

    @app.post(f"{PREFIX}/jobs/{{job_id}}/reply", status_code=202)
    def reply_job(
        job_id: str, body: ReplyInput, current=Depends(user), key=Depends(idempotency)
    ):
        return {"data": store.reply_job(current["id"], job_id, body.message, key)}

    @app.get(f"{PREFIX}/skills")
    def skills(current=Depends(user)):
        return {"data": store.list_skills(current["id"])}

    @app.post(f"{PREFIX}/skills/{{skill_id}}/activate")
    def activate_skill(skill_id: str, current=Depends(user)):
        return {"data": store.activate_skill(current["id"], skill_id)}

    @app.middleware("http")
    async def no_cache(request: Request, call_next):
        response = await call_next(request)
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        return response

    return app
