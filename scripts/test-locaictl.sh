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
      printf '%s\n' "${LOCALAI_FAKE_BACKEND_STATE:-active}"
      ;;
    *" is-active localai-tls-compose.service "*) printf '%s\n' "${LOCALAI_FAKE_TLS_STATE:-active}" ;;
    *" is-active localai-tls-forward.socket "*) printf '%s\n' "${LOCALAI_FAKE_SOCKET_STATE:-active}" ;;
    *) printf 'inactive\n' ;;
  esac
fi
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

printf 'localaictl tests passed\n'
