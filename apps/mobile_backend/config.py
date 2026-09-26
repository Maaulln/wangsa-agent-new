"""Configuration for the mobile control plane; credentials stay out of YAML."""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

import yaml
from cryptography.fernet import Fernet


@dataclass(frozen=True)
class Settings:
    data_dir: Path
    encryption_key: str
    host: str = "127.0.0.1"
    port: int = 9902
    runtime_image: str = "wangsa-mobile-runtime:local"
    max_workers: int = 2
    job_timeout_seconds: int = 900
    max_pending_per_user: int = 5
    max_jobs_per_day: int = 50
    session_ttl_seconds: int = 30 * 24 * 3600
    runtime_cpus: float = 1.0
    runtime_memory: str = "1g"
    runtime_pids_limit: int = 128

    def __post_init__(self) -> None:
        object.__setattr__(self, "data_dir", Path(self.data_dir).expanduser().resolve())
        try:
            Fernet(self.encryption_key.encode())
        except Exception:
            raise ValueError("A valid Fernet encryption key is required.") from None
        for name, low, high in (
            ("port", 1, 65535),
            ("max_workers", 1, 16),
            ("job_timeout_seconds", 30, 3600),
            ("max_pending_per_user", 1, 100),
            ("max_jobs_per_day", 1, 10000),
            ("session_ttl_seconds", 60, 90 * 86400),
            ("runtime_pids_limit", 16, 1024),
        ):
            value = getattr(self, name)
            if (
                isinstance(value, bool)
                or not isinstance(value, int)
                or not low <= value <= high
            ):
                raise ValueError(f"{name} must be an integer between {low} and {high}.")
        if not 0.1 <= self.runtime_cpus <= 16:
            raise ValueError("runtime_cpus must be between 0.1 and 16.")
        if not self.runtime_image or any(c.isspace() for c in self.runtime_image):
            raise ValueError("runtime_image must be a Docker image reference.")


def load_settings(path: Path) -> Settings:
    path = path.expanduser().resolve()
    raw = yaml.safe_load(path.read_text()) or {}
    if not isinstance(raw, dict):
        raise ValueError("Mobile backend configuration must be a YAML mapping.")
    values = dict(raw)
    key_file = Path(values.pop("encryption_key_file", "mobile.key"))
    if not key_file.is_absolute():
        key_file = path.parent / key_file
    key = os.environ.get("WANGSA_MOBILE_ENCRYPTION_KEY", "").strip()
    if not key:
        try:
            key = key_file.read_text().strip()
        except FileNotFoundError:
            raise ValueError(
                "Encryption key missing. Run the mobile backend init command first."
            ) from None
    # The master key is a secret, never inline behavioral configuration.
    if "encryption_key" in values:
        raise ValueError(
            "Use encryption_key_file or WANGSA_MOBILE_ENCRYPTION_KEY, not an inline key."
        )
    directory = Path(values.pop("data_dir", "data"))
    if not directory.is_absolute():
        directory = path.parent / directory
    return Settings(data_dir=directory, encryption_key=key, **values)


def initialize(directory: Path) -> Path:
    """Create a fresh deployment without overwriting a key or an existing DB."""
    directory = directory.expanduser().resolve()
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    config_path = directory / "mobile.yaml"
    key_path = directory / "mobile.key"
    if config_path.exists() or key_path.exists() or (directory / "data").exists():
        raise ValueError(
            "Destination already contains mobile state; refusing to replace its encryption key."
        )
    fd = os.open(key_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(fd, "w") as stream:
        stream.write(Fernet.generate_key().decode() + "\n")
    with config_path.open("x") as stream:
        yaml.safe_dump(
            {
                "host": "127.0.0.1",
                "port": 9902,
                "data_dir": "data",
                "encryption_key_file": "mobile.key",
                "runtime_image": "wangsa-mobile-runtime:local",
                "max_workers": 2,
                "job_timeout_seconds": 900,
                "max_pending_per_user": 5,
                "max_jobs_per_day": 50,
            },
            stream,
            sort_keys=False,
        )
    return config_path
