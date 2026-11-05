"""Pure tray/controller helpers; intentionally independent of PyQt."""

from __future__ import annotations

import json
import re
from urllib.parse import urlsplit


MENU_STRUCTURE = (
    "status",
    "manager_help",
    None,
    "doctor",
    "open_endpoint",
    "copy_endpoint",
    None,
    "backend_logs",
    "tls_logs",
    None,
    "start",
    "stop",
    None,
    "quit_stop",
    "exit",
)

_SERVICE_STATES = {
    "active",
    "inactive",
    "failed",
    "activating",
    "deactivating",
    "unknown",
    "disabled",
}


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
    result: dict[str, object] = {}
    for key in ("backend", "tls_compose", "https_socket"):
        state = value[key]
        if not isinstance(state, str) or state not in _SERVICE_STATES:
            raise ValueError("invalid LocalAI service state")
        result[key] = state
    if not isinstance(value["tls_enabled"], bool):
        raise ValueError("invalid LocalAI TLS state")
    result["tls_enabled"] = value["tls_enabled"]
    result["endpoint"] = endpoint(value)
    return result


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
    if not isinstance(value, str) or any(char.isspace() or ord(char) < 32 for char in value):
        raise ValueError("LocalAI status has no safe HTTP(S) endpoint")
    if "\\" in value or "%" in value:
        raise ValueError("LocalAI status has no safe HTTP(S) endpoint")
    try:
        parsed = urlsplit(value)
        port = parsed.port
    except ValueError as error:
        raise ValueError("LocalAI status has no safe HTTP(S) endpoint") from error
    if (
        parsed.scheme not in {"http", "https"}
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or "?" in value
        or "#" in value
        or parsed.path not in {"", "/"}
        or (port is not None and not 1 <= port <= 65535)
        or "@" in parsed.netloc
    ):
        raise ValueError("LocalAI status has no safe HTTP(S) endpoint")
    return value


def doctor_result(output: str) -> tuple[str, int | None]:
    """Reduce untrusted doctor output to a safe result and optional HTTP code."""
    codes = re.findall(r"^health result: HTTP ([1-5][0-9]{2})$", output, re.MULTILINE)
    if codes:
        code = int(codes[-1])
        if code in {401, 403}:
            return "authentication-required", code
        return "reachable", code
    if re.search(r"^health result: transport or TLS validation failed \(no HTTP response\)$", output, re.MULTILINE):
        return "unreachable", None
    return "unknown", None


def doctor_summary(output: str) -> str:
    result, code = doctor_result(output)
    if result == "authentication-required":
        return f"Endpoint reachable; authentication required (HTTP {code})."
    if result == "reachable":
        return f"Endpoint reachable (HTTP {code})."
    if result == "unreachable":
        return "Endpoint unreachable (no HTTP response)."
    return "Health check could not determine endpoint status."


def parse_start_requested(argv: list[str]) -> bool:
    import argparse

    parser = argparse.ArgumentParser(description="Control the configured LocalAI stack from the system tray.")
    parser.add_argument("--start", action="store_true", help="start the LocalAI stack after the tray appears")
    return parser.parse_args(argv).start


def should_start_after_status(start_requested: bool, status: dict[str, object] | None) -> bool:
    return start_requested and status is not None and not stack_healthy(status)


def menu_entries(actions: dict[str, object]) -> tuple[object | None, ...]:
    return tuple(None if name is None else actions[name] for name in MENU_STRUCTURE)
