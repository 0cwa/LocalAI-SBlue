#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/config.sh
# The sourced helper is checked independently.
# shellcheck disable=SC1091
source "$repo_root/lib/config.sh"
TEST_REPO_ROOT="$repo_root"
source "$repo_root/scripts/test-support.sh"
test_sanitize_localai_environment
source "$repo_root/lib/tls_compose_render.sh"

tmp_dir="$(test_mktemp_dir render-config-test)"
trap 'rm -rf "$tmp_dir"' EXIT

cat >"$tmp_dir/config" <<'EOF'
LOCALAI_BIND_HOST=127.0.0.1
LOCALAI_BIND_PORT=11455
LOCALAI_TLS_ENABLED=true
LOCALAI_TLS_PUBLIC_SOCKET=true
LOCALAI_TLS_PUBLIC_HOST=localai.example.test
LOCALAI_TLS_PUBLIC_PORT=443
LOCALAI_TLS_INTERNAL_HOST=127.0.0.1
LOCALAI_TLS_INTERNAL_PORT=8443
EOF
localai_config_load "$tmp_dir/config"

# Static certificate migration selects only a key matching the existing leaf
# certificate. Auto mode keeps the internal CA when no static material exists;
# incomplete, malformed, and ambiguous static inputs fail closed.
if command -v openssl >/dev/null 2>&1; then
  static_cert_dir="$tmp_dir/static-certs"
  mkdir -p "$static_cert_dir"
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$static_cert_dir/legacy-leaf.key" \
    -out "$static_cert_dir/fullchain.crt" -days 1 \
    -subj '/CN=localai.example.test' >/dev/null 2>&1
  resolved_key="$(localai_tls_resolve_static_key \
    "$static_cert_dir" "$static_cert_dir/fullchain.crt" localai '' 0)"
  [[ "$resolved_key" == "$static_cert_dir/legacy-leaf.key" ]]

# Static certificate paths must be canonical files inside existing Caddy mounts
# and readable by the TLS service account before Caddyfile installation.
# The source path is selected or generated at runtime.
# shellcheck disable=SC1090
source <(sed -n '/^tls_compose_mount_dirs() {$/,/^}/p' \
  "$repo_root/localai-podman-compose/install.sh")
# The source path is selected or generated at runtime.
# shellcheck disable=SC1090
source <(sed -n '/^localai_tls_preflight_static_paths() {$/,/^}/p' \
  "$repo_root/localai-podman-compose/install.sh")
tls_state_dir="$tmp_dir/tls-state"
tls_config_dir="$tls_state_dir/caddy-config"
tls_storage_dir="$tls_state_dir/caddy-storage"
tls_cache_dir="$tls_state_dir/cache"
# The value is consumed by a sourced or dynamically extracted helper.
# shellcheck disable=SC2034
tls_certs_dir="$static_cert_dir"
tls_app_home_dir="$tls_state_dir/app-home"
# The value is consumed by a sourced or dynamically extracted helper.
# shellcheck disable=SC2034
tls_image_ref=docker.io/library/caddy:2-alpine
run_pull=1
mkdir -p "$tls_config_dir" "$tls_storage_dir" "$tls_state_dir/data" \
  "$tls_state_dir/config" "$tls_cache_dir" "$tls_app_home_dir"
readable_check_paths=()
mock_tls_unreadable_path=""
mock_tls_image_available=1
mock_tls_image_checks=0
mock_tls_container_readable=1
mock_tls_container_checks=0
run_as_tls() {
  if [[ "$1" == /usr/bin/test && "$2" == -r ]]; then
    readable_check_paths+=("$3")
    [[ "$3" != "$mock_tls_unreadable_path" && -r "$3" ]]
  elif [[ "$1" == /usr/bin/podman && "$2" == image && "$3" == exists ]]; then
    mock_tls_image_checks=$((mock_tls_image_checks + 1))
    [[ "$mock_tls_image_available" == 1 ]]
  elif [[ "$1" == /usr/bin/podman && "$2" == run ]]; then
    mock_tls_container_checks=$((mock_tls_container_checks + 1))
    [[ "$mock_tls_container_readable" == 1 ]]
  else
    return 1
  fi
}
localai_tls_preflight_static_paths \
  "$static_cert_dir/fullchain.crt" "$static_cert_dir/legacy-leaf.key"
# The value is assigned by a dynamically extracted helper.
# shellcheck disable=SC2154
[[ "$tls_preflight_fullchain" == "$(/usr/bin/realpath -e "$static_cert_dir/fullchain.crt")" ]]
# The value is assigned by a dynamically extracted helper.
# shellcheck disable=SC2154
[[ "$tls_preflight_leaf_key" == "$(/usr/bin/realpath -e "$static_cert_dir/legacy-leaf.key")" ]]
[[ "${#readable_check_paths[@]}" == 2 ]]
[[ "$mock_tls_container_checks" == 1 ]]

mock_tls_container_readable=0
if localai_tls_preflight_static_paths \
  "$static_cert_dir/fullchain.crt" "$static_cert_dir/legacy-leaf.key"; then
  printf 'expected Caddy container unreadability to fail preflight\n' >&2
  exit 1
else
  [[ "$?" == 2 ]]
fi
mock_tls_container_readable=1

outside_cert_dir="$tmp_dir/outside-certs"
mkdir -p "$outside_cert_dir"
cp -- "$static_cert_dir/fullchain.crt" "$outside_cert_dir/fullchain.crt"
readable_check_paths=()
if localai_tls_preflight_static_paths \
  "$outside_cert_dir/fullchain.crt" "$static_cert_dir/legacy-leaf.key"; then
  printf 'expected static files outside the Caddy mounts to fail preflight\n' >&2
  exit 1
else
  [[ "$?" == 1 ]]
  [[ "${#readable_check_paths[@]}" == 0 ]]
fi

mock_tls_unreadable_path="$static_cert_dir/legacy-leaf.key"
if localai_tls_preflight_static_paths \
  "$static_cert_dir/fullchain.crt" "$static_cert_dir/legacy-leaf.key"; then
  printf 'expected TLS service unreadability to fail preflight\n' >&2
  exit 1
else
  [[ "$?" == 2 ]]
fi
mock_tls_unreadable_path=""
run_pull=0
mock_tls_image_available=0
if localai_tls_preflight_static_paths \
  "$static_cert_dir/fullchain.crt" "$static_cert_dir/legacy-leaf.key"; then
  printf 'expected unavailable image with --no-pull to fail preflight\n' >&2
  exit 1
else
  [[ "$?" == 3 ]]
fi
mock_tls_image_available=1
localai_tls_preflight_static_paths \
  "$static_cert_dir/fullchain.crt" "$static_cert_dir/legacy-leaf.key"
[[ "$mock_tls_image_checks" == 2 ]]
# The value is consumed by a sourced or dynamically extracted helper.
# shellcheck disable=SC2034
run_pull=1

  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
    -out "$static_cert_dir/unrelated.key" >/dev/null 2>&1
  resolved_key="$(localai_tls_resolve_static_key \
    "$static_cert_dir" "$static_cert_dir/fullchain.crt" localai '' 0)"
  [[ "$resolved_key" == "$static_cert_dir/legacy-leaf.key" ]]

  cp -- "$static_cert_dir/legacy-leaf.key" "$static_cert_dir/duplicate.key"
  if localai_tls_resolve_static_key \
    "$static_cert_dir" "$static_cert_dir/fullchain.crt" localai '' 0 >/dev/null; then
    printf 'expected ambiguous static keys to fail closed\n' >&2
    exit 1
  else
    [[ "$?" == 4 ]]
  fi

  rm -- "$static_cert_dir/duplicate.key"
  printf 'not a private key\n' >"$static_cert_dir/invalid.key"
  if localai_tls_resolve_static_key \
    "$static_cert_dir" "$static_cert_dir/fullchain.crt" localai '' 0 >/dev/null; then
    printf 'expected invalid key input to fail closed\n' >&2
    exit 1
  else
    [[ "$?" == 2 ]]
  fi

  rm -- "$static_cert_dir/invalid.key"
  explicit_key="$(localai_tls_resolve_static_key \
    "$static_cert_dir" "$static_cert_dir/fullchain.crt" localai \
    "$static_cert_dir/legacy-leaf.key" 0)"
  [[ "$explicit_key" == "$static_cert_dir/legacy-leaf.key" ]]

  if localai_tls_resolve_static_key \
    "$static_cert_dir" "$static_cert_dir/fullchain.crt" localai \
    "$static_cert_dir/unrelated.key" 0 >/dev/null; then
    printf 'expected mismatched explicit key to fail closed\n' >&2
    exit 1
  else
    [[ "$?" == 2 ]]
  fi

  no_material_dir="$tmp_dir/no-static-material"
  mkdir -p "$no_material_dir"
  if resolved_key="$(localai_tls_resolve_static_key \
    "$no_material_dir" "$no_material_dir/fullchain.crt" localai '' 0)"; then
    printf 'expected no-static-material result to request normal fallback\n' >&2
    exit 1
  else
    [[ "$?" == 1 ]]
    [[ "$resolved_key" == "$no_material_dir/localai.key" ]]
  fi
  # The source path is selected or generated at runtime.
  # shellcheck disable=SC1090
  source <(sed -n '/^tls_chain_enabled() {$/,/^}/p' \
    "$repo_root/localai-podman-compose/install.sh")
  if tls_chain_enabled auto "$no_material_dir/fullchain.crt" \
    "$no_material_dir/localai.key"; then
    printf 'expected auto mode to use the internal CA without static files\n' >&2
    exit 1
  fi

  touch "$no_material_dir/legacy.key"
  if localai_tls_resolve_static_key \
    "$no_material_dir" "$no_material_dir/fullchain.crt" localai '' 0 >/dev/null; then
    printf 'expected incomplete static material to fail closed\n' >&2
    exit 1
  else
    [[ "$?" == 2 ]]
  fi

  if localai_tls_resolve_static_key \
    "$no_material_dir" "$no_material_dir/missing-fullchain.crt" localai '' 1 >/dev/null; then
    printf 'expected explicit missing fullchain to fail closed\n' >&2
    exit 1
  else
    [[ "$?" == 2 ]]
  fi
else
  printf 'openssl unavailable; static certificate migration checks skipped\n' >&2
fi

[[ "$LOCALAI_BIND_HOST:$LOCALAI_BIND_PORT" == 127.0.0.1:11455 ]]
[[ "$LOCALAI_TLS_PUBLIC_HOST:$LOCALAI_TLS_PUBLIC_PORT" == localai.example.test:443 ]]
[[ "$LOCALAI_TLS_INTERNAL_HOST:$LOCALAI_TLS_INTERNAL_PORT" == 127.0.0.1:8443 ]]

# Static template checks protect the boot/readiness contract without invoking
# systemd, Podman, SELinux, or a host installer in CI.
restore_marker_guard='ExecStartPre=/usr/bin/test ! -e /var/lib/.localaictl-backup-restore.pending'
for service_template in \
  "$repo_root/secureblue-localai-install/localai.service.in" \
  "$repo_root/localai-podman-compose/localai-tls-compose.service.in"; do
  rg -q -x -F "$restore_marker_guard" "$service_template"
done
rg -q '^Wants=network-online.target$' "$repo_root/localai-podman-compose/localai-tls-compose.service.in"
rg -q '^After=network-online.target default.target$' "$repo_root/localai-podman-compose/localai-tls-compose.service.in"
rg -q '^FreeBind=true$' "$repo_root/localai-podman-compose/localai-tls-forward.socket.in"
rg -q '^Restart=on-failure$' "$repo_root/localai-podman-compose/localai-tls-forward.service.in"
rg -q '^StartLimitBurst=5$' "$repo_root/localai-podman-compose/localai-tls-forward.service.in"
rg -q 'podman compose' "$repo_root/localai-podman-compose/localai-tls-compose.service.in"
if rg -q -- '--remove-orphans' "$repo_root/localai-podman-compose/localai-tls-compose.service.in"; then
  printf 'Unexpected match in negative assertion\n' >&2
  exit 1
fi
if rg -q '^Restart=' "$repo_root/localai-podman-compose/localai-tls-compose.service.in"; then
  printf 'Unexpected match in negative assertion\n' >&2
  exit 1
fi
if rg -q '^RestartSec=' "$repo_root/localai-podman-compose/localai-tls-compose.service.in"; then
  printf 'Unexpected match in negative assertion\n' >&2
  exit 1
fi
rg -q 'SERVICE_BIND_HOST=\"\$LOCALAI_BIND_HOST\"' "$repo_root/secureblue-localai-install/install.sh"
rg -q 'tls_backend_host=.*LOCALAI_BIND_HOST' "$repo_root/localai-podman-compose/install.sh"

# Exercise the same pure renderer used by the TLS installer. This writes only
# the rendered YAML into task scratch and does not call Podman or modify units.
rendered="$tmp_dir/localai-tls-compose.yaml"
state_dir="$tmp_dir/tls-state"
app_home="$state_dir/app-home"
storage_dir="$state_dir/caddy-storage"
data_home="$state_dir/data"
config_home="$state_dir/config"
cache_dir="$state_dir/cache"
config_dir="$state_dir/caddy-config"
cert_dir="$state_dir/certs"
caddyfile_path="$config_dir/Caddyfile"
localai_tls_render_compose_template \
  "$repo_root/localai-podman-compose/localai-tls-compose.yaml.in" \
  docker.io/library/caddy:2-alpine localai-tls "$state_dir" "$app_home" \
  "$storage_dir" "$data_home" "$config_home" "$cache_dir" "$config_dir" \
  "$cert_dir" "$caddyfile_path" >"$rendered"

for mount_dir in "$config_dir" "$storage_dir" "$data_home" "$config_home" "$cache_dir" "$cert_dir" "$app_home"; do
  rg -q -F "source: '$mount_dir'" "$rendered"
  rg -q -F "target: '$mount_dir'" "$rendered"
done
[[ "$(rg -c 'type: bind' "$rendered")" == 7 ]]
if rg -q -F "source: '$state_dir'" "$rendered"; then
  printf 'Unexpected match in negative assertion\n' >&2
  exit 1
fi
if rg -q -F "target: '$state_dir'" "$rendered"; then
  printf 'Unexpected match in negative assertion\n' >&2
  exit 1
fi
rg -q -F "HOME: '$app_home'" "$rendered"
rg -q -F "XDG_DATA_HOME: '$data_home'" "$rendered"
rg -q -F "XDG_CONFIG_HOME: '$config_home'" "$rendered"
rg -q -F "XDG_CACHE_HOME: '$cache_dir'" "$rendered"
if python3 -c 'import yaml' >/dev/null 2>&1; then
  python3 - "$rendered" "$config_dir" "$storage_dir" "$data_home" "$config_home" "$cache_dir" "$cert_dir" "$app_home" <<'PY'
import pathlib
import sys
import yaml

document = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())
volumes = document["services"]["localai-tls"]["volumes"]
expected = set(sys.argv[2:])
assert len(volumes) == len(expected), volumes
assert {entry["source"] for entry in volumes} == expected, volumes
assert all(entry["source"] == entry["target"] for entry in volumes), volumes
assert document["services"]["localai-tls"]["environment"]["HOME"] == sys.argv[8]
PY
fi

# Render the same service unit template used by the installer and ensure
# shutdown targets only the services defined in that compose file.
compose_file="$tmp_dir/localai-tls-compose.yaml"
rendered_unit="$tmp_dir/localai-tls-compose.service"
localai_tls_render_compose_service_template \
  "$repo_root/localai-podman-compose/localai-tls-compose.service.in" \
  955 "$state_dir" "$compose_file" localai-tls-test >"$rendered_unit"
rg -q -x -F "ExecStop=/usr/bin/podman compose -p localai-tls-test -f $compose_file down" "$rendered_unit"
if rg -q -- '--remove-orphans' "$rendered_unit"; then
  printf 'Unexpected match in negative assertion\n' >&2
  exit 1
fi

# Exercise the actual uninstaller function with a captured argv. This is a
# fixture-only call: no Podman, systemd, or host services are invoked.
mkdir -p "$tmp_dir/tls-compose"
touch "$tmp_dir/tls-compose/localai-tls-compose.yaml"
tls_compose_dir="$tmp_dir/tls-compose"
tls_compose_file_name=localai-tls-compose.yaml
# The value is consumed by a sourced or dynamically extracted helper.
# shellcheck disable=SC2034
tls_compose_project_name=localai-tls-test
# The value is consumed by a sourced or dynamically extracted helper.
# shellcheck disable=SC2034
tls_container_name=localai-tls
# The value is consumed by a sourced or dynamically extracted helper.
# shellcheck disable=SC2034
tls_uid=955
# The source path is selected or generated at runtime.
# shellcheck disable=SC1090
source <(sed -n '/^remove_container() {$/,/^}/p' "$repo_root/localai-podman-compose/uninstall.sh")
log() { :; }
captured_argv=()
run_tls_unit() { captured_argv=("$@"); }
remove_container
expected_argv=(/usr/bin/podman compose -p localai-tls-test -f "$tls_compose_dir/$tls_compose_file_name" down)
[[ "${#captured_argv[@]}" -eq "${#expected_argv[@]}" ]]
for index in "${!expected_argv[@]}"; do
  [[ "${captured_argv[$index]}" == "${expected_argv[$index]}" ]]
done

printf 'render/readiness checks passed\n'
