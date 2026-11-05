#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./test-support.sh
# The sourced helper is checked independently.
# shellcheck disable=SC1091
source "$repo_root/scripts/test-support.sh"
test_sanitize_localai_environment
# shellcheck disable=SC1091
source "$repo_root/lib/installer_safety.sh"
ipv4_publish_host="$(localai_installer_podman_publish_host 127.0.0.1)"
ipv6_publish_host="$(localai_installer_podman_publish_host ::1)"
if localai_installer_podman_publish_host localhost >/dev/null 2>&1; then
  printf 'hostname unexpectedly accepted for Podman published-port address\n' >&2
  exit 1
fi

python3 - "$repo_root" "$ipv4_publish_host" "$ipv6_publish_host" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
ipv4_publish_host = sys.argv[2]
ipv6_publish_host = sys.argv[3]
service = (root / "secureblue-localai-install/localai.service.in").read_text()
installer = (root / "secureblue-localai-install/install.sh").read_text()
compose = (root / "localai-podman-compose/localai-tls-compose.yaml.in").read_text()

required_service_mounts = (
    "LOCALAI_APP_HOME_PATH",
    "LOCALAI_MODELS_PATH",
    "LOCALAI_DATA_PATH",
    "LOCALAI_CONFIG_DIR",
    "LOCALAI_GENERATED_CONTENT_PATH",
    "LOCALAI_UPLOAD_PATH",
    "LOCALAI_CACHE_DIR",
    "LOCALAI_LOG_DIR",
    "LOCALAI_BACKENDS_PATH",
    "LOCALAI_DOWNLOAD_STAGING_PATH",
    "LOCALAI_BACKEND_TEMP_DIR",
)
for variable in required_service_mounts:
    entry = f"--volume ${{{variable}}}:${{{variable}}}"
    assert entry in service, f"missing same-path service mount for {variable}"

required_service_env = (
    "--env HOME=${LOCALAI_APP_HOME_PATH}",
    "--env XDG_CACHE_HOME=${LOCALAI_CACHE_DIR}",
    "--env TMPDIR=${LOCALAI_BACKEND_TEMP_DIR}",
    "--env LOCALAI_BACKENDS_PATH=${LOCALAI_BACKENDS_PATH}",
    "--env LOCALAI_DOWNLOAD_STAGING_PATH=${LOCALAI_DOWNLOAD_STAGING_PATH}",
    "--env LOCALAI_BACKEND_TEMP_DIR=${LOCALAI_BACKEND_TEMP_DIR}",
)
for entry in required_service_env:
    assert entry in service, f"missing service environment mapping: {entry}"

assert "Environment=HOME=@STATE_DIR@" in service, "host Podman HOME must stay the service-account state root"
assert "--volume ${LOCALAI_STATE_DIR}:${LOCALAI_STATE_DIR}" not in service, "do not expose the whole service-account HOME"
assert "--volume ${LOCALAI_BACKENDS_PATH}:/backends" not in service, "do not hide image-provided /backends contents"
assert ":/var/lib/local-ai/backends" not in service, "do not overlay the image's system-backend fallback path"
assert "--userns=keep-id" in service
assert "--group-add=keep-groups" in service
assert "--security-opt=no-new-privileges" in service

# Render the service's container command with synthetic values so the hardening
# assertions cover the generated invocation, including the loopback port map.
rendered = service.replace("@PUBLISH_HOST@", ipv4_publish_host)
rendered = rendered.replace("${LOCALAI_BIND_PORT}", "11455")
exec_start = next(line for line in rendered.splitlines() if line.startswith("ExecStart="))
for flag in (
    "--cap-drop=all",
    "--security-opt=no-new-privileges",
    "--pids-limit=4096",
    "--read-only",
    "--tmpfs /tmp:rw,nosuid,nodev,size=2g",
    "--network=pasta",
    f"--publish {ipv4_publish_host}:11455:11455",
    "--env LOCALAI_ADDRESS=0.0.0.0:11455",
):
    assert flag in exec_start, f"missing rendered backend hardening flag: {flag}"
assert "--network=host" not in exec_start, "backend must not share the host network namespace"
assert "--memory" not in exec_start, "memory limit remains unselected pending model workload qualification"
ipv6_rendered = service.replace("@PUBLISH_HOST@", ipv6_publish_host).replace("${LOCALAI_BIND_PORT}", "11455")
ipv6_exec_start = next(line for line in ipv6_rendered.splitlines() if line.startswith("ExecStart="))
assert f"--publish {ipv6_publish_host}:11455:11455" in ipv6_exec_start
publish_preflight = installer.index('localai_installer_podman_publish_host "$LOCALAI_BIND_HOST" >/dev/null')
elevation = installer.index("elevate_once\n")
existing_service_stop = installer.index("stop_existing_managed_service", elevation)
assert publish_preflight < elevation < existing_service_stop, "unsupported hostname must fail before elevation or stopping the existing service"

assert "@TLS_VOLUME_ENTRIES@" in compose, "TLS compose must use the individually generated volume list"
assert "@TLS_APP_HOME_DIR@" in compose, "TLS container HOME must use an app-only directory"
assert "HOME: @TLS_APP_HOME_DIR@" in compose
assert "XDG_DATA_HOME: @TLS_DATA_HOME@" in compose
assert "XDG_CONFIG_HOME: @TLS_CONFIG_HOME@" in compose
assert "XDG_CACHE_HOME: @TLS_CACHE_DIR@" in compose
assert "@TLS_STATE_DIR@:@TLS_STATE_DIR@" not in compose, "do not expose the whole TLS service-account HOME"
assert "@TLS_VOLUME@" not in compose, "legacy whole-state volume must not return"
assert "userns_mode: keep-id" in compose
assert "no-new-privileges" in compose

print("runtime writable-path template checks passed")
PY
