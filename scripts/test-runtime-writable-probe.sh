#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./test-support.sh
# The sourced helper is checked independently.
# shellcheck disable=SC1091
source "$repo_root/scripts/test-support.sh"
test_sanitize_localai_environment

scratch_root="${HOME:?HOME must be set}/agent-scratch/LocalAI-SBlue"
mkdir -p "$scratch_root"
scratch="$(mktemp -d "$scratch_root/issue-18-probe-test.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/image-backends" "$scratch/state/app-home" \
  "$scratch/models" "$scratch/managed-backends" "$scratch/downloading" \
  "$scratch/data" "$scratch/config" "$scratch/generated" "$scratch/uploads" \
  "$scratch/cache" "$scratch/logs" "$scratch/backend-tmp" "$scratch/tmp"

cat >"$scratch/bin/podman" <<'MOCK_PODMAN'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$LOCALAI_TEST_CALL_LOG"
if [[ "$1 $2" == "container inspect" ]]; then
  [[ "$3 $4 $5" == "--format {{json .}} mock-localai" ]]
  python3 - <<'PY'
import json
import os

state = os.environ["LOCALAI_STATE_DIR"]
name = os.environ["LOCALAI_CONTAINER_NAME"]
env = {
    "HOME": os.environ["LOCALAI_TEST_CONTAINER_HOME"],
    "LOCALAI_MODELS_PATH": os.environ["LOCALAI_MODELS_PATH"],
    "LOCALAI_BACKENDS_PATH": os.environ["LOCALAI_BACKENDS_PATH"],
    "LOCALAI_DOWNLOAD_STAGING_PATH": os.environ["LOCALAI_DOWNLOAD_STAGING_PATH"],
    "LOCALAI_DATA_PATH": os.environ["LOCALAI_DATA_PATH"],
    "LOCALAI_CONFIG_DIR": os.environ["LOCALAI_CONFIG_DIR"],
    "LOCALAI_GENERATED_CONTENT_PATH": os.environ["LOCALAI_GENERATED_CONTENT_PATH"],
    "LOCALAI_UPLOAD_PATH": os.environ["LOCALAI_UPLOAD_PATH"],
    "LOCALAI_CACHE_DIR": os.environ["LOCALAI_CACHE_DIR"],
    "LOCALAI_LOG_DIR": os.environ["LOCALAI_LOG_DIR"],
    "XDG_CACHE_HOME": os.environ["LOCALAI_CACHE_DIR"],
    "TMPDIR": os.environ["LOCALAI_BACKEND_TEMP_DIR"],
    "LOCALAI_BACKEND_TEMP_DIR": os.environ["LOCALAI_BACKEND_TEMP_DIR"],
    "LOCALAI_AUTH_DATABASE_URL": os.environ["LOCALAI_DATA_PATH"].rstrip("/") + "/database.db",
}
paths = [
    env["HOME"], env["LOCALAI_MODELS_PATH"], env["LOCALAI_BACKENDS_PATH"],
    env["LOCALAI_DOWNLOAD_STAGING_PATH"], env["LOCALAI_DATA_PATH"],
    env["LOCALAI_CONFIG_DIR"], env["LOCALAI_GENERATED_CONTENT_PATH"],
    env["LOCALAI_UPLOAD_PATH"], env["LOCALAI_CACHE_DIR"], env["LOCALAI_LOG_DIR"],
    env["XDG_CACHE_HOME"], env["TMPDIR"], env["LOCALAI_BACKEND_TEMP_DIR"],
]
mounts = [{"Type": "bind", "Source": path, "Destination": path} for path in paths]
mounts.append({"Type": "volume", "Name": name + "-image-backends", "Destination": "/backends"})
if os.environ.get("LOCALAI_TEST_BAD_MODELS_SOURCE") == "1":
    next(m for m in mounts if m["Destination"] == env["LOCALAI_MODELS_PATH"])["Source"] = "/unrelated/source"
labels = {
    "io.localai.secureblue.managed": "localai",
    "io.localai.secureblue.state": state,
    "io.localai.secureblue.container": name,
}
if os.environ.get("LOCALAI_TEST_WRONG_CONTAINER_LABEL") == "1":
    labels["io.localai.secureblue.container"] = "another-container"
print(json.dumps({"Id": "mock-container-id-123", "Config": {"Labels": labels, "Env": [f"{k}={v}" for k, v in env.items()]}, "Mounts": mounts}))
PY
  exit
fi
if [[ "$1 $2" == "volume inspect" ]]; then
  [[ "$3 $4 $5" == "--format {{json .}} mock-localai-image-backends" ]]
  python3 - <<'PY'
import json
import os

labels = {
    "io.localai.secureblue.managed": "image-volume",
    "io.localai.secureblue.state": os.environ["LOCALAI_STATE_DIR"],
    "io.localai.secureblue.container": os.environ["LOCALAI_CONTAINER_NAME"],
    "io.localai.secureblue.role": "backends",
}
if os.environ.get("LOCALAI_TEST_WRONG_VOLUME_LABEL") == "1":
    labels["io.localai.secureblue.role"] = "models"
driver = "nfs" if os.environ.get("LOCALAI_TEST_WRONG_VOLUME_DRIVER") == "1" else "local"
options = {"type": "nfs"} if os.environ.get("LOCALAI_TEST_WRONG_VOLUME_OPTIONS") == "1" else {}
print(json.dumps({
    "Name": os.environ["LOCALAI_CONTAINER_NAME"] + "-image-backends",
    "Driver": driver,
    "Options": options,
    "Labels": labels,
}))
PY
  exit
fi
if [[ "$1" == exec ]]; then
  shift
  [[ "$1" == "mock-container-id-123" ]]
  shift
  [[ "$1 $2 $3" == "/bin/sh -eu -c" ]]
  shift 3
  script="$1"
  script="${script/check_dir \"image-provided \/backends (separate from managed bind)\" \/backends/check_dir \"image-provided \/backends (separate from managed bind)\" \"$LOCALAI_TEST_IMAGE_BACKENDS\"}"
  export HOME="$LOCALAI_TEST_CONTAINER_HOME"
  exec /bin/sh -eu -c "$script"
fi
printf 'unexpected mocked podman call: %s\n' "$*" >&2
exit 99
MOCK_PODMAN
chmod 0755 "$scratch/bin/podman"

export PATH="$scratch/bin:$PATH"
export LOCALAI_SERVICE_USER="$(id -un)"
export LOCALAI_CONFIG_FILE="$scratch/no-config"
export LOCALAI_STATE_DIR="$scratch/state"
export LOCALAI_CONTAINER_NAME=mock-localai
export LOCALAI_TEST_IMAGE_BACKENDS="$scratch/image-backends"
export LOCALAI_TEST_CALL_LOG="$scratch/podman.calls"
export LOCALAI_TEST_CONTAINER_HOME="$scratch/state/app-home"
export TMPDIR="$scratch/backend-tmp"
export XDG_CACHE_HOME="$scratch/cache"
export LOCALAI_MODELS_PATH="$scratch/models"
export LOCALAI_BACKENDS_PATH="$scratch/managed-backends"
export LOCALAI_DOWNLOAD_STAGING_PATH="$scratch/downloading"
export LOCALAI_DATA_PATH="$scratch/data"
export LOCALAI_CONFIG_DIR="$scratch/config"
export LOCALAI_GENERATED_CONTENT_PATH="$scratch/generated"
export LOCALAI_UPLOAD_PATH="$scratch/uploads"
export LOCALAI_CACHE_DIR="$scratch/cache"
export LOCALAI_LOG_DIR="$scratch/logs"
export LOCALAI_BACKEND_TEMP_DIR="$scratch/backend-tmp"
export LOCALAI_AUTH_DATABASE_URL="sqlite:///$scratch/data/database.db?token=synthetic-secret-marker"

probe="$repo_root/localai/probe-container-writable-paths.sh"
output="$scratch/output"
if ! "$probe" --confirm-write-probe mock-localai >"$output" 2>&1; then
  cat "$output" >&2
  exit 1
fi
for expected in \
  'write/read/remove succeeded (managed backend storage (LOCALAI_BACKENDS_PATH bind))' \
  'write/read/remove succeeded (image-provided /backends (separate from managed bind))' \
  'write/read/remove succeeded (backend temporary scratch)' \
  'write/read/remove succeeded (/tmp scratch)' \
  'authentication database directory is covered by the data-directory probe' \
  'not probed: image system-backend fallback /var/lib/local-ai/backends'; do
  rg -Fq "$expected" "$output" || { cat "$output" >&2; printf 'missing probe result: %s\n' "$expected" >&2; exit 1; }
done
if rg -Fq 'synthetic-secret-marker' "$output"; then
  printf 'probe exposed the authentication database URL\n' >&2
  exit 1
fi
if find "$scratch" -name '.localai-write-probe.*' -print -quit | rg -q .; then
  printf 'probe left a temporary file behind\n' >&2
  exit 1
fi

rm -rf -- "$scratch/logs"
if "$probe" --confirm-write-probe mock-localai >"$output" 2>&1; then
  printf 'probe unexpectedly accepted a missing configured persistent directory\n' >&2
  exit 1
fi
rg -Fq 'missing directory (logs)' "$output" || { cat "$output" >&2; exit 1; }

for rejection in wrong-container-label bad-models-source wrong-volume-label wrong-volume-driver wrong-volume-options; do
  : >"$LOCALAI_TEST_CALL_LOG"
  case "$rejection" in
    wrong-container-label) export LOCALAI_TEST_WRONG_CONTAINER_LABEL=1; expected='ownership labels do not match' ;;
    bad-models-source) export LOCALAI_TEST_BAD_MODELS_SOURCE=1; expected='configured LOCALAI_MODELS_PATH is not mounted' ;;
    wrong-volume-label) export LOCALAI_TEST_WRONG_VOLUME_LABEL=1; expected='/backends volume metadata does not match' ;;
    wrong-volume-driver) export LOCALAI_TEST_WRONG_VOLUME_DRIVER=1; expected='/backends volume metadata does not match' ;;
    wrong-volume-options) export LOCALAI_TEST_WRONG_VOLUME_OPTIONS=1; expected='/backends volume metadata does not match' ;;
  esac
  if "$probe" --confirm-write-probe mock-localai >"$output" 2>&1; then
    printf 'probe unexpectedly accepted %s\n' "$rejection" >&2
    exit 1
  fi
  rg -Fq "$expected" "$output" || { cat "$output" >&2; exit 1; }
  if rg -q '^exec ' "$LOCALAI_TEST_CALL_LOG"; then
    printf 'probe executed in the container after rejecting %s\n' "$rejection" >&2
    exit 1
  fi
  unset LOCALAI_TEST_WRONG_CONTAINER_LABEL LOCALAI_TEST_BAD_MODELS_SOURCE \
    LOCALAI_TEST_WRONG_VOLUME_LABEL LOCALAI_TEST_WRONG_VOLUME_DRIVER LOCALAI_TEST_WRONG_VOLUME_OPTIONS
done

printf 'Mocked writable runtime probe checks passed.\n'
