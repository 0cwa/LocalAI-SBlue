"""Pure tray/controller helpers; intentionally independent of PyQt."""

from __future__ import annotations

import json


def command_args(action: str) -> list[str]:
    allowed = {"start", "stop", "restart", "status", "doctor"}
    if action not in allowed:
        raise ValueError(f"unsupported LocalAI action: {action}")
    return ["status", "--json"] if action == "status" else [action]


def parse_status(payload: str) -> dict[str, object]:
    value = json.loads(payload)
    required = {"backend", "tls_compose", "https_socket", "tls_enabled", "endpoint"}
    if not isinstance(value, dict) or not required.issubset(value):
        raise ValueError("incomplete LocalAI status response")
    return value


def stack_healthy(status: dict[str, object]) -> bool:
    if status.get("backend") != "active":
        return False
    if status.get("tls_enabled") is not True:
        return True
    return status.get("tls_compose") == "active" and status.get("https_socket") in {"active", "disabled"}


def display_state(value: object) -> str:
    return "unavailable" if value == "unknown" else str(value)


def has_unavailable_manager(status: dict[str, object]) -> bool:
    return any(status.get(key) == "unknown" for key in ("backend", "tls_compose", "https_socket"))


def endpoint(status: dict[str, object]) -> str:
    value = status.get("endpoint")
    if not isinstance(value, str) or not (value.startswith("http://") or value.startswith("https://")):
        raise ValueError("LocalAI status has no safe HTTP(S) endpoint")
    return value
