"""
Wangsa Mobile platform plugin for Hermes Agent.

Registers the ``wangsa_mobile`` inbound platform adapter — a two-route REST
API (GET agent identity, POST a message) consumed by the Wangsa Flutter
mobile app. Pure stdlib, zero core edits — everything goes through the
public PluginContext surface (``ctx.register_platform``).
"""

from __future__ import annotations

import logging
import os

logger = logging.getLogger(__name__)

__all__ = ["register"]


def check_requirements() -> bool:
    """Stdlib only — always loadable. Binds localhost-only unless a bearer
    token is configured."""
    return True


def validate_config(config) -> bool:
    """No required config — port/host/token have safe defaults."""
    return True


def is_connected(config) -> bool:
    extra = getattr(config, "extra", {}) or {}
    return bool(extra.get("enabled")) or bool(os.getenv("WANGSA_MOBILE_PORT")) or bool(os.getenv("WANGSA_MOBILE_ENABLED"))


def env_enablement() -> Optional[dict]:
    port = os.getenv("WANGSA_MOBILE_PORT")
    enabled = os.getenv("WANGSA_MOBILE_ENABLED", "").strip().lower() in ("1", "true", "yes")
    if not port and not enabled:
        return None
    return {
        "enabled": True,
        "port": int(port or 8000),
    }


def interactive_setup() -> None:
    """`hermes gateway setup` flow for Wangsa Mobile."""
    from wangsa_cli.setup import (
        prompt,
        prompt_yes_no,
        save_env_value,
        get_env_value,
        print_header,
        print_info,
        print_warning,
    )

    print_header("Wangsa Mobile")
    print_info("Expose Hermes to the Wangsa Flutter mobile app over a small REST API.")
    print_info("Uses Python stdlib — no extra packages needed.")
    print()

    port = prompt("Inbound port (default 9901)", default=get_env_value("WANGSA_MOBILE_PORT") or "")
    if port:
        try:
            save_env_value("WANGSA_MOBILE_PORT", str(int(port)))
        except ValueError:
            print_warning("Invalid port — using default 9901")

    name = prompt("Agent name to expose to the app (blank = default)", default=get_env_value("WANGSA_MOBILE_AGENT_NAME") or "")
    if name:
        save_env_value("WANGSA_MOBILE_AGENT_NAME", name.strip())

    purpose = prompt("Agent purpose/description (blank = default)", default=get_env_value("WANGSA_MOBILE_AGENT_PURPOSE") or "")
    if purpose:
        save_env_value("WANGSA_MOBILE_AGENT_PURPOSE", purpose.strip())

    print()
    print_info("Security: with NO token configured the server binds to 127.0.0.1 only.")
    if prompt_yes_no("Configure a bearer token to allow REMOTE access (e.g. a physical device)?", False):
        token = prompt("Bearer token (blank to skip)", password=True)
        if token:
            save_env_value("WANGSA_MOBILE_BEARER_TOKEN", token)
            host = prompt("Bind host for remote access (e.g. 0.0.0.0)", default=get_env_value("WANGSA_MOBILE_HOST") or "")
            if host:
                save_env_value("WANGSA_MOBILE_HOST", host.strip())
        else:
            print_warning("No token entered — staying localhost-only.")


def register(ctx) -> None:
    """Plugin entry point — called by the Hermes plugin system."""
    try:
        from .adapter import WangsaMobileAdapter
        ctx.register_platform(
            name="wangsa_mobile",
            label="Wangsa Mobile",
            adapter_factory=lambda cfg: WangsaMobileAdapter(cfg),
            check_fn=check_requirements,
            validate_config=validate_config,
            is_connected=is_connected,
            required_env=[],
            install_hint="No extra packages needed (stdlib only)",
            setup_fn=interactive_setup,
            emoji="\U0001f4f1",  # mobile phone
            allowed_users_env="WANGSA_MOBILE_ALLOWED_USERS",
            allow_all_env="WANGSA_MOBILE_ALLOW_ALL_USERS",
            cron_deliver_env_var="WANGSA_MOBILE_HOME_CHANNEL",
            env_enablement_fn=env_enablement,
            allow_update_command=False,
            platform_hint=(
                "You are reachable from the Wangsa mobile app. Replies are "
                "delivered synchronously back to the app over REST — keep "
                "answers concise and mobile-friendly."
            ),
        )
    except Exception:
        logger.warning("wangsa_mobile: failed to register platform adapter", exc_info=True)
