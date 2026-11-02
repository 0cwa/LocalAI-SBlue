#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
asset_dir="${LOCALAI_ASSET_DIR:-$repo_root/localai}"
lock_file="$asset_dir/localai.lock"
policy_file="$asset_dir/localai-tls-containers-policy.json"
config_lib="${LOCALAI_CONFIG_LIB:-$repo_root/lib/config.sh}"
# The source path is selected or generated at runtime.
# shellcheck disable=SC1090
source "$config_lib"
safety_lib="${LOCALAI_INSTALLER_SAFETY_LIB:-$repo_root/lib/installer_safety.sh}"
# The source path is selected or generated at runtime.
# shellcheck disable=SC1090
source "$safety_lib"
compose_render_lib="${LOCALAI_TLS_COMPOSE_RENDER_LIB:-$repo_root/lib/tls_compose_render.sh}"
# The source path is selected or generated at runtime.
# shellcheck disable=SC1090
source "$compose_render_lib"
canonical_config="$LOCALAI_INSTALLER_CONFIG_DEST"
requested_config="${LOCALAI_CONFIG_FILE:-}"
original_args=("$@")
trap localai_installer_cleanup_temps EXIT

localai_service_user="${LOCALAI_SERVICE_USER:-localai}"
localai_state_dir="${LOCALAI_STATE_DIR:-/var/lib/localai}"

tls_user="${LOCALAI_TLS_USER:-localai-tls}"
tls_state_dir="${LOCALAI_TLS_STATE_DIR:-/var/lib/localai-tls}"
tls_app_home_dir="$tls_state_dir/app-home"
tls_storage_dir="$tls_state_dir/caddy"
tls_config_dir="${LOCALAI_TLS_CONFIG_DIR:-$tls_state_dir/caddy}"
tls_cache_dir="${LOCALAI_TLS_CACHE_DIR:-$tls_state_dir/cache}"
tls_certs_dir="${LOCALAI_TLS_CERT_DIR:-$tls_state_dir/certs}"
tls_compose_dir="${LOCALAI_TLS_COMPOSE_DIR:-$tls_state_dir/.local/share/localai-tls-compose}"
tls_compose_file_name="${LOCALAI_TLS_COMPOSE_FILE_NAME:-localai-tls-compose.yaml}"
tls_service_name="${LOCALAI_TLS_SERVICE_NAME:-localai-tls-compose.service}"
legacy_tls_service_name="${LOCALAI_TLS_LEGACY_SERVICE_NAME:-localai-tls.service}"
tls_forward_service_name="${LOCALAI_TLS_FORWARD_SERVICE_NAME:-localai-tls-forward.service}"
tls_forward_socket_name="${LOCALAI_TLS_FORWARD_SOCKET_NAME:-localai-tls-forward.socket}"
tls_project_name="${LOCALAI_TLS_COMPOSE_PROJECT_NAME:-localai-tls}"
tls_selinux_port_type="${LOCALAI_TLS_SELINUX_PORT_TYPE:-systemd_socket_proxyd_port_t}"
tls_legacy_selinux_module="${LOCALAI_TLS_LEGACY_SELINUX_MODULE:-localai_tls_forward}"
tls_bind_selinux_module="${LOCALAI_TLS_BIND_SELINUX_MODULE:-localai_tls_forward_bind}"
tls_bind_selinux_module_prefix="localai-tls-forward-bind."
subid_count="${LOCALAI_TLS_SUBID_COUNT:-65536}"
subid_min="${LOCALAI_TLS_SUBID_MIN:-1200000}"
tls_public_host="${LOCALAI_TLS_PUBLIC_HOST:-${LOCALAI_TLS_BIND_HOST:-}}"
tls_public_port="${LOCALAI_TLS_PUBLIC_PORT:-${LOCALAI_TLS_BIND_PORT:-443}}"
tls_internal_host="${LOCALAI_TLS_INTERNAL_HOST:-127.0.0.1}"
tls_internal_port="${LOCALAI_TLS_INTERNAL_PORT:-8443}"
tls_hostnames="${LOCALAI_TLS_HOSTNAMES:-localai.internal}"
tls_backend_host="${LOCALAI_TLS_BACKEND_HOST:-}"
tls_backend_port="${LOCALAI_TLS_BACKEND_PORT:-}"
tls_image_ref="${LOCALAI_TLS_IMAGE_REF:-docker.io/library/caddy:2-alpine}"
tls_container_name="${LOCALAI_TLS_CONTAINER_NAME:-localai-tls}"
tls_leaf_name="${LOCALAI_TLS_LEAF_NAME:-localai}"
tls_chain_mode="${LOCALAI_TLS_CHAIN_MODE:-auto}" # auto|always|off
tls_fullchain_path="${LOCALAI_TLS_FULLCHAIN_PATH:-}"
tls_leaf_key_path="${LOCALAI_TLS_LEAF_KEY_PATH:-}"
socket_proxyd=""

assume_yes=0
run_pull=1
install_service=1
start_service=1
install_public_socket=1
public_socket_explicit=0
rebind_localai_loopback=0
enable_container_userns=0

usage() {
  cat <<'EOF'
Usage:
  ./install.sh [options]

Installs a rootless Caddy TLS reverse proxy for LocalAI using podman compose.

This creates:
  - localai-tls service user and subordinate ids
  - rootless user policy and directories under /var/lib/localai-tls
  - a compose-managed rootless Caddy container
  - optional host socket proxy from :443 to internal Caddy port

The installer changes host state in these areas:
  - /var/lib/localai-tls and children
  - /etc/systemd/system for optional socket-proxy units
  - /etc/subuid and /etc/subgid entries for localai-tls
  - SELinux labels/modules for the internal Caddy port and socket-proxy bind rules

Options:
  -y, --yes                 Do not prompt for optional actions.
  --no-pull                  Install config files but do not pull image.
  --no-service               Generate files but do not install the compose unit.
  --no-start                 Install config but do not enable/start it.
  --no-public-socket         Do not install system socket proxy to :443.
  --hide-direct-http
  --rebind-localai-loopback  Regenerate LocalAI to bind HTTP to 127.0.0.1.
  --enable-container-userns  Enable secureblue container-domain user namespaces
                             if rootless Podman needs it.
  -h, --help                Show this help.

Environment:
  LOCALAI_TLS_IMAGE_REF        Image used for Caddy (default: docker.io/library/caddy:2-alpine)
  LOCALAI_TLS_STATE_DIR        Default: /var/lib/localai-tls
  LOCALAI_TLS_COMPOSE_DIR      Default: /var/lib/localai-tls/.local/share/localai-tls-compose
  LOCALAI_TLS_COMPOSE_FILE_NAME
                              Default: localai-tls-compose.yaml
  LOCALAI_TLS_CHAIN_MODE       auto|always|off (default: auto)
  LOCALAI_TLS_FULLCHAIN_PATH   Fullchain cert path (default: $LOCALAI_TLS_CERT_DIR/fullchain.crt)
  LOCALAI_TLS_LEAF_KEY_PATH    Leaf private key path (default: $LOCALAI_TLS_CERT_DIR/$LOCALAI_TLS_LEAF_NAME.key)
  LOCALAI_TLS_SERVICE_NAME     Default: localai-tls-compose.service
  LOCALAI_TLS_COMPOSE_PROJECT_NAME
                              Compose project name (default: localai-tls)
  LOCALAI_TLS_HOSTNAMES        Default: localai.internal
EOF
}

log() {
  printf '==> %s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

confirm() {
  local prompt="$1" answer
  if [[ "$assume_yes" == "1" ]]; then
    return 0
  fi
  printf '%s [y/N] ' "$prompt" >&2
  read -r answer
  [[ "$answer" == "y" || "$answer" == "Y" || "$answer" == "yes" || "$answer" == "YES" ]]
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

validate_identifier() {
  local value="$1" label="$2"
  if [[ ! "$value" =~ ^[A-Za-z0-9._-]+$ ]]; then
    die "$label must match [A-Za-z0-9._-]+, got: $value"
  fi
}

validate_abs_path() {
  local value="$1" label="$2"
  if [[ -z "$value" || "$value" != /* ]]; then
    die "$label must be an absolute path, got: $value"
  fi
  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* || "$value" == *$'\t'* || "$value" == *" "* ]]; then
    die "$label must not contain whitespace, got: $value"
  fi
}

validate_port() {
  local value="$1" label="$2"
  if [[ ! "$value" =~ ^[0-9]+$ ]] || (( value < 1 || value > 65535 )); then
    die "$label must be an integer in [1, 65535], got: $value"
  fi
}

validate_host_name() {
  local value="$1" label="$2"
  [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ || "$value" =~ ^\[[A-Fa-f0-9:]+\]$ ]] || die "$label must be a DNS name, IPv4 address, or bracketed IPv6 address."
}

validate_names() {
  validate_identifier "$tls_compose_file_name" "LOCALAI_TLS_COMPOSE_FILE_NAME"
  validate_identifier "$tls_service_name" "LOCALAI_TLS_SERVICE_NAME"
  validate_identifier "$tls_forward_service_name" "LOCALAI_TLS_FORWARD_SERVICE_NAME"
  validate_identifier "$tls_forward_socket_name" "LOCALAI_TLS_FORWARD_SOCKET_NAME"
  validate_identifier "$tls_project_name" "LOCALAI_TLS_COMPOSE_PROJECT_NAME"
  validate_abs_path "$tls_state_dir" "LOCALAI_TLS_STATE_DIR"
  validate_abs_path "$tls_config_dir" "LOCALAI_TLS_CONFIG_DIR"
  validate_abs_path "$tls_cache_dir" "LOCALAI_TLS_CACHE_DIR"
  validate_abs_path "$tls_certs_dir" "LOCALAI_TLS_CERT_DIR"
  validate_abs_path "$tls_compose_dir" "LOCALAI_TLS_COMPOSE_DIR"
  validate_abs_path "$tls_app_home_dir" "TLS application home"
  validate_abs_path "$tls_storage_dir" "Caddy storage directory"
  [[ "$tls_leaf_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "LOCALAI_TLS_LEAF_NAME must be a filename stem."
  [[ "$tls_chain_mode" == auto || "$tls_chain_mode" == always || "$tls_chain_mode" == off ]] || die "LOCALAI_TLS_CHAIN_MODE must be auto, always, or off."
  local cert_path hostname
  for cert_path in "$tls_fullchain_path" "$tls_leaf_key_path"; do
    if [[ -n "$cert_path" && ( "$cert_path" != /* || ! "$cert_path" =~ ^/[A-Za-z0-9._/-]+$ ) ]]; then
      die "TLS certificate paths must be absolute and contain only letters, digits, slash, dot, underscore, or hyphen."
    fi
  done
  validate_host_name "$tls_internal_host" "LOCALAI_TLS_INTERNAL_HOST"
  [[ -z "$tls_public_host" ]] || validate_host_name "$tls_public_host" "LOCALAI_TLS_PUBLIC_HOST"
  [[ -z "$tls_backend_host" ]] || validate_host_name "$tls_backend_host" "LOCALAI_TLS_BACKEND_HOST"
  for hostname in ${tls_hostnames//,/ }; do
    validate_host_name "$hostname" "LOCALAI_TLS_HOSTNAMES"
  done
  localai_installer_validate_service_account_name "$localai_service_user" "LOCALAI_SERVICE_USER" || return 1
  localai_installer_validate_service_account_name "$tls_user" "LOCALAI_TLS_USER" || return 1
  localai_installer_validate_managed_path "$localai_state_dir" "LOCALAI_STATE_DIR" || return 1
  localai_installer_validate_managed_path "$tls_state_dir" "LOCALAI_TLS_STATE_DIR" || return 1
  local path
  for path in "$tls_app_home_dir" "$tls_storage_dir" "$tls_config_dir" "$tls_cache_dir" "$tls_certs_dir" "$tls_compose_dir" "$tls_state_dir/data" "$tls_state_dir/config"; do
    localai_installer_validate_managed_path "$path" "TLS managed directory" || return 1
  done
  for path in "$tls_app_home_dir" "$tls_storage_dir" "$tls_config_dir" "$tls_cache_dir" "$tls_certs_dir" "$tls_state_dir/data" "$tls_state_dir/config"; do
    [[ "$path" != "$tls_state_dir" && "$tls_state_dir" != "$path/"* ]] || die "TLS container mounts must not expose the TLS service home."
    for reserved in "$tls_state_dir/.config" "$tls_state_dir/.local/share/containers"; do
      [[ "$path" != "$reserved" && "$path" != "$reserved/"* && "$reserved" != "$path/"* ]] || die "TLS container mounts must not overlap service configuration or Podman storage."
    done
  done
  [[ "$tls_state_dir" != "$localai_state_dir" && "$tls_state_dir" != "$localai_state_dir/"* && "$localai_state_dir" != "$tls_state_dir/"* ]] || die "TLS and LocalAI service state directories must be separate."
  [[ "$tls_selinux_port_type" =~ ^[A-Za-z0-9_]+_t$ ]] || die "LOCALAI_TLS_SELINUX_PORT_TYPE must be a SELinux type identifier."
  [[ "$tls_legacy_selinux_module" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "Invalid legacy SELinux module name."
  [[ "$tls_bind_selinux_module" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "Invalid SELinux module name."
  validate_port "$tls_public_port" "LOCALAI_TLS_PUBLIC_PORT"
  validate_port "$tls_internal_port" "LOCALAI_TLS_INTERNAL_PORT"
  if [[ "$install_public_socket" == 1 && -z "$tls_public_host" ]]; then
    die "LOCALAI_TLS_PUBLIC_HOST must be non-empty when the public TLS socket is enabled"
  fi
}

run0_pipe() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  else
    run0 -i "$@"
  fi
}

elevate_once() {
  local key value
  local -a config_env=()
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    return 0
  fi

  require_cmd run0
  for key in "${!LOCALAI_CONFIG_ENV_OVERRIDES[@]}"; do
    config_env+=("$key=${LOCALAI_CONFIG_ENV_OVERRIDES[$key]}")
  done
  for key in \
    LOCALAI_TLS_CONFIG_DIR LOCALAI_TLS_CACHE_DIR LOCALAI_TLS_CERT_DIR \
    LOCALAI_TLS_COMPOSE_DIR LOCALAI_TLS_COMPOSE_FILE_NAME LOCALAI_TLS_COMPOSE_PROJECT_NAME \
    LOCALAI_TLS_LEGACY_SERVICE_NAME \
    LOCALAI_TLS_CHAIN_MODE LOCALAI_TLS_FULLCHAIN_PATH LOCALAI_TLS_LEAF_KEY_PATH \
    LOCALAI_TLS_LEAF_NAME LOCALAI_TLS_BACKEND_HOST LOCALAI_TLS_BACKEND_PORT \
    LOCALAI_TLS_SELINUX_PORT_TYPE LOCALAI_TLS_LEGACY_SELINUX_MODULE \
    LOCALAI_TLS_BIND_SELINUX_MODULE LOCALAI_TLS_SUBID_MIN LOCALAI_TLS_SUBID_COUNT; do
    if value="$(printenv "$key" 2>/dev/null)"; then config_env+=("$key=$value"); fi
  done
  log "Elevating once with run0. Further root steps will run inside this session."
  exec run0 -i \
    /usr/bin/env \
    "${config_env[@]}" \
    "LOCALAI_ASSET_DIR=$asset_dir" \
    "LOCALAI_CONFIG_FILE=$requested_config" \
    "LOCALAI_TLS_SUBID_MIN=$subid_min" \
    "LOCALAI_TLS_SUBID_COUNT=$subid_count" \
    /usr/bin/bash "$script_dir/install.sh" "${original_args[@]}"
}

asset_requirements() {
  local missing=0 file
  for file in \
    "$lock_file" \
    "$policy_file" \
    "$script_dir/localai-tls-compose.yaml.in" \
    "$script_dir/localai-tls-compose.service.in" \
    "$script_dir/localai-tls-forward.service.in" \
    "$script_dir/localai-tls-forward.socket.in"; do
    if [[ ! -e "$file" ]]; then
      printf 'Missing required file: %s\n' "$file" >&2
      missing=1
    fi
  done
  [[ "$missing" == "0" ]] || exit 1
}

load_localai_lock() {
  localai_installer_select_config "$canonical_config" "$requested_config" /etc/localai.conf "$repo_root/config/localai.conf" "$lock_file" || die "Cannot select a safe configuration source."
  localai_installer_load_config "$LOCALAI_INSTALLER_CONFIG_SOURCE" "$LOCALAI_INSTALLER_CONFIG_FORMAT" || die "Invalid LocalAI configuration."
  localai_service_user="$LOCALAI_SERVICE_USER"
  localai_state_dir="$LOCALAI_STATE_DIR"
  tls_user="$LOCALAI_TLS_USER"
  tls_state_dir="$LOCALAI_TLS_STATE_DIR"
  tls_app_home_dir="$tls_state_dir/app-home"
  tls_storage_dir="$tls_state_dir/caddy"
  tls_config_dir="${LOCALAI_TLS_CONFIG_DIR:-$tls_state_dir/caddy}"
  tls_cache_dir="${LOCALAI_TLS_CACHE_DIR:-$tls_state_dir/cache}"
  tls_certs_dir="${LOCALAI_TLS_CERT_DIR:-$tls_state_dir/certs}"
  tls_compose_dir="${LOCALAI_TLS_COMPOSE_DIR:-$tls_state_dir/.local/share/localai-tls-compose}"
  tls_compose_file_name="${LOCALAI_TLS_COMPOSE_FILE_NAME:-localai-tls-compose.yaml}"
  tls_project_name="${LOCALAI_TLS_COMPOSE_PROJECT_NAME:-localai-tls}"
  tls_public_host="$LOCALAI_TLS_PUBLIC_HOST"
  tls_public_port="$LOCALAI_TLS_PUBLIC_PORT"
  tls_internal_host="$LOCALAI_TLS_INTERNAL_HOST"
  tls_internal_port="$LOCALAI_TLS_INTERNAL_PORT"
  tls_hostnames="$LOCALAI_TLS_HOSTNAMES"
  tls_image_ref="$LOCALAI_TLS_IMAGE_REF"
  if [[ -n "$LOCALAI_TLS_IMAGE_DIGEST" ]]; then
    tls_image_ref="${tls_image_ref%@*}@${LOCALAI_TLS_IMAGE_DIGEST}"
  fi
  tls_container_name="$LOCALAI_TLS_CONTAINER_NAME"
  tls_service_name="$LOCALAI_TLS_SERVICE_NAME"
  tls_forward_service_name="$LOCALAI_TLS_FORWARD_SERVICE_NAME"
  tls_forward_socket_name="$LOCALAI_TLS_FORWARD_SOCKET_NAME"
  tls_backend_port="$LOCALAI_BIND_PORT"
  if [[ "$public_socket_explicit" == 0 ]]; then
    install_public_socket=0
    [[ "$LOCALAI_TLS_PUBLIC_SOCKET" == true ]] && install_public_socket=1
  fi
  if [[ "$rebind_localai_loopback" == "1" ]]; then
    tls_backend_host="${tls_backend_host:-127.0.0.1}"
  else
    tls_backend_host="${tls_backend_host:-$LOCALAI_BIND_HOST}"
  fi
}

resolve_localai_user() {
  getent passwd "$localai_service_user" >/dev/null || {
    die "LocalAI service user '$localai_service_user' does not exist. Run secureblue-localai-install/install.sh first."
  }
  localai_uid="$(localai_installer_validate_existing_service_account "$localai_service_user" "$localai_state_dir" "LocalAI service")" || die "Unsafe LocalAI service account."
  [[ -n "$localai_uid" ]] || die "Could not resolve UID for $localai_service_user"
}

ensure_tls_user() {
  localai_installer_validate_service_account_name "$tls_user" "LOCALAI_TLS_USER" || die "Unsafe TLS service account name."
  if getent passwd "$tls_user" >/dev/null; then
    tls_uid="$(localai_installer_validate_existing_service_account "$tls_user" "$tls_state_dir" "TLS proxy service")" || die "Unsafe existing TLS service account."
    log "Using existing TLS proxy user: $tls_user"
  else
    localai_installer_check_directory_chain "$tls_state_dir" "LOCALAI_TLS_STATE_DIR" 0 || die "Unsafe TLS state path."
    log "Creating system user: $tls_user"
    run0_pipe /usr/sbin/useradd \
      --system \
      --home-dir "$tls_state_dir" \
      --shell /usr/sbin/nologin \
      "$tls_user"
  fi

  tls_uid="$(localai_installer_validate_existing_service_account "$tls_user" "$tls_state_dir" "TLS proxy service")" || die "Could not validate TLS service account."
  [[ -n "$tls_uid" ]] || die "Could not resolve UID for $tls_user"
  log "TLS proxy user UID: $tls_uid"
}

tls_runtime_dir() {
  printf '/run/user/%s\n' "$tls_uid"
}

localai_runtime_dir() {
  printf '/run/user/%s\n' "$localai_uid"
}

run_as_tls() {
  local -a command=(/usr/bin/systemd-run --user --machine="$tls_user@.host" --wait --pipe --collect
    --setenv=HOME="$tls_state_dir"
    --setenv=XDG_RUNTIME_DIR="$(tls_runtime_dir)"
    --setenv=DBUS_SESSION_BUS_ADDRESS="unix:path=$(tls_runtime_dir)/bus"
    --setenv=PATH=/usr/bin:/bin
    -- "$@")
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then "${command[@]}"; else run0 -i "${command[@]}"; fi
}

run_tls_unit() {
  run_as_tls "$@"
}

run_as_localai() {
  local -a command=(/usr/bin/systemd-run --user --machine="$localai_service_user@.host" --wait --pipe --collect
    --setenv=HOME="$localai_state_dir"
    --setenv=XDG_RUNTIME_DIR="$(localai_runtime_dir)"
    --setenv=DBUS_SESSION_BUS_ADDRESS="unix:path=$(localai_runtime_dir)/bus"
    --setenv=PATH=/usr/bin:/bin
    -- "$@")
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then "${command[@]}"; else run0 -i "${command[@]}"; fi
}

# The function is called indirectly by a helper or test.
# shellcheck disable=SC2329
run_localai_unit() {
  run_as_localai "$@"
}

localai_service_lifecycle_requested() {
  [[ "$rebind_localai_loopback" == 1 ]]
}

preflight_localai_backend_state() {
  local service_unit="$localai_state_dir/.config/systemd/user/localai.service"
  local storage_root="$localai_state_dir/.local/share/containers/storage"
  local storage_config="$localai_state_dir/.config/containers/storage.conf"
  local manager_active=0 manager_status=0 old_name
  local -a container_names=("${LOCALAI_CONTAINER_NAME:-localai}")
  localai_service_lifecycle_requested || return 0
  localai_installer_validate_identifier "${LOCALAI_CONTAINER_NAME:-localai}" "LOCALAI_CONTAINER_NAME" || die "Unsafe LocalAI container name."

  if [[ -e "$service_unit" || -L "$service_unit" ]]; then
    localai_installer_check_directory_chain "${service_unit%/*}" "LocalAI user-unit directory" "$localai_uid" || die "Unsafe LocalAI user-unit path."
    localai_installer_check_managed_file "$service_unit" "LocalAI user unit" "$localai_uid" \
      '# Managed by LocalAI secureblue installer.' 'Description=LocalAI OpenAI-compatible API and web UI container' || die "Refusing to inspect an unrelated LocalAI user unit."
    existing_localai_service_unit=1
    old_name="$(/usr/bin/awk '
      /^Environment=LOCALAI_CONTAINER_NAME=/ {
        sub(/^Environment=LOCALAI_CONTAINER_NAME=/, "")
        print
      }
    ' "$service_unit")"
    if [[ -n "$old_name" ]]; then
      [[ "$old_name" != *$'\n'* ]] || die "Existing LocalAI unit has duplicate container-name settings."
      localai_installer_validate_identifier "$old_name" "existing LocalAI container name" || die "Existing LocalAI unit has an unsafe container name."
      [[ "$old_name" == "${container_names[0]}" ]] || container_names+=("$old_name")
    fi
  fi

  if localai_installer_user_manager_is_active "$localai_uid"; then
    manager_active=1
  else
    manager_status=$?
    [[ "$manager_status" -eq 3 ]] || die "Could not determine whether the LocalAI user manager is active."
  fi
  if [[ "$manager_active" == 0 ]]; then
    if [[ -e "$storage_root" || -e "$storage_config" || "$existing_localai_service_unit" == 1 ]]; then
      die "Existing LocalAI Podman state cannot be inspected while its user manager is inactive; refusing to start a manager that could auto-start an old --rm service. Inventory and back up all containers and volumes for this account, stop every running container, run 'podman system migrate' manually as $localai_service_user only if Podman requires it, then retry."
    fi
    return 0
  fi

  localai_installer_preflight_backend_containers run_as_localai \
    "${LOCALAI_BACKENDS_PATH:-$localai_state_dir/backends}" "$localai_uid" "$localai_state_dir" "${container_names[@]}" || die "LocalAI backend state is not safe to stop or replace."
}

run_localai_unit() {
  run_as_localai "$@"
}

subid_line() {
  local file="$1"
  awk -F: -v user="$tls_user" '$1 == user { print }' "$file" 2>/dev/null || true
}

has_subid() {
  local file="$1"
  [[ -n "$(subid_line "$file")" ]]
}

find_common_subid_range() {
  awk -F: -v start="$subid_min" -v count="$subid_count" '
    /^[[:space:]]*#/ || NF < 3 { next }
    {
      s = $2 + 0
      c = $3 + 0
      e = s + c - 1
      if (e >= start && e + 1 > start) {
        start = e + 1
      }
    }
    END {
      rem = start % count
      if (rem != 0) {
        start += count - rem
      }
      printf "%d-%d\n", start, start + count - 1
    }
  ' /etc/subuid /etc/subgid
}

ensure_subids() {
  local need_subuid=0 need_subgid=0 range
  local storage_root="$tls_state_dir/.local/share/containers/storage"
  local storage_config="$tls_state_dir/.config/containers/storage.conf"

  if ! has_subid /etc/subuid; then
    need_subuid=1
  fi
  if ! has_subid /etc/subgid; then
    need_subgid=1
  fi

  if [[ "$need_subuid" == "0" && "$need_subgid" == "0" ]]; then
    log "Subordinate IDs already exist for $tls_user"
    subid_line /etc/subuid
    subid_line /etc/subgid
    return 0
  fi

  if [[ -e "$storage_root" || -L "$storage_root" || -e "$storage_config" || -L "$storage_config" ]]; then
    die "Existing Podman storage for $tls_user needs subordinate IDs. The installer will not change mappings or stop all containers automatically. Inventory and back up this account's containers and volumes, stop every running container for the account, add the required mappings, run 'podman system migrate' manually as $tls_user, then retry."
  fi

  range="$(find_common_subid_range)"
  log "Rootless Podman needs subordinate IDs for $tls_user."
  log "Proposed non-overlapping range from /etc/subuid and /etc/subgid: $range"
  confirm "Add subordinate UID/GID range $range to $tls_user?" || {
    die "Subordinate IDs are required for rootless compose."
  }

  if [[ "$need_subuid" == "1" && "$need_subgid" == "1" ]]; then
    run0_pipe /usr/sbin/usermod --add-subuids "$range" --add-subgids "$range" "$tls_user"
  elif [[ "$need_subuid" == "1" ]]; then
    run0_pipe /usr/sbin/usermod --add-subuids "$range" "$tls_user"
  else
    run0_pipe /usr/sbin/usermod --add-subgids "$range" "$tls_user"
  fi
  log "Updated /etc/subuid and /etc/subgid entries for $tls_user"
  subid_line /etc/subuid
  subid_line /etc/subgid
}

install_dirs() {
  log "Creating LocalAI TLS state directories"
  local dir
  for dir in \
    "$tls_state_dir" "$tls_state_dir/data" "$tls_state_dir/config" \
    "$tls_app_home_dir" "$tls_storage_dir" "$tls_config_dir" \
    "$tls_cache_dir" "$tls_certs_dir" "$tls_compose_dir"; do
    localai_installer_ensure_service_directory "$dir" "TLS managed directory" "$tls_user" "$tls_user" "$tls_uid" 0750 || die "Unsafe TLS managed directory: $dir"
  done
}

install_container_policy() {
  local policy_dir="$tls_state_dir/.config/containers"
  log "Installing per-user containers policy for $tls_user"
  localai_installer_ensure_service_directory "$tls_state_dir/.config" "TLS account config directory" "$tls_user" "$tls_user" "$tls_uid" 0700 || die "Unsafe TLS account config path."
  localai_installer_ensure_service_directory "$policy_dir" "TLS containers policy directory" "$tls_user" "$tls_user" "$tls_uid" 0700 || die "Unsafe TLS policy path."
  run0_pipe /usr/bin/install -o "$tls_user" -g "$tls_user" -m 0600 "$policy_file" "$policy_dir/policy.json"
}

label_container_state() {
  if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled; then
    command -v chcon >/dev/null 2>&1 || die "SELinux is enabled but chcon is not available."
    log "Labeling mounted TLS directories for container access"
    /usr/bin/find -P \
      "$tls_config_dir" \
      "$tls_cache_dir" \
      "$tls_certs_dir" \
      "$tls_app_home_dir" \
      "$tls_storage_dir" \
      "$tls_state_dir/data" \
      "$tls_state_dir/config" \
      -xdev -exec "$(command -v chcon)" -h -t container_file_t -- {} +
  else
    log "SELinux is not enabled; skipping container volume relabel."
  fi
}

guard_tls_manager_start() {
  local status=0 unit="$tls_state_dir/.config/systemd/user/$tls_service_name"
  if localai_installer_user_manager_is_active "$tls_uid"; then
    return 0
  else
    status=$?
  fi
  [[ "$status" == 3 ]] || die "Could not determine whether the TLS user manager is active."
  if [[ -e "$unit" || -L "$unit" ]]; then
    die "Cannot safely preserve TLS service state while its user manager is inactive."
  fi
}

ensure_user_manager() {
  log "Enabling linger for TLS service user"
  run0_pipe /usr/bin/loginctl enable-linger "$tls_user"
  run0_pipe /usr/bin/systemctl start "user@$tls_uid.service"
  if localai_service_lifecycle_requested; then
    log "Enabling linger for LocalAI service user"
    run0_pipe /usr/bin/loginctl enable-linger "$localai_service_user"
    run0_pipe /usr/bin/systemctl start "user@$localai_uid.service"
  fi
}

ensure_container_userns() {
  local output status=0 ujust_cmd

  log "Checking rootless Podman user namespace support for $tls_user"
  output="$(run_tls_unit /usr/bin/podman unshare /usr/bin/true 2>&1)" || status=$?
  if [[ "$status" -eq 0 ]]; then
    return 0
  fi

  printf '%s\n' "$output" >&2
  if [[ "$output" != *"cannot clone"* && "$output" != *"cannot re-exec process"* ]]; then
    die "Rootless Podman preflight failed. If Podman reports that migration is required, inventory and back up this account's containers and volumes, stop every running container for the account, run 'podman system migrate' manually as $tls_user, then retry. The installer does not run account-wide Podman migration."
  fi

  cat >&2 <<'EOF'

Rootless Podman cannot create a user namespace.

This can be fixed by relaxing secureblue's container-domain user namespace
control. Security cost: processes confined to the container domain can create
user namespaces, which secureblue disables by default because of kernel history.
Scope: container domain, not global unconfined user namespaces.
Revert with: ujust set-container-userns off
EOF

  if [[ "$enable_container_userns" != "1" ]]; then
    if [[ "$assume_yes" == "1" ]]; then
      die "--yes does not authorize changing secureblue user-namespace policy; rerun with --enable-container-userns to request it explicitly."
    fi
    confirm "Run 'ujust set-container-userns on' now?" || {
      die "Enable container user namespaces or rerun with --enable-container-userns."
    }
  fi

  ujust_cmd="$(command -v ujust)" || die "ujust not found; cannot enable secureblue container user namespaces."
  run0_pipe "$ujust_cmd" set-container-userns on

  log "Rechecking rootless Podman user namespace support"
  run_tls_unit /usr/bin/podman unshare /usr/bin/true
}

caddy_site_addresses() {
  local addresses=() name
  for name in $tls_hostnames; do
    [[ -n "$name" ]] && addresses+=("https://$name")
  done
  if [[ -n "$tls_public_host" ]]; then
    addresses+=("https://$tls_public_host")
  fi

  local joined="" address
  for address in "${addresses[@]}"; do
    if [[ -z "$joined" ]]; then
      joined="$address"
    else
      joined="$joined, $address"
    fi
  done
  printf '%s\n' "$joined"
}

caddy_default_sni() {
  if [[ "$tls_public_host" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
    printf '%s\n' "$tls_public_host"
  fi
}

tls_chain_enabled() {
  local chain_mode="$1" fullchain="$2" leaf_key="$3"
  case "$chain_mode" in
    always)
      if [[ -r "$fullchain" && -r "$leaf_key" ]]; then
        return 0
      fi
      return 1
      ;;
    off)
      return 1
      ;;
    *)
      if [[ -r "$fullchain" && -r "$leaf_key" ]]; then
        return 0
      fi
      return 1
      ;;
  esac
}

# Check static TLS files before installing the generated Caddyfile. Paths are
# canonicalized into existing bind mounts and checked as the TLS service user.
localai_tls_preflight_static_paths() {
  if (( $# != 2 )); then
    return 1
  fi

  local fullchain="$1" leaf_key="$2" mount_dir
  local -a mount_dirs=() volume_args=()
  while IFS= read -r mount_dir; do
    if [[ -n "$mount_dir" ]]; then
      mount_dirs+=("$mount_dir")
      volume_args+=(--volume "$mount_dir:$mount_dir")
    fi
  done < <(tls_compose_mount_dirs)

  tls_preflight_fullchain="$(localai_tls_resolve_mounted_file "$fullchain" "${mount_dirs[@]}")" || return 1
  tls_preflight_leaf_key="$(localai_tls_resolve_mounted_file "$leaf_key" "${mount_dirs[@]}")" || return 1

  run_as_tls /usr/bin/test -r "$tls_preflight_fullchain" >/dev/null 2>&1 || return 2
  run_as_tls /usr/bin/test -r "$tls_preflight_leaf_key" >/dev/null 2>&1 || return 2
  if [[ "$run_pull" != "1" ]]; then
    run_as_tls /usr/bin/podman image exists "$tls_image_ref" >/dev/null 2>&1 || return 3
  fi
  # The quoted text is intentionally evaluated by another shell.
  # shellcheck disable=SC2016
  run_as_tls /usr/bin/podman run --rm --pull=never \
    --userns=keep-id --security-opt=no-new-privileges --network=none \
    "${volume_args[@]}" --entrypoint /bin/sh "$tls_image_ref" \
    -c 'test -r "$1" && test -r "$2"' sh \
    "$tls_preflight_fullchain" "$tls_preflight_leaf_key" >/dev/null 2>&1 || return 2
  return 0
}

write_caddyfile() {
  local tmp_caddyfile site_addresses default_sni chain_full chain_key
  local tls_directive preflight_status
  tls_static_chain_active=0
  site_addresses="$(caddy_site_addresses)"
  default_sni="$(caddy_default_sni)"
  [[ -n "$site_addresses" ]] || die "No TLS site names were generated."
  localai_installer_mktemp_var tmp_caddyfile localai.Caddyfile.XXXXXX || die "Could not create a private Caddyfile temporary."

  chain_full="${tls_fullchain_path:-$tls_certs_dir/fullchain.crt}"
  chain_key="${tls_leaf_key_path:-$tls_certs_dir/$tls_leaf_name.key}"
  if [[ "$tls_chain_mode" != "off" ]]; then
    local explicit_fullchain=0 resolve_status
    [[ -n "$tls_fullchain_path" ]] && explicit_fullchain=1
    if chain_key="$(localai_tls_resolve_static_key \
      "$tls_certs_dir" "$chain_full" "$tls_leaf_name" \
      "$tls_leaf_key_path" "$explicit_fullchain")"; then
      :
    else
      resolve_status=$?
      case "$resolve_status" in
        1) : ;; # No static files are present; auto mode keeps Caddy's internal CA.
        2) die "Static TLS material is incomplete, unreadable, invalid, or mismatched; refusing to switch to Caddy's internal CA." ;;
        3) die "A static fullchain exists but no matching key was found; set LOCALAI_TLS_LEAF_KEY_PATH to select the certificate key or remove the stale fullchain if you intend to use Caddy's internal CA." ;;
        4) die "More than one static key matches the fullchain; set LOCALAI_TLS_LEAF_KEY_PATH to select one explicitly." ;;
        *) die "Could not safely resolve the static TLS certificate key." ;;
      esac
    fi
  fi
  if tls_chain_enabled "$tls_chain_mode" "$chain_full" "$chain_key"; then
    if localai_tls_preflight_static_paths "$chain_full" "$chain_key"; then
      chain_full="$tls_preflight_fullchain"
      chain_key="$tls_preflight_leaf_key"
    else
      preflight_status=$?
      case "$preflight_status" in
        1) die "Static TLS certificate paths must resolve inside the existing Caddy bind mounts." ;;
        2) die "The TLS service account cannot read the static certificate files; refusing to install the Caddyfile." ;;
        3) die "Static TLS validation with --no-pull requires the Caddy image to already be available." ;;
        *) die "Static TLS files failed preflight; refusing to install the Caddyfile." ;;
      esac
    fi
    tls_static_chain_active=1
    tls_directive="    tls ${chain_full} ${chain_key}"
    log "Using static chain mode for Caddyfile (tls ${chain_full} ...)"
  else
    if [[ "$tls_chain_mode" == "always" ]]; then
      die "TLS_CHAIN_MODE=always but required chain files were not found/readable: $chain_full and $chain_key"
    fi
    tls_directive="    tls internal"
    if [[ -n "$tls_fullchain_path" || -n "$tls_leaf_key_path" ]]; then
      log "Chain files not present; falling back to caddy internal CA.
  - checked fullchain: ${chain_full}
  - checked key: ${chain_key}"
    fi
  fi

  printf '# Managed by LocalAI secureblue TLS installer.\n' >"$tmp_caddyfile"
  {
    printf '{\n'
    printf '    admin off\n'
    printf '    https_port %s\n' "$tls_internal_port"
    printf '    auto_https disable_redirects\n'
    if [[ -n "$default_sni" ]]; then
      printf '    default_sni %s\n' "$default_sni"
    fi
    printf '    storage file_system %s\n' "$tls_storage_dir"
    printf '}\n\n'
    printf '%s {\n' "$site_addresses"
    printf '    bind %s\n' "$tls_internal_host"
    printf '%s\n' "$tls_directive"
    printf '    encode zstd gzip\n'
    printf '    reverse_proxy http://%s:%s {\n' "$tls_backend_host" "$tls_backend_port"
    printf '        header_up X-Forwarded-Proto https\n'
    printf '        header_up X-Forwarded-Host {host}\n'
    printf '    }\n'
    printf '}\n'
  } >>"$tmp_caddyfile"

  log "Installing Caddyfile at $tls_config_dir/Caddyfile"
  localai_installer_check_managed_file "$tls_config_dir/Caddyfile" "Caddyfile" "$tls_uid" \
    '# Managed by LocalAI secureblue TLS installer.' "    storage file_system $tls_storage_dir" || die "Refusing to replace an unrelated Caddyfile."
  run0_pipe /usr/bin/install -o "$tls_user" -g "$tls_user" -m 0644 "$tmp_caddyfile" "$tls_config_dir/Caddyfile"
}

validate_caddyfile() {
  if [[ "$run_pull" != "1" && "$tls_static_chain_active" != "1" ]]; then
    log "Skipping Caddyfile validation because --no-pull was requested and no static chain is configured."
    return 0
  fi

  log "Validating Caddyfile in Caddy container"
  local -a volume_args=() pull_args=()
  [[ "$run_pull" == "1" ]] || pull_args+=(--pull=never)
  local mount_dir
  while IFS= read -r mount_dir; do
    [[ -n "$mount_dir" ]] && volume_args+=(--volume "$mount_dir:$mount_dir")
  done < <(tls_compose_mount_dirs)
  run_tls_unit /usr/bin/podman run --rm "${pull_args[@]}" \
    --userns=keep-id \
    --security-opt=no-new-privileges \
    --network=none \
    "${volume_args[@]}" \
    "$tls_image_ref" \
    caddy validate --config "$tls_config_dir/Caddyfile"
}

require_compose() {
  require_cmd podman
  if ! podman compose version >/dev/null 2>&1; then
    die "podman compose is not available. Install the Podman compose plugin and retry."
  fi
}

pull_image() {
  [[ "$run_pull" == "1" ]] || return 0
  log "Pulling Caddy image for TLS proxy: $tls_image_ref"
  run_as_tls /usr/bin/podman pull "$tls_image_ref"
}

yaml_quote() {
  localai_tls_compose_yaml_quote "$1"
}

tls_compose_mount_dirs() {
  localai_tls_compose_mount_dirs \
    "$tls_config_dir" "$tls_storage_dir" "$tls_state_dir/data" \
    "$tls_state_dir/config" "$tls_cache_dir" "$tls_certs_dir" \
    "$tls_app_home_dir"
}

write_compose_file() {
  local tmp_compose
  localai_installer_mktemp_var tmp_compose localai-tls-compose.XXXXXX.yaml || die "Could not create a private Compose file temporary."

  printf '# Managed by LocalAI secureblue TLS installer.\n' >"$tmp_compose"
  localai_tls_render_compose_template \
    "$script_dir/localai-tls-compose.yaml.in" \
    "$tls_image_ref" "$tls_container_name" "$tls_state_dir" \
    "$tls_app_home_dir" "$tls_storage_dir" "$tls_state_dir/data" \
    "$tls_state_dir/config" "$tls_cache_dir" "$tls_config_dir" \
    "$tls_certs_dir" "$tls_config_dir/Caddyfile" >>"$tmp_compose"

  log "Installing compose definition at $tls_compose_dir/$tls_compose_file_name"
  localai_installer_check_managed_file "$tls_compose_dir/$tls_compose_file_name" "TLS compose definition" "$tls_uid" \
    '# Managed by LocalAI secureblue TLS installer.' "container_name: $(yaml_quote "$tls_container_name")" || die "Refusing to replace an unrelated Compose definition."
  run0_pipe /usr/bin/install -o "$tls_user" -g "$tls_user" -m 0644 "$tmp_compose" "$tls_compose_dir/$tls_compose_file_name"
}

write_compose_service() {
  [[ "$install_service" == "1" ]] || return 0
  local tmp_service compose_file user_unit_dir
  localai_installer_mktemp_var tmp_service localai-tls-compose.service.XXXXXX || die "Could not create a private TLS unit temporary."
  # These values are systemd unit fields, not shell or YAML values. The
  # validated paths contain no whitespace, so quoting them here would make
  # WorkingDirectory= invalid and prevent the user unit from loading.
  compose_file="$tls_compose_dir/$tls_compose_file_name"
  user_unit_dir="$tls_state_dir/.config/systemd/user"

  printf '# Managed by LocalAI secureblue TLS installer.\n' >"$tmp_service"
  localai_tls_render_compose_service_template \
    "$script_dir/localai-tls-compose.service.in" "$tls_uid" "$tls_state_dir" \
    "$compose_file" "$tls_project_name" >>"$tmp_service"

  log "Installing user systemd compose unit at $user_unit_dir/$tls_service_name"
  localai_installer_ensure_service_directory "$user_unit_dir" "TLS user-unit directory" "$tls_user" "$tls_user" "$tls_uid" 0700 || die "Unsafe TLS user-unit directory."
  localai_installer_check_managed_file "$user_unit_dir/$tls_service_name" "TLS user unit" "$tls_uid" \
    '# Managed by LocalAI secureblue TLS installer.' 'Description=LocalAI TLS reverse proxy compose stack' || die "Refusing to replace an unrelated TLS user unit."
  run0_pipe /usr/bin/install -o "$tls_user" -g "$tls_user" -m 0644 "$tmp_service" "$user_unit_dir/$tls_service_name"
  run_as_tls /usr/bin/systemctl --user daemon-reload
}

find_socket_proxyd() {
  local candidate
  for candidate in \
    /usr/lib/systemd/systemd-socket-proxyd \
    /lib/systemd/systemd-socket-proxyd \
    /usr/libexec/systemd/systemd-socket-proxyd; do
    if [[ -x "$candidate" ]]; then
      socket_proxyd="$candidate"
      return 0
    fi
  done
  socket_proxyd="$(command -v systemd-socket-proxyd || true)"
  [[ -n "$socket_proxyd" ]] || die "systemd-socket-proxyd was not found. Rerun with --no-public-socket and expose LOCALAI_TLS_INTERNAL_PORT another way."
}

write_forward_units() {
  local tmp_service tmp_socket
  [[ "$install_service" == "1" && "$install_public_socket" == "1" ]] || return 0
  find_socket_proxyd
  localai_installer_mktemp_var tmp_service localai-tls-forward.service.XXXXXX || die "Could not create a private socket-proxy unit temporary."
  localai_installer_mktemp_var tmp_socket localai-tls-forward.socket.XXXXXX || die "Could not create a private socket unit temporary."

  printf '# Managed by LocalAI secureblue TLS installer.\n' >"$tmp_service"
  sed \
    -e "s|@SOCKET_PROXYD@|$socket_proxyd|g" \
    -e "s|@TLS_UID@|$tls_uid|g" \
    -e "s|@TLS_INTERNAL_HOST@|$tls_internal_host|g" \
    -e "s|@TLS_INTERNAL_PORT@|$tls_internal_port|g" \
    "$script_dir/localai-tls-forward.service.in" >>"$tmp_service"

  printf '# Managed by LocalAI secureblue TLS installer.\n' >"$tmp_socket"
  sed \
    -e "s|@TLS_PUBLIC_HOST@|$tls_public_host|g" \
    -e "s|@TLS_PUBLIC_PORT@|$tls_public_port|g" \
    "$script_dir/localai-tls-forward.socket.in" >>"$tmp_socket"

  log "Installing host systemd socket proxy units for ${tls_public_host}:${tls_public_port}"
  localai_installer_check_managed_file "/etc/systemd/system/$tls_forward_service_name" "TLS host socket-proxy unit" 0 \
    '# Managed by LocalAI secureblue TLS installer.' 'Description=LocalAI HTTPS socket proxy' || die "Refusing to replace an unrelated host socket-proxy unit."
  localai_installer_check_managed_file "/etc/systemd/system/$tls_forward_socket_name" "TLS host socket unit" 0 \
    '# Managed by LocalAI secureblue TLS installer.' 'Description=LocalAI HTTPS socket' || die "Refusing to replace an unrelated host socket unit."
  run0_pipe /usr/bin/install -o root -g root -m 0644 "$tmp_service" "/etc/systemd/system/$tls_forward_service_name"
  run0_pipe /usr/bin/install -o root -g root -m 0644 "$tmp_socket" "/etc/systemd/system/$tls_forward_socket_name"
  rm -f "$tmp_service" "$tmp_socket"
  run0_pipe /usr/bin/systemctl daemon-reload
}

selinux_port_state_file() {
  localai_installer_selinux_state_file "$1"
}

tcp_port_type() {
  local port="$1"
  semanage port -l | awk -v port="$port" '
    $2 == "tcp" {
      for (i = 3; i <= NF; i++) {
        item = $i
        gsub(",", "", item)
        split(item, range, "-")
        if (range[2] == "" && range[1] == port) {
          print $1
          exit
        }
        if (range[2] != "" && port >= range[1] && port <= range[2]) {
          print $1
          exit
        }
      }
    }
  '
}

label_one_forward_selinux_port() {
  local role="$1" port="$2" purpose="$3"
  local current_type action state_file status current_after
  [[ -n "$port" ]] || return 0

  state_file="$(selinux_port_state_file "$role")" || die "Invalid SELinux port role."
  current_type="$(tcp_port_type "$port")"

  if [[ "$current_type" == "$tls_selinux_port_type" ]]; then
    log "SELinux TCP port $port already labeled $tls_selinux_port_type"
    return 0
  fi

  cat >&2 <<EOF

This labels TCP port $port as $tls_selinux_port_type so the socket proxy can
$purpose.

Security cost: this reserves TCP port $port for the SELinux
systemd_socket_proxyd_port_t type. Scope: this one TCP port label only.
EOF

  if [[ -n "$current_type" ]]; then
    action="modify"
  else
    action="add"
  fi
  localai_installer_write_selinux_port_state "$role" "$action" "$port" "$current_type" "$tls_selinux_port_type" || die "Could not save root-owned SELinux rollback metadata."
  if [[ "$action" == modify ]]; then
    run0_pipe semanage port -m -t "$tls_selinux_port_type" -p tcp "$port" || status=$?
  else
    run0_pipe semanage port -a -t "$tls_selinux_port_type" -p tcp "$port" || status=$?
  fi
  if [[ "${status:-0}" != 0 ]]; then
    current_after="$(tcp_port_type "$port")"
    if [[ "$current_after" != "$tls_selinux_port_type" ]]; then
      localai_installer_remove_selinux_port_state "$role" || true
    fi
    return "$status"
  fi
}

restore_forward_selinux_port_if_tracked() {
  local role="$1"
  local state_file state action="" port="" previous_type="" new_type="" current_type
  state_file="$(selinux_port_state_file "$role")" || die "Invalid SELinux port role."

  [[ -e "$state_file" || -L "$state_file" ]] || return 0
  require_cmd semanage
  state="$(localai_installer_read_selinux_port_state "$state_file")" || die "Refusing untrusted SELinux rollback metadata."
  IFS='|' read -r action port previous_type new_type <<< "$state"
  current_type="$(tcp_port_type "$port")"
  if [[ "$current_type" == "$new_type" && "$action" == add ]]; then
    log "Removing SELinux TCP port label for $port"
    run0_pipe semanage port -d -p tcp "$port" || die "Could not remove tracked SELinux port label $port."
  elif [[ "$current_type" == "$new_type" && "$action" == modify ]]; then
    log "Restoring SELinux TCP port $port label to $previous_type"
    run0_pipe semanage port -m -t "$previous_type" -p tcp "$port" || die "Could not restore tracked SELinux port label $port."
  elif [[ "$current_type" != "$new_type" ]]; then
    log "SELinux TCP port $port is now labeled ${current_type:-<unlabeled>}; leaving the administrator's change intact."
  fi
  localai_installer_remove_selinux_port_state "$role" || die "Could not remove SELinux rollback metadata."
}

label_forward_selinux_ports() {
  [[ "$install_public_socket" == "1" ]] || return 0
  if ! command -v selinuxenabled >/dev/null 2>&1 || ! selinuxenabled; then
    log "SELinux is not enabled; skipping socket proxy port labels."
    return 0
  fi

  require_cmd semanage
  restore_forward_selinux_port_if_tracked "public"
  restore_forward_selinux_port_if_tracked "internal"
  label_one_forward_selinux_port "internal" "$tls_internal_port" "connect to ${tls_internal_host}:${tls_internal_port}"

  if command -v semodule >/dev/null 2>&1; then
    if semodule -l | awk -v module="$tls_legacy_selinux_module" '$1 == module { found = 1 } END { exit found ? 0 : 1 }'; then
      run0_pipe semodule -r "$tls_legacy_selinux_module" || true
    fi
  fi
}

remove_forward_bind_selinux_modules() {
  local module
  command -v semodule >/dev/null 2>&1 || return 0

  while IFS= read -r module; do
    [[ -n "$module" ]] || continue
    log "Removing existing SELinux module $module"
    run0_pipe semodule -r "$module" || true
  done < <(
    semodule -l | awk \
      -v stable="$tls_bind_selinux_module" \
      -v random_prefix="$tls_bind_selinux_module_prefix" \
      '$1 == stable || index($1, random_prefix) == 1 { print $1 }'
  )
}

install_forward_bind_selinux_policy() {
  local current_type cil_file
  [[ "$install_public_socket" == "1" ]] || return 0
  if ! command -v selinuxenabled >/dev/null 2>&1 || ! selinuxenabled; then
    return 0
  fi

  require_cmd semanage
  require_cmd semodule
  current_type="$(tcp_port_type "$tls_public_port")"
  [[ -n "$current_type" ]] || die "Could not resolve SELinux type for TCP port $tls_public_port"

  if [[ "$current_type" == "$tls_selinux_port_type" ]]; then
    return 0
  fi

  cat >&2 <<EOF

This installs a local SELinux rule allowing systemd-socket-proxyd to bind TCP
port $tls_public_port while leaving that port's global label unchanged.
Security cost: bind permission for that port's SELinux type is widened only for
the socket-proxyd domain.
EOF

  remove_forward_bind_selinux_modules

  [[ "$current_type" =~ ^[A-Za-z0-9_]+_t$ ]] || die "Could not validate SELinux type for TCP port $tls_public_port"
  localai_installer_mktemp_var cil_file "${tls_bind_selinux_module}.XXXXXX.cil" || die "Could not create private SELinux policy temporary."
  cat >"$cil_file" <<EOF
(block $tls_bind_selinux_module
  (allow systemd_socket_proxyd_t $current_type (tcp_socket (name_bind)))
)
EOF
  run0_pipe semodule -i "$cil_file"
}

preserve_linked_service_states() {
  [[ "$install_service" == 1 ]] || return 0
  if [[ "$start_service" == 0 ]]; then
    log "TLS units installed without starting them (--no-start)."
  else
    log "TLS units installed; existing service and socket states are unchanged."
  fi
  log "Restart an already-running TLS service explicitly to apply changed configuration."
}

retire_legacy_direct_tls_service() {
  local legacy_unit="$tls_state_dir/.config/systemd/user/$legacy_tls_service_name"
  [[ "$legacy_tls_service_name" != "$tls_service_name" ]] || return 0
  [[ -e "$legacy_unit" ]] || return 0

  log "Retiring legacy direct-Caddy user unit $legacy_tls_service_name"
  if [[ -n "${tls_uid:-}" ]]; then
    run_as_tls /usr/bin/systemctl --user disable --now "$legacy_tls_service_name" || true
    run_as_tls /usr/bin/systemctl --user daemon-reload || true
  fi
  # Preserve all TLS state, including the internal CA; remove only the stale
  # unit that could compete with the Compose-managed service.
  run0_pipe /usr/bin/rm -f "$legacy_unit"
}

rebind_localai_if_requested() {
  [[ "$rebind_localai_loopback" == "1" ]] || return 0

  cat >&2 <<EOF

This will regenerate the LocalAI service so its plain HTTP backend binds only
to 127.0.0.1:$tls_backend_port. HTTPS remains exposed on
$tls_public_host:$tls_public_port.
EOF
  confirm "Rebind LocalAI's HTTP backend to loopback now?" || return 0

  log "Regenerating LocalAI service with loopback backend bind"
  LOCALAI_BIND_HOST=127.0.0.1 \
    LOCALAI_BIND_PORT="$tls_backend_port" \
    LOCALAI_ASSET_DIR="$asset_dir" \
    LOCALAI_SERVICE_USER="$localai_service_user" \
    LOCALAI_STATE_DIR="$localai_state_dir" \
    "$repo_root/secureblue-localai-install/install.sh" --yes --no-pull
}

persist_tls_lifecycle_config() {
  [[ "$install_service" == "1" ]] || return 0
  local public_socket=true
  [[ "$install_public_socket" == "1" ]] || public_socket=false
  localai_installer_update_config "$canonical_config" \
    LOCALAI_TLS_ENABLED true \
    LOCALAI_TLS_PUBLIC_SOCKET "$public_socket" \
    LOCALAI_TLS_PUBLIC_HOST "$tls_public_host" \
    LOCALAI_TLS_PUBLIC_PORT "$tls_public_port" \
    LOCALAI_TLS_INTERNAL_HOST "$tls_internal_host" \
    LOCALAI_TLS_INTERNAL_PORT "$tls_internal_port" \
    LOCALAI_TLS_HOSTNAMES "$tls_hostnames" \
    LOCALAI_TLS_USER "$tls_user" \
    LOCALAI_TLS_STATE_DIR "$tls_state_dir" \
    LOCALAI_TLS_CONFIG_DIR "$tls_config_dir" \
    LOCALAI_TLS_CACHE_DIR "$tls_cache_dir" \
    LOCALAI_TLS_CERT_DIR "$tls_certs_dir" \
    LOCALAI_TLS_COMPOSE_DIR "$tls_compose_dir" \
    LOCALAI_TLS_COMPOSE_FILE_NAME "$tls_compose_file_name" \
    LOCALAI_TLS_COMPOSE_PROJECT_NAME "$tls_project_name" \
    LOCALAI_TLS_IMAGE_REF "$LOCALAI_TLS_IMAGE_REF" \
    LOCALAI_TLS_IMAGE_DIGEST "$LOCALAI_TLS_IMAGE_DIGEST" \
    LOCALAI_TLS_CONTAINER_NAME "$tls_container_name" \
    LOCALAI_TLS_SERVICE_NAME "$tls_service_name" \
    LOCALAI_TLS_FORWARD_SERVICE_NAME "$tls_forward_service_name" \
    LOCALAI_TLS_FORWARD_SOCKET_NAME "$tls_forward_socket_name"
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -y|--yes)
      assume_yes=1
      ;;
    --no-pull)
      run_pull=0
      ;;
    --no-service)
      install_service=0
      start_service=0
      ;;
    --no-start)
      start_service=0
      ;;
    --no-public-socket)
      install_public_socket=0
      public_socket_explicit=1
      ;;
    --hide-direct-http|--rebind-localai-loopback)
      rebind_localai_loopback=1
      ;;
    --enable-container-userns)
      enable_container_userns=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "Unknown option: $1"
      ;;
  esac
  shift
done

require_cmd awk
require_cmd sed
require_cmd mktemp
require_compose
asset_requirements
load_localai_lock
elevate_once
localai_installer_prepare_config "$canonical_config" "$LOCALAI_INSTALLER_CONFIG_SOURCE" "$LOCALAI_INSTALLER_CONFIG_FORMAT" || die "Could not safely persist the shared LocalAI configuration."
localai_installer_persist_environment_overrides "$canonical_config" || die "Could not safely persist explicit configuration overrides."
load_localai_lock
require_cmd run0
validate_names
resolve_localai_user
ensure_tls_user
guard_tls_manager_start
ensure_subids
install_dirs
install_container_policy
existing_localai_service_unit=0
preflight_localai_backend_state
ensure_user_manager
ensure_container_userns
rebind_localai_if_requested
pull_image
label_container_state
write_caddyfile
validate_caddyfile
write_compose_file
write_compose_service
write_forward_units
label_forward_selinux_ports
install_forward_bind_selinux_policy
persist_tls_lifecycle_config
retire_legacy_direct_tls_service
preserve_linked_service_states

log "Compose-based TLS proxy install complete."
if [[ "$install_public_socket" == "1" ]]; then
  if [[ "$tls_public_port" == "443" ]]; then
    log "HTTPS endpoint: https://${tls_public_host}"
  else
    log "HTTPS endpoint: https://${tls_public_host}:${tls_public_port}"
  fi
else
  log "Internal HTTPS endpoint: https://${tls_internal_host}:${tls_internal_port}"
fi
if [[ "$tls_chain_mode" != "off" ]]; then
  log "Static cert chain files expected at: $tls_certs_dir/fullchain.crt and $tls_certs_dir/$tls_leaf_name.key"
  log "Static chain fallback is automatic unless TLS_CHAIN_MODE=off."
fi
if [[ "$tls_chain_mode" == "always" ]]; then
  log "TLS_CHAIN_MODE=always enabled: both files must exist at install time."
fi
if [[ -r "$tls_config_dir/Caddyfile" ]]; then
  log "Caddyfile: $tls_config_dir/Caddyfile"
fi
