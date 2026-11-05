#!/usr/bin/env python3
import importlib.util
from pathlib import Path

module_path = Path(__file__).parents[1] / "localai-tray" / "adapter.py"
spec = importlib.util.spec_from_file_location("localai_tray_adapter", module_path)
assert spec and spec.loader
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)

assert adapter.command_args("status") == ["status", "--json"]
assert adapter.command_args("start") == ["start"]
assert adapter.command_args("doctor") == ["doctor"]
try:
    adapter.command_args("systemctl")
except ValueError:
    pass
else:
    raise AssertionError("arbitrary controller commands must be rejected")

tls_public = adapter.parse_status('{"backend":"active","tls_compose":"active","https_socket":"active","tls_enabled":true,"endpoint":"https://localai.example.test"}')
assert adapter.stack_healthy(tls_public)
assert adapter.endpoint(tls_public) == "https://localai.example.test"

tls_internal = adapter.parse_status('{"backend":"active","tls_compose":"active","https_socket":"disabled","tls_enabled":true,"endpoint":"https://127.0.0.1:8443"}')
assert adapter.stack_healthy(tls_internal)
assert adapter.endpoint(tls_internal) == "https://127.0.0.1:8443"

plain = adapter.parse_status('{"backend":"active","tls_compose":"disabled","https_socket":"disabled","tls_enabled":false,"endpoint":"http://127.0.0.1:11455"}')
assert adapter.stack_healthy(plain)
assert adapter.endpoint(plain).startswith("http://")

unavailable = adapter.parse_status('{"backend":"unknown","tls_compose":"unknown","https_socket":"unknown","tls_enabled":true,"endpoint":"https://localhost"}')
assert not adapter.stack_healthy(unavailable)
assert adapter.display_state(unavailable["backend"]) == "unavailable"
assert adapter.has_unavailable_manager(unavailable)
assert not adapter.has_unavailable_manager(plain)

# Service state is preserved independently and unknown payload fields never
# cross into the tray presentation model.
independent = adapter.parse_status(
    '{"backend":"failed","tls_compose":"active","https_socket":"inactive",'
    '"tls_enabled":true,"endpoint":"https://localai.example.test",'
    '"unexpected":"ignored"}'
)
assert independent["backend"] == "failed"
assert independent["tls_compose"] == "active"
assert independent["https_socket"] == "inactive"
assert "unexpected" not in independent

for unsafe_url in (
    "https://@localai.example.test",
    "https://localai.example.test?token",
    "https://localai.example.test#fragment",
    "https://localai.example.test/private-path",
):
    try:
        adapter.parse_status(
            '{"backend":"active","tls_compose":"disabled","https_socket":"disabled",'
            f'"tls_enabled":false,"endpoint":"{unsafe_url}"}}'
        )
    except ValueError:
        pass
    else:
        raise AssertionError("unsafe endpoint data must not be displayed or copied")

assert adapter.doctor_result("health result: HTTP 200") == ("reachable", 200)
assert adapter.doctor_result("health result: HTTP 401") == ("authentication-required", 401)
assert adapter.doctor_result(
    "health result: transport or TLS validation failed (no HTTP response)"
) == ("unreachable", None)
assert adapter.doctor_result("configuration error before health request") == ("unknown", None)
assert adapter.doctor_result("health endpoint: https://localai.example.test?token\n") == ("unknown", None)
assert adapter.doctor_summary("health endpoint: https://localai.example.test?token\nhealth result: HTTP 401") == (
    "Endpoint reachable; authentication required (HTTP 401)."
)
assert "localai.example.test" not in adapter.doctor_summary(
    "health endpoint: https://localai.example.test?token\nhealth result: HTTP 200"
)

# The visible menu is built directly from this headless-tested structure.
assert adapter.MENU_STRUCTURE == (
    "status", "manager_help", None, "doctor", "open_endpoint", "copy_endpoint",
    None, "backend_logs", "tls_logs", None, "start", "stop", None, "quit_stop", "exit",
)
menu_action_ids = {name: name for name in adapter.MENU_STRUCTURE if name is not None}
assert adapter.menu_entries(menu_action_ids) == (
    "status", "manager_help", None, "doctor", "open_endpoint", "copy_endpoint",
    None, "backend_logs", "tls_logs", None, "start", "stop", None, "quit_stop", "exit",
)
assert adapter.parse_start_requested([]) is False
assert adapter.parse_start_requested(["--start"]) is True
assert adapter.should_start_after_status(True, unavailable) is True
assert adapter.should_start_after_status(True, plain) is False
assert adapter.should_start_after_status(False, unavailable) is False

print("tray adapter tests passed")
