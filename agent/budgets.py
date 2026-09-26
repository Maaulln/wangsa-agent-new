"""Per-profile spend budgets — pre-turn enforcement for shared backends.

Each profile carries its own ``budgets:`` section in its own ``config.yaml``
(``wangsa_cli/config_defaults.py``), and its own spend ledger in its own
``state.db`` (``session_model_usage``, aux-inclusive). This module reads both
**inside the caller's profile scope** — call it only from a path that already
installed ``_profile_runtime_scope`` (gateway ``_run_agent``, mobile
``_guarded``, cron fire) so ``get_hermes_home()`` resolves to the right user.

Spend = ``SUM(COALESCE(actual_cost_usd, estimated_cost_usd, 0))`` over the
complete ledger (main loop ``task=''`` + aux ``task!=''``), windowed on
``sessions.started_at`` (same convention as analytics + InsightsEngine).

Fail-open: any read error (missing DB, locked, corrupt) returns
``allowed=True`` with ``status["degraded"]=True`` — a budget must never
brick chat because the ledger was unreadable. Overshoot between check and
write is possible (async accounting queue); caps are guardrails, not
atomic bank balances.
"""

from __future__ import annotations

import logging
import sqlite3
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Optional, Tuple

logger = logging.getLogger(__name__)


def _coerce_usd(value: Any) -> Optional[float]:
    """Positive float or None (None/0/negative/unparseable = unlimited)."""
    if value is None:
        return None
    try:
        amount = float(value)
    except (TypeError, ValueError):
        return None
    if amount <= 0:
        return None
    return amount


def _coerce_threshold(value: Any) -> float:
    try:
        threshold = float(value if value is not None else 0.8)
    except (TypeError, ValueError):
        return 0.8
    return min(1.0, max(0.0, threshold))


def get_budget_config() -> Dict[str, Any]:
    """Return the active profile's budget config (never raises)."""
    try:
        try:
            from wangsa_cli.config import load_config_readonly
        except ImportError:
            from hermes_cli.config import load_config_readonly  # type: ignore
        cfg = load_config_readonly().get("budgets") or {}
        if not isinstance(cfg, dict):
            return {}
        return cfg
    except Exception:
        logger.debug("budgets: failed to load config", exc_info=True)
        return {}


def _state_db_path() -> Optional[Path]:
    try:
        try:
            from wangsa_constants import get_hermes_home
        except ImportError:
            from hermes_constants import get_hermes_home  # type: ignore
        path = get_hermes_home() / "state.db"
        return path if path.is_file() else None
    except Exception:
        return None


def profile_spend_usd(since_ts: float) -> Tuple[float, bool]:
    """Spend in USD since *since_ts* for the active profile.

    Returns ``(spend, degraded)``. ``degraded=True`` means the ledger could
    not be read — treat spend as 0 and fail open.
    """
    path = _state_db_path()
    if path is None:
        return 0.0, False
    try:
        con = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=5)
    except Exception:
        logger.debug("budgets: cannot open state.db", exc_info=True)
        return 0.0, True
    try:
        try:
            row = con.execute(
                """
                SELECT COALESCE(SUM(COALESCE(u.actual_cost_usd, u.estimated_cost_usd, 0)), 0)
                FROM session_model_usage u
                JOIN sessions s ON s.id = u.session_id
                WHERE s.started_at > ?
                """,
                (since_ts,),
            ).fetchone()
        except sqlite3.OperationalError:
            # Pre-migration schema without cost columns — fail open.
            return 0.0, True
        spend = float(row[0] or 0.0) if row else 0.0
        return max(0.0, spend), False
    except Exception:
        logger.debug("budgets: spend query failed", exc_info=True)
        return 0.0, True
    finally:
        try:
            con.close()
        except Exception:
            pass


def _utc_midnight_ts(now: Optional[float] = None) -> float:
    now_dt = datetime.fromtimestamp(now or time.time(), tz=timezone.utc)
    midnight = now_dt.replace(hour=0, minute=0, second=0, microsecond=0)
    return midnight.timestamp()


def budget_status(now: Optional[float] = None) -> Dict[str, Any]:
    """Full budget picture for the active profile (never raises)."""
    now = now or time.time()
    cfg = get_budget_config()
    enabled = bool(cfg.get("enabled", True))
    daily_cap = _coerce_usd(cfg.get("daily_usd"))
    monthly_cap = _coerce_usd(cfg.get("monthly_usd"))
    threshold = _coerce_threshold(cfg.get("alert_threshold"))

    spent_day, degraded_day = profile_spend_usd(_utc_midnight_ts(now))
    spent_month, degraded_month = profile_spend_usd(now - 30 * 86400)

    breached: Optional[str] = None
    if enabled:
        if daily_cap is not None and spent_day >= daily_cap:
            breached = "daily"
        elif monthly_cap is not None and spent_month >= monthly_cap:
            breached = "monthly"

    alert = False
    if enabled and breached is None and threshold > 0:
        if daily_cap is not None and spent_day >= daily_cap * threshold:
            alert = True
        if monthly_cap is not None and spent_month >= monthly_cap * threshold:
            alert = True

    return {
        "enabled": enabled,
        "daily_usd": daily_cap,
        "monthly_usd": monthly_cap,
        "alert_threshold": threshold,
        "spent_day": round(spent_day, 4),
        "spent_month": round(spent_month, 4),
        "breached": breached,
        "alert": alert,
        "degraded": bool(degraded_day or degraded_month),
    }


def check_budget(now: Optional[float] = None) -> Tuple[bool, str, Dict[str, Any]]:
    """Pre-turn gate. Returns ``(allowed, message, status)`` (never raises)."""
    status = budget_status(now)
    if not status["enabled"] or status["breached"] is None:
        return True, "", status
    if status["breached"] == "daily":
        message = (
            f"Batas harian tercapai (${status['spent_day']:.2f} / "
            f"${status['daily_usd']:.2f}). Limit reset tengah malam UTC "
            f"atau naikkan di config.yaml (budgets.daily_usd)."
        )
    else:
        message = (
            f"Batas bulanan tercapai (${status['spent_month']:.2f} / "
            f"${status['monthly_usd']:.2f}). Naikkan di config.yaml "
            f"(budgets.monthly_usd) atau tunggu periode berjalan."
        )
    return False, message, status
