"""Small deterministic anamnesis planner; LLM adapter can replace internals later."""

from __future__ import annotations


def _validate(value: dict) -> None:
    if value.get("version") != 1 or not value.get("goal") or not value.get("steps"):
        raise ValueError("Invalid blueprint")


def plan_request(prompt: str) -> dict:
    prompt = prompt.strip()
    if prompt.casefold() in {"bantu dong", "tolong", "help", "bantu"}:
        return {
            "outcome": "needs_info",
            "questions": ["Apa hasil akhir yang Anda inginkan, dan di mana hasilnya harus dikirim atau disimpan?"],
            "blueprint": None,
        }
    blueprint = {
        "version": 1,
        "goal": prompt,
        "title": prompt[:70],
        "summary": "Execute requested automation after explicit approval.",
        "assumptions": [],
        "questions": [],
        "required_access": [],
        "steps": [{"id": "step-1", "action": "agent_execute", "description": prompt, "side_effect": True}],
        "risks": ["External side effects require explicit approval."],
        "approval_points": ["before_external_side_effect"],
        "execution_mode": "subagent",
        "schedule": None,
    }
    _validate(blueprint)
    return {"outcome": "blueprint_ready", "questions": [], "blueprint": blueprint}


def plan_to_json(prompt: str) -> dict:
    return plan_request(prompt)


__all__ = ["plan_request", "plan_to_json"]
