#!/usr/bin/env bash
set -euo pipefail
trap 'printf "localaictl test assertion failed at line %s\\n" "$LINENO" >&2' ERR

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# Sourced test support reads this variable indirectly.
# shellcheck disable=SC2034
TEST_REPO_ROOT="$repo_root"
source "$repo_root/scripts/test-support.sh"
test_sanitize_localai_environment
# shellcheck disable=SC1090
source <(sed -n '/^rootless_tar_failure_category() {$/,/^}/p' "$repo_root/bin/localaictl")
# shellcheck disable=SC1090
source <(sed -n '/^rootless_tar_member_metadata_category() {$/,/^}/p' "$repo_root/bin/localaictl")
[[ "$(rootless_tar_failure_category 'tar: cannot write: Permission denied')" == permission ]]
[[ "$(rootless_tar_failure_category 'tar: synthetic: Cannot open: Permission denied')" == source-open-permission ]]
[[ "$(rootless_tar_failure_category 'tar: synthetic: Cannot read: Permission denied')" == source-read-permission ]]
[[ "$(rootless_tar_failure_category 'tar: synthetic: Cannot get extended attributes: Permission denied')" == xattr-read-permission ]]
[[ "$(rootless_tar_failure_category 'tar: synthetic: Cannot set extended attributes: Permission denied')" == xattr-write-permission ]]
[[ "$(rootless_tar_failure_category 'tar: synthetic: Cannot get ACL: Permission denied')" == acl-read-permission ]]
[[ "$(rootless_tar_failure_category 'tar: synthetic: Cannot set ACL: Permission denied')" == acl-write-permission ]]
[[ "$(rootless_tar_failure_category 'tar: synthetic: Cannot stat: Permission denied')" == source-stat-permission ]]
[[ "$(rootless_tar_failure_category 'tar: synthetic: Cannot change ownership: Permission denied')" == ownership-permission ]]
[[ "$(rootless_tar_failure_category 'tar: write failed: No space left on device')" == capacity ]]
[[ "$(rootless_tar_failure_category 'tar: file changed as we read it')" == source-changed ]]
[[ "$(rootless_tar_failure_category 'tar: unrecognized option -- test')" == unsupported-option ]]
[[ "$(rootless_tar_failure_category 'tar: Cannot stat: No such file or directory')" == source-path ]]
[[ "$(rootless_tar_failure_category 'tar: Operation not permitted')" == operation-not-permitted ]]
[[ "$(rootless_tar_failure_category 'Failed to connect to bus')" == service-manager ]]
[[ "$(rootless_tar_failure_category 'tar: xattr failed')" == xattr ]]
[[ "$(rootless_tar_failure_category '')" == empty-error ]]
[[ "$(rootless_tar_failure_category 'synthetic unclassified diagnostic')" == other ]]
tmp_dir="$(test_mktemp_dir localaictl-test)"
trap 'rm -rf "$tmp_dir"' EXIT
export TMPDIR="$tmp_dir"
mkdir -p "$tmp_dir/storage"
printf 'synthetic fixture\n' >"$tmp_dir/storage/member"
chmod 0640 "$tmp_dir/storage/member"
[[ "$(LOCALAI_DIAGNOSTIC_SERVICE_UID="$(id -u)" rootless_tar_member_metadata_category "$tmp_dir/storage" 'tar: storage/member: Cannot open: Permission denied' "$tmp_dir/storage/.localaictl-backup-restore-marker")" == member-regular-owner-service-mode-0640-path-other-root-entry ]]
printf 'synthetic marker\n' >"$tmp_dir/storage/.localaictl-backup-restore-marker"
chmod 0600 "$tmp_dir/storage/.localaictl-backup-restore-marker"
[[ "$(LOCALAI_DIAGNOSTIC_SERVICE_UID="$(id -u)" rootless_tar_member_metadata_category "$tmp_dir/storage" 'tar: storage/.localaictl-backup-restore-marker: Cannot open: Permission denied' "$tmp_dir/storage/.localaictl-backup-restore-marker")" == member-acceptance-marker-owner-service-mode-0600-persistence-fixture ]]
[[ "$(LOCALAI_DIAGNOSTIC_SERVICE_UID="$(id -u)" rootless_tar_member_metadata_category "$tmp_dir/storage" 'synthetic diagnostic with no path' "$tmp_dir/storage/.localaictl-backup-restore-marker")" == member-unidentified ]]
[[ "$(LOCALAI_DIAGNOSTIC_SERVICE_UID="$(id -u)" rootless_tar_member_metadata_category "$tmp_dir/storage" 'tar: ../outside: Cannot open: Permission denied' "$tmp_dir/storage/.localaictl-backup-restore-marker")" == member-outside-graphroot ]]
mkdir -p "$tmp_dir/outside"
ln -s "$tmp_dir/outside" "$tmp_dir/storage/link"
[[ "$(LOCALAI_DIAGNOSTIC_SERVICE_UID="$(id -u)" rootless_tar_member_metadata_category "$tmp_dir/storage" 'tar: storage/link/member: Cannot open: Permission denied' "$tmp_dir/storage/.localaictl-backup-restore-marker")" == member-path-unsafe ]]

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
if [[ "${1:-}" == /usr/bin/python3 && "${2:-}" == "${LOCALAI_FAKE_BACKUP_HELPER:?}" ]]; then
  case "${3:-}" in
    restore-marker-check)
      [[ ! -e "${LOCALAI_FAKE_TRANSACTION_MARKER:?}" ]] || exit 1
      exit 0
      ;;
    restore-marker-create)
      [[ ! -e "${LOCALAI_FAKE_TRANSACTION_MARKER:?}" ]] || exit 1
      printf 'synthetic pending transaction\n' >"$LOCALAI_FAKE_TRANSACTION_MARKER"
      printf 'restore-marker-create\n' >>"${LOCALAI_FAKE_LOG:?}"
      exit 0
      ;;
    restore-marker-clear)
      printf 'restore-marker-clear\n' >>"${LOCALAI_FAKE_LOG:?}"
      rm -f -- "${LOCALAI_FAKE_TRANSACTION_MARKER:?}"
      exit 0
      ;;
    sync-destinations)
      printf 'sync-destinations\n' >>"${LOCALAI_FAKE_LOG:?}"
      exit 0
      ;;
    sync-staging-snapshot)
      printf 'sync-staging-snapshot\n' >>"${LOCALAI_FAKE_LOG:?}"
      exit 0
      ;;
    rollback-new)
      [[ "${LOCALAI_FAKE_FAIL_ROLLBACK:-false}" != true ]] || exit 1
      ;;
  esac
fi
if [[ "${1:-}" == /usr/bin/getent && "${2:-}" == passwd ]]; then
  printf '%s:x:1001:1001::%s/service-home:/bin/bash\n' "$3" "${LOCALAI_FAKE_STATE_DIR:?}"
  exit 0
fi
if [[ "${1:-}" == /usr/bin/systemd-run ]]; then
  shift
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --user|--wait|--pipe|--collect|--quiet) shift ;;
      --machine=*|--setenv=*) shift ;;
      --) shift; break ;;
      *) exit 96 ;;
    esac
  done
  if [[ "${1:-}" == /usr/bin/podman && "${2:-}" == info ]]; then
    printf '%s/nonexistent-graphroot\n' "${LOCALAI_FAKE_STATE_DIR:?}"
    exit 0
  fi
  if [[ "${1:-}" == /usr/bin/podman && "${2:-}" == unshare ]]; then
    printf '0:1001:1;1:100000:65536\n0:1001:1;1:200000:65536\n'
    exit 0
  fi
  if [[ "${1:-}" == /usr/bin/podman && "${2:-}" == ps ]]; then
    exit 0
  fi
  exit 96
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
if [[ -e "${LOCALAI_FAKE_TRANSACTION_MARKER:-}" && ( " $* " == *" start localai.service "* ||
      " $* " == *" start localai-tls-compose.service "* ||
      " $* " == *" start localai-tls-forward.socket "* ||
      " $* " == *" start localai-tls-forward.service "* ) ]]; then
  exit 1
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
if [[ " $* " == *" show --property=ExecStartPre --value "* ]]; then
  if [[ "${LOCALAI_FAKE_MISSING_RESTORE_GUARD:-}" != backend && " $* " == *" localai.service "* ]]; then
    case "${LOCALAI_FAKE_RESTORE_GUARD_FORM:-exact}" in
      wrapped)
        printf '{ path=/bin/sh ; argv[]=/bin/sh -c echo /usr/bin/test ! -e /var/lib/.localaictl-backup-restore.pending ; ignore_errors=no ; start_time=[n/a] ; }\n' ;;
      ignored)
        printf '{ path=/usr/bin/test ; argv[]=/usr/bin/test ! -e /var/lib/.localaictl-backup-restore.pending ; ignore_errors=yes ; start_time=[n/a] ; }\n' ;;
      extra-argv)
        printf '{ path=/usr/bin/test ; argv[]=/usr/bin/test ! -e /var/lib/.localaictl-backup-restore.pending extra ; ignore_errors=no ; start_time=[n/a] ; }\n' ;;
      *)
        printf '{ path=/usr/bin/test ; argv[]=/usr/bin/test ! -e /var/lib/.localaictl-backup-restore.pending ; ignore_errors=no ; start_time=[n/a] ; }\n' ;;
    esac
  fi
  if [[ "${LOCALAI_FAKE_MISSING_RESTORE_GUARD:-}" != tls && " $* " == *" localai-tls-compose.service "* ]]; then
    printf '{ path=/usr/bin/test ; argv[]=/usr/bin/test ! -e /var/lib/.localaictl-backup-restore.pending ; ignore_errors=no ; start_time=[n/a] ; }\n'
  fi
fi
if [[ " $* " == *" show --property=Conditions --value "* ]]; then
  if [[ "${LOCALAI_FAKE_MISSING_RESTORE_GUARD:-}" != socket && " $* " == *" localai-tls-forward.socket "* ]]; then
    printf '{ type=ConditionPathExists ; trigger=false ; negate=true ; parameter=/var/lib/.localaictl-backup-restore.pending ; state=untested ; }\n'
  fi
  if [[ "${LOCALAI_FAKE_MISSING_RESTORE_GUARD:-}" != forward-service && " $* " == *" localai-tls-forward.service "* ]]; then
    printf '{ type=ConditionPathExists ; trigger=false ; negate=true ; parameter=/var/lib/.localaictl-backup-restore.pending ; state=untested ; }\n'
  fi
fi
if [[ " $* " == *" show localai.service --property=DropInPaths --value "* ]]; then
  printf '\n'
fi
if [[ " $* " == *" show localai.service --property=Environment --value "* ]]; then
  printf 'LOCALAI_AUTH=true LOCALAI_AUTH_DATABASE_URL=%s/database.db LOCALAI_ADDRESS=127.0.0.1:11455\n' "${LOCALAI_FAKE_DATA_PATH:-/var/lib/localai/data}"
fi
if [[ " $* " == *" stop localai.service "* ]]; then printf 'inactive\n' >"${LOCALAI_FAKE_STATE_DIR}/backend"; fi
if [[ "${LOCALAI_FAKE_FAIL_BACKEND:-false}" == true && " $* " == *" start localai.service "* ]]; then exit 1; fi
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
  localai|localai.backup-test-1) printf '1001\n' ;;
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
export LOCALAI_FAKE_TRANSACTION_MARKER="$tmp_dir/service-state/restore.pending"
export LOCALAI_FAKE_BACKUP_HELPER="$repo_root/lib/backup_archive.py"
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

export LOCALAI_FAKE_FAIL_BACKEND=true
: >"$tmp_dir/commands"
if "$repo_root/bin/localaictl" start; then
  printf 'start ignored a backend start failure\n' >&2
  exit 1
fi
unset LOCALAI_FAKE_FAIL_BACKEND
if rg -q 'start localai-tls-compose.service|start localai-tls-forward.socket' "$tmp_dir/commands"; then
  printf 'start activated TLS after a backend start failure\n' >&2
  exit 1
fi

(
  # shellcheck disable=SC1090,SC2030,SC2031,SC2034
  source <(sed -n '/^restore_backup_service_state() {$/,/^}/p' "$repo_root/bin/localaictl")
  # shellcheck disable=SC2034
  backup_was_active=(backend tls socket)
  # shellcheck disable=SC2034
  RESTORE_STACK_POLICY_SET=1
  # shellcheck disable=SC2030
  RESTORE_TLS_ENABLED=false
  # shellcheck disable=SC2030
  RESTORE_TLS_PUBLIC_SOCKET=true
  # shellcheck disable=SC2329
  backup_unit_action() { printf '%s\n' "$1" >>"$tmp_dir/reconciled-units"; }
  # shellcheck disable=SC2329
  log() { :; }
  : >"$tmp_dir/reconciled-units"
  restore_backup_service_state
  [[ "$(<"$tmp_dir/reconciled-units")" == backend ]]

  RESTORE_TLS_ENABLED=true
  RESTORE_TLS_PUBLIC_SOCKET=false
  : >"$tmp_dir/reconciled-units"
  restore_backup_service_state
  [[ "$(<"$tmp_dir/reconciled-units")" == $'backend\ntls' ]]

  RESTORE_TLS_PUBLIC_SOCKET=true
  : >"$tmp_dir/reconciled-units"
  # shellcheck disable=SC2329
  backup_unit_action() {
    printf '%s\n' "$1" >>"$tmp_dir/reconciled-units"
    [[ "$1" != backend ]]
  }
  if restore_backup_service_state; then
    printf 'restore restarted dependent services after backend start failed\n' >&2
    exit 1
  fi
  [[ "$(<"$tmp_dir/reconciled-units")" == backend ]]
)

(
  # shellcheck disable=SC1090,SC2030,SC2031,SC2034
  source <(sed -n '/^load_restore_stack_policy() {$/,/^}/p' "$repo_root/bin/localaictl")
  # shellcheck disable=SC2034
  config_lib="$repo_root/lib/config.sh"
  # shellcheck disable=SC2034
  legacy_config_file="$repo_root/localai/localai.lock"
  restored_config="$tmp_dir/restore-policy.conf"
  printf 'LOCALAI_TLS_ENABLED=false\nLOCALAI_TLS_PUBLIC_SOCKET=false\n' >"$restored_config"
  export LOCALAI_TLS_ENABLED=true LOCALAI_TLS_PUBLIC_SOCKET=true
  load_restore_stack_policy "$restored_config"
  # shellcheck disable=SC2031
  [[ "$RESTORE_TLS_ENABLED" == false && "$RESTORE_TLS_PUBLIC_SOCKET" == false ]]
)

export LOCALAI_FAKE_FAIL_TLS=true
if "$repo_root/bin/localaictl" start; then
  printf 'expected partial TLS start failure\n' >&2
  exit 1
fi
rg -q '"action":"start".*"result":"failure"' "$tmp_dir/audit/$(date +%Y-%m-%d).jsonl"
if rg -q 'start localai-tls-forward.socket' "$tmp_dir/commands"; then
  printf 'start activated the public socket after TLS service startup failed\n' >&2
  exit 1
fi

# Backup and restore exercise real tar metadata operations against disposable
# paths while service-manager commands remain mocked.
unset LOCALAI_FAKE_FAIL_TLS
mkdir -p "$tmp_dir/backup-state" "$tmp_dir/backup-tls" "$tmp_dir/backup-cache" "$tmp_dir/backup-config-dir"
mkdir -p "$tmp_dir/backup-state/.config/systemd/user"
printf '# Managed by LocalAI secureblue installer.\nDescription=LocalAI OpenAI-compatible API and web UI container\n' >"$tmp_dir/backup-state/.config/systemd/user/localai.service"
chmod 0644 "$tmp_dir/backup-state/.config/systemd/user/localai.service"
mkdir -p "$tmp_dir/backup-tls/compose"
printf 'services:\n  caddy:\n    image: trusted-test-baseline\n' >"$tmp_dir/backup-tls/compose/localai-tls-compose.yaml"
chmod 0755 "$tmp_dir/backup-tls/compose"
chmod 0644 "$tmp_dir/backup-tls/compose/localai-tls-compose.yaml"
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
custom_user_archive="$tmp_dir/custom-service-user.tar.gz"
: >"$LOCALAI_FAKE_LOG"
if ! LOCALAI_SERVICE_USER=localai.backup-test-1 "$repo_root/bin/localaictl" backup "$custom_user_archive" >/dev/null 2>&1; then
  printf 'backup failed for a supported custom service-account name\n' >&2
  exit 1
fi
rg -q -- '--machine=localai\.backup-test-1@\.host' "$LOCALAI_FAKE_LOG"
rg -q 'getent passwd localai\.backup-test-1' "$LOCALAI_FAKE_LOG"
rg -q '^ExecStartPre=/usr/bin/test ! -e /var/lib/\.localaictl-backup-restore\.pending$' \
  "$repo_root/secureblue-localai-install/localai.service.in"
rg -q '^ExecStartPre=/usr/bin/test ! -e /var/lib/\.localaictl-backup-restore\.pending$' \
  "$repo_root/localai-podman-compose/localai-tls-compose.service.in"
rg -q '^ConditionPathExists=!/var/lib/\.localaictl-backup-restore\.pending$' \
  "$repo_root/localai-podman-compose/localai-tls-forward.socket.in"
rg -q '^ConditionPathExists=!/var/lib/\.localaictl-backup-restore\.pending$' \
  "$repo_root/localai-podman-compose/localai-tls-forward.service.in"
archive_listing="$tmp_dir/backup-members"
/usr/bin/tar -tzf "$backup_archive" >"$archive_listing"
# A configured-off public socket can still be active from an earlier setup.
# Inventory and stop/restart it only when both root-owned LocalAI unit files
# prove that the socket is managed by this installer.
printf '# Managed by LocalAI secureblue TLS installer.\n' >"$tmp_dir/systemd/localai-tls-forward.socket"
printf '# Managed by LocalAI secureblue TLS installer.\n' >"$tmp_dir/systemd/localai-tls-forward.service"
printf 'active\n' >"$tmp_dir/service-state/socket"
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
root_config_archive="$tmp_dir/root-config-generated-backup.tar.gz"
python3 - "$backup_archive" "$root_config_archive" "$tmp_dir/backup-config-dir/localai.conf" <<'PY'
import os, sys, tarfile
source_path, destination_path, config_path = sys.argv[1:]
with tarfile.open(source_path, 'r:gz') as source, tarfile.open(destination_path, 'w:gz', format=tarfile.PAX_FORMAT) as target:
    for info in source:
        data = source.extractfile(info) if info.isfile() else None
        if info.name == config_path.lstrip('/'):
            info.uid = info.gid = 0
            info.mode = 0o644
        target.addfile(info, data)
os.chmod(destination_path, 0o600)
PY
python3 "$repo_root/lib/backup_archive.py" validate "$root_config_archive" "$tmp_dir/backup-config-dir/localai.conf" \
  "$tmp_dir/backup-state" "$tmp_dir/backup-tls" "$tmp_dir/backup-cache" || {
  printf 'archive validator rejected a generated root-owned 0644 configuration backup\n' >&2
  exit 1
}
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
PYTHONDONTWRITEBYTECODE=1 python3 - "$repo_root/lib" <<'PY'
import builtins
import contextlib
import io
import pwd
import grp
import os
import stat
import sys
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, sys.argv[1])
import backup_archive as helper

with tempfile.TemporaryDirectory(prefix="source-growth-test-", dir=os.environ["TMPDIR"]) as parent:
    source = os.path.join(parent, "source.tar.gz")
    destination = os.path.join(parent, "staged.tar.gz")
    with open(source, "wb") as stream:
        stream.write(b"synthetic archive source")
    real_read = os.read
    did_grow = {"value": False}
    def grow_source_after_read(fd, size):
        chunk = real_read(fd, size)
        if not did_grow["value"]:
            did_grow["value"] = True
            with open(source, "ab") as stream:
                stream.write(b"concurrent growth")
        return chunk
    with patch.object(helper.os, "read", side_effect=grow_source_after_read):
        try:
            helper.copy_source(source, destination)
        except SystemExit:
            pass
        else:
            raise SystemExit("restore source staging accepted a concurrently grown archive")
    if os.path.exists(destination):
        raise SystemExit("restore source staging retained a partial copy after source growth")

with tempfile.TemporaryDirectory(prefix="label-metadata-test-", dir=os.environ["TMPDIR"]) as parent:
    staged = os.path.join(parent, "staged")
    installed = os.path.join(parent, "installed")
    os.mkdir(staged, 0o700)
    os.mkdir(installed, 0o700)
    def xattrs(path, **kwargs):
        return ["security.selinux"]
    def labels(path, name, **kwargs):
        return b"staging_t" if os.fspath(path) == staged else b"container_file_t"
    with patch.object(helper.os, "listxattr", side_effect=xattrs), \
         patch.object(helper.os, "getxattr", side_effect=labels):
        if not helper.directory_metadata_not_weaker(staged, installed):
            raise SystemExit("destination policy relabel was rejected as a changed ancestor xattr")
    def custom_xattrs(path, **kwargs):
        return ["user.localai-ancestor-test"]
    def custom_values(path, name, **kwargs):
        return b"staged" if os.fspath(path) == staged else b"installed"
    with patch.object(helper.os, "listxattr", side_effect=custom_xattrs), \
         patch.object(helper.os, "getxattr", side_effect=custom_values):
        if helper.directory_metadata_not_weaker(staged, installed):
            raise SystemExit("directory metadata validation ignored a non-SELinux xattr difference")

uid_map = "0:1001:1;1:200000:65536"
gid_map = "0:1001:1;1:300000:65536"
rootless_path = "/var/lib/localai/.local/share/containers/storage"
if not helper.valid_service_account_name("localai.backup-test-1"):
    raise SystemExit("valid service-account punctuation was rejected")
for invalid_service_account in ("root", "0", "bad/name", "ümlaut"):
    if helper.valid_service_account_name(invalid_service_account):
        raise SystemExit("invalid service-account name was accepted")
original_open = builtins.open

def fixture_open(filename, *args, **kwargs):
    if filename == "/etc/subuid":
        return io.StringIO("localai:200000:65536\n")
    if filename == "/etc/subgid":
        return io.StringIO("localai:300000:65536\n")
    return original_open(filename, *args, **kwargs)

with tempfile.TemporaryDirectory(prefix="owner-policy-test-", dir=os.environ["TMPDIR"]) as parent:
    def check_owner_policy(subuid, subgid, passwd, group):
        files = {
            "/etc/subuid": subuid,
            "/etc/subgid": subgid,
            "/etc/passwd": passwd,
            "/etc/group": group,
        }
        def policy_open(filename, *args, **kwargs):
            if os.fspath(filename) in files:
                return io.StringIO(files[os.fspath(filename)])
            return original_open(filename, *args, **kwargs)
        with patch.object(pwd, "getpwuid", return_value=SimpleNamespace(pw_name="svc")), \
             patch.object(builtins, "open", side_effect=policy_open):
            return helper.owner_id_policy(parent)

    safe_policy = check_owner_policy(
        "svc:200000:100\nother:300000:100\n",
        "svc:400000:100\nother:500000:100\n",
        "root:x:0:0:root:/root:/bin/bash\nsvc:x:1001:1001:svc:/nonexistent:/sbin/nologin\n",
        "root:x:0:\nsvc:x:1001:\n",
    )
    if (200000, 200100) not in safe_policy[3] or (400000, 400100) not in safe_policy[4]:
        raise SystemExit("valid persistent-root subordinate ID ranges were not accepted")
    root_metadata = os.stat(parent)
    numeric_policy = check_owner_policy(
        f"{root_metadata.st_uid}:210000:100\nother:310000:100\n",
        f"{root_metadata.st_uid}:410000:100\nother:510000:100\n",
        "root:x:0:0:root:/root:/bin/bash\nsvc:x:1001:1001:svc:/nonexistent:/sbin/nologin\n",
        "root:x:0:\nsvc:x:1001:\n",
    )
    if (210000, 210100) not in numeric_policy[3] or (410000, 410100) not in numeric_policy[4]:
        raise SystemExit("numeric-keyed persistent-root subordinate ID ranges were rejected")
    numeric_map_files = {
        "/etc/subuid": f"{root_metadata.st_uid}:200000:65536\n",
        "/etc/subgid": f"{root_metadata.st_uid}:300000:65536\n",
        "/etc/passwd": "root:x:0:0:root:/root:/bin/bash\nsvc:x:1001:1001:svc:/nonexistent:/sbin/nologin\n",
        "/etc/group": "root:x:0:\nsvc:x:1001:\n",
    }
    def numeric_map_open(filename, *args, **kwargs):
        if os.fspath(filename) in numeric_map_files:
            return io.StringIO(numeric_map_files[os.fspath(filename)])
        return original_open(filename, *args, **kwargs)
    with patch.object(pwd, "getpwnam", return_value=SimpleNamespace(pw_uid=root_metadata.st_uid)), \
         patch.object(builtins, "open", side_effect=numeric_map_open):
        helper.validate_id_map(f"0:1001:1;1:200000:65536", 1001, "svc", "/etc/subuid")
        helper.validate_id_map(f"0:1001:1;1:300000:65536", 1001, "svc", "/etc/subgid")
    unsafe_policies = (
        ("svc:4294967290:10\n", "svc:400000:100\n", "root:x:0:0:root:/root:/bin/bash\nsvc:x:1001:1001:svc:/nonexistent:/sbin/nologin\n", "root:x:0:\nsvc:x:1001:\n"),
        ("svc:200000:100\nother:200050:100\n", "svc:400000:100\n", "root:x:0:0:root:/root:/bin/bash\nsvc:x:1001:1001:svc:/nonexistent:/sbin/nologin\n", "root:x:0:\nsvc:x:1001:\n"),
        ("svc:200000:100\n", "svc:400000:100\nother:400050:100\n", "root:x:0:0:root:/root:/bin/bash\nsvc:x:1001:1001:svc:/nonexistent:/sbin/nologin\n", "root:x:0:\nsvc:x:1001:\n"),
        ("svc:200000:100\n", "svc:400000:100\n", "intruder:x:200050:1002::/:/sbin/nologin\n", "root:x:0:\nsvc:x:1001:\n"),
        ("svc:200000:100\n", "svc:400000:100\n", "root:x:0:0:root:/root:/bin/bash\nsvc:x:1001:1001:svc:/nonexistent:/sbin/nologin\n", "intruder:x:400050:\n"),
    )
    for policy in unsafe_policies:
        with contextlib.redirect_stderr(io.StringIO()):
            try:
                check_owner_policy(*policy)
            except SystemExit:
                continue
        raise SystemExit("persistent-root subordinate ID collision or overlap was accepted")

def make_archive(entries):
    output = io.BytesIO()
    with helper.tarfile.open(fileobj=output, mode="w:") as archive:
        for info, payload in entries:
            info.uid = info.uid or 0
            info.gid = info.gid or 0
            if payload is None:
                archive.addfile(info)
            else:
                info.size = len(payload)
                archive.addfile(info, io.BytesIO(payload))
    return output.getvalue()

def directory(name, mode=0o700, uid=0, gid=0):
    info = helper.tarfile.TarInfo(name)
    info.type = helper.tarfile.DIRTYPE
    info.mode, info.uid, info.gid = mode, uid, gid
    return info, None

def regular(name, payload=b"fixture", mode=0o600, uid=1, gid=1, pax=None):
    info = helper.tarfile.TarInfo(name)
    info.mode, info.uid, info.gid = mode, uid, gid
    info.pax_headers = pax or {}
    return info, payload

def validate(raw, uid_value=uid_map, gid_value=gid_map):
    with patch.object(pwd, "getpwnam", return_value=SimpleNamespace(pw_uid=1001)), \
         patch.object(grp, "getgrnam", return_value=SimpleNamespace(gr_gid=1001)), \
         patch.object(builtins, "open", side_effect=fixture_open), \
         patch.object(helper.os.path, "lexists", return_value=False):
        return helper.validate_graphroot_tar(io.BytesIO(raw), rootless_path, uid_map, gid_map,
                                             uid_value, gid_value, "localai")

def rejects(raw, uid_value=uid_map, gid_value=gid_map):
    with contextlib.redirect_stderr(io.StringIO()):
        try:
            validate(raw, uid_value, gid_value)
        except SystemExit:
            return
    raise SystemExit("unsafe nested graphroot archive was accepted")

valid = make_archive([
    directory("storage/"),
    regular("storage/overlay/layer/diff/tool", b"synthetic", mode=0o2750),
])
if "storage/overlay/layer/diff/tool" not in validate(valid):
    raise SystemExit("nested graphroot archive member was not validated")
for unsafe_root_mode in (0o000, 0o500, 0o1700, 0o2700):
    rejects(make_archive([directory("storage/", mode=unsafe_root_mode)]))
rejects(valid, "0:1002:1;1:200000:65536")
rejects(make_archive([directory("storage/"), regular("storage/../outside")]))
rejects(make_archive([directory("storage/"), regular("storage/cap", pax={"SCHILY.xattr.security.capability": "synthetic"})]))
fifo = helper.tarfile.TarInfo("storage/fifo")
fifo.type = helper.tarfile.FIFOTYPE
fifo.uid = fifo.gid = 1
rejects(make_archive([directory("storage/"), (fifo, None)]))
hardlink = helper.tarfile.TarInfo("storage/hardlink")
hardlink.type = helper.tarfile.LNKTYPE
hardlink.linkname = "storage/overlay/layer/diff/tool"
hardlink.uid, hardlink.gid, hardlink.mode = 1, 1, 0o2750
rejects(make_archive([directory("storage/"), regular("storage/overlay/layer/diff/tool", mode=0o2750), (hardlink, None)]))
rejects(valid + b"unvalidated")

oversized_pax = helper.tarfile.TarInfo("PaxHeaders/member")
oversized_pax.type = helper.tarfile.XHDTYPE
oversized_pax.size = helper.MAX_PAX_HEADER_BYTES + 1
with contextlib.redirect_stderr(io.StringIO()):
    try:
        helper.preflight_tar_stream(io.BytesIO(oversized_pax.tobuf()))
    except SystemExit:
        pass
    else:
        raise SystemExit("archive preflight accepted an oversized pax header")

empty_member = helper.tarfile.TarInfo("member").tobuf()
class RepeatedHeaders:
    def __init__(self):
        self.count = 0
    def seek(self, _offset):
        self.count = 0
    def read(self, size):
        if size != 512 or self.count >= helper.MAX_ARCHIVE_MEMBERS + 1:
            return b""
        self.count += 1
        return empty_member

with contextlib.redirect_stderr(io.StringIO()):
    try:
        helper.preflight_tar_stream(RepeatedHeaders())
    except SystemExit:
        pass
    else:
        raise SystemExit("archive preflight accepted too many members")

long_path = b"x" * (helper.MAX_MEMBER_NAME_BYTES + 1)
record = f"{len(long_path) + 20} path=".encode() + long_path + b"\n"
while True:
    record = f"{len(record)} path=".encode() + long_path + b"\n"
    declared = int(record.split(b" ", 1)[0])
    if declared == len(record):
        break
long_pax = helper.tarfile.TarInfo("PaxHeaders/member")
long_pax.type = helper.tarfile.XHDTYPE
long_pax.size = len(record)
long_raw = long_pax.tobuf() + record + b"\0" * ((-len(record)) % 512)
with contextlib.redirect_stderr(io.StringIO()):
    try:
        helper.preflight_tar_stream(io.BytesIO(long_raw))
    except SystemExit:
        pass
    else:
        raise SystemExit("archive preflight accepted an overlong pax path")

with tempfile.TemporaryDirectory(prefix="restore-marker-test-", dir=os.environ["TMPDIR"]) as parent:
    marker_path = os.path.join(parent, "restore.pending")
    graphroot = os.path.join(parent, "storage")
    rollback = graphroot + ".rollback"
    helper.create_transaction_marker(graphroot, rollback, "1:42", marker_path)
    marker = helper.read_transaction_marker(marker_path)
    if marker["graphroot"] != graphroot or marker["rollback_path"] != rollback or marker["graphroot_inode"] != "1:42":
        raise SystemExit("durable restore marker did not preserve the recovery identity")
    if os.stat(marker_path).st_mode & 0o777 != 0o644:
        raise SystemExit("durable restore marker is not readable by the service startup guard")
    with contextlib.redirect_stderr(io.StringIO()):
        try:
            helper.check_transaction_marker(marker_path)
        except SystemExit:
            pass
        else:
            raise SystemExit("restore marker did not block a subsequent operation")
    helper.clear_transaction_marker(marker_path)
    helper.check_transaction_marker(marker_path)
    sentinel = os.path.join(parent, "sentinel")
    with open(sentinel, "w", encoding="ascii") as stream:
        stream.write("synthetic")
    os.symlink(sentinel, marker_path)
    with contextlib.redirect_stderr(io.StringIO()):
        try:
            helper.check_transaction_marker(marker_path)
        except SystemExit:
            pass
        else:
            raise SystemExit("restore marker followed a symbolic link")
    os.unlink(marker_path)
    if open(sentinel, encoding="ascii").read() != "synthetic":
        raise SystemExit("restore marker cleanup followed a symbolic link")

with tempfile.TemporaryDirectory(prefix="graphroot-home-mode-", dir=os.environ["TMPDIR"]) as parent:
    service_home = os.path.join(parent, "service-home")
    private = os.path.join(service_home, "private")
    graphroot = os.path.join(private, "storage")
    os.mkdir(service_home, 0o750)
    os.mkdir(private, 0o700)
    os.mkdir(graphroot, 0o700)
    uid, gid = os.getuid(), os.getgid()
    real_lstat = os.lstat

    def ancestry_lstat(path, *args, **kwargs):
        path = os.fspath(path)
        if path in {service_home, private, graphroot}:
            return real_lstat(path, *args, **kwargs)
        fields = list(real_lstat("/", *args, **kwargs))
        fields[0] = stat.S_IFDIR | 0o755
        fields[4], fields[5] = 0, 0
        return os.stat_result(fields)

    with patch.object(helper.os, "lstat", side_effect=ancestry_lstat), \
         patch.object(helper.os, "listxattr", return_value=[]), \
         patch.object(helper, "graphroot_mounts", return_value=[]):
        helper.validate_graphroot_path(graphroot, service_home, uid, gid, [service_home])
        os.chmod(private, 0o750)
        public_error = io.StringIO()
        with patch.dict(os.environ, {"LOCALAI_ACCEPTANCE_DIAGNOSTIC": "1"}), \
             contextlib.redirect_stderr(public_error):
            try:
                helper.validate_graphroot_path(graphroot, service_home, uid, gid, [service_home])
            except SystemExit:
                pass
            else:
                raise SystemExit("graphroot accepted a public descendant directory")
        if "service-home ancestry is publicly traversable" not in public_error.getvalue():
            raise SystemExit("graphroot public descendant refusal lacked its fixed category")
        if "diagnostic-graphroot-ancestor-mode:depth-1:mode-0750" not in public_error.getvalue():
            raise SystemExit("graphroot mode diagnostic exposed an unexpected category or value")
        os.chmod(private, 0o700)
        def wrong_owner_lstat(path, *args, **kwargs):
            if os.fspath(path) == private:
                fields = list(real_lstat(path, *args, **kwargs))
                fields[4] = uid + 1
                return os.stat_result(fields)
            return ancestry_lstat(path, *args, **kwargs)
        owner_error = io.StringIO()
        with patch.object(helper.os, "lstat", side_effect=wrong_owner_lstat), \
             contextlib.redirect_stderr(owner_error):
            try:
                helper.validate_graphroot_path(graphroot, service_home, uid, gid, [service_home])
            except SystemExit:
                pass
            else:
                raise SystemExit("graphroot accepted an ancestor with unexpected ownership")
        if "service-home ancestry has unexpected ownership" not in owner_error.getvalue():
            raise SystemExit("graphroot owner refusal lacked its fixed category")
        os.chmod(private, 0o2700)
        special_error = io.StringIO()
        with contextlib.redirect_stderr(special_error):
            try:
                helper.validate_graphroot_path(graphroot, service_home, uid, gid, [service_home])
            except SystemExit:
                pass
            else:
                raise SystemExit("graphroot accepted special permission bits on an ancestor")
        if "service-home ancestry has special permission bits" not in special_error.getvalue():
            raise SystemExit("graphroot special-bit refusal lacked its fixed category")
        os.chmod(private, 0o700)
        os.chmod(graphroot, 0o500)
        with contextlib.redirect_stderr(io.StringIO()):
            try:
                helper.validate_graphroot_path(graphroot, service_home, uid, gid, [service_home])
            except SystemExit:
                pass
            else:
                raise SystemExit("graphroot accepted a non-writable root directory")
        os.chmod(graphroot, 0o2700)
        with contextlib.redirect_stderr(io.StringIO()):
            try:
                helper.validate_graphroot_path(graphroot, service_home, uid, gid, [service_home])
            except SystemExit:
                pass
            else:
                raise SystemExit("graphroot accepted special root mode bits")

with tempfile.TemporaryDirectory(prefix="graphroot-rename-", dir=os.environ["TMPDIR"]) as parent:
    with patch.object(builtins, "open", return_value=io.StringIO("pos:\t0\nflags:\t0100000\n")), \
         contextlib.redirect_stderr(io.StringIO()) as missing_mount_id:
        try:
            helper.fd_mount_id(123)
        except SystemExit:
            pass
        else:
            raise SystemExit("rootless graphroot removal accepted missing fd mount identity")
    if "cannot verify rootless graphroot mount identity" not in missing_mount_id.getvalue():
        raise SystemExit("missing mount identity refusal lacked its fixed category")

    source = os.path.join(parent, "store")
    destination = os.path.join(parent, "store.rollback")
    os.mkdir(source, 0o700)
    with open(os.path.join(source, "payload"), "w", encoding="ascii") as stream:
        stream.write("synthetic")
    helper.rename_graphroot_noreplace(source, destination)
    if os.path.exists(source) or not os.path.isfile(os.path.join(destination, "payload")):
        raise SystemExit("rootless graphroot no-replace rename did not preserve the tree")
    device, inode = os.stat(destination).st_dev, os.stat(destination).st_ino
    with contextlib.redirect_stderr(io.StringIO()):
        try:
            helper.remove_graphroot_nofollow(destination, device, inode + 1)
        except SystemExit:
            pass
        else:
            raise SystemExit("rootless graphroot removal accepted a mismatched inode")
    sentinel = os.path.join(parent, "outside")
    with open(sentinel, "w", encoding="ascii") as stream:
        stream.write("keep")
    os.symlink(sentinel, os.path.join(destination, "outside-link"))
    mount_like = os.path.join(destination, "mount-like")
    os.mkdir(mount_like)
    mount_sentinel = os.path.join(mount_like, "preserve-me")
    with open(mount_sentinel, "w", encoding="ascii") as stream:
        stream.write("synthetic mount payload")
    mount_inode = os.stat(mount_like).st_ino
    real_fd_mount_id = helper.fd_mount_id

    def synthetic_mount_id(fd):
        actual = real_fd_mount_id(fd)
        return actual + 1 if os.fstat(fd).st_ino == mount_inode else actual

    with patch.object(helper, "graphroot_mounts", return_value=[]), \
         patch.object(helper, "fd_mount_id", side_effect=synthetic_mount_id), \
         contextlib.redirect_stderr(io.StringIO()) as mount_error:
        try:
            helper.remove_graphroot_nofollow(destination, device, inode)
        except SystemExit:
            pass
        else:
            raise SystemExit("rootless graphroot removal crossed a changed mount ID")
    if "mount changed during safe removal" not in mount_error.getvalue():
        raise SystemExit("rootless graphroot mount refusal lacked its fixed category")
    if not os.path.isfile(mount_sentinel):
        raise SystemExit("rootless graphroot removal deleted data below a changed mount ID")
    helper.remove_graphroot_nofollow(destination, device, inode)
    if not os.path.isfile(sentinel):
        raise SystemExit("rootless graphroot cleanup followed a symbolic link")
    os.unlink(sentinel)

    race_source = os.path.join(parent, "race-store")
    race_old = os.path.join(parent, "race-store.original")
    race_destination = os.path.join(parent, "race-store.rollback")
    os.mkdir(race_source, 0o700)
    expected = os.stat(race_source)
    os.rename(race_source, race_old)
    os.mkdir(race_source, 0o700)
    with contextlib.redirect_stderr(io.StringIO()):
        try:
            helper.rename_graphroot_noreplace(race_source, race_destination, (expected.st_dev, expected.st_ino))
        except SystemExit:
            pass
        else:
            raise SystemExit("rootless graphroot rename accepted a replaced source inode")
    if os.path.exists(race_destination) or not os.path.isdir(race_source) or not os.path.isdir(race_old):
        raise SystemExit("rootless graphroot replacement race changed either tree")

with tempfile.TemporaryDirectory(prefix="graphroot-outer-", dir=os.environ["TMPDIR"]) as outer:
    os.chmod(outer, 0o700)
    graphroot = os.path.join(outer, "storage")
    os.mkdir(graphroot, 0o700)
    uid, gid = os.getuid(), os.getgid()
    context = {"graphroot": graphroot, "uid_map": f"0:{uid}:1;1:200000:65536",
               "gid_map": f"0:{gid}:1;1:300000:65536", "service_home": outer,
               "service_uid": uid, "service_gid": gid, "service_user": "localai"}
    config = os.path.join(outer, "localai.conf")
    with open(config, "w", encoding="ascii") as stream:
        stream.write("synthetic config\n")
    os.chmod(config, 0o600)
    archive_path = os.path.join(outer, "backup.tar.gz")
    metadata_text = ("format=2\nbackend_image=synthetic\nbackend_digest=sha256:synthetic\n"
                     f"graphroot={graphroot}\nuid_map={context['uid_map']}\ngid_map={context['gid_map']}\n")
    outer_members = [(helper.tarfile.TarInfo("metadata"), metadata_text.encode())]
    outer_members[0][0].mode = 0o600
    outer_members += [(helper.tarfile.TarInfo(outer.lstrip("/") + "/"), None),
                      (helper.tarfile.TarInfo(config.lstrip("/")), b"synthetic config\n")]
    outer_members[-1][0].mode = 0o600
    outer_members[-1][0].uid, outer_members[-1][0].gid = uid, gid
    ordinary_name = outer.lstrip("/") + "/ordinary.data"
    ordinary = helper.tarfile.TarInfo(ordinary_name)
    ordinary.mode, ordinary.uid, ordinary.gid = 0o600, uid, gid
    outer_members.append((ordinary, b"synthetic payload\n"))
    sensitive_link = helper.tarfile.TarInfo(outer.lstrip("/") + "/ca.key")
    sensitive_link.type = helper.tarfile.LNKTYPE
    sensitive_link.linkname = ordinary_name
    sensitive_link.mode, sensitive_link.uid, sensitive_link.gid = 0o600, uid, gid
    outer_members.append((sensitive_link, None))
    nested_info = helper.tarfile.TarInfo(helper.ROOTLESS_GRAPHROOT_MEMBER)
    nested_info.mode, nested_info.uid, nested_info.gid = 0o600, 0, 0
    outer_members.append((nested_info, valid))
    outer_raw = io.BytesIO()
    with helper.tarfile.open(fileobj=outer_raw, mode="w:gz") as bundle:
        for info, payload in outer_members:
            if payload is not None:
                info.size = len(payload)
                bundle.addfile(info, io.BytesIO(payload))
            else:
                if not (info.issym() or info.islnk()):
                    info.type = helper.tarfile.DIRTYPE
                    info.mode = 0o700
                    info.uid, info.gid = uid, gid
                bundle.addfile(info)
    with open(archive_path, "wb") as stream:
        stream.write(outer_raw.getvalue())
    actual_lstat = os.lstat
    def fixture_lstat(path, *args, **kwargs):
        path = os.fspath(path)
        info = actual_lstat(path, *args, **kwargs)
        if path in {outer, graphroot}:
            return info
        fields = list(info)
        fields[0] = stat.S_IFDIR | 0o755
        fields[4], fields[5] = 0, 0
        return os.stat_result(fields)
    with patch.object(pwd, "getpwnam", return_value=SimpleNamespace(pw_uid=uid)), \
         patch.object(grp, "getgrnam", return_value=SimpleNamespace(gr_gid=gid)), \
         patch.object(builtins, "open", side_effect=fixture_open), \
         patch.object(helper.os, "lstat", side_effect=fixture_lstat), \
         patch.object(helper.os, "listxattr", return_value=[]), \
         patch.object(helper.os, "getxattr", side_effect=OSError(helper.errno.ENODATA, "synthetic label absent")), \
         patch.object(helper, "graphroot_mounts", return_value=[]):
        names = helper.validate_archive(archive_path, config, [outer], require_root_config=False,
                                        rootless_context=context)
        if helper.ROOTLESS_GRAPHROOT_MEMBER in names:
            raise SystemExit("nested graphroot tar was included in ordinary restore paths")
        helper.space_check(archive_path, outer, destinations=[outer], rootless_context=context)

        sync_calls = []
        def synthetic_syncfs(descriptor):
            sync_calls.append(os.fstat(descriptor).st_dev)
            return 0
        with patch.object(helper.ctypes, "CDLL", return_value=SimpleNamespace(syncfs=synthetic_syncfs)):
            helper.sync_restore_filesystems(archive_path, config, [outer], rootless_context=context)
        if not sync_calls:
            raise SystemExit("restore durability check did not flush any destination filesystem")
        with patch.object(helper.ctypes, "CDLL", return_value=SimpleNamespace(syncfs=lambda _fd: -1)), \
             contextlib.redirect_stderr(io.StringIO()):
            try:
                helper.sync_restore_filesystems(archive_path, config, [outer], rootless_context=context)
            except SystemExit:
                pass
            else:
                raise SystemExit("restore durability check ignored a filesystem flush failure")

        snapshot = os.path.join(outer, "rollback.tar")
        with open(snapshot, "wb") as stream:
            stream.write(b"synthetic rollback")
        fsync_calls = []
        original_fsync = helper.os.fsync
        def capture_fsync(descriptor):
            fsync_calls.append(descriptor)
            return original_fsync(descriptor)
        with patch.object(helper.os, "fsync", side_effect=capture_fsync):
            helper.sync_staging_snapshot(snapshot, outer)
        if len(fsync_calls) < 2:
            raise SystemExit("rollback snapshot durability did not flush both file and staging directory")

        def archive_with_config_change(changed_path, mutate, destination_name):
            with helper.tarfile.open(archive_path, "r:gz") as source, \
                 helper.tarfile.open(destination_name, "w:gz") as destination:
                for member in source:
                    if member.name.rstrip("/") == changed_path.rstrip("/"):
                        mutate(member)
                    destination.addfile(member, source.extractfile(member) if member.isfile() else None)

        for case, mutate in (
            ("foreign-owner", lambda member: setattr(member, "uid", uid + 10000)),
            ("foreign-group", lambda member: setattr(member, "gid", gid + 10000)),
            ("sensitive-hardlink-mode", lambda member: setattr(member, "mode", 0o640)),
            ("unsafe-acl", lambda member: member.pax_headers.update({"SCHILY.acl.access": "other::rw-"})),
            ("unsafe-selinux", lambda member: member.pax_headers.update({"SCHILY.xattr.security.selinux": "untrusted_t:s0"})),
        ):
            changed_archive = os.path.join(outer, f"{case}.tar.gz")
            changed_path = outer.lstrip("/") + "/ca.key" if case == "sensitive-hardlink-mode" else config.lstrip("/")
            archive_with_config_change(changed_path, mutate, changed_archive)
            with contextlib.redirect_stderr(io.StringIO()):
                try:
                    helper.validate_archive(changed_archive, config, [outer], require_root_config=False,
                                            rootless_context=context)
                except SystemExit:
                    pass
                else:
                    raise SystemExit(f"outer archive accepted {case}")

        for unsafe_root_mode in (0o000, 0o500):
            changed_archive = os.path.join(outer, f"root-mode-{unsafe_root_mode:o}.tar.gz")
            archive_with_config_change(outer.lstrip("/"), lambda member, mode=unsafe_root_mode: setattr(member, "mode", mode), changed_archive)
            with contextlib.redirect_stderr(io.StringIO()):
                try:
                    helper.validate_archive(changed_archive, config, [outer], require_root_config=False,
                                            rootless_context=context)
                except SystemExit:
                    pass
                else:
                    raise SystemExit("outer archive accepted a non-writable persistent root")

        bad_context = dict(context, graphroot=os.path.join(outer, "other-storage"))
        with contextlib.redirect_stderr(io.StringIO()):
            try:
                helper.validate_archive(archive_path, config, [outer], require_root_config=False,
                                        rootless_context=bad_context)
            except SystemExit:
                pass
            else:
                raise SystemExit("nested graphroot archive accepted a different live destination")
PY
python3 - "$repo_root/lib" "$tmp_dir" <<'PY'
import io
import os
import sys
import tarfile
import tempfile
from contextlib import redirect_stderr
from unittest.mock import patch

sys.path.insert(0, sys.argv[1])
import backup_archive as helper

with tempfile.TemporaryDirectory(prefix="trusted-compose-test-", dir=sys.argv[2]) as work:
    live_root = os.path.join(work, "tls-compose")
    os.mkdir(live_root, 0o700)
    live_file = os.path.join(live_root, "localai-tls-compose.yaml")
    with open(live_file, "wb") as stream:
        stream.write(b"services:\n  caddy:\n    image: trusted\n")
    os.chmod(live_file, 0o644)
    archive_path = os.path.join(work, "backup.tar.gz")
    staged_root = os.path.join(work, "stage")
    os.mkdir(staged_root, 0o700)

    def write_bundle(payload):
        with tarfile.open(archive_path, "w:gz") as archive:
            root = tarfile.TarInfo(live_root.lstrip("/") + "/")
            root.type, root.mode = tarfile.DIRTYPE, 0o700
            root.uid, root.gid = os.getuid(), os.getgid()
            archive.addfile(root)
            member = tarfile.TarInfo(live_file.lstrip("/"))
            member.size, member.mode = len(payload), 0o644
            member.uid, member.gid = os.getuid(), os.getgid()
            archive.addfile(member, io.BytesIO(payload))
        os.makedirs(os.path.join(staged_root, live_root.lstrip("/")), mode=0o700, exist_ok=True)
        with open(os.path.join(staged_root, live_file.lstrip("/")), "wb") as stream:
            stream.write(payload)
        os.chmod(os.path.join(staged_root, live_file.lstrip("/")), 0o644)

    trusted = b"services:\n  caddy:\n    image: trusted\n"
    write_bundle(trusted)
    helper.trusted_compose_tree(archive_path, staged_root, live_root)
    malicious = b"services:\n  attacker:\n    image: untrusted\n"
    write_bundle(malicious)
    with redirect_stderr(io.StringIO()):
        try:
            helper.trusted_compose_tree(archive_path, staged_root, live_root)
        except SystemExit:
            pass
        else:
            raise SystemExit("restore accepted a changed TLS Compose workload")
PY
for missing_restore_guard in backend tls socket forward-service; do
  stop_count_before="$(rg -c ' stop localai.service$' "$tmp_dir/commands" || true)"
  if LOCALAI_FAKE_MISSING_RESTORE_GUARD="$missing_restore_guard" "$repo_root/bin/localaictl" restore --yes "$backup_archive" >/dev/null 2>&1; then
    printf 'restore proceeded with an old effective %s unit lacking the durable marker guard\n' "$missing_restore_guard" >&2
    exit 1
  fi
  stop_count_after="$(rg -c ' stop localai.service$' "$tmp_dir/commands" || true)"
  [[ "$stop_count_before" == "$stop_count_after" ]]
done
for restore_guard_form in wrapped ignored extra-argv; do
  stop_count_before="$(rg -c ' stop localai.service$' "$tmp_dir/commands" || true)"
  if LOCALAI_FAKE_RESTORE_GUARD_FORM="$restore_guard_form" "$repo_root/bin/localaictl" restore --yes "$backup_archive" >/dev/null 2>&1; then
    printf 'restore accepted a %s effective backend marker guard\n' "$restore_guard_form" >&2
    exit 1
  fi
  stop_count_after="$(rg -c ' stop localai.service$' "$tmp_dir/commands" || true)"
  [[ "$stop_count_before" == "$stop_count_after" ]]
done
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
snapshot_sync_line="$(rg -n '^sync-staging-snapshot$' "$tmp_dir/commands" | head -n1 | cut -d: -f1)"
marker_create_line="$(rg -n '^restore-marker-create$' "$tmp_dir/commands" | head -n1 | cut -d: -f1)"
destination_sync_line="$(rg -n '^sync-destinations$' "$tmp_dir/commands" | tail -n1 | cut -d: -f1)"
marker_clear_line="$(rg -n '^restore-marker-clear$' "$tmp_dir/commands" | tail -n1 | cut -d: -f1)"
[[ -n "$snapshot_sync_line" && -n "$marker_create_line" && -n "$destination_sync_line" && -n "$marker_clear_line" ]]
(( snapshot_sync_line < marker_create_line && destination_sync_line < marker_clear_line ))
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
rg -q "^restorecon -F -R -- $tmp_dir/backup-state$" "$tmp_dir/commands"
rg -q "^restorecon -F -R -- $tmp_dir/backup-tls$" "$tmp_dir/commands"
rg -q "^restorecon -F -R -- $tmp_dir/backup-cache$" "$tmp_dir/commands"
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
rollback_sync_line="$(rg -n '^sync-destinations$' "$tmp_dir/commands" | tail -n1 | cut -d: -f1)"
rollback_marker_clear_line="$(rg -n '^restore-marker-clear$' "$tmp_dir/commands" | tail -n1 | cut -d: -f1)"
[[ -n "$rollback_sync_line" && -n "$rollback_marker_clear_line" ]]
(( rollback_sync_line < rollback_marker_clear_line ))
if [[ "$(<"$LOCALAI_FAKE_STATE_DIR/backend")" != active ]]; then
  cat "$tmp_dir/rollback-output" "$tmp_dir/rollback-error" >&2
  cat "$tmp_dir/commands" >&2
  exit 1
fi

printf 'before incomplete rollback\n' >"$tmp_dir/backup-state/database.db"
export LOCALAI_FAKE_FAIL_LABEL=true
export LOCALAI_FAKE_FAIL_ROLLBACK=true
if "$repo_root/bin/localaictl" restore --yes "$backup_archive" >"$tmp_dir/incomplete-output" 2>"$tmp_dir/incomplete-error"; then
  printf 'restore ignored an incomplete rollback\n' >&2
  exit 1
fi
unset LOCALAI_FAKE_FAIL_LABEL LOCALAI_FAKE_FAIL_ROLLBACK
[[ -e "$LOCALAI_FAKE_TRANSACTION_MARKER" ]]
if [[ "$(<"$LOCALAI_FAKE_STATE_DIR/backend")" == active ]]; then
  printf 'services restarted with an unresolved restore marker\n' >&2
  exit 1
fi
: >"$tmp_dir/commands"
if "$repo_root/bin/localaictl" start >/dev/null 2>&1; then
  printf 'controller start ignored an unresolved restore marker\n' >&2
  exit 1
fi
if rg -q 'start localai.service|start localai-tls-compose.service|start localai-tls-forward.socket' "$tmp_dir/commands"; then
  printf 'controller issued start commands with an unresolved restore marker\n' >&2
  exit 1
fi
if "$LOCALAI_SYSTEMCTL_BIN" --user --machine=localai@.host start localai.service >/dev/null 2>&1; then
  printf 'service startup ignored the durable restore marker\n' >&2
  exit 1
fi
if "$LOCALAI_SYSTEMCTL_BIN" --user --machine=localai-tls@.host start localai-tls-compose.service >/dev/null 2>&1 ||
   "$LOCALAI_SYSTEMCTL_BIN" start localai-tls-forward.socket >/dev/null 2>&1 ||
   "$LOCALAI_SYSTEMCTL_BIN" start localai-tls-forward.service >/dev/null 2>&1; then
  printf 'TLS activation ignored the durable restore marker\n' >&2
  exit 1
fi
: >"$tmp_dir/commands"
if "$repo_root/bin/localaictl" backup "$tmp_dir/blocked-backup.tar.gz" >/dev/null 2>&1; then
  printf 'backup proceeded with an unresolved restore marker\n' >&2
  exit 1
fi
if rg -q ' stop localai.service$' "$tmp_dir/commands"; then
  printf 'backup stopped services before checking the unresolved marker\n' >&2
  exit 1
fi
rm -f -- "$LOCALAI_FAKE_TRANSACTION_MARKER"
printf 'active\n' >"$LOCALAI_FAKE_STATE_DIR/backend"
printf 'active\n' >"$LOCALAI_FAKE_STATE_DIR/tls"
printf 'active\n' >"$LOCALAI_FAKE_STATE_DIR/socket"

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
