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

print("tray adapter tests passed")
