#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# Sourced test support reads this variable indirectly.
# shellcheck disable=SC2034
TEST_REPO_ROOT="$repo_root"
source "$repo_root/scripts/test-support.sh"
test_sanitize_localai_environment
tmp_dir="$(test_mktemp_dir localaictl-test)"
trap 'rm -rf "$tmp_dir"' EXIT

cat >"$tmp_dir/config" <<'EOF'
LOCALAI_TLS_ENABLED=true
LOCALAI_TLS_PUBLIC_SOCKET=true
LOCALAI_TLS_PUBLIC_HOST=localhost
EOF

cat >"$tmp_dir/run0" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'run0' >> "${LOCALAI_FAKE_LOG:?}"
printf ' %s' "$@" >>"${LOCALAI_FAKE_LOG:?}"
printf '\n' >>"${LOCALAI_FAKE_LOG:?}"
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --pipe|-i|--user=*|--setenv=*) shift ;;
    *) break ;;
  esac
done
if [[ "${1:-}" == /usr/bin/flock ]]; then
  shift
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      -n) shift ;;
      -E) shift 2 ;;
      *) break ;;
    esac
  done
  shift # replace the production lock path with a private fixture path
  exec /usr/bin/flock -n "${LOCALAI_FAKE_LOCK_FILE:?}" "$@"
fi
if [[ "${1:-}" == /usr/bin/python3 && "${2:-}" == /etc/localai/bootstrap-guard.py ]]; then
  exit 0
fi
if [[ "${1:-}" == /usr/bin/rm ]]; then
  for target in "$@"; do
    if [[ "$target" == "$LOCALAI_RESTORE_STAGE_BASE"/* ]]; then
      printf 'synthetic-stage-cleanup\n' >>"${LOCALAI_FAKE_LOG:?}"
      python3 - "$target" <<'PY'
import os, shutil, sys
target = sys.argv[1]
def retry(function, path, _error):
    os.chmod(os.path.dirname(path), 0o700)
    if os.path.lexists(path) and not os.path.islink(path):
        os.chmod(path, 0o700)
    function(path)
if os.path.islink(target) or os.path.isfile(target):
    try:
        os.unlink(target)
    except FileNotFoundError:
        pass
elif os.path.isdir(target):
    shutil.rmtree(target, onerror=retry)
PY
      exit 0
    fi
  done
  exec /usr/bin/rm "$@"
fi
if [[ "${1:-}" == /usr/bin/stat && "${2:-}" == -c && "${3:-}" == %u && "${4:-}" == -- ]]; then
  case "${5:-}" in
    */backup-tls/.config/systemd/user/*)
      [[ "${LOCALAI_FAKE_WRONG_TLS_UNIT_OWNER:-false}" != true ]] && printf '1002\n' || printf '9999\n'
      exit 0
      ;;
    */backup-state/.config/systemd/user/localai.service)
      [[ "${LOCALAI_FAKE_WRONG_BACKEND_UNIT_OWNER:-false}" != true ]] && printf '1001\n' || printf '9999\n'
      exit 0
      ;;
    */systemd/localai-tls-forward.*)
      [[ "${LOCALAI_FAKE_WRONG_SOCKET_UNIT_OWNER:-false}" != true ]] && printf '0\n' || printf '9999\n'
      exit 0
      ;;
  esac
fi
exec "$@"
EOF
chmod 0755 "$tmp_dir/run0"

cat >"$tmp_dir/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'systemctl' >>"${LOCALAI_FAKE_LOG:?}"
printf ' %s' "$@" >>"${LOCALAI_FAKE_LOG:?}"
printf '\n' >>"${LOCALAI_FAKE_LOG:?}"
if [[ -n "${LOCALAI_DOCTOR_TOKEN+x}" ]]; then
  printf 'doctor token leaked to systemctl environment\n' >&2
  exit 97
fi
if [[ " $* " == *" is-active "* ]]; then
  case " $* " in
    *" is-active localai.service "*)
      if [[ "${LOCALAI_FAKE_BACKEND_UNAVAILABLE:-false}" == true ]]; then exit 1; fi
      if [[ -f "${LOCALAI_FAKE_STATE_DIR:-}/backend" ]]; then cat "${LOCALAI_FAKE_STATE_DIR}/backend"; else printf '%s\n' "${LOCALAI_FAKE_BACKEND_STATE:-active}"; fi
      ;;
    *" is-active localai-tls-compose.service "*) if [[ -f "${LOCALAI_FAKE_STATE_DIR:-}/tls" ]]; then cat "${LOCALAI_FAKE_STATE_DIR}/tls"; else printf '%s\n' "${LOCALAI_FAKE_TLS_STATE:-active}"; fi ;;
    *" is-active localai-tls-forward.socket "*) if [[ -f "${LOCALAI_FAKE_STATE_DIR:-}/socket" ]]; then cat "${LOCALAI_FAKE_STATE_DIR}/socket"; else printf '%s\n' "${LOCALAI_FAKE_SOCKET_STATE:-active}"; fi ;;
    *) printf 'inactive\n' ;;
  esac
fi
if [[ " $* " == *" show localai.service --property=DropInPaths --value "* ]]; then
  printf '\n'
fi
if [[ " $* " == *" show localai.service --property=Environment --value "* ]]; then
  printf 'LOCALAI_AUTH=true LOCALAI_AUTH_DATABASE_URL=%s/database.db LOCALAI_ADDRESS=127.0.0.1:11455\n' "${LOCALAI_FAKE_DATA_PATH:-/var/lib/localai/data}"
fi
if [[ " $* " == *" stop localai.service "* ]]; then printf 'inactive\n' >"${LOCALAI_FAKE_STATE_DIR}/backend"; fi
if [[ " $* " == *" start localai.service "* ]]; then printf 'active\n' >"${LOCALAI_FAKE_STATE_DIR}/backend"; fi
if [[ " $* " == *" stop localai-tls-compose.service "* ]]; then printf 'inactive\n' >"${LOCALAI_FAKE_STATE_DIR}/tls"; fi
if [[ " $* " == *" start localai-tls-compose.service "* ]]; then printf 'active\n' >"${LOCALAI_FAKE_STATE_DIR}/tls"; fi
if [[ " $* " == *" stop localai-tls-forward.socket "* ]]; then printf 'inactive\n' >"${LOCALAI_FAKE_STATE_DIR}/socket"; fi
if [[ " $* " == *" start localai-tls-forward.socket "* ]]; then printf 'active\n' >"${LOCALAI_FAKE_STATE_DIR}/socket"; fi
if [[ "${LOCALAI_FAKE_FAIL_TLS:-false}" == true && " $* " == *" start localai-tls-compose.service "* ]]; then
  exit 1
fi
EOF
chmod 0755 "$tmp_dir/systemctl"

cat >"$tmp_dir/id" <<'EOF'
#!/usr/bin/env bash
case "${2:-}" in
  localai) printf '1001\n' ;;
  localai-tls) printf '1002\n' ;;
  *) exit 1 ;;
esac
EOF
chmod 0755 "$tmp_dir/id"

cat >"$tmp_dir/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"${LOCALAI_CURL_ARGS_FILE:?}"
cat >"${LOCALAI_CURL_STDIN_FILE:?}"
printf '200\n'
EOF
chmod 0755 "$tmp_dir/curl"

cat >"$tmp_dir/journalctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'journalctl' >>"${LOCALAI_FAKE_LOG:?}"
printf ' %s' "$@" >>"${LOCALAI_FAKE_LOG:?}"
printf '\n' >>"${LOCALAI_FAKE_LOG:?}"
printf 'fake journal output\n'
EOF
chmod 0755 "$tmp_dir/journalctl"

export LOCALAI_CONFIG_FILE="$tmp_dir/config"
export LOCALAI_RUN0_BIN="$tmp_dir/run0"
export LOCALAI_SYSTEMCTL_BIN="$tmp_dir/systemctl"
export LOCALAI_AUDIT_DIR="$tmp_dir/audit"
export LOCALAI_FAKE_LOG="$tmp_dir/commands"
export LOCALAI_FAKE_STATE_DIR="$tmp_dir/service-state"
export LOCALAI_FAKE_LOCK_FILE="$tmp_dir/backup.lock"
export XDG_RUNTIME_DIR="$tmp_dir"
export LOCALAI_RESTORE_STAGE_BASE="$tmp_dir/restore-stage"
mkdir -p "$tmp_dir/fakebin"
cat >"$tmp_dir/fakebin/stat" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "-c %u -- $LOCALAI_RESTORE_STAGE_BASE" ]]; then
  printf '0\n'
else
  exec /usr/bin/stat "$@"
fi
EOF
chmod 0755 "$tmp_dir/fakebin/stat"
export PATH="$tmp_dir/fakebin:$PATH"
mkdir -p "$LOCALAI_FAKE_STATE_DIR"
export LOCALAI_ID_BIN="$tmp_dir/id"
export LOCALAI_JOURNALCTL_BIN="$tmp_dir/journalctl"
export LOCALAI_SYSTEM_UNIT_DIR="$tmp_dir/systemd"
export HOME="$tmp_dir/home"
mkdir -m 0700 "$LOCALAI_RESTORE_STAGE_BASE"
python3 "$repo_root/lib/backup_archive.py" stage-check "$LOCALAI_RESTORE_STAGE_BASE"
if python3 "$repo_root/lib/backup_archive.py" stage-check /run >/dev/null 2>&1; then
  printf 'restore staging accepted a memory-backed filesystem\n' >&2
  exit 1
fi

# Exercise the elevated-command helpers with both effective privilege states.
# shellcheck disable=SC1090
source <(sed -n '/^run_elevated() {$/,/^}/p' "$repo_root/bin/localaictl")
# shellcheck disable=SC1090
source <(sed -n '/^run_elevated_pipe() {$/,/^}/p' "$repo_root/bin/localaictl")
# Consumed by the extracted elevation helpers.
# shellcheck disable=SC2034
run0_bin="$tmp_dir/run0"
# The extracted elevation helpers invoke this stub indirectly.
# shellcheck disable=SC2329
is_effectively_root() { return 0; }
: >"$tmp_dir/commands"
run_elevated "$tmp_dir/systemctl" sample
run_elevated_pipe "$tmp_dir/journalctl" sample >/dev/null
if rg -q '^run0' "$tmp_dir/commands"; then
  printf 'already-root command invoked run0\n' >&2; exit 1
fi
# shellcheck disable=SC2329
is_effectively_root() { return 1; }
run_elevated "$tmp_dir/systemctl" sample
run_elevated_pipe "$tmp_dir/journalctl" sample >/dev/null
rg -q '^run0 -i ' "$tmp_dir/commands"
rg -q '^run0 -i --pipe ' "$tmp_dir/commands"
: >"$tmp_dir/commands"

mkdir -p "$tmp_dir/systemd"
printf '[Socket]\nFreeBind=true\n' >"$tmp_dir/systemd/localai-tls-forward.socket"

[[ "$("$repo_root/bin/localaictl" --version)" == "localaictl $(<"$repo_root/VERSION")" ]]
(
  # The function and its dependencies are exercised with isolated mocks.
  # shellcheck disable=SC1090
  source <(sed -n '/^bootstrap_admin() {$/,/^}/p' "$repo_root/bin/localaictl")
  # shellcheck disable=SC2329
  verify_bootstrap_unit() { [[ "${MOCK_UNIT_SAFE:-true}" == true ]]; }
  # shellcheck disable=SC2329
  bootstrap_listener_inactive() { [[ "${MOCK_LISTENERS_SAFE:-true}" == true ]]; }
  # shellcheck disable=SC2329
  bootstrap_listener_disabled() { [[ "${MOCK_LISTENERS_SAFE:-true}" == true ]]; }
  # shellcheck disable=SC2329
  bootstrap_ports_clear() { [[ "${MOCK_LISTENERS_SAFE:-true}" == true ]]; }
  # shellcheck disable=SC2329
  bootstrap_tls_containers_absent() { [[ "${MOCK_LISTENERS_SAFE:-true}" == true ]]; }
  # shellcheck disable=SC2329
  ensure_bootstrap_isolation() { [[ "${MOCK_LISTENERS_SAFE:-true}" == true ]] || exit 1; }
  # shellcheck disable=SC2329
  run_or_dry() { printf '%s\n' "$*" >> "$tmp_dir/bootstrap-actions"; }
  # shellcheck disable=SC2329
  log() { :; }
  # shellcheck disable=SC2329
  die() { exit 1; }
  # Values are read indirectly by the extracted function.
  # shellcheck disable=SC2034
  LOCALAI_AUTH=true LOCALAI_BIND_HOST=127.0.0.1 LOCALAI_TLS_FORWARD_SOCKET_NAME=localai-tls-forward.socket LOCALAI_TLS_SERVICE_NAME=localai-tls-compose.service LOCALAI_TLS_USER=localai-tls id_bin="$tmp_dir/id"
  bootstrap_admin
  [[ "$(<"$tmp_dir/bootstrap-actions")" == 'backend_systemctl start localai.service' ]]
  if (MOCK_UNIT_SAFE=false; bootstrap_admin); then exit 1; fi
  if (MOCK_LISTENERS_SAFE=false; bootstrap_admin); then exit 1; fi
  # The value is read by the extracted production function.
  # shellcheck disable=SC2034
  if (LOCALAI_BIND_HOST=0.0.0.0; bootstrap_admin); then exit 1; fi
)
(
  # shellcheck disable=SC1090
  source <(sed -n '/^bootstrap_tls_identity_safe() {$/,/^}/p' "$repo_root/bin/localaictl")
  # These mocks are used by the extracted function.
  # shellcheck disable=SC2329
  run_elevated() { "$@"; }
  # shellcheck disable=SC2329
  bootstrap_listener_inactive() { return 0; }
  # shellcheck disable=SC2329
  bootstrap_listener_disabled() { [[ "${*: -1}" != custom-legacy.service ]]; }
  # shellcheck disable=SC2329
  bootstrap_tls_containers_absent() { return 0; }
  # shellcheck disable=SC2329
  die() { exit 1; }
  # shellcheck disable=SC2034
  id_bin="$tmp_dir/id" LOCALAI_TLS_SERVICE_NAME=localai-tls-compose.service tls_footprint=0
  mkdir -p "$tmp_dir/tls/.config/systemd/user"
  : > "$tmp_dir/tls/.config/systemd/user/custom-legacy.service"
  if (bootstrap_tls_identity_safe localai-tls "$tmp_dir/tls"); then
    printf 'enabled custom legacy service was accepted\n' >&2; exit 1
  fi
  rm "$tmp_dir/tls/.config/systemd/user/custom-legacy.service"
  mkdir -p "$tmp_dir/tls/.config/systemd/user/default.target.wants"
  ln -s /dev/null "$tmp_dir/tls/.config/systemd/user/default.target.wants/custom-legacy.service"
  if (bootstrap_tls_identity_safe localai-tls "$tmp_dir/tls"); then
    printf 'enabled linked legacy service was accepted\n' >&2; exit 1
  fi
)
if "$repo_root/bin/localaictl" --version extra >/dev/null 2>&1; then
  printf 'version accepted an extra argument\n' >&2
  exit 1
fi

"$repo_root/bin/localaictl" --dry-run start >"$tmp_dir/dry-run"
if [[ -s "$tmp_dir/commands" ]]; then
  printf 'Unexpected match in negative assertion\n' >&2
  exit 1
fi
rg -q 'backend_systemctl' "$tmp_dir/dry-run"

"$repo_root/bin/localaictl" status --json >"$tmp_dir/status"
[[ "$(<"$tmp_dir/status")" == '{"backend":"active","tls_compose":"active","https_socket":"active","tls_enabled":true,"endpoint":"https://localhost"}' ]]
rg -q -F 'systemctl --no-ask-password --user --machine=localai@.host is-active localai.service' "$tmp_dir/commands"
rg -q -F 'systemctl --no-ask-password --user --machine=localai-tls@.host is-active localai-tls-compose.service' "$tmp_dir/commands"
rg -q -F 'systemctl --no-ask-password is-active localai-tls-forward.socket' "$tmp_dir/commands"
if rg -q -F 'run0 -i' "$tmp_dir/commands"; then
  printf 'Unexpected match in negative assertion\n' >&2
  exit 1
fi

if LOCALAI_FAKE_BACKEND_STATE=inactive "$repo_root/bin/localaictl" status --json >"$tmp_dir/inactive-status"; then
  printf 'inactive backend status unexpectedly succeeded\n' >&2
  exit 1
fi
[[ "$(<"$tmp_dir/inactive-status")" == '{"backend":"inactive","tls_compose":"active","https_socket":"active","tls_enabled":true,"endpoint":"https://localhost"}' ]]
if LOCALAI_FAKE_BACKEND_UNAVAILABLE=true "$repo_root/bin/localaictl" status --json >"$tmp_dir/unavailable-status" 2>"$tmp_dir/unavailable-status.err"; then
  printf 'unavailable backend status unexpectedly succeeded\n' >&2
  exit 1
fi
[[ "$(<"$tmp_dir/unavailable-status")" == '{"backend":"unknown","tls_compose":"active","https_socket":"active","tls_enabled":true,"endpoint":"https://localhost"}' ]]
rg -q 'unknown does not mean inactive' "$tmp_dir/unavailable-status.err"
"$repo_root/bin/localaictl" status --elevated --json >"$tmp_dir/elevated-status"
[[ "$(<"$tmp_dir/elevated-status")" == '{"backend":"active","tls_compose":"active","https_socket":"active","tls_enabled":true,"endpoint":"https://localhost"}' ]]
rg -q -F "run0 -i $tmp_dir/systemctl --no-ask-password --user --machine=localai@.host is-active localai.service" "$tmp_dir/commands"
rg -q -F "run0 -i $tmp_dir/systemctl --no-ask-password --user --machine=localai-tls@.host is-active localai-tls-compose.service" "$tmp_dir/commands"
rg -q -F "run0 -i $tmp_dir/systemctl --no-ask-password is-active localai-tls-forward.socket" "$tmp_dir/commands"

if "$repo_root/bin/localaictl" status unexpected >/dev/null 2>&1; then
  printf 'status unexpectedly accepted an extra argument\n' >&2
  exit 1
fi

cat >"$tmp_dir/http-config" <<'EOF'
LOCALAI_TLS_ENABLED=false
LOCALAI_BIND_HOST=127.0.0.1
LOCALAI_BIND_PORT=19090
EOF
export LOCALAI_CONFIG_FILE="$tmp_dir/http-config"
export LOCALAI_SYSTEM_UNIT_DIR="$tmp_dir/systemd"
"$repo_root/bin/localaictl" status --json >"$tmp_dir/detected-tls-status"
rg -q '"tls_enabled":false' "$tmp_dir/detected-tls-status"
rg -q '"endpoint":"http://127.0.0.1:19090"' "$tmp_dir/detected-tls-status"
LOCALAI_BIND_HOST=127.0.0.2 "$repo_root/bin/localaictl" status --json >"$tmp_dir/environment-status"
rg -q '"endpoint":"http://127.0.0.2:19090"' "$tmp_dir/environment-status"

cat >"$tmp_dir/doctor-config" <<'EOF'
LOCALAI_TLS_ENABLED=true
LOCALAI_TLS_PUBLIC_SOCKET=true
LOCALAI_TLS_PUBLIC_HOST=localhost
EOF
export LOCALAI_CONFIG_FILE="$tmp_dir/doctor-config"
LOCALAI_DOCTOR_TOKEN=token-marker \
LOCALAI_DOCTOR_CACERT="$tmp_dir/root.crt" \
LOCALAI_CURL_BIN="$tmp_dir/curl" \
LOCALAI_CURL_ARGS_FILE="$tmp_dir/curl-args" \
LOCALAI_CURL_STDIN_FILE="$tmp_dir/curl-stdin" \
  "$repo_root/bin/localaictl" doctor >"$tmp_dir/doctor-output"
if rg -q -F 'token-marker' "$tmp_dir/curl-args"; then
  printf 'Unexpected match in negative assertion\n' >&2
  exit 1
fi
if rg -q -F 'token-marker' "$tmp_dir/commands" "$tmp_dir/doctor-output"; then
  printf 'Unexpected match in negative assertion\n' >&2
  exit 1
fi
rg -q -F -x 'Authorization: Bearer token-marker' "$tmp_dir/curl-stdin"
rg -q -F -x -- '--header' "$tmp_dir/curl-args"
rg -q -F -x -- '@-' "$tmp_dir/curl-args"
rg -q -F -x -- '--cacert' "$tmp_dir/curl-args"
rg -q -F -x "$tmp_dir/root.crt" "$tmp_dir/curl-args"
rg -q 'health result: HTTP 200' "$tmp_dir/doctor-output"

"$repo_root/bin/localaictl" logs backend >"$tmp_dir/backend-logs"
[[ "$(<"$tmp_dir/backend-logs")" == 'fake journal output' ]]
rg -q -F "run0 -i --pipe $tmp_dir/journalctl --system -n 120 --no-pager _SYSTEMD_USER_UNIT=localai.service _SYSTEMD_OWNER_UID=1001" "$tmp_dir/commands"
"$repo_root/bin/localaictl" logs tls >"$tmp_dir/tls-logs"
[[ "$(<"$tmp_dir/tls-logs")" == 'fake journal output' ]]
rg -q -F "run0 -i --pipe $tmp_dir/journalctl --system -n 160 --no-pager _SYSTEMD_USER_UNIT=localai-tls-compose.service _SYSTEMD_OWNER_UID=1002" "$tmp_dir/commands"
if rg -q -F 'journalctl --user' "$tmp_dir/commands"; then
  printf 'Unexpected match in negative assertion\n' >&2
  exit 1
fi
if rg -q 'run0 .*--user=localai' "$tmp_dir/commands"; then
  printf 'Unexpected match in negative assertion\n' >&2
  exit 1
fi

cat >"$tmp_dir/legacy-config" <<'EOF'
LOCALAI_BIND_HOST=127.0.0.1
LOCALAI_BIND_PORT=19090
LOCALAI_TLS_PUBLIC_HOST=localhost
EOF
export LOCALAI_CONFIG_FILE="$tmp_dir/legacy-config"
"$repo_root/bin/localaictl" status --json >"$tmp_dir/legacy-tls-status"
rg -q '"tls_enabled":true' "$tmp_dir/legacy-tls-status"
rg -q '"endpoint":"https://localhost"' "$tmp_dir/legacy-tls-status"

"$repo_root/bin/localaictl" start
"$repo_root/bin/localaictl" stop
[[ -s "$tmp_dir/audit/$(date +%Y-%m-%d).jsonl" ]]
rg -q '"config_hash":"' "$tmp_dir/audit/$(date +%Y-%m-%d).jsonl"

start_line="$(rg -n -- 'start localai.service' "$tmp_dir/commands" | head -n1 | cut -d: -f1)"
tls_line="$(rg -n -- 'start localai-tls-compose.service' "$tmp_dir/commands" | head -n1 | cut -d: -f1)"
socket_line="$(rg -n -- 'start localai-tls-forward.socket' "$tmp_dir/commands" | head -n1 | cut -d: -f1)"
(( start_line < tls_line && tls_line < socket_line ))
rg -q -F "run0 -i $tmp_dir/systemctl --no-ask-password --user --machine=localai@.host start localai.service" "$tmp_dir/commands"
rg -q -F "run0 -i $tmp_dir/systemctl --no-ask-password --user --machine=localai-tls@.host start localai-tls-compose.service" "$tmp_dir/commands"
rg -q -F "run0 -i $tmp_dir/systemctl --no-ask-password start localai-tls-forward.socket localai-tls-forward.service" "$tmp_dir/commands"
if rg -q -F 'run0 --pipe --user=localai' "$tmp_dir/commands"; then
  printf 'Unexpected match in negative assertion\n' >&2
  exit 1
fi

stop_socket_line="$(rg -n -- 'stop localai-tls-forward.socket' "$tmp_dir/commands" | head -n1 | cut -d: -f1)"
stop_tls_line="$(rg -n -- 'stop localai-tls-compose.service' "$tmp_dir/commands" | head -n1 | cut -d: -f1)"
stop_backend_line="$(rg -n -- 'stop localai.service' "$tmp_dir/commands" | head -n1 | cut -d: -f1)"
(( stop_socket_line < stop_tls_line && stop_tls_line < stop_backend_line ))

export LOCALAI_FAKE_FAIL_TLS=true
if "$repo_root/bin/localaictl" start; then
  printf 'expected partial TLS start failure\n' >&2
  exit 1
fi
rg -q '"action":"start".*"result":"failure"' "$tmp_dir/audit/$(date +%Y-%m-%d).jsonl"
rg -q 'start localai-tls-forward.socket' "$tmp_dir/commands"

# Backup and restore exercise real tar metadata operations against disposable
# paths while service-manager commands remain mocked.
unset LOCALAI_FAKE_FAIL_TLS
mkdir -p "$tmp_dir/backup-state" "$tmp_dir/backup-tls" "$tmp_dir/backup-cache" "$tmp_dir/backup-config-dir"
mkdir -p "$tmp_dir/backup-state/.config/systemd/user"
printf '# Managed by LocalAI secureblue installer.\nDescription=LocalAI OpenAI-compatible API and web UI container\n' >"$tmp_dir/backup-state/.config/systemd/user/localai.service"
chmod 0644 "$tmp_dir/backup-state/.config/systemd/user/localai.service"
mkdir -p "$tmp_dir/backup-tls/.config/systemd/user"
printf '# Managed by LocalAI secureblue TLS installer.\nDescription=LocalAI TLS reverse proxy compose stack\n' >"$tmp_dir/backup-tls/.config/systemd/user/localai-tls-compose.service"
chmod 0644 "$tmp_dir/backup-tls/.config/systemd/user/localai-tls-compose.service"
chmod 0710 "$tmp_dir/backup-state"
printf 'active\n' >"$LOCALAI_FAKE_STATE_DIR/backend"
printf 'state fixture\n' >"$tmp_dir/backup-state/database.db"
chmod 0640 "$tmp_dir/backup-state/database.db"
python3 - "$tmp_dir/backup-state/database.db" <<'PY'
import os, sys
try:
    os.setxattr(sys.argv[1], 'user.localai-test', b'preserve-xattr')
except OSError:
    pass
PY
ln -s database.db "$tmp_dir/backup-state/database-current"
printf 'tls fixture\n' >"$tmp_dir/backup-tls/ca.key"
printf 'preserve this\n' >"$tmp_dir/backup-state/unrelated.txt"
printf 'external cache fixture\n' >"$tmp_dir/backup-cache/cache.db"
printf 'LOCALAI_STATE_DIR=%s\nLOCALAI_MODELS_PATH=%s\nLOCALAI_BACKENDS_PATH=%s/backends\nLOCALAI_DOWNLOAD_STAGING_PATH=%s/downloading\nLOCALAI_BACKEND_TEMP_DIR=%s/tmp\nLOCALAI_DATA_PATH=%s/data\nLOCALAI_CONFIG_DIR=%s/config\nLOCALAI_GENERATED_CONTENT_PATH=%s/generated\nLOCALAI_UPLOAD_PATH=%s/uploads\nLOCALAI_CACHE_DIR=%s\nLOCALAI_LOG_DIR=%s/logs\nLOCALAI_TLS_STATE_DIR=%s\nLOCALAI_TLS_CONFIG_DIR=%s/caddy\nLOCALAI_TLS_CACHE_DIR=%s/cache\nLOCALAI_TLS_CERT_DIR=%s/certs\nLOCALAI_TLS_COMPOSE_DIR=%s/compose\nLOCALAI_TLS_ENABLED=false\n' \
  "$tmp_dir/backup-state" "$tmp_dir/backup-state/models" "$tmp_dir/backup-state" "$tmp_dir/backup-state" "$tmp_dir/backup-state" "$tmp_dir/backup-state" "$tmp_dir/backup-state" "$tmp_dir/backup-state" "$tmp_dir/backup-state" "$tmp_dir/backup-cache" "$tmp_dir/backup-state" "$tmp_dir/backup-tls" "$tmp_dir/backup-tls" "$tmp_dir/backup-tls" "$tmp_dir/backup-tls" "$tmp_dir/backup-tls" >"$tmp_dir/backup-config-dir/localai.conf"
mkdir -p "$tmp_dir/backup-state/models"
printf 'model fixture\n' >"$tmp_dir/backup-state/models/model.bin"
podman_layer="$tmp_dir/backup-state/.local/share/containers/storage/overlay/acceptance-layer/diff/usr/lib/systemd"
mkdir -p "$podman_layer/system" "$podman_layer/user"
printf 'inert image system unit\n' >"$podman_layer/system/inert.service"
printf 'inert image user unit\n' >"$podman_layer/user/inert.service"
export LOCALAI_CONFIG_FILE="$tmp_dir/backup-config-dir/localai.conf"
cat >"$tmp_dir/tar-test" <<'EOF'
#!/usr/bin/env bash
args=()
for arg in "$@"; do [[ "$arg" == --same-owner ]] || args+=("$arg"); done
exec /usr/bin/tar "${args[@]}"
EOF
chmod 0755 "$tmp_dir/tar-test"
export LOCALAI_TAR_BIN="$tmp_dir/tar-test"
cat >"$tmp_dir/matchpathcon" <<'EOF'
#!/usr/bin/env bash
printf 'matchpathcon %s\n' "$*" >>"${LOCALAI_FAKE_LOG:?}"
[[ "${LOCALAI_FAKE_FAIL_LABEL:-false}" != true ]]
EOF
chmod 0755 "$tmp_dir/matchpathcon"
export LOCALAI_MATCHPATHCON_BIN="$tmp_dir/matchpathcon"
cat >"$tmp_dir/restorecon" <<'EOF'
#!/usr/bin/env bash
printf 'restorecon %s\n' "$*" >>"${LOCALAI_FAKE_LOG:?}"
EOF
chmod 0755 "$tmp_dir/restorecon"
export LOCALAI_RESTORECON_BIN="$tmp_dir/restorecon"
: >"$tmp_dir/commands"
rm -f "$tmp_dir/systemd/localai-tls-forward.socket"
backup_archive="$tmp_dir/backup.tar.gz"
if ! "$repo_root/bin/localaictl" backup --exclude-models "$backup_archive" 2>"$tmp_dir/backup-warning"; then
  cat "$tmp_dir/backup-warning" >&2
  cat "$tmp_dir/commands" >&2
  exit 1
fi
archive_listing="$tmp_dir/backup-members"
/usr/bin/tar -tzf "$backup_archive" >"$archive_listing"
# A configured-off public socket can still be active from an earlier setup.
# Inventory and stop/restart it only when both root-owned LocalAI unit files
# prove that the socket is managed by this installer.
printf '# Managed by LocalAI secureblue TLS installer.\n' >"$tmp_dir/systemd/localai-tls-forward.socket"
printf '# Managed by LocalAI secureblue TLS installer.\n' >"$tmp_dir/systemd/localai-tls-forward.service"
: >"$tmp_dir/commands"
stale_socket_archive="$tmp_dir/stale-managed-socket.tar.gz"
if ! LOCALAI_TLS_ENABLED=true LOCALAI_TLS_PUBLIC_SOCKET=false "$repo_root/bin/localaictl" backup "$stale_socket_archive" >"$tmp_dir/stale-socket-output" 2>"$tmp_dir/stale-socket-error"; then
  printf 'backup refused a verified stale managed TLS socket\n' >&2
  exit 1
fi
rg -q 'stop localai-tls-forward.socket localai-tls-forward.service' "$tmp_dir/commands"
rg -q 'start localai-tls-forward.socket localai-tls-forward.service' "$tmp_dir/commands"
# The test's unprivileged run0 shim cannot restore a root-owned config. Verify
# strict validation rejects its user-owned config, then omit that member from
# the state-only round-trip fixture. Real root-owned config restore needs VM proof.
if python3 "$repo_root/lib/backup_archive.py" validate "$backup_archive" "$tmp_dir/backup-config-dir/localai.conf" \
  "$tmp_dir/backup-state" "$tmp_dir/backup-tls" "$tmp_dir/backup-cache" >/dev/null 2>&1; then
  printf 'archive validator accepted a non-root-owned configuration member\n' >&2
  exit 1
fi
python3 - "$backup_archive" "$tmp_dir/backup-config-dir/localai.conf" <<'PY'
import os, sys, tarfile, tempfile
archive_path, config_path = sys.argv[1:]
fd, rewritten = tempfile.mkstemp(dir=os.path.dirname(archive_path))
os.close(fd)
try:
    with tarfile.open(archive_path, 'r:gz') as source, tarfile.open(rewritten, 'w:gz', format=tarfile.PAX_FORMAT) as target:
        for info in source:
            if info.name == config_path.lstrip('/'):
                continue
            data = source.extractfile(info) if info.isfile() else None
            target.addfile(info, data)
    os.chmod(rewritten, 0o600)
    os.replace(rewritten, archive_path)
finally:
    if os.path.exists(rewritten): os.unlink(rewritten)
PY
[[ "$(stat -c '%a' "$backup_archive")" == 600 ]]
rg -q 'TLS CA private key' "$tmp_dir/backup-warning"
archive_metadata="$(/usr/bin/tar -xOzf "$backup_archive" metadata)"
rg -q '^backend_image=' <<<"$archive_metadata"
rg -q '^backend_digest=' <<<"$archive_metadata"
if ! rg -q 'backup-state/.config/systemd/user/localai.service' "$archive_listing"; then
  printf 'backup omitted the configured backend service unit state\n' >&2
  exit 1
fi
if ! rg -q 'backup-tls/.config/systemd/user/localai-tls-compose.service' "$archive_listing"; then
  printf 'backup omitted the configured TLS service unit state\n' >&2
  exit 1
fi
if rg -q 'models/model.bin' "$archive_listing"; then
  printf 'models were included despite --exclude-models\n' >&2
  exit 1
fi
if ! rg -q 'backup-cache/cache.db' "$archive_listing"; then
  printf 'configured persistent data outside the main state root was omitted\n' >&2
  exit 1
fi
python3 - "$repo_root/lib" "$backup_archive" "$tmp_dir/backup-config-dir/localai.conf" "$tmp_dir/backup-state" "$tmp_dir/backup-tls" "$tmp_dir/backup-cache" "$podman_layer" <<'PY'
import sys

sys.path.insert(0, sys.argv[1])
from backup_archive import has_systemd_tree, systemd_tree_prefix, validate_archive

archive, config, state, tls, cache, podman_layer = sys.argv[2:]
roots = [state, tls, cache]
names = validate_archive(archive, config, roots, require_root_config=False)
for manager in ("system", "user"):
    image_unit = f"{podman_layer.lstrip('/')}/{manager}/inert.service"
    if image_unit not in names or has_systemd_tree(image_unit, manager, roots):
        raise SystemExit("inert Podman image unit was treated as host unit configuration")
    if systemd_tree_prefix(image_unit, manager, [state, tls]) is not None:
        raise SystemExit("inert Podman image unit was treated as service-home unit configuration")
for service_root, unit in ((state, "localai.service"), (tls, "localai-tls-compose.service")):
    unit_path = f"{service_root.lstrip('/')}/.config/systemd/user/{unit}"
    if systemd_tree_prefix(unit_path, "user", [state, tls]) != f"{service_root.lstrip('/')}/.config/systemd/user":
        raise SystemExit("configured service-home unit tree was not recognized")
system_unit = f"{state.lstrip('/')}/.config/systemd/system/evil.service"
if not has_systemd_tree(system_unit, "system", roots):
    raise SystemExit("configured-root system manager unit tree was not rejected")
PY
stop_count_before="$(rg -c ' stop localai.service$' "$tmp_dir/commands" || true)"
if LOCALAI_FAKE_WRONG_TLS_UNIT_OWNER=true "$repo_root/bin/localaictl" backup "$tmp_dir/wrong-tls-owner.tar.gz" >/dev/null 2>&1; then
  printf 'backup accepted a TLS unit with the wrong owner\n' >&2
  exit 1
fi
stop_count_after="$(rg -c ' stop localai.service$' "$tmp_dir/commands" || true)"
[[ "$stop_count_before" == "$stop_count_after" ]]
if LOCALAI_TEST_BACKUP_STAGE_DIR="$tmp_dir" LOCALAI_FAKE_WRONG_BACKEND_UNIT_OWNER=true \
  "$repo_root/bin/localaictl" restore --yes "$backup_archive" >/dev/null 2>&1; then
  printf 'restore accepted a backend unit with the wrong owner\n' >&2
  exit 1
fi
stop_count_after="$(rg -c ' stop localai.service$' "$tmp_dir/commands" || true)"
[[ "$stop_count_before" == "$stop_count_after" ]]
if env -u LOCALAI_TEST_BACKUP_STAGE_DIR LOCALAI_FAKE_WRONG_BACKEND_UNIT_OWNER=true \
  "$repo_root/bin/localaictl" restore --yes "$backup_archive" >/dev/null 2>&1; then
  printf 'restore accepted a backend unit with the wrong owner when the test variable was unset\n' >&2
  exit 1
fi
stop_count_after="$(rg -c ' stop localai.service$' "$tmp_dir/commands" || true)"
[[ "$stop_count_before" == "$stop_count_after" ]]
if "$repo_root/bin/localaictl" backup "$tmp_dir/backup-state/inside.tar.gz" >/dev/null 2>&1; then
  printf 'backup destination inside state was accepted\n' >&2
  exit 1
fi
malicious_archive="$tmp_dir/malicious.tar.gz"
python3 - "$malicious_archive" "$tmp_dir/backup-state" <<'PY'
import io, sys, tarfile
with tarfile.open(sys.argv[1], 'w:gz') as archive:
    info = tarfile.TarInfo('metadata')
    info.size = 3
    archive.addfile(info, io.BytesIO(b'v=1'))
    info = tarfile.TarInfo(sys.argv[2].lstrip('/') + '/escape')
    info.type = tarfile.SYMTYPE
    info.linkname = '../../../../etc/passwd'
    archive.addfile(info)
PY
stop_count_before="$(rg -c ' stop localai.service$' "$tmp_dir/commands" || true)"
if "$repo_root/bin/localaictl" restore --yes "$malicious_archive" >/dev/null 2>&1; then
  printf 'restore accepted a traversal symbolic link\n' >&2
  exit 1
fi
stop_count_after="$(rg -c ' stop localai.service$' "$tmp_dir/commands" || true)"
[[ "$stop_count_before" == "$stop_count_after" ]]
omitted_units_archive="$tmp_dir/omitted-units.tar.gz"
python3 - "$backup_archive" "$omitted_units_archive" <<'PY'
import sys, tarfile
source_path, target_path = sys.argv[1:]
with tarfile.open(source_path, 'r:gz') as source, tarfile.open(target_path, 'w:gz') as target:
    for member in source:
        parts = member.name.rstrip('/').split('/')
        if any(parts[index:index + 2] == ['systemd', 'user'] for index in range(len(parts) - 1)):
            continue
        target.addfile(member, source.extractfile(member) if member.isfile() else None)
PY
stop_count_before="$(rg -c ' stop localai.service$' "$tmp_dir/commands" || true)"
if "$repo_root/bin/localaictl" restore --yes "$omitted_units_archive" >/dev/null 2>&1; then
  printf 'restore accepted an archive that omitted installed user service units\n' >&2
  exit 1
fi
stop_count_after="$(rg -c ' stop localai.service$' "$tmp_dir/commands" || true)"
[[ "$stop_count_before" == "$stop_count_after" ]]
for unsafe_ancestor in persistent-root config-parent systemd-parent directory-xattr directory-acl; do
  unsafe_ancestor_archive="$tmp_dir/unsafe-ancestor-$unsafe_ancestor.tar.gz"
  python3 - "$backup_archive" "$unsafe_ancestor_archive" "$tmp_dir" "$unsafe_ancestor" <<'PY'
import io, sys, tarfile
source_path, target_path, base, kind = sys.argv[1:]
target = {
    'persistent-root': f'{base}/backup-state',
    'config-parent': f'{base}/backup-state/.config',
    'systemd-parent': f'{base}/backup-state/.config/systemd',
    'directory-xattr': f'{base}/backup-state/.config',
    'directory-acl': f'{base}/backup-state/.config',
}[kind].lstrip('/')
with tarfile.open(source_path, 'r:gz') as source, tarfile.open(target_path, 'w:gz', format=tarfile.PAX_FORMAT) as target_archive:
    for member in source:
        if member.name.rstrip('/') == target:
            if kind == 'directory-xattr':
                member.pax_headers['SCHILY.xattr.user.localai-ancestor-test'] = 'tampered'
            elif kind == 'directory-acl':
                member.pax_headers['SCHILY.acl.default'] = 'user::rwx\ngroup::rwx\nother::rwx\n'
            else:
                member.mode = 0o777
        target_archive.addfile(member, source.extractfile(member) if member.isfile() else None)
PY
  stop_count_before="$(rg -c ' stop localai.service$' "$tmp_dir/commands" || true)"
  if "$repo_root/bin/localaictl" restore --yes "$unsafe_ancestor_archive" >/dev/null 2>&1; then
    printf 'restore accepted weakened unit ancestor metadata (%s)\n' "$unsafe_ancestor" >&2
    exit 1
  fi
  stop_count_after="$(rg -c ' stop localai.service$' "$tmp_dir/commands" || true)"
  [[ "$stop_count_before" == "$stop_count_after" ]]
done
for entry_type in directory symlink; do
  invalid_config_archive="$tmp_dir/invalid-config-$entry_type.tar.gz"
  python3 - "$invalid_config_archive" "$tmp_dir/backup-config-dir/localai.conf" "$entry_type" <<'PY'
import sys, tarfile
archive_path, config_path, entry_type = sys.argv[1:]
with tarfile.open(archive_path, 'w:gz') as archive:
    metadata = tarfile.TarInfo('metadata')
    metadata.size = 3
    import io
    archive.addfile(metadata, io.BytesIO(b'v=1'))
    config = tarfile.TarInfo(config_path.lstrip('/'))
    if entry_type == 'directory':
        config.type = tarfile.DIRTYPE
    else:
        config.type = tarfile.SYMTYPE
        config.linkname = 'outside'
    archive.addfile(config)
PY
  if "$repo_root/bin/localaictl" restore --yes "$invalid_config_archive" >/dev/null 2>&1; then
    printf 'restore accepted a configuration member of type %s\n' "$entry_type" >&2
    exit 1
  fi
done
unsafe_config_archive="$tmp_dir/unsafe-config-mode.tar.gz"
python3 - "$unsafe_config_archive" "$tmp_dir/backup-config-dir/localai.conf" <<'PY'
import io, sys, tarfile
archive_path, config_path = sys.argv[1:]
with tarfile.open(archive_path, 'w:gz') as archive:
    metadata = tarfile.TarInfo('metadata')
    metadata.size = 3
    archive.addfile(metadata, io.BytesIO(b'v=1'))
    config = tarfile.TarInfo(config_path.lstrip('/'))
    config.mode = 0o666
    config.size = 3
    archive.addfile(config, io.BytesIO(b'x=1'))
PY
if "$repo_root/bin/localaictl" restore --yes "$unsafe_config_archive" >/dev/null 2>&1; then
  printf 'restore accepted a group/world-writable configuration member\n' >&2
  exit 1
fi
cross_root_archive="$tmp_dir/cross-root-link.tar.gz"
python3 - "$cross_root_archive" "$tmp_dir/backup-state" "$tmp_dir/backup-tls" <<'PY'
import io, sys, tarfile
archive_path, state, tls = sys.argv[1:]
with tarfile.open(archive_path, 'w:gz') as archive:
    metadata = tarfile.TarInfo('metadata')
    metadata.size = 3
    archive.addfile(metadata, io.BytesIO(b'v=1'))
    root = tarfile.TarInfo(state.lstrip('/'))
    root.type = tarfile.DIRTYPE
    archive.addfile(root)
    link = tarfile.TarInfo(state.lstrip('/') + '/cross-root')
    link.type = tarfile.SYMTYPE
    link.linkname = tls + '/ca.key'
    archive.addfile(link)
PY
if "$repo_root/bin/localaictl" restore --yes "$cross_root_archive" >/dev/null 2>&1; then
  printf 'restore accepted a symbolic link crossing configured persistent roots\n' >&2
  exit 1
fi
stop_count_after="$(rg -c ' stop localai.service$' "$tmp_dir/commands" || true)"
[[ "$stop_count_before" == "$stop_count_after" ]]
for unsafe_kind in setuid capability; do
  unsafe_archive="$tmp_dir/unsafe-$unsafe_kind.tar.gz"
  python3 - "$unsafe_archive" "$tmp_dir/backup-state" "$unsafe_kind" <<'PY'
import io, sys, tarfile
archive_path, state, unsafe_kind = sys.argv[1:]
with tarfile.open(archive_path, 'w:gz', format=tarfile.PAX_FORMAT) as archive:
    metadata = tarfile.TarInfo('metadata')
    metadata.size = 3
    archive.addfile(metadata, io.BytesIO(b'v=1'))
    root = tarfile.TarInfo(state.lstrip('/'))
    root.type = tarfile.DIRTYPE
    root.mode = 0o755
    archive.addfile(root)
    member = tarfile.TarInfo(state.lstrip('/') + '/privileged')
    member.size = 1
    if unsafe_kind == 'setuid':
        member.mode = 0o4755
    else:
        member.mode = 0o755
        member.pax_headers['SCHILY.xattr.security.capability'] = 'cap_setuid=ep'
    archive.addfile(member, io.BytesIO(b'x'))
PY
  if "$repo_root/bin/localaictl" restore --yes "$unsafe_archive" >/dev/null 2>&1; then
    printf 'restore accepted a %s executable entry\n' "$unsafe_kind" >&2
    exit 1
  fi
done
for unit_case in tls-exec tls-dropin user-wants system-unit; do
  unit_archive="$tmp_dir/unsafe-unit-$unit_case.tar.gz"
  python3 - "$unit_archive" "$tmp_dir/backup-tls" "$unit_case" <<'PY'
import io, sys, tarfile
archive_path, tls_root, unit_case = sys.argv[1:]
root_name = tls_root.lstrip('/')
if unit_case == 'tls-exec':
    member_name = root_name + '/.config/systemd/user/localai-tls-compose.service'
    payload = b'[Service]\nExecStart=/usr/bin/touch /root/restore-unit-compromise\n'
elif unit_case == 'tls-dropin':
    member_name = root_name + '/.config/systemd/user/localai-tls-compose.service.d/override.conf'
    payload = b'[Service]\nExecStart=/usr/bin/touch /root/restore-unit-compromise\n'
elif unit_case == 'user-wants':
    member_name = root_name + '/.config/systemd/user/default.target.wants/evil.service'
    payload = b'[Service]\nExecStart=/usr/bin/touch /root/restore-unit-compromise\n'
else:
    member_name = root_name + '/.config/systemd/system/evil.service'
    payload = b'[Service]\nExecStart=/usr/bin/touch /root/restore-unit-compromise\n'
with tarfile.open(archive_path, 'w:gz') as archive:
    metadata = tarfile.TarInfo('metadata')
    metadata.size = 3
    archive.addfile(metadata, io.BytesIO(b'v=1'))
    root = tarfile.TarInfo(root_name)
    root.type = tarfile.DIRTYPE
    archive.addfile(root)
    member = tarfile.TarInfo(member_name)
    member.size = len(payload)
    archive.addfile(member, io.BytesIO(payload))
PY
  if "$repo_root/bin/localaictl" restore --yes "$unit_archive" >/dev/null 2>&1; then
    printf 'restore accepted changed or unsupported systemd unit content (%s)\n' "$unit_case" >&2
    exit 1
  fi
  stop_count_after="$(rg -c ' stop localai.service$' "$tmp_dir/commands" || true)"
  [[ "$stop_count_before" == "$stop_count_after" ]]
done
non_directory_root_archive="$tmp_dir/non-directory-root.tar.gz"
python3 - "$non_directory_root_archive" "$tmp_dir/backup-state" <<'PY'
import io, sys, tarfile
archive_path, state = sys.argv[1:]
with tarfile.open(archive_path, 'w:gz') as archive:
    metadata = tarfile.TarInfo('metadata')
    metadata.size = 3
    archive.addfile(metadata, io.BytesIO(b'v=1'))
    root = tarfile.TarInfo(state.lstrip('/'))
    root.size = 1
    archive.addfile(root, io.BytesIO(b'x'))
PY
if "$repo_root/bin/localaictl" restore --yes "$non_directory_root_archive" >/dev/null 2>&1; then
  printf 'restore accepted a non-directory persistent root member\n' >&2
  exit 1
fi
stop_count_after="$(rg -c ' stop localai.service$' "$tmp_dir/commands" || true)"
[[ "$stop_count_before" == "$stop_count_after" ]]
rm "$tmp_dir/backup-state/database-current"
ln -s elsewhere "$tmp_dir/backup-state/database-current"
if "$repo_root/bin/localaictl" restore --yes "$backup_archive" >/dev/null 2>&1; then
  printf 'restore accepted a mismatched destination symlink\n' >&2
  exit 1
fi
stop_count_after="$(rg -c ' stop localai.service$' "$tmp_dir/commands" || true)"
[[ "$stop_count_before" == "$stop_count_after" ]]
rm "$tmp_dir/backup-state/database-current"
ln -s database.db "$tmp_dir/backup-state/database-current"
rg -q '^systemctl .*stop localai.service$' "$tmp_dir/commands"
rg -q '^systemctl .*start localai.service$' "$tmp_dir/commands"
if "$repo_root/bin/localaictl" backup "$backup_archive" >/dev/null 2>&1; then
  printf 'backup overwrote an existing destination\n' >&2
  exit 1
fi
if "$repo_root/bin/localaictl" restore "$backup_archive" >/dev/null 2>&1; then
  printf 'restore overwrote non-empty state without confirmation\n' >&2
  exit 1
fi
python3 - "$repo_root/bin/localaictl" "$backup_archive" <<'PY'
import errno, os, pty, select, sys, time
pid, terminal = pty.fork()
if pid == 0:
    os.execv(sys.argv[1], [sys.argv[1], 'restore', sys.argv[2]])
output = bytearray()
sent = False
deadline = time.monotonic() + 45
status = None
while time.monotonic() < deadline:
    ready, _, _ = select.select([terminal], [], [], 0.1)
    if ready:
        try:
            chunk = os.read(terminal, 4096)
        except OSError as error:
            if error.errno != errno.EIO:
                raise
            chunk = b''
        output.extend(chunk)
        if not sent and b'Continue? [y/N]' in output:
            os.write(terminal, b'y\n')
            sent = True
    finished, child_status = os.waitpid(pid, os.WNOHANG)
    if finished:
        status = child_status
        break
if status is None:
    os.kill(pid, 15)
    os.waitpid(pid, 0)
    raise SystemExit('interactive restore timed out')
if not sent or not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
    text = bytes(output)
    reason = 'unexpected'
    for marker, label in ((b'insufficient free disk', 'space'), (b'memory-backed', 'filesystem'),
                          (b'unsupported or unsafe', 'archive-validation'), (b'SELinux', 'label-check'),
                          (b'rollback', 'rollback'), (b'ownership checks', 'unit-ownership'),
                          (b'bootstrap safety', 'bootstrap-safety'), (b'daemon-reload', 'manager-reload'),
                          (b'insufficient free inodes', 'inode-capacity'), (b'cannot create', 'copy-create'),
                          (b'Permission denied', 'permission'), (b'Operation not permitted', 'ownership-operation'),
                          (b'targets changed', 'target-race'), (b'could not prepare rollback', 'rollback-snapshot'),
                          (b'No space left', 'space-exhausted'), (b'File exists', 'collision'),
                          (b'failed to preserve', 'metadata-copy'), (b'chmod:', 'fixture-chmod'),
                          (b'find:', 'fixture-find'), (b'rm:', 'fixture-rm'),
                          (b'user unit file differs', 'unit-file-mismatch'),
                          (b'user unit tree entries differ', 'unit-entry-set-mismatch'),
                          (b'user unit link differs', 'unit-link-mismatch'),
                          (b'user unit entry type differs', 'unit-type-mismatch'),
                          (b'absent from the installed tree', 'unit-missing'),
                          (b'unit', 'unit-safety'), (b'bootstrap', 'bootstrap-safety')):
        if marker in text:
            reason = label
            break
    exited = os.WIFEXITED(status)
    code = os.WEXITSTATUS(status) if exited else -1
    raise SystemExit(f'interactive restore failed: response-sent={int(sent)} exited={int(exited)} code={code} reason={reason}')
PY
[[ "$(<"$tmp_dir/backup-state/database.db")" == 'state fixture' ]]
printf 'damaged state\n' >"$tmp_dir/backup-state/database.db"
printf 'damaged external cache\n' >"$tmp_dir/backup-cache/cache.db"
chmod 0755 "$tmp_dir/backup-state"
"$repo_root/bin/localaictl" restore --yes "$backup_archive" >"$tmp_dir/restore-output"
[[ "$(stat -c '%a' "$tmp_dir/backup-state")" == 710 ]]
restore_config_dir="$tmp_dir/restore-config"
mkdir -m 0700 "$restore_config_dir"
restore_config_path="$restore_config_dir/localai.conf"
printf 'LOCALAI_STATE_DIR=%s\nLOCALAI_MODELS_PATH=%s/models\nLOCALAI_BACKENDS_PATH=%s/backends\nLOCALAI_DOWNLOAD_STAGING_PATH=%s/downloading\nLOCALAI_BACKEND_TEMP_DIR=%s/tmp\nLOCALAI_DATA_PATH=%s/data\nLOCALAI_CONFIG_DIR=%s/config\nLOCALAI_GENERATED_CONTENT_PATH=%s/generated\nLOCALAI_UPLOAD_PATH=%s/uploads\nLOCALAI_CACHE_DIR=%s\nLOCALAI_LOG_DIR=%s/logs\nLOCALAI_TLS_STATE_DIR=%s\nLOCALAI_TLS_CONFIG_DIR=%s/caddy\nLOCALAI_TLS_CACHE_DIR=%s/cache\nLOCALAI_TLS_CERT_DIR=%s/certs\nLOCALAI_TLS_COMPOSE_DIR=%s/compose\nLOCALAI_TLS_ENABLED=false\n' \
  "$tmp_dir/backup-state" "$tmp_dir/backup-state" "$tmp_dir/backup-state" "$tmp_dir/backup-state" "$tmp_dir/backup-state" "$tmp_dir/backup-state" "$tmp_dir/backup-state" "$tmp_dir/backup-state" "$tmp_dir/backup-state" "$tmp_dir/backup-cache" "$tmp_dir/backup-state" "$tmp_dir/backup-tls" "$tmp_dir/backup-tls" "$tmp_dir/backup-tls" "$tmp_dir/backup-tls" "$tmp_dir/backup-tls" >"$restore_config_path"
config_archive="$tmp_dir/root-owned-config.tar.gz"
python3 - "$config_archive" "$restore_config_path" "$backup_archive" <<'PY'
import io, sys, tarfile
archive_path, config_path, source_path = sys.argv[1:]
with tarfile.open(archive_path, 'w:gz') as archive:
    metadata = tarfile.TarInfo('metadata')
    metadata.size = 3
    archive.addfile(metadata, io.BytesIO(b'v=1'))
    config = tarfile.TarInfo(config_path.lstrip('/'))
    config.uid = 0
    config.gid = 0
    config.mode = 0o600
    config_data = b'LOCALAI_AUTH=true\n'
    config.size = len(config_data)
    archive.addfile(config, io.BytesIO(config_data))
    with tarfile.open(source_path, 'r:gz') as source:
        unit_roots = set()
        for member in source:
            parts = member.name.rstrip('/').split('/')
            for index in range(len(parts) - 1):
                if parts[index:index + 2] == ['systemd', 'user']:
                    unit_roots.add('/'.join(parts[:index - 1]))
        for member in source:
            if any(member.name.rstrip('/') == root or member.name.startswith(root + '/') for root in unit_roots):
                archive.addfile(member, source.extractfile(member) if member.isfile() else None)
PY
cat >"$tmp_dir/cp-config-test" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *" ${LOCALAI_TEST_CONFIG_DEST:?} "* ]]; then
  exec /usr/bin/cp -a --no-preserve=ownership "${@:3}"
fi
exec /usr/bin/cp "$@"
EOF
chmod 0755 "$tmp_dir/cp-config-test"
export LOCALAI_TEST_CONFIG_DEST="$restore_config_path"
export LOCALAI_CP_BIN="$tmp_dir/cp-config-test"
LOCALAI_CONFIG_FILE="$restore_config_path" "$repo_root/bin/localaictl" restore --yes "$config_archive" >"$tmp_dir/config-restore-output"
unset LOCALAI_CP_BIN LOCALAI_TEST_CONFIG_DEST
[[ "$(<"$tmp_dir/backup-state/database.db")" == 'state fixture' ]]
[[ "$(stat -c '%a' "$tmp_dir/backup-state/database.db")" == 640 ]]
python3 - "$tmp_dir/backup-state/database.db" <<'PY'
import os, sys
try:
    assert os.getxattr(sys.argv[1], 'user.localai-test') == b'preserve-xattr'
except OSError:
    pass
PY
[[ "$(<"$tmp_dir/backup-tls/ca.key")" == 'tls fixture' ]]
[[ "$(<"$tmp_dir/backup-cache/cache.db")" == 'external cache fixture' ]]
[[ "$(readlink "$tmp_dir/backup-state/database-current")" == database.db ]]
rg -q '^matchpathcon -V ' "$tmp_dir/commands"
rg -q "^restorecon -F -- $restore_config_path$" "$tmp_dir/commands"
rg -q "^matchpathcon -V $restore_config_path$" "$tmp_dir/commands"
if rg -q '^restorecon .*backup-(state|tls|cache)' "$tmp_dir/commands"; then
  printf 'restore recursively relabeled persistent state\n' >&2
  exit 1
fi
rg -q 'start localai.service' "$tmp_dir/commands"
[[ "$(<"$tmp_dir/backup-state/unrelated.txt")" == 'preserve this' ]]
[[ "$(<"$LOCALAI_FAKE_STATE_DIR/backend")" == active ]]

# Send TERM immediately after the first state directory copy. The EXIT cleanup
# must roll back the snapshot before restarting services.
printf 'before signal\n' >"$tmp_dir/backup-state/database.db"
cat >"$tmp_dir/cp-then-term" <<'EOF'
#!/usr/bin/env bash
/usr/bin/cp "$@"
if [[ "${LOCALAI_FAKE_TERM_AFTER_COPY:-false}" == true && " $* " == *"backup-state/. "* ]]; then
  kill -TERM "$PPID"
fi
EOF
chmod 0755 "$tmp_dir/cp-then-term"
export LOCALAI_CP_BIN="$tmp_dir/cp-then-term"
export LOCALAI_FAKE_TERM_AFTER_COPY=true
python3 - "$repo_root/bin/localaictl" "$backup_archive" <<'PY'
import errno, os, pty, select, sys, time
pid, terminal = pty.fork()
if pid == 0:
    os.execv(sys.argv[1], [sys.argv[1], 'restore', '--yes', sys.argv[2]])
status = None
deadline = time.monotonic() + 45
while time.monotonic() < deadline:
    ready, _, _ = select.select([terminal], [], [], 0.1)
    if ready:
        try:
            os.read(terminal, 4096)
        except OSError as error:
            if error.errno != errno.EIO:
                raise
    finished, child_status = os.waitpid(pid, os.WNOHANG)
    if finished:
        status = child_status
        break
if status is None:
    os.kill(pid, 15)
    os.waitpid(pid, 0)
    raise SystemExit('restore signal test timed out')
if not os.WIFEXITED(status) or os.WEXITSTATUS(status) == 0:
    raise SystemExit('restore unexpectedly succeeded after TERM')
PY
unset LOCALAI_CP_BIN LOCALAI_FAKE_TERM_AFTER_COPY
[[ "$(<"$tmp_dir/backup-state/database.db")" == 'before signal' ]]
[[ "$(<"$LOCALAI_FAKE_STATE_DIR/backend")" == active ]]

printf 'before rollback\n' >"$tmp_dir/backup-state/database.db"
export LOCALAI_FAKE_FAIL_LABEL=true
if "$repo_root/bin/localaictl" restore --yes "$backup_archive" >"$tmp_dir/rollback-output" 2>"$tmp_dir/rollback-error"; then
  printf 'restore ignored a failed SELinux label verification\n' >&2
  exit 1
fi
unset LOCALAI_FAKE_FAIL_LABEL
[[ "$(<"$tmp_dir/backup-state/database.db")" == 'before rollback' ]]
if [[ "$(<"$LOCALAI_FAKE_STATE_DIR/backend")" != active ]]; then
  cat "$tmp_dir/rollback-output" "$tmp_dir/rollback-error" >&2
  cat "$tmp_dir/commands" >&2
  exit 1
fi

# TLS is disabled in config, but previously installed managed units remain
# part of the state snapshot. Refuse unowned units before stopping anything.
tls_unit_dir="$tmp_dir/backup-tls/.config/systemd/user"
mkdir -p "$tls_unit_dir" "$tmp_dir/systemd"
printf '# unrelated unit\n' >"$tls_unit_dir/localai-tls-compose.service"
: >"$tmp_dir/commands"
stale_archive="$tmp_dir/stale-tls.tar.gz"
if "$repo_root/bin/localaictl" backup "$stale_archive" >/dev/null 2>&1; then
  printf 'backup accepted an unowned TLS unit while TLS was disabled\n' >&2
  exit 1
fi
if rg -q ' stop localai' "$tmp_dir/commands"; then
  printf 'backup stopped a service before verifying TLS unit ownership\n' >&2
  exit 1
fi
printf '# Managed by LocalAI secureblue TLS installer.\n' >"$tls_unit_dir/localai-tls-compose.service"
printf '# Managed by LocalAI secureblue TLS installer.\n' >"$tmp_dir/systemd/localai-tls-forward.socket"
printf '# Managed by LocalAI secureblue TLS installer.\n' >"$tmp_dir/systemd/localai-tls-forward.service"
: >"$tmp_dir/commands"
"$repo_root/bin/localaictl" backup "$stale_archive" >"$tmp_dir/stale-backup-output" 2>"$tmp_dir/stale-backup-warning"
backend_start_line="$(rg -n ' start localai.service$' "$tmp_dir/commands" | tail -n1 | cut -d: -f1)"
tls_start_line="$(rg -n ' start localai-tls-compose.service$' "$tmp_dir/commands" | tail -n1 | cut -d: -f1)"
socket_start_line="$(rg -n ' start localai-tls-forward.socket' "$tmp_dir/commands" | tail -n1 | cut -d: -f1)"
(( backend_start_line < tls_start_line && tls_start_line < socket_start_line ))

printf 'localaictl tests passed\n'
