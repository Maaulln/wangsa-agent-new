#!/usr/bin/env python3
"""Runner script for Wangsa Agent Backend with Wangsa Mobile Platform enabled."""

from __future__ import annotations

import os
import sys

# Ensure default environment variables for container / server execution
port = os.getenv("WANGSA_MOBILE_PORT", "9901")
host = os.getenv("WANGSA_MOBILE_HOST", "0.0.0.0")

os.environ["WANGSA_MOBILE_PORT"] = str(port)
os.environ["WANGSA_MOBILE_HOST"] = str(host)
os.environ["WANGSA_MOBILE_ENABLED"] = "1"
os.environ.setdefault("WANGSA_MOBILE_ALLOW_INSECURE_HOST", "1")
os.environ.setdefault("GATEWAY_MULTIPLEX_PROFILES", "1")

print("==================================================================")
print(f"🚀 Wangsa Mobile Backend Server Starting")
print(f"   Listening on: http://{host}:{port}")
print(f"   Mobile API:   http://{host}:{port}/api/v1/agents/wangsa")
print("==================================================================")

# Ensure bundled and registered plugins are discovered
try:
    from wangsa_cli.plugins import discover_plugins

    discover_plugins(force=True)
except Exception as e:
    print(f"⚠️ Plugin discovery warning: {e}", file=sys.stderr)

# Run standard gateway
from gateway.run import main

if __name__ == "__main__":
    main()
