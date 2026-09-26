"""Mobile-only browser secret filling. Values never enter model tool arguments."""

from __future__ import annotations

import json

from tools.registry import registry

_ACTIVE_SECRETS: dict[str, str] = {}


def set_active_secrets(values: dict[str, str]) -> None:
    _ACTIVE_SECRETS.clear()
    _ACTIVE_SECRETS.update(values)


def clear_active_secrets() -> None:
    for key in tuple(_ACTIVE_SECRETS):
        _ACTIVE_SECRETS[key] = ""
    _ACTIVE_SECRETS.clear()


def _fill(args: dict, **kw) -> str:
    name, ref = args.get("name"), args.get("ref")
    value = _ACTIVE_SECRETS.get(name, "")
    if not value:
        return json.dumps({"success": False, "error": "Credential unavailable."})
    try:
        from tools.browser_tool import browser_type_secret

        result = json.loads(browser_type_secret(ref, value, task_id=kw.get("task_id")))
    except Exception:
        return json.dumps({"success": False, "error": "Credential could not be filled."})
    # Never pass through the browser tool's echoed typed value or page content.
    if result.get("success"):
        return json.dumps({"success": True, "credential": name, "element": ref})
    return json.dumps({"success": False, "error": "Credential could not be filled."})


registry.register(
    name="browser_fill_secret",
    toolset="mobile_browser_secrets",
    schema={
        "name": "browser_fill_secret",
        "description": (
            "Fill a login field using a user-supplied credential without exposing its value. "
            "The available names are netid and password. Inspect the browser first."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "enum": ["netid", "password"]},
                "ref": {"type": "string", "description": "Input ref such as @e2"},
            },
            "required": ["name", "ref"],
        },
    },
    handler=_fill,
    check_fn=lambda: True,
    emoji="🔐",
)
