#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/config.sh
# The config loader is checked independently.
# shellcheck disable=SC1091
source "$script_dir/../lib/config.sh"

config_file="${LOCALAI_CONFIG_FILE:-/etc/localai/localai.conf}"
legacy_config_file="${LOCALAI_LEGACY_CONFIG_FILE:-/etc/localai.conf}"
if [[ -z "${LOCALAI_CONFIG_FILE:-}" && ! -e "$config_file" && ! -e "$legacy_config_file" ]]; then
  legacy_config_file="$script_dir/localai.lock"
fi
localai_config_load_compat "$config_file" "$legacy_config_file" || exit 2

service_user="$LOCALAI_SERVICE_USER"
service_uid="$(id -u "$service_user" 2>/dev/null || true)"
if [[ -z "$service_uid" || "$(id -u)" != "$service_uid" ]]; then
  printf 'Run this probe as the %s service account.\n' "$service_user" >&2
  exit 2
fi

confirm_probe=0
container_name="$LOCALAI_CONTAINER_NAME"
if [[ "${1:-}" == "--confirm-write-probe" ]]; then
  confirm_probe=1
  [[ -z "${2:-}" ]] || container_name="$2"
elif [[ -n "${1:-}" ]]; then
  container_name="$1"
fi
if [[ "$container_name" != "$LOCALAI_CONTAINER_NAME" ]]; then
  printf 'Refusing container %s; configured service container is %s.\n' "$container_name" "$LOCALAI_CONTAINER_NAME" >&2
  exit 2
fi

state_dir="$LOCALAI_STATE_DIR"
app_home_path="${state_dir%/}/app-home"
if [[ "$state_dir" == / ]]; then app_home_path=/app-home; fi
if ! inspect_json="$(podman container inspect --format '{{json .}}' "$container_name")"; then
  printf 'Could not inspect configured LocalAI service container %s.\n' "$container_name" >&2
  exit 1
fi

if ! container_identity="$(/usr/bin/python3 -c '
import json
import sys

def fail(message):
    print("LocalAI container preflight failed: " + message, file=sys.stderr)
    raise SystemExit(1)

container_name, state_dir, *specs = sys.argv[1:]
try:
    payload = json.load(sys.stdin)
    if not isinstance(payload, dict):
        fail("inspect did not return one container")
    inspected = payload
    container_id = inspected.get("Id")
    if not isinstance(container_id, str) or not container_id:
        fail("container inspect did not return an immutable ID")
    config = inspected.get("Config") or {}
    labels = config.get("Labels") or {}
    expected_labels = {
        "io.localai.secureblue.managed": "localai",
        "io.localai.secureblue.state": state_dir,
        "io.localai.secureblue.container": container_name,
    }
    if any(labels.get(key) != value for key, value in expected_labels.items()):
        fail("ownership labels do not match the configured LocalAI service")
    environment = {}
    for item in config.get("Env") or []:
        key, separator, value = item.partition("=")
        if separator:
            environment[key] = value
    for spec in specs:
        key, separator, expected = spec.partition("=")
        if not separator or environment.get(key) != expected:
            fail("container environment does not match configured " + key)
    mounts = inspected.get("Mounts") or []
    for spec in specs:
        key, _, expected = spec.partition("=")
        if key == "LOCALAI_AUTH_DATABASE_URL":
            continue
        if not expected.startswith("/"):
            fail("configured " + key + " is not an absolute path")
        if not any(
            isinstance(mount, dict)
            and mount.get("Type") == "bind"
            and mount.get("Source") == expected
            and mount.get("Destination") == expected
            for mount in mounts
        ):
            fail("configured " + key + " is not mounted from its exact persistent source")
    backend_mounts = [
        mount for mount in mounts
        if isinstance(mount, dict) and mount.get("Destination") == "/backends"
    ]
    if len(backend_mounts) != 1 or backend_mounts[0].get("Type") != "volume":
        fail("image-provided /backends is not a separate named volume")
    volume_name = backend_mounts[0].get("Name")
    expected_volume = container_name + "-image-backends"
    if volume_name != expected_volume:
        fail("image-provided /backends volume name is not the managed backend volume")
    print(container_id + "\t" + volume_name)
except (json.JSONDecodeError, TypeError, ValueError) as error:
    fail("invalid inspect data (" + type(error).__name__ + ")")
' "$container_name" "$state_dir" \
  "HOME=$app_home_path" \
  "LOCALAI_MODELS_PATH=$LOCALAI_MODELS_PATH" \
  "LOCALAI_BACKENDS_PATH=$LOCALAI_BACKENDS_PATH" \
  "LOCALAI_DOWNLOAD_STAGING_PATH=$LOCALAI_DOWNLOAD_STAGING_PATH" \
  "LOCALAI_DATA_PATH=$LOCALAI_DATA_PATH" \
  "LOCALAI_CONFIG_DIR=$LOCALAI_CONFIG_DIR" \
  "LOCALAI_GENERATED_CONTENT_PATH=$LOCALAI_GENERATED_CONTENT_PATH" \
  "LOCALAI_UPLOAD_PATH=$LOCALAI_UPLOAD_PATH" \
  "LOCALAI_CACHE_DIR=$LOCALAI_CACHE_DIR" \
  "LOCALAI_LOG_DIR=$LOCALAI_LOG_DIR" \
  "XDG_CACHE_HOME=$LOCALAI_CACHE_DIR" \
  "TMPDIR=$LOCALAI_BACKEND_TEMP_DIR" \
  "LOCALAI_BACKEND_TEMP_DIR=$LOCALAI_BACKEND_TEMP_DIR" \
  "LOCALAI_AUTH_DATABASE_URL=${LOCALAI_DATA_PATH%/}/database.db" <<<"$inspect_json")"; then
  exit 1
fi
IFS=$'\t' read -r container_id backends_volume <<<"$container_identity"

if ! volume_json="$(podman volume inspect --format '{{json .}}' "$backends_volume")"; then
  printf 'Could not inspect the managed /backends volume.\n' >&2
  exit 1
fi
if ! printf '%s\n' "$volume_json" | /usr/bin/python3 -c '
import json
import sys

name, state_dir, container_name = sys.argv[1:]
try:
    volume = json.load(sys.stdin)
    labels = (volume or {}).get("Labels") or {}
except (json.JSONDecodeError, TypeError):
    volume = None
    labels = {}
if not isinstance(volume, dict) or volume.get("Name") != name or volume.get("Driver") != "local" or volume.get("Options") or any(
    labels.get(key) != expected
    for key, expected in {
        "io.localai.secureblue.managed": "image-volume",
        "io.localai.secureblue.state": state_dir,
        "io.localai.secureblue.container": container_name,
        "io.localai.secureblue.role": "backends",
    }.items()
):
    print("LocalAI container preflight failed: /backends volume metadata does not match its expected name, local driver, empty options, and ownership labels.", file=sys.stderr)
    raise SystemExit(1)
' "$backends_volume" "$state_dir" "$container_name"; then
  exit 1
fi

if [[ "$confirm_probe" != "1" ]]; then
  printf 'Write-probe candidates in existing container %s (using its rendered mounts and container user):\n' "$container_name" >&2
  podman exec "$container_id" /bin/sh -eu -c '
printf "persistent: application home: %s\\n" "$HOME"
printf "persistent: models: %s\\n" "${LOCALAI_MODELS_PATH:-/models}"
printf "persistent: managed backend storage (LOCALAI_BACKENDS_PATH): %s\\n" "${LOCALAI_BACKENDS_PATH:-}"
printf "persistent: download staging: %s\\n" "${LOCALAI_DOWNLOAD_STAGING_PATH:-/downloading}"
printf "persistent: data and auth database parent: %s\\n" "${LOCALAI_DATA_PATH:-/data}"
printf "persistent: configuration: %s\\n" "${LOCALAI_CONFIG_DIR:-/configuration}"
printf "persistent: generated content: %s\\n" "${LOCALAI_GENERATED_CONTENT_PATH:-}"
printf "persistent: uploads: %s\\n" "${LOCALAI_UPLOAD_PATH:-}"
printf "persistent: cache: %s\\n" "${LOCALAI_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}}"
printf "persistent: logs: %s\\n" "${LOCALAI_LOG_DIR:-}"
printf "image-provided backend directory: /backends\\n"
printf "scratch: backend temporary directory: %s\\n" "${LOCALAI_BACKEND_TEMP_DIR:-${TMPDIR:-/tmp}}"
printf "scratch: /tmp\\n"
' >&2
  printf 'The image system-backend fallback /var/lib/local-ai/backends is distinct from LOCALAI_BACKENDS_PATH and /backends; it is not write-probed.\n' >&2
  printf 'Rerun with --confirm-write-probe [container] to create, read, and remove one unique file per required directory. Missing directories fail the probe.\n' >&2
  exit 2
fi

podman exec "$container_id" /bin/sh -eu -c '
nonce="$(date +%s%N)-$$"
failures=0
file=""
cleanup() { [ -z "$file" ] || rm -f -- "$file"; }
trap cleanup EXIT HUP INT TERM

check_dir() {
  label="$1"
  dir="$2"
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    printf "missing directory (%s): %s\\n" "$label" "${dir:-<unset>}"
    failures=$((failures + 1))
    return
  fi
  if ! file="$(mktemp "$dir/.localai-write-probe.XXXXXXXXXX" 2>/dev/null)"; then
    printf "write failed (%s): %s\\n" "$label" "$dir"
    failures=$((failures + 1))
    return
  fi
  if ! printf "%s\\n" "$nonce" > "$file"; then
    printf "write failed (%s): %s\\n" "$label" "$dir"
    failures=$((failures + 1))
  elif [ "$(cat "$file" 2>/dev/null || true)" != "$nonce" ]; then
    printf "readback failed (%s): %s\\n" "$label" "$dir"
    failures=$((failures + 1))
  elif ! rm -f -- "$file"; then
    printf "remove failed (%s): %s\\n" "$label" "$dir"
    failures=$((failures + 1))
  else
    file=""
    printf "write/read/remove succeeded (%s): %s\\n" "$label" "$dir"
  fi
  cleanup
}

check_dir "application home" "$HOME"
check_dir "models" "${LOCALAI_MODELS_PATH:-/models}"
check_dir "managed backend storage (LOCALAI_BACKENDS_PATH bind)" "${LOCALAI_BACKENDS_PATH:-}"
check_dir "download staging" "${LOCALAI_DOWNLOAD_STAGING_PATH:-/downloading}"
check_dir "data and auth database parent" "${LOCALAI_DATA_PATH:-/data}"
check_dir "configuration" "${LOCALAI_CONFIG_DIR:-/configuration}"
check_dir "generated content" "${LOCALAI_GENERATED_CONTENT_PATH:-}"
check_dir "uploads" "${LOCALAI_UPLOAD_PATH:-}"
check_dir "cache" "${LOCALAI_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}}"
check_dir "logs" "${LOCALAI_LOG_DIR:-}"
check_dir "image-provided /backends (separate from managed bind)" /backends
check_dir "backend temporary scratch" "${LOCALAI_BACKEND_TEMP_DIR:-${TMPDIR:-/tmp}}"
check_dir "/tmp scratch" /tmp

if [ -n "${LOCALAI_AUTH_DATABASE_URL:-}" ]; then
  printf "authentication database directory is covered by the data-directory probe; its URL is not printed\\n"
else
  printf "authentication database URL is unset; checked the data directory only\\n" >&2
fi
printf "not probed: image system-backend fallback /var/lib/local-ai/backends (distinct from LOCALAI_BACKENDS_PATH and /backends)\\n" >&2

exit "$failures"
'
