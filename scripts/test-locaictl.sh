#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
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
mkdir -p "$LOCALAI_FAKE_STATE_DIR"
export LOCALAI_ID_BIN="$tmp_dir/id"
export LOCALAI_JOURNALCTL_BIN="$tmp_dir/journalctl"
export LOCALAI_SYSTEM_UNIT_DIR="$tmp_dir/systemd"
export HOME="$tmp_dir/home"

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
mkdir -p "$tmp_dir/backup-state" "$tmp_dir/backup-tls" "$tmp_dir/backup-config-dir"
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
printf 'LOCALAI_STATE_DIR=%s\nLOCALAI_TLS_STATE_DIR=%s\nLOCALAI_MODELS_PATH=%s\nLOCALAI_TLS_ENABLED=false\n' \
  "$tmp_dir/backup-state" "$tmp_dir/backup-tls" "$tmp_dir/backup-state/models" >"$tmp_dir/backup-config-dir/localai.conf"
mkdir -p "$tmp_dir/backup-state/models"
printf 'model fixture\n' >"$tmp_dir/backup-state/models/model.bin"
export LOCALAI_CONFIG_FILE="$tmp_dir/backup-config-dir/localai.conf"
export LOCALAI_TAR_BIN=/usr/bin/tar
cat >"$tmp_dir/matchpathcon" <<'EOF'
#!/usr/bin/env bash
printf 'matchpathcon %s\n' "$*" >>"${LOCALAI_FAKE_LOG:?}"
[[ "${LOCALAI_FAKE_FAIL_LABEL:-false}" != true ]]
EOF
chmod 0755 "$tmp_dir/matchpathcon"
export LOCALAI_MATCHPATHCON_BIN="$tmp_dir/matchpathcon"
: >"$tmp_dir/commands"
backup_archive="$tmp_dir/backup.tar.gz"
if ! "$repo_root/bin/localaictl" backup --exclude-models "$backup_archive" 2>"$tmp_dir/backup-warning"; then
  cat "$tmp_dir/backup-warning" >&2
  exit 1
fi
[[ "$(stat -c '%a' "$backup_archive")" == 600 ]]
rg -q 'TLS CA private key' "$tmp_dir/backup-warning"
archive_metadata="$(/usr/bin/tar -xOzf "$backup_archive" metadata)"
rg -q '^backend_image=' <<<"$archive_metadata"
rg -q '^backend_digest=' <<<"$archive_metadata"
if /usr/bin/tar -tzf "$backup_archive" | rg -q 'models/model.bin'; then
  printf 'models were included despite --exclude-models\n' >&2
  exit 1
fi
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
    raise SystemExit('interactive restore did not accept the explicit y response')
PY
[[ "$(<"$tmp_dir/backup-state/database.db")" == 'state fixture' ]]
printf 'damaged state\n' >"$tmp_dir/backup-state/database.db"
"$repo_root/bin/localaictl" restore --yes "$backup_archive" >"$tmp_dir/restore-output"
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
[[ "$(readlink "$tmp_dir/backup-state/database-current")" == database.db ]]
rg -q '^matchpathcon -V ' "$tmp_dir/commands"
if rg -q '^restorecon ' "$tmp_dir/commands"; then
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

printf 'localaictl tests passed\n'
