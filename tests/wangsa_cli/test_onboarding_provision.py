"""Tests for wangsa_cli.onboarding_provision — auto-provisioning an
isolated profile + its own gateway process from a user-supplied Telegram
bot token. Mirrors the fixture style of tests/wangsa_cli/test_profiles.py
(redirect Path.home()/HERMES_HOME into tmp_path) and stubs Telegram's
getMe / subprocess spawn at their exact seams so no real network call or
real service install ever happens in the test suite.
"""

from __future__ import annotations

from pathlib import Path
from unittest.mock import patch, MagicMock

import pytest

from wangsa_cli.onboarding_provision import (
    looks_like_bot_token,
    token_already_in_use,
    verify_bot_token_live,
    provision_profile_for_token,
    ensure_gateway_installed_and_started,
    ProvisioningError,
)

FAKE_TOKEN = "123456789:AAFakeTokenForTestingPurposesOnly1234"
FAKE_TOKEN_2 = "987654321:AAAnotherFakeTokenForTestingPurpose99"


@pytest.fixture()
def profile_env(tmp_path, monkeypatch):
    """Same isolation fixture as tests/wangsa_cli/test_profiles.py."""
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    default_home = tmp_path / ".hermes"
    default_home.mkdir(exist_ok=True)
    monkeypatch.setenv("HERMES_HOME", str(default_home))
    return tmp_path


class TestLooksLikeBotToken:
    def test_accepts_realistic_shape(self):
        assert looks_like_bot_token(FAKE_TOKEN)

    def test_rejects_garbage(self):
        assert not looks_like_bot_token("not-a-token-at-all")

    def test_rejects_missing_colon(self):
        assert not looks_like_bot_token("123456789AAFakeTokenForTestingPurposesOnly")

    def test_rejects_too_short_secret(self):
        assert not looks_like_bot_token("123456789:short")

    def test_tolerates_surrounding_whitespace(self):
        assert looks_like_bot_token(f"  {FAKE_TOKEN}  ")


class TestTokenAlreadyInUse:
    def test_no_profiles_returns_none(self, profile_env):
        assert token_already_in_use(FAKE_TOKEN) is None

    def test_finds_token_in_an_existing_profile(self, profile_env):
        from wangsa_cli.profiles import create_profile
        from wangsa_constants import set_hermes_home_override, reset_hermes_home_override
        from wangsa_cli.config import save_env_value

        profile_dir = create_profile("existing-user", no_alias=True)
        token = set_hermes_home_override(str(profile_dir))
        try:
            save_env_value("TELEGRAM_BOT_TOKEN", FAKE_TOKEN)
        finally:
            reset_hermes_home_override(token)

        assert token_already_in_use(FAKE_TOKEN) == "existing-user"
        # A different token must not false-positive against it.
        assert token_already_in_use(FAKE_TOKEN_2) is None

    def test_ignores_profile_with_no_env_token(self, profile_env):
        from wangsa_cli.profiles import create_profile

        create_profile("no-token-user", no_alias=True)
        assert token_already_in_use(FAKE_TOKEN) is None


class TestVerifyBotTokenLive:
    def test_raises_token_invalid_on_http_error(self, profile_env):
        import urllib.error

        with patch("urllib.request.urlopen", side_effect=urllib.error.HTTPError(
            "url", 401, "Unauthorized", {}, None
        )):
            with pytest.raises(ProvisioningError) as exc_info:
                verify_bot_token_live(FAKE_TOKEN)
            assert exc_info.value.stage == "token_invalid"

    def test_raises_token_unreachable_on_network_error(self, profile_env):
        import urllib.error

        with patch("urllib.request.urlopen", side_effect=urllib.error.URLError("no route")):
            with pytest.raises(ProvisioningError) as exc_info:
                verify_bot_token_live(FAKE_TOKEN)
            assert exc_info.value.stage == "token_unreachable"

    def test_raises_token_invalid_when_telegram_says_not_ok(self, profile_env):
        import json
        import io

        fake_body = json.dumps({"ok": False, "description": "Unauthorized"}).encode()

        class FakeResponse:
            def __enter__(self):
                return self
            def __exit__(self, *a):
                return False
            def read(self):
                return fake_body

        with patch("urllib.request.urlopen", return_value=FakeResponse()):
            with pytest.raises(ProvisioningError) as exc_info:
                verify_bot_token_live(FAKE_TOKEN)
            assert exc_info.value.stage == "token_invalid"

    def test_returns_bot_info_on_success(self, profile_env):
        import json

        fake_body = json.dumps({"ok": True, "result": {"username": "my_test_bot", "id": 42}}).encode()

        class FakeResponse:
            def __enter__(self):
                return self
            def __exit__(self, *a):
                return False
            def read(self):
                return fake_body

        with patch("urllib.request.urlopen", return_value=FakeResponse()):
            result = verify_bot_token_live(FAKE_TOKEN)
            assert result["username"] == "my_test_bot"


class TestEnsureGatewayInstalledAndStarted:
    def test_runs_install_then_start_with_profile_flag(self, profile_env):
        calls = []

        def fake_run(cmd, **kwargs):
            calls.append(cmd)
            return MagicMock(returncode=0, stdout="", stderr="")

        with patch("subprocess.run", side_effect=fake_run):
            ensure_gateway_installed_and_started("alpha", hermes_executable=["FAKE_HERMES"])

        assert calls == [
            ["FAKE_HERMES", "--profile", "alpha", "gateway", "install", "--start-now"],
            ["FAKE_HERMES", "--profile", "alpha", "gateway", "start"],
        ]

    def test_raises_gateway_install_failed_on_nonzero_exit(self, profile_env):
        def fake_run(cmd, **kwargs):
            if "install" in cmd:
                return MagicMock(returncode=1, stdout="", stderr="boom")
            return MagicMock(returncode=0, stdout="", stderr="")

        with patch("subprocess.run", side_effect=fake_run):
            with pytest.raises(ProvisioningError) as exc_info:
                ensure_gateway_installed_and_started("alpha", hermes_executable=["FAKE_HERMES"])
            assert exc_info.value.stage == "gateway_install_failed"

    def test_raises_gateway_start_failed_on_nonzero_exit(self, profile_env):
        def fake_run(cmd, **kwargs):
            if "start" in cmd:
                return MagicMock(returncode=1, stdout="", stderr="start boom")
            return MagicMock(returncode=0, stdout="", stderr="")

        with patch("subprocess.run", side_effect=fake_run):
            with pytest.raises(ProvisioningError) as exc_info:
                ensure_gateway_installed_and_started("alpha", hermes_executable=["FAKE_HERMES"])
            assert exc_info.value.stage == "gateway_start_failed"


class TestProvisionProfileForToken:
    def _patch_getme(self, username="new_user_bot"):
        import json

        fake_body = json.dumps({"ok": True, "result": {"username": username, "id": 1}}).encode()

        class FakeResponse:
            def __enter__(self):
                return self
            def __exit__(self, *a):
                return False
            def read(self):
                return fake_body

        return patch("urllib.request.urlopen", return_value=FakeResponse())

    def test_rejects_malformed_token_before_any_io(self, profile_env):
        with patch("subprocess.run") as mock_run:
            with pytest.raises(ProvisioningError) as exc_info:
                provision_profile_for_token(
                    profile_name="alpha",
                    token="not-a-real-token",
                    requester_platform_user_id="555",
                )
            assert exc_info.value.stage == "token_invalid"
            mock_run.assert_not_called()

    def test_rejects_token_already_claimed_by_another_profile(self, profile_env):
        from wangsa_cli.profiles import create_profile
        from wangsa_constants import set_hermes_home_override, reset_hermes_home_override
        from wangsa_cli.config import save_env_value

        profile_dir = create_profile("holder", no_alias=True)
        token = set_hermes_home_override(str(profile_dir))
        try:
            save_env_value("TELEGRAM_BOT_TOKEN", FAKE_TOKEN)
        finally:
            reset_hermes_home_override(token)

        with pytest.raises(ProvisioningError) as exc_info:
            provision_profile_for_token(
                profile_name="beta",
                token=FAKE_TOKEN,
                requester_platform_user_id="555",
            )
        assert exc_info.value.stage == "token_conflict"

    def test_full_success_path_creates_isolated_profile_with_token(self, profile_env):
        with self._patch_getme(username="alpha_bot"), patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=0, stdout="", stderr="")

            result = provision_profile_for_token(
                profile_name="alpha-user",
                token=FAKE_TOKEN,
                requester_platform_user_id="555",
                hermes_executable=["FAKE_HERMES"],
            )

        assert result.profile_name == "alpha-user"
        assert result.bot_username == "alpha_bot"
        assert result.profile_dir.is_dir()

        env_text = (result.profile_dir / ".env").read_text(encoding="utf-8")
        assert f"TELEGRAM_BOT_TOKEN={FAKE_TOKEN}" in env_text

        # The subprocess calls happened with --profile pointed at THIS
        # profile, never the default/root profile.
        install_call = mock_run.call_args_list[0].args[0]
        assert install_call == ["FAKE_HERMES", "--profile", "alpha-user", "gateway", "install", "--start-now"]

        # The root .env (default profile) must be untouched by this
        # provisioning run — the token belongs to alpha-user only.
        root_env = profile_env / ".hermes" / ".env"
        assert not root_env.exists() or "TELEGRAM_BOT_TOKEN" not in root_env.read_text()

    def test_second_provision_with_same_profile_name_is_rejected(self, profile_env):
        with self._patch_getme(), patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=0, stdout="", stderr="")
            provision_profile_for_token(
                profile_name="dup-user",
                token=FAKE_TOKEN,
                requester_platform_user_id="555",
                hermes_executable=["FAKE_HERMES"],
            )

            with pytest.raises(ProvisioningError) as exc_info:
                provision_profile_for_token(
                    profile_name="dup-user",
                    token=FAKE_TOKEN_2,
                    requester_platform_user_id="777",
                    hermes_executable=["FAKE_HERMES"],
                )
            assert exc_info.value.stage == "profile_exists"

    def test_gateway_install_failure_does_not_swallow_the_created_profile_error(self, profile_env):
        """A late-stage failure still surfaces its own stage, not a generic one —
        callers rely on `.stage` to tell the user exactly what to retry."""
        def fake_run(cmd, **kwargs):
            return MagicMock(returncode=1, stdout="", stderr="install exploded")

        with self._patch_getme(), patch("subprocess.run", side_effect=fake_run):
            with pytest.raises(ProvisioningError) as exc_info:
                provision_profile_for_token(
                    profile_name="fails-late",
                    token=FAKE_TOKEN,
                    requester_platform_user_id="555",
                    hermes_executable=["FAKE_HERMES"],
                )
            assert exc_info.value.stage == "gateway_install_failed"

        # The profile directory + token WERE written before the failing
        # step — documented behavior (see provision_profile_for_token's
        # docstring): re-provisioning under the same name must go through
        # ensure_gateway_installed_and_started directly, not this function.
        from wangsa_cli.profiles import get_profile_dir
        assert (get_profile_dir("fails-late") / ".env").read_text(encoding="utf-8").find(FAKE_TOKEN) != -1
