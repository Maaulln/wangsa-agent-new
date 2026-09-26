"""One durable queue supervisor; agent execution never runs in this process."""

from __future__ import annotations

import asyncio
import logging
import os
import threading

from .runtime import DockerRuntime, RuntimeExecutionError

log = logging.getLogger(__name__)


class Scheduler:
    def __init__(self, store, settings, runtime=None):
        self.store = store
        self.settings = settings
        self.runtime = runtime or DockerRuntime(
            image=settings.runtime_image,
            timeout_seconds=settings.job_timeout_seconds,
            cpus=settings.runtime_cpus,
            memory=settings.runtime_memory,
            pids_limit=settings.runtime_pids_limit,
        )
        self._stopping = threading.Event()
        self._tasks: set[asyncio.Task] = set()
        self._running: set[str] = set()
        self._tenant_by_job: dict[str, str] = {}
        self._loop_task: asyncio.Task | None = None
        self._lock_file = None

    def _acquire(self) -> None:
        self.settings.data_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        self._lock_file = (self.settings.data_dir / "supervisor.lock").open("a+b")
        try:
            if os.name == "nt":
                import msvcrt

                self._lock_file.seek(0)
                if not self._lock_file.read(1):
                    self._lock_file.write(b"0")
                    self._lock_file.flush()
                self._lock_file.seek(0)
                msvcrt.locking(self._lock_file.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl

                fcntl.flock(self._lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            self._lock_file.close()
            self._lock_file = None
            raise RuntimeError(
                "This mobile data directory already has a running supervisor."
            ) from None

    def _release(self) -> None:
        if self._lock_file:
            if os.name == "nt":
                import msvcrt

                self._lock_file.seek(0)
                msvcrt.locking(self._lock_file.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                import fcntl

                fcntl.flock(self._lock_file.fileno(), fcntl.LOCK_UN)
            self._lock_file.close()
            self._lock_file = None

    async def start(self) -> None:
        if self._loop_task:
            return
        self._acquire()
        try:
            self._stopping.clear()
            # A crashed run may already have caused external side effects.
            # Keep its record and fail it explicitly, never replay silently.
            for job_id in await asyncio.to_thread(self.store.recover_interrupted):
                await asyncio.to_thread(self.runtime.cancel, job_id)
            self._loop_task = asyncio.create_task(self._loop())
        except BaseException:
            self._release()
            raise

    async def stop(self) -> None:
        self._stopping.set()
        if self._loop_task:
            self._loop_task.cancel()
            await asyncio.gather(self._loop_task, return_exceptions=True)
            self._loop_task = None
        try:
            await asyncio.gather(
                *(
                    asyncio.to_thread(self.runtime.cancel, job_id)
                    for job_id in tuple(self._running)
                ),
                return_exceptions=True,
            )
            if self._tasks:
                await asyncio.gather(*tuple(self._tasks), return_exceptions=True)
        finally:
            self._release()

    async def cancel(self, job_id: str) -> None:
        await asyncio.to_thread(self.runtime.cancel, job_id)

    async def _loop(self) -> None:
        while not self._stopping.is_set():
            try:
                while len(self._tasks) < self.settings.max_workers:
                    # Claim is a short local SQLite transaction. Keeping it
                    # on this thread makes claim + task registration atomic
                    # relative to shutdown cancellation.
                    job = self.store.claim_next(tuple(self._tenant_by_job.values()))
                    if not job:
                        break
                    self._tenant_by_job[job["id"]] = job["tenant_id"]
                    task = asyncio.create_task(self._execute(job))
                    self._tasks.add(task)
                    task.add_done_callback(self._tasks.discard)
            except Exception:
                # Do not log exception text: DB/provider errors can contain
                # user input. A failing store is surfaced by health/read APIs.
                log.error("Mobile queue claim failed; retrying on next tick.")
            await asyncio.sleep(0.25)

    async def _execute(self, job: dict) -> None:
        job_id = job["id"]
        self._running.add(job_id)

        def cancelled() -> bool:
            return self._stopping.is_set() or self.store.job_status(job_id) != "running"

        try:
            if cancelled():
                return
            payload = await asyncio.to_thread(self.store.payload_for, job)
            result = await asyncio.to_thread(
                self.runtime.run,
                job_id,
                job["tenant_id"],
                payload,
                lambda message: self.store.append_event(job_id, message),
                cancelled,
            )
            if self._stopping.is_set():
                self.store.fail_job(
                    job_id,
                    "Server dihentikan saat pekerjaan berlangsung. Buat pekerjaan baru untuk mencoba lagi.",
                )
            elif not cancelled():
                self.store.complete_job(job, result)
        except RuntimeExecutionError as exc:
            self.store.fail_job(job_id, str(exc))
            log.warning(
                "Mobile runtime job %s failed with a safe runtime error.", job_id
            )
        except Exception:
            # Runtime errors are deliberately sanitized. Preserve cancellation
            # (conditional store transitions), never turn it into a failure.
            self.store.fail_job(
                job_id,
                "Pekerjaan tidak dapat diselesaikan. Periksa konfigurasi model dan ketersediaan runtime, lalu buat pekerjaan baru.",
            )
            log.warning("Mobile runtime job %s stopped without a result.", job_id)
        finally:
            if self._stopping.is_set():
                self.store.fail_job(
                    job_id,
                    "Server dihentikan saat pekerjaan berlangsung. Buat pekerjaan baru untuk mencoba lagi.",
                )
            self._running.discard(job_id)
            self._tenant_by_job.pop(job_id, None)
