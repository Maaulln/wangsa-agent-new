"""Tests for per-profile spend budgets (agent/budgets.py).

Budgets are guardrails read inside the caller's profile scope: config from
the profile's config.yaml, spend from the profile's state.db ledger
(session_model_usage, aux-inclusive). Fail-open on any read error.
"""

from __future__ import annotations

import sqlite3
import time

import agent.budgets as budgets


def _write_state_db(path, rows):
    """Create a minimal ledger: sessions + session_model_usage with cost cols."""
    con = sqlite3.connect(str(path))
    con.execute(
        """CREATE TABLE sessions (
            id TEXT PRIMARY KEY, started_at REAL,
            estimated_cost_usd REAL, actual_cost_usd REAL)"""
    )
    con.execute(
        """CREATE TABLE session_model_usage (
            session_id TEXT, model TEXT, billing_provider TEXT DEFAULT '',
            billing_base_url TEXT DEFAULT '', billing_mode TEXT DEFAULT '',
            task TEXT DEFAULT '', api_call_count INT DEFAULT 0,
            input_tokens INT DEFAULT 0, output_tokens INT DEFAULT 0,
            cache_read_tokens INT DEFAULT 0, cache_write_tokens INT DEFAULT 0,
            reasoning_tokens INT DEFAULT 0,
            estimated_cost_usd REAL DEFAULT 0, actual_cost_usd REAL DEFAULT 0,
            cost_status TEXT, cost_source TEXT,
            first_seen REAL, last_seen REAL,
            PRIMARY KEY(session_id,model,billing_provider,billing_base_url,billing_mode,task))"""
    )
    now = time.time()
    for i, (age_secs, est, actual) in enumerate(rows):
        sid = f"sess-{i}"
        con.execute(
            "INSERT INTO sessions(id,started_at,estimated_cost_usd,actual_cost_usd)"
            " VALUES (?,?,?,?)",
            (sid, now - age_secs, est, actual),
        )
        con.execute(
            "INSERT INTO session_model_usage(session_id,model,task,estimated_cost_usd,actual_cost_usd)"
            " VALUES (?,?,?,?,?)",
            (sid, "m", "", est, actual),
        )
    con.commit()
    con.close()


def _use_home(monkeypatch, tmp_path):
    home = tmp_path / ".hermes"
    home.mkdir()
    monkeypatch.setenv("HERMES_HOME", str(home))
    return home


def _write_config(home, budgets_cfg):
    import wangsa_cli.config as config_mod

    cfg = config_mod.load_config()
    cfg["budgets"] = budgets_cfg
    config_mod.save_config(cfg)


class TestCoerce:
    def test_usd(self):
        assert budgets._coerce_usd(None) is None
        assert budgets._coerce_usd(0) is None
        assert budgets._coerce_usd(-5) is None
        assert budgets._coerce_usd("abc") is None
        assert budgets._coerce_usd(10) == 10.0
        assert budgets._coerce_usd("2.5") == 2.5

    def test_threshold(self):
        assert budgets._coerce_threshold(None) == 0.8
        assert budgets._coerce_threshold(2) == 1.0
        assert budgets._coerce_threshold(-1) == 0.0


class TestSpend:
    def test_no_db_is_zero_not_degraded(self, monkeypatch, tmp_path):
        _use_home(monkeypatch, tmp_path)
        spend, degraded = budgets.profile_spend_usd(time.time() - 100)
        assert spend == 0.0
        assert degraded is False

    def test_actual_over_estimated(self, monkeypatch, tmp_path):
        home = _use_home(monkeypatch, tmp_path)
        # actual=0.30 wins over estimated=1.50; NULLs count 0.
        _write_state_db(home / "state.db", [(100, 1.50, 0.30), (200, 0.10, None)])
        spend, degraded = budgets.profile_spend_usd(time.time() - 1000)
        assert degraded is False
        assert abs(spend - 0.40) < 1e-9

    def test_window_filters_old_rows(self, monkeypatch, tmp_path):
        home = _use_home(monkeypatch, tmp_path)
        _write_state_db(home / "state.db", [(100, 1.0, None), (100000, 5.0, None)])
        spend, _ = budgets.profile_spend_usd(time.time() - 1000)
        assert abs(spend - 1.0) < 1e-9


class TestGate:
    def test_unlimited_allows(self, monkeypatch, tmp_path):
        home = _use_home(monkeypatch, tmp_path)
        _write_config(home, {"enabled": True, "daily_usd": None, "monthly_usd": None})
        _write_state_db(home / "state.db", [(100, 99.0, None)])
        allowed, msg, status = budgets.check_budget()
        assert allowed is True
        assert status["breached"] is None

    def test_disabled_allows(self, monkeypatch, tmp_path):
        home = _use_home(monkeypatch, tmp_path)
        _write_config(home, {"enabled": False, "daily_usd": 0.01})
        _write_state_db(home / "state.db", [(100, 99.0, None)])
        allowed, _, status = budgets.check_budget()
        assert allowed is True
        assert status["enabled"] is False

    def test_daily_breach_blocks(self, monkeypatch, tmp_path):
        home = _use_home(monkeypatch, tmp_path)
        _write_config(home, {"enabled": True, "daily_usd": 1.0, "monthly_usd": None})
        _write_state_db(home / "state.db", [(100, 2.5, None)])
        allowed, msg, status = budgets.check_budget()
        assert allowed is False
        assert status["breached"] == "daily"
        assert "harian" in msg

    def test_monthly_breach_blocks(self, monkeypatch, tmp_path):
        home = _use_home(monkeypatch, tmp_path)
        # Old spend (2 days ago) is outside the daily window but inside 30d.
        _write_config(home, {"enabled": True, "daily_usd": None, "monthly_usd": 1.0})
        _write_state_db(home / "state.db", [(2 * 86400, 2.5, None)])
        allowed, msg, status = budgets.check_budget()
        assert allowed is False
        assert status["breached"] == "monthly"
        assert "bulanan" in msg

    def test_alert_without_breach(self, monkeypatch, tmp_path):
        home = _use_home(monkeypatch, tmp_path)
        _write_config(
            home,
            {"enabled": True, "daily_usd": 10.0, "monthly_usd": None, "alert_threshold": 0.8},
        )
        _write_state_db(home / "state.db", [(100, 8.5, None)])
        allowed, _, status = budgets.check_budget()
        assert allowed is True
        assert status["breached"] is None
        assert status["alert"] is True
