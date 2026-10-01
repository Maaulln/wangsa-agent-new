"""Onboarding provisioning — turn a user-supplied Telegram bot token into a
fully isolated, independently-running Wangsa profile.

Design: see docs/design/onboarding-provisioning-plan.md. Summary of the
decision this module implements — every end-user gets their OWN Telegram
bot token (created by them via @BotFather, never by us) and their OWN
process-isolated Wangsa profile. This is deliberately NOT built on
``gateway.profile_routing`` / ``multiplex_profiles`` (routing many users
through one shared bot token in one process): a single Telegram bot token
can only be polled (``getUpdates``) by one process at a time, so "isolated
brain per user" here means "isolated OS process per user", which
``hermes profile create`` + ``hermes gateway install`` already provide as
core, tested functionality (see ``wangsa_cli/profiles.py``'s
``create_profile()`` and ``wangsa_cli/gateway.py``'s
``launchd_install()``/``systemd_install()``). This module is orchestration
only — it does not reimplement any of that.

Token handling: a token is written to the target profile's own ``.env``
(via ``save_env_value`` under a ``set_hermes_home_override`` scope — see
``verify_and_reserve_token`` / ``provision_profile_for_token``) and is
never written into this module's own process environment, never logged,
and never persisted anywhere outside that one profile's ``.env`` file.
"""

from __future__ import annotations

import re
import sys
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

_TOKEN_RE = re.compile(r"^\d{6,16}:[A-Za-z0-9_-]{30,}$")


class ProvisioningError(RuntimeError):
    """A provisioning step failed. ``.stage`` identifies which one, for
    both user-facing messaging and test assertions — callers should never
    have to string-match ``str(exc)`` to know what failed."""

    def __init__(self, stage: str, message: str):
        super().__init__(message)
        self.stage = stage


def looks_like_bot_token(token: str) -> bool:
    """Cheap shape check before any network call — catches pasted-garbage
    input immediately with a clear message instead of a confusing getMe
    failure. Real Telegram bot tokens are ``<digits>:<35-char secret>``;
    the length floor here is intentionally loose (30, not 35) so a minor
    future Telegram format change doesn't start rejecting valid tokens."""
    return bool(_TOKEN_RE.match(token.strip()))


def token_already_in_use(token: str) -> Optional[str]:
    """Return the profile name already holding this exact token, or None.

    Scans every existing profile's ``.env`` (never the process environment
    — a token belongs to exactly one profile's file, never os.environ,
    which the multiplexer already relies on for correctness). Best-effort:
    a profile whose ``.env`` can't be read is skipped, not fatal — an
    unreadable file cannot be holding a token we'd collide with in a way
    this check could have caught anyway.
    """
    from wangsa_cli.profiles import list_profiles
    from wangsa_constants import set_hermes_home_override, reset_hermes_home_override
    from wangsa_cli.config import get_env_path

    stripped = token.strip()
    for info in list_profiles():
        profile_dir: Path = info.path
        token_tok = set_hermes_home_override(str(profile_dir))
        try:
            env_path = get_env_path()
            if not env_path.is_file():
                continue
            text = env_path.read_text(encoding="utf-8-sig", errors="replace")
        except OSError:
            continue
        finally:
            reset_hermes_home_override(token_tok)

        for line in text.splitlines():
            if line.strip().startswith("TELEGRAM_BOT_TOKEN="):
                existing = line.split("=", 1)[1].strip().strip('"').strip("'")
                if existing == stripped:
                    return info.name
    return None


def verify_bot_token_live(token: str, *, timeout: float = 10.0) -> dict:
    """Call Telegram's ``getMe`` to confirm the token is real and live.

    Raises ProvisioningError(stage="token_invalid") on any non-2xx response
    or network failure — a dead/typo'd/revoked token must never reach
    profile creation. Returns the parsed ``result`` object (bot username,
    id, etc.) on success, useful for the confirmation message back to the
    user ("your bot @foo_bot is now live").
    """
    import urllib.request
    import urllib.error
    import json as _json

    url = f"https://api.telegram.org/bot{token.strip()}/getMe"
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            body = _json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        raise ProvisioningError(
            "token_invalid", f"Telegram menolak token ini (HTTP {exc.code}) — cek lagi token dari @BotFather."
        ) from exc
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise ProvisioningError(
            "token_unreachable", f"Gagal menghubungi Telegram API untuk verifikasi token: {exc}"
        ) from exc
    except ValueError as exc:  # JSON decode failure
        raise ProvisioningError("token_invalid", "Respons Telegram tidak valid saat verifikasi token.") from exc

    if not body.get("ok"):
        raise ProvisioningError(
            "token_invalid", f"Token ditolak Telegram: {body.get('description', 'unknown error')}"
        )
    return body.get("result", {})


@dataclass(frozen=True)
class ProvisionResult:
    profile_name: str
    profile_dir: Path
    bot_username: Optional[str]


def provision_profile_for_token(
    *,
    profile_name: str,
    token: str,
    requester_platform_user_id: str,
    hermes_executable: Optional[list[str]] = None,
) -> ProvisionResult:
    """End-to-end: validate token, create an isolated profile, install and
    start its own gateway service. Raises ProvisioningError at the first
    failing stage — callers should treat any raised stage as "no
    half-created profile was left running" (see the per-step cleanup
    below); a profile DIRECTORY may remain on disk after a late-stage
    failure (service install/start), but it will not have a live gateway
    process, and re-running provisioning with the same name is safe
    (``create_profile`` is called only once per name; a retry after an
    install/start failure should call ``ensure_gateway_installed_and_started``
    directly rather than this function, to avoid a duplicate
    ``create_profile`` FileExistsError).

    ``hermes_executable`` is injectable for tests (avoids spawning the
    real CLI); defaults to ``[sys.executable, "-m", "wangsa_cli.main"]``,
    the same entry point ``pyproject.toml`` wires to the ``hermes``
    console script.
    """
    stripped_token = token.strip()

    if not looks_like_bot_token(stripped_token):
        raise ProvisioningError(
            "token_invalid",
            "Format token tidak seperti token bot Telegram (harusnya <angka>:<kode>). "
            "Ambil token dari @BotFather lalu kirim ulang.",
        )

    holder = token_already_in_use(stripped_token)
    if holder is not None:
        raise ProvisioningError(
            "token_conflict",
            f"Token ini sudah dipakai profile '{holder}' di instalasi ini — "
            "setiap bot butuh token sendiri, tidak bisa dipakai bersama.",
        )

    bot_info = verify_bot_token_live(stripped_token)

    from wangsa_cli.profiles import create_profile, normalize_profile_name, validate_profile_name

    canonical_name = normalize_profile_name(profile_name)
    validate_profile_name(canonical_name)

    try:
        profile_dir = create_profile(canonical_name, no_alias=True)
    except FileExistsError as exc:
        raise ProvisioningError(
            "profile_exists", f"Profile '{canonical_name}' sudah ada — hubungi admin kalau ini bukan bot Anda."
        ) from exc

    try:
        _write_token_to_profile(profile_dir, stripped_token)
    except Exception as exc:
        raise ProvisioningError("token_write_failed", f"Gagal menyimpan token ke profile baru: {exc}") from exc

    ensure_gateway_installed_and_started(canonical_name, hermes_executable=hermes_executable)

    return ProvisionResult(
        profile_name=canonical_name,
        profile_dir=profile_dir,
        bot_username=bot_info.get("username"),
    )


def _write_token_to_profile(profile_dir: Path, token: str) -> None:
    """Write TELEGRAM_BOT_TOKEN into ``profile_dir``'s own .env, scoped via
    ``set_hermes_home_override`` so ``save_env_value`` targets that
    profile's file — never the process-global/root .env (verified against
    the real, non-mocked config module in the test suite, not a stub)."""
    from wangsa_constants import set_hermes_home_override, reset_hermes_home_override
    from wangsa_cli.config import save_env_value

    home_token = set_hermes_home_override(str(profile_dir))
    try:
        save_env_value("TELEGRAM_BOT_TOKEN", token)
    finally:
        reset_hermes_home_override(home_token)


def ensure_gateway_installed_and_started(
    profile_name: str,
    *,
    hermes_executable: Optional[list[str]] = None,
    timeout: float = 120.0,
) -> None:
    """Install (if needed) and start this profile's own gateway service via
    the SAME CLI entry point an operator would use by hand —
    ``hermes --profile <name> gateway install`` then ``... gateway start``
    — run as real subprocesses so ``--profile`` is intercepted at argv
    parse time (wangsa_cli/main.py's pre-parse step) exactly like every
    other ``--profile`` invocation. Deliberately not calling
    ``launchd_install()``/``systemd_install()`` in-process: those read
    process-global state (``get_hermes_home()`` et al.) that this
    process's own ``HERMES_HOME`` already point elsewhere, and mixing that
    with a context override was the exact multiplexer bug class Fase 5 in
    the sibling wangsa/ project was formed to avoid — a real subprocess
    sidesteps it entirely, at the cost of a slower call.
    """
    base = hermes_executable or [sys.executable, "-m", "wangsa_cli.main"]

    install = subprocess.run(
        [*base, "--profile", profile_name, "gateway", "install", "--start-now"],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if install.returncode != 0:
        raise ProvisioningError(
            "gateway_install_failed",
            f"Gagal menginstall gateway untuk profile '{profile_name}': {install.stderr.strip() or install.stdout.strip()}",
        )

    start = subprocess.run(
        [*base, "--profile", profile_name, "gateway", "start"],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if start.returncode != 0:
        raise ProvisioningError(
            "gateway_start_failed",
            f"Gateway ter-install tapi gagal start untuk profile '{profile_name}': {start.stderr.strip() or start.stdout.strip()}",
        )
