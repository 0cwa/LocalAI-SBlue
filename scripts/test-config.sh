#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_REPO_ROOT="$repo_root"
source "$repo_root/scripts/test-support.sh"
test_sanitize_localai_environment
# shellcheck source=../lib/config.sh
source "$repo_root/lib/config.sh"

tmp_dir="$(test_mktemp_dir config-test)"
trap 'rm -rf "$tmp_dir"' EXIT

expect_failure() {
  local file="$1"
  if (localai_config_load "$file") 2>/dev/null; then
    printf 'expected config failure: %s\n' "$file" >&2
    exit 1
  fi
}

cat >"$tmp_dir/duplicate.conf" <<'EOF'
LOCALAI_BIND_PORT=11455
LOCALAI_BIND_PORT=11456
EOF
expect_failure "$tmp_dir/duplicate.conf"

printf 'LOCALAI_BIND_HOST=$(touch %s)\n' "$tmp_dir/config-injection" >"$tmp_dir/injection.conf"
expect_failure "$tmp_dir/injection.conf"
[[ ! -e "$tmp_dir/config-injection" ]]

cat >"$tmp_dir/empty-tls-host.conf" <<'EOF'
LOCALAI_TLS_ENABLED=true
LOCALAI_TLS_PUBLIC_SOCKET=true
LOCALAI_TLS_PUBLIC_HOST=
EOF
expect_failure "$tmp_dir/empty-tls-host.conf"

cat >"$tmp_dir/bad-port.conf" <<'EOF'
LOCALAI_BIND_PORT=70000
EOF
expect_failure "$tmp_dir/bad-port.conf"

cat >"$tmp_dir/bad-path.conf" <<'EOF'
LOCALAI_MODELS_PATH=relative/models
EOF
expect_failure "$tmp_dir/bad-path.conf"

cat >"$tmp_dir/systemd-specifier.conf" <<'EOF'
LOCALAI_LOG_LEVEL=%n
EOF
expect_failure "$tmp_dir/systemd-specifier.conf"

# Environment overrides use the same strict grammar as file values, before
# callers can render them into systemd Environment= lines.
if env LOCALAI_LOG_LEVEL='%n' bash -c '
  source "$1"
  localai_config_load "$2"
' _ "$repo_root/lib/config.sh" "$repo_root/config/localai.conf.example" 2>/dev/null; then
  printf 'configuration accepted a systemd specifier from the environment\n' >&2
  exit 1
fi
if env LOCALAI_LOG_LEVEL='%n' bash -c '
  source "$1"
  localai_config_load_compat "$2" "$3"
' _ "$repo_root/lib/config.sh" "$repo_root/config/localai.conf.example" "$repo_root/localai/localai.lock" 2>/dev/null; then
  printf 'compatibility config loader accepted a systemd specifier from the environment\n' >&2
  exit 1
fi

cat >"$tmp_dir/root-user.conf" <<'EOF'
LOCALAI_SERVICE_USER=root
EOF
expect_failure "$tmp_dir/root-user.conf"

cat >"$tmp_dir/bad-compose-name.conf" <<'EOF'
LOCALAI_TLS_COMPOSE_FILE_NAME=../localai.yaml
EOF
expect_failure "$tmp_dir/bad-compose-name.conf"

cat >"$tmp_dir/good.conf" <<'EOF'
LOCALAI_BIND_HOST=127.0.0.3
LOCALAI_BIND_PORT=11456
LOCALAI_TLS_ENABLED=false
EOF
cat >"$tmp_dir/second.conf" <<'EOF'
LOCALAI_BIND_HOST=127.0.0.4
EOF

# The initial process environment is captured before defaults can overwrite
# exported variables. The snapshot remains stable across repeated loads; use
# localai_config_override for a same-process change after loading.
(
  export LOCALAI_BIND_HOST=127.0.0.6 LOCALAI_TLS_BIND_HOST=localhost LOCALAI_TLS_BIND_PORT=8443
  localai_config_load "$tmp_dir/good.conf"
  [[ "$LOCALAI_BIND_HOST" == 127.0.0.6 ]]
  [[ "$LOCALAI_TLS_PUBLIC_HOST" == localhost ]]
  [[ "$LOCALAI_TLS_PUBLIC_PORT" == 8443 ]]
  unset LOCALAI_BIND_HOST
  localai_config_load "$tmp_dir/second.conf"
  [[ "$LOCALAI_BIND_HOST" == 127.0.0.6 ]]
  [[ "$LOCALAI_TLS_PUBLIC_HOST" == localhost ]]
  [[ "$LOCALAI_TLS_PUBLIC_PORT" == 8443 ]]
  localai_config_override LOCALAI_BIND_HOST 127.0.0.7
  [[ "$LOCALAI_BIND_HOST" == 127.0.0.7 ]]
)

localai_config_load "$repo_root/config/localai.conf.example"
[[ "$LOCALAI_BIND_HOST" == 127.0.0.1 ]]
[[ "$LOCALAI_AUTH" == true ]]
[[ "$LOCALAI_REGISTRATION_MODE" == approval ]]
[[ "$LOCALAI_TLS_CONFIG_DIR" == /var/lib/localai-tls/caddy ]]

localai_config_load "$tmp_dir/good.conf"
[[ "$LOCALAI_BIND_HOST" == 127.0.0.3 ]]
[[ "$LOCALAI_BIND_PORT" == 11456 ]]
[[ "$LOCALAI_TLS_ENABLED" == false ]]
localai_config_load "$tmp_dir/second.conf"
[[ "$LOCALAI_BIND_HOST" == 127.0.0.4 ]]
localai_config_override LOCALAI_BIND_HOST 127.0.0.5
[[ "$LOCALAI_BIND_HOST" == 127.0.0.5 ]]
[[ -n "${LOCALAI_CONFIG_SEEN[LOCALAI_BIND_HOST]+x}" ]]
localai_config_load "$tmp_dir/second.conf"
[[ "$LOCALAI_BIND_HOST" == 127.0.0.4 ]]

[[ "$LOCALAI_AUTH" == true ]]
[[ "$LOCALAI_REGISTRATION_MODE" == approval ]]
[[ "$LOCALAI_TLS_PUBLIC_HOST" == "" ]]
[[ "$LOCALAI_MODELS_PATH" == /var/lib/localai/models ]]
[[ "$LOCALAI_BACKENDS_PATH" == /var/lib/localai/backends ]]
[[ "$LOCALAI_TLS_CONFIG_DIR" == /var/lib/localai-tls/caddy ]]
[[ "$LOCALAI_TLS_CACHE_DIR" == /var/lib/localai-tls/cache ]]
[[ "$LOCALAI_TLS_CERT_DIR" == /var/lib/localai-tls/certs ]]
[[ "$LOCALAI_TLS_COMPOSE_DIR" == /var/lib/localai-tls/.local/share/localai-tls-compose ]]

cat >"$tmp_dir/custom-tls-state.conf" <<'EOF'
LOCALAI_TLS_STATE_DIR=/srv/localai/tls
EOF
localai_config_load "$tmp_dir/custom-tls-state.conf"
[[ "$LOCALAI_TLS_CONFIG_DIR" == /srv/localai/tls/caddy ]]
[[ "$LOCALAI_TLS_CACHE_DIR" == /srv/localai/tls/cache ]]
[[ "$LOCALAI_TLS_CERT_DIR" == /srv/localai/tls/certs ]]

localai_config_load_compat "$tmp_dir/no-canonical.conf" "$repo_root/localai/localai.lock"
[[ "$LOCALAI_BIND_HOST" == 127.0.0.1 ]]
[[ "$LOCALAI_BIND_PORT" == 11455 ]]
[[ "$LOCALAI_IMAGE_REF" == docker.io/localai/localai:latest-gpu-hipblas ]]
[[ "$LOCALAI_REGISTRATION_MODE" == approval ]]

printf 'config tests passed\n'
