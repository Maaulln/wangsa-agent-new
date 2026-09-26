"""Run with python -m apps.mobile_backend init|serve|doctor."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from .config import initialize, load_settings


def main() -> None:
    parser = argparse.ArgumentParser(description="Wangsa Android product backend")
    sub = parser.add_subparsers(dest="command", required=True)
    init = sub.add_parser("init", help="Create config and a new private encryption key")
    init.add_argument("directory", type=Path)
    for name in ("serve", "doctor"):
        command = sub.add_parser(name)
        command.add_argument("--config", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == "init":
            print(f"Created {initialize(args.directory)}")
            return
        settings = load_settings(args.config)
        if args.command == "doctor":
            from .runtime import DockerRuntime

            result = DockerRuntime(image=settings.runtime_image).readiness()
            print(json.dumps(result, indent=2))
            if not result.get("available"):
                raise SystemExit(1)
            return
        import uvicorn

        from .api import create_app

        # Exactly one supervisor owns a SQLite control-plane directory.
        # Horizontal scaling requires an external transactional queue first.
        uvicorn.run(
            create_app(settings), host=settings.host, port=settings.port, workers=1
        )
    except (ValueError, OSError) as exc:
        parser.exit(2, f"Mobile backend: {exc}\n")


if __name__ == "__main__":
    main()
