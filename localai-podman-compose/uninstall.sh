#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
asset_dir="${LOCALAI_ASSET_DIR:-$repo_root/localai}"
lock_file="$asset_dir/localai.lock"
config_lib="${LOCALAI_CONFIG_LIB:-$repo_root/lib/config.sh}"
# The source path is selected or generated at runtime.
# shellcheck disable=SC1090
source "$config_lib"
safety_lib="${LOCALAI_INSTALLER_SAFETY_LIB:-$repo_root/lib/installer_safety.sh}"
# The source path is selected or generated at runtime.
# shellcheck disable=SC1090
source "$safety_lib"
canonical_config="$LOCALAI_INSTALLER_CONFIG_DEST"
requested_config="${LOCALAI_CONFIG_FILE:-}"
original_args=("$@")
trap localai_installer_cleanup_temps EXIT

tls_user="${LOCALAI_TLS_USER:-localai-tls}"
tls_state_dir="${LOCALAI_TLS_STATE_DIR:-/var/lib/localai-tls}"
localai_state_dir="${LOCALAI_STATE_DIR:-/var/lib/localai}"
tls_config_dir="${LOCALAI_TLS_CONFIG_DIR:-$tls_state_dir/caddy}"
tls_cache_dir="${LOCALAI_TLS_CACHE_DIR:-$tls_state_dir/cache}"
tls_certs_dir="${LOCALAI_TLS_CERT_DIR:-$tls_state_dir/certs}"
tls_compose_dir="${LOCALAI_TLS_COMPOSE_DIR:-$tls_state_dir/.local/share/localai-tls-compose}"
tls_compose_file_name="${LOCALAI_TLS_COMPOSE_FILE_NAME:-localai-tls-compose.yaml}"
tls_service_name="${LOCALAI_TLS_SERVICE_NAME:-localai-tls-compose.service}"
legacy_tls_service_name="${LOCALAI_TLS_LEGACY_SERVICE_NAME:-localai-tls.service}"
tls_compose_project_name="${LOCALAI_TLS_COMPOSE_PROJECT_NAME:-localai-tls}"
tls_forward_service_name="${LOCALAI_TLS_FORWARD_SERVICE_NAME:-localai-tls-forward.service}"
tls_forward_socket_name="${LOCALAI_TLS_FORWARD_SOCKET_NAME:-localai-tls-forward.socket}"
tls_legacy_selinux_module="${LOCALAI_TLS_LEGACY_SELINUX_MODULE:-localai_tls_forward}"
tls_bind_selinux_module="${LOCALAI_TLS_BIND_SELINUX_MODULE:-localai_tls_forward_bind}"
tls_bind_selinux_module_prefix="localai-tls-forward-bind."
tls_container_name="${LOCALAI_TLS_CONTAINER_NAME:-localai-tls}"

localai_installer_select_config "$canonical_config" "$requested_config" /etc/localai.conf "$repo_root/config/localai.conf" "$lock_file" || {
  localai_installer_error "cannot select a safe LocalAI configuration source"
  exit 1
}
localai_installer_load_config "$LOCALAI_INSTALLER_CONFIG_SOURCE" "$LOCALAI_INSTALLER_CONFIG_FORMAT" || {
  localai_installer_error "invalid LocalAI configuration"
  exit 1
}
tls_user="$LOCALAI_TLS_USER"
tls_state_dir="$LOCALAI_TLS_STATE_DIR"
localai_state_dir="$LOCALAI_STATE_DIR"
tls_config_dir="${LOCALAI_TLS_CONFIG_DIR:-$tls_state_dir/caddy}"
tls_cache_dir="${LOCALAI_TLS_CACHE_DIR:-$tls_state_dir/cache}"
tls_certs_dir="${LOCALAI_TLS_CERT_DIR:-$tls_state_dir/certs}"
tls_compose_dir="${LOCALAI_TLS_COMPOSE_DIR:-$tls_state_dir/.local/share/localai-tls-compose}"
tls_compose_file_name="${LOCALAI_TLS_COMPOSE_FILE_NAME:-localai-tls-compose.yaml}"
tls_service_name="$LOCALAI_TLS_SERVICE_NAME"
legacy_tls_service_name="${LOCALAI_TLS_LEGACY_SERVICE_NAME:-localai-tls.service}"
tls_compose_project_name="${LOCALAI_TLS_COMPOSE_PROJECT_NAME:-localai-tls}"
tls_forward_service_name="$LOCALAI_TLS_FORWARD_SERVICE_NAME"
tls_forward_socket_name="$LOCALAI_TLS_FORWARD_SOCKET_NAME"
tls_container_name="$LOCALAI_TLS_CONTAINER_NAME"
remove_user=0
remove_user_confirmed=0
purge_state=0
assume_yes=0

usage() {
  cat <<'EOF'
Usage:
  ./uninstall.sh [options]

Uninstalls the Compose-based LocalAI TLS reverse proxy.

Default behavior:
  - stop and disable localai-tls-compose user service and public socket proxy
  - remove the user unit and compose definition
  - remove TLS state in /var/lib/localai-tls/cache and config if --purge-state is set
  - preserve TLS state/certs unless --purge-state is set

Options:
  -y, --yes       Do not prompt for destructive options.
  --purge-state   Remove TLS state/cache, including Caddy volumes.
  --remove-user   Confirm and terminate all TLS service-user processes, then remove the service user.
  --all           Remove unit, config, state/cache, and service user; confirms account-wide process termination.
  -h, --help      Show this help.
EOF
}

log() {
  printf '==> %s\n' "$*"
}

yaml_quote() {
  local value="$1"
  value="${value//\'/\'\'}"
  printf "'%s'" "$value"
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

validate_names() {
  validate_identifier "$tls_compose_file_name" "LOCALAI_TLS_COMPOSE_FILE_NAME"
  validate_identifier "$tls_service_name" "LOCALAI_TLS_SERVICE_NAME"
  validate_identifier "$tls_forward_service_name" "LOCALAI_TLS_FORWARD_SERVICE_NAME"
  validate_identifier "$tls_forward_socket_name" "LOCALAI_TLS_FORWARD_SOCKET_NAME"
  validate_identifier "$tls_compose_project_name" "LOCALAI_TLS_COMPOSE_PROJECT_NAME"
  validate_abs_path "$tls_state_dir" "LOCALAI_TLS_STATE_DIR"
  validate_abs_path "$tls_config_dir" "LOCALAI_TLS_CONFIG_DIR"
  validate_abs_path "$tls_cache_dir" "LOCALAI_TLS_CACHE_DIR"
  validate_abs_path "$tls_certs_dir" "LOCALAI_TLS_CERT_DIR"
  validate_abs_path "$tls_compose_dir" "LOCALAI_TLS_COMPOSE_DIR"
  localai_installer_validate_service_account_name "$tls_user" "LOCALAI_TLS_USER" || return 1
  localai_installer_validate_managed_path "$localai_state_dir" "LOCALAI_STATE_DIR" || return 1
  localai_installer_validate_managed_path "$tls_state_dir" "LOCALAI_TLS_STATE_DIR" || return 1
  local path
  for path in "$tls_config_dir" "$tls_cache_dir" "$tls_certs_dir" "$tls_compose_dir"; do
    localai_installer_validate_managed_path "$path" "TLS managed path" || return 1
  done
  [[ "$tls_state_dir" != "$localai_state_dir" && "$tls_state_dir" != "$localai_state_dir/"* && "$localai_state_dir" != "$tls_state_dir/"* ]] || die "TLS and LocalAI service state directories must be separate."
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
    LOCALAI_TLS_LEGACY_SERVICE_NAME LOCALAI_TLS_LEGACY_SELINUX_MODULE \
    LOCALAI_TLS_BIND_SELINUX_MODULE; do
    if value="$(printenv "$key" 2>/dev/null)"; then config_env+=("$key=$value"); fi
  done
  log "Elevating once with run0. Further root steps will run inside this session."
  exec run0 -i \
    /usr/bin/env \
    "${config_env[@]}" \
    "LOCALAI_ASSET_DIR=$asset_dir" \
    "LOCALAI_CONFIG_FILE=$requested_config" \
    /usr/bin/bash "$script_dir/uninstall.sh" "${original_args[@]}"
}

resolve_tls_user() {
  if getent passwd "$tls_user" >/dev/null; then
    tls_uid="$(localai_installer_validate_existing_service_account "$tls_user" "$tls_state_dir" "TLS proxy service")" || die "Refusing unsafe TLS account reuse or removal."
  else
    tls_uid=""
  fi
}

preflight_removal_targets() {
  local user_unit="$tls_state_dir/.config/systemd/user/$tls_service_name"
  local legacy_unit="$tls_state_dir/.config/systemd/user/$legacy_tls_service_name"
  local compose_file="$tls_compose_dir/$tls_compose_file_name"
  local caddyfile="$tls_config_dir/Caddyfile"
  local expected_uid="${tls_uid:-0}"
  local path

  if [[ -e "$tls_state_dir" || -L "$tls_state_dir" ]]; then
    localai_installer_check_directory_chain "$tls_state_dir" "LOCALAI_TLS_STATE_DIR" "$expected_uid" || die "Unsafe TLS state path."
  fi
  for path in "$tls_state_dir/.config/systemd/user" "$tls_compose_dir" "$tls_config_dir"; do
    if [[ -e "$path" || -L "$path" ]]; then
      localai_installer_check_directory_chain "$path" "TLS removal directory" "$expected_uid" || die "Unsafe TLS removal path: $path"
    fi
  done

  localai_installer_check_managed_file "$user_unit" "TLS user unit" "$expected_uid" \
    '# Managed by LocalAI secureblue TLS installer.' 'Description=LocalAI TLS reverse proxy compose stack' || die "Refusing to remove an unrelated TLS user unit."
  if [[ "$legacy_tls_service_name" != "$tls_service_name" ]]; then
    localai_installer_check_managed_file "$legacy_unit" "legacy TLS user unit" "$expected_uid" \
      '# Managed by LocalAI secureblue TLS installer.' 'Description=LocalAI TLS reverse proxy' || die "Refusing to remove an unrelated legacy TLS unit."
  fi
  localai_installer_check_managed_file "$compose_file" "TLS compose definition" "$expected_uid" \
    '# Managed by LocalAI secureblue TLS installer.' "container_name: $(yaml_quote "$tls_container_name")" || die "Refusing to remove an unrelated Compose definition."
  localai_installer_check_managed_file "$caddyfile" "Caddyfile" "$expected_uid" \
    '# Managed by LocalAI secureblue TLS installer.' "    storage file_system $tls_state_dir/caddy" || die "Refusing to remove an unrelated Caddyfile."
  localai_installer_check_managed_file "/etc/systemd/system/$tls_forward_service_name" "TLS host socket-proxy unit" 0 \
    '# Managed by LocalAI secureblue TLS installer.' 'Description=LocalAI HTTPS socket proxy' || die "Refusing to remove an unrelated host unit."
  localai_installer_check_managed_file "/etc/systemd/system/$tls_forward_socket_name" "TLS host socket unit" 0 \
    '# Managed by LocalAI secureblue TLS installer.' 'Description=LocalAI HTTPS socket' || die "Refusing to remove an unrelated host unit."
}

tls_runtime_dir() {
  printf '/run/user/%s\n' "$tls_uid"
}

run_as_tls() {
  [[ -n "$tls_uid" ]] || return 0
  local -a command=(/usr/bin/systemd-run --user --machine="$tls_user@.host" --wait --pipe --collect
    --setenv=HOME="$tls_state_dir"
    --setenv=XDG_RUNTIME_DIR="$(tls_runtime_dir)"
    --setenv=DBUS_SESSION_BUS_ADDRESS="unix:path=$(tls_runtime_dir)/bus"
    --setenv=PATH=/usr/bin:/bin
    -- "$@")
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then "${command[@]}"; else run0 -i "${command[@]}"; fi
}

run_tls_unit() {
  [[ -n "$tls_uid" ]] || return 0
  run_as_tls "$@"
}

stop_service() {
  if [[ -f "/etc/systemd/system/$tls_forward_socket_name" ]]; then
    log "Disabling and stopping public HTTPS socket proxy if present"
    run0_pipe /usr/bin/systemctl disable --now "$tls_forward_socket_name" || true
  fi
  if [[ -f "/etc/systemd/system/$tls_forward_service_name" ]]; then
    run0_pipe /usr/bin/systemctl stop "$tls_forward_service_name" || true
  fi

  if [[ -n "${tls_uid:-}" ]]; then
    if [[ -f "$tls_state_dir/.config/systemd/user/$tls_service_name" ]]; then
      log "Disabling and stopping $tls_service_name in the $tls_user user manager if present"
      run_as_tls /usr/bin/systemctl --user disable --now "$tls_service_name" || true
    fi
    if [[ "$legacy_tls_service_name" != "$tls_service_name" ]]; then
      if [[ -f "$tls_state_dir/.config/systemd/user/$legacy_tls_service_name" ]]; then
        log "Disabling legacy direct-Caddy unit $legacy_tls_service_name if present"
        run_as_tls /usr/bin/systemctl --user disable --now "$legacy_tls_service_name" || true
      fi
    fi
  fi
}

confirm_tls_service_account_removal() {
  [[ "$remove_user" == "1" && -n "$tls_uid" ]] || return 0
  confirm "Remove dedicated TLS service account $tls_user? This terminates every process running as the account, including unrelated containers and services, before removing the account." || die "TLS service-account removal was not confirmed."
  remove_user_confirmed=1
}

remove_container() {
  local compose_file="$tls_compose_dir/$tls_compose_file_name"
  if [[ -n "${tls_uid:-}" && -r "$compose_file" && -f "$compose_file" ]]; then
    log "Removing managed compose stack $tls_compose_project_name if present"
    run_tls_unit /usr/bin/podman compose -p "$tls_compose_project_name" -f "$compose_file" down || true
  elif [[ -n "${tls_uid:-}" ]]; then
    log "No managed compose definition found; preserving any container named $tls_container_name."
  fi
}

remove_unit_and_config() {
  local user_unit="$tls_state_dir/.config/systemd/user/$tls_service_name"
  local compose_file="$tls_compose_dir/$tls_compose_file_name"
  log "Removing TLS proxy unit and compose artifacts"
  if [[ -e "$user_unit" ]]; then
    localai_installer_check_managed_file "$user_unit" "TLS user unit" "${tls_uid:-0}" \
      '# Managed by LocalAI secureblue TLS installer.' 'Description=LocalAI TLS reverse proxy compose stack' || die "Refusing to remove an unrelated TLS unit."
    run0_pipe /usr/bin/rm -f -- "$user_unit"
  fi
  if [[ "$legacy_tls_service_name" != "$tls_service_name" ]]; then
    local legacy_unit="$tls_state_dir/.config/systemd/user/$legacy_tls_service_name"
    if [[ -e "$legacy_unit" ]]; then
      localai_installer_check_managed_file "$legacy_unit" "legacy TLS user unit" "${tls_uid:-0}" \
        '# Managed by LocalAI secureblue TLS installer.' 'Description=LocalAI TLS reverse proxy' || die "Refusing to remove an unrelated legacy TLS unit."
      run0_pipe /usr/bin/rm -f -- "$legacy_unit"
    fi
  fi
  if [[ -e "$compose_file" ]]; then
    localai_installer_check_managed_file "$compose_file" "TLS compose definition" "${tls_uid:-0}" \
      '# Managed by LocalAI secureblue TLS installer.' "container_name: $(yaml_quote "$tls_container_name")" || die "Refusing to remove an unrelated Compose definition."
    run0_pipe /usr/bin/rm -f -- "$compose_file"
  fi
  if [[ -e "$tls_config_dir/Caddyfile" ]]; then
    localai_installer_check_managed_file "$tls_config_dir/Caddyfile" "Caddyfile" "${tls_uid:-0}" \
      '# Managed by LocalAI secureblue TLS installer.' "    storage file_system $tls_state_dir/caddy" || die "Refusing to remove an unrelated Caddyfile."
    run0_pipe /usr/bin/rm -f -- "$tls_config_dir/Caddyfile"
  fi
  if [[ -n "${tls_uid:-}" ]]; then
    run_as_tls /usr/bin/systemctl --user daemon-reload || true
  fi

  if [[ -e "/etc/systemd/system/$tls_forward_service_name" ]]; then
    localai_installer_check_managed_file "/etc/systemd/system/$tls_forward_service_name" "TLS host socket-proxy unit" 0 \
      '# Managed by LocalAI secureblue TLS installer.' 'Description=LocalAI HTTPS socket proxy' || die "Refusing to remove an unrelated host unit."
    run0_pipe /usr/bin/rm -f -- "/etc/systemd/system/$tls_forward_service_name"
  fi
  if [[ -e "/etc/systemd/system/$tls_forward_socket_name" ]]; then
    localai_installer_check_managed_file "/etc/systemd/system/$tls_forward_socket_name" "TLS host socket unit" 0 \
      '# Managed by LocalAI secureblue TLS installer.' 'Description=LocalAI HTTPS socket' || die "Refusing to remove an unrelated host unit."
    run0_pipe /usr/bin/rm -f -- "/etc/systemd/system/$tls_forward_socket_name"
  fi
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

restore_one_selinux_port_label() {
  local role="$1"
  local state_file state action="" port="" previous_type="" new_type="" current_type
  state_file="$(selinux_port_state_file "$role")" || die "Invalid SELinux metadata role."
  [[ -e "$state_file" || -L "$state_file" ]] || return 0
  command -v semanage >/dev/null 2>&1 || return 0

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

restore_selinux_port_labels() {
  local module
  restore_one_selinux_port_label "public"
  restore_one_selinux_port_label "internal"

  if command -v semodule >/dev/null 2>&1; then
    while IFS= read -r module; do
      [[ -n "$module" ]] || continue
      log "Removing local SELinux module $module"
      run0_pipe semodule -r "$module" || true
    done < <(
      semodule -l | awk \
        -v stable="$tls_bind_selinux_module" \
        -v random_prefix="$tls_bind_selinux_module_prefix" \
        '$1 == stable || index($1, random_prefix) == 1 { print $1 }'
    )
    if semodule -l | awk -v module="$tls_legacy_selinux_module" '$1 == module { found = 1 } END { exit found ? 0 : 1 }'; then
      log "Removing legacy local SELinux module $tls_legacy_selinux_module"
      run0_pipe semodule -r "$tls_legacy_selinux_module" || true
    fi
  fi
}

remove_state() {
  [[ "$purge_state" == "1" ]] || return 0
  local expected_uid="${tls_uid:-0}"
  local path
  local -a paths=(
    "$tls_state_dir" "$tls_cache_dir" "$tls_certs_dir" "$tls_config_dir"
    "$tls_compose_dir" "$tls_state_dir/data" "$tls_state_dir/config"
    "$tls_state_dir/app-home" "$tls_state_dir/caddy"
  )
  for path in "${paths[@]}"; do
    localai_installer_validate_managed_path "$path" "TLS state path" || die "Refusing unsafe TLS purge path: $path"
    if [[ -d "$path" ]]; then
      localai_installer_check_directory_chain "$path" "TLS state path" "$expected_uid" || die "Refusing to purge unsafe TLS state: $path"
    elif [[ -e "$path" || -L "$path" ]]; then
      die "Refusing to purge a TLS state path that is not a real directory: $path"
    fi
  done

  confirm "Remove TLS proxy state/cache, including Caddy storage?" || return 0
  log "Removing TLS proxy state/cache"
  local -a unique_paths=()
  local seen duplicate

  for path in "${paths[@]}"; do
    duplicate=
    for seen in "${unique_paths[@]}"; do
      if [[ "$path" == "$seen" ]]; then
        duplicate=1
        break
      fi
    done
    if [[ -n "$duplicate" ]]; then
      continue
    fi
    unique_paths+=("$path")
    if [[ -d "$path" ]]; then
      localai_installer_check_directory_chain "$path" "TLS state path" "$expected_uid" || die "Refusing to purge unsafe TLS state: $path"
    fi
    run0_pipe /usr/bin/rm -rf --one-file-system "$path"
  done
}

disable_tls_lifecycle_config() {
  [[ -f "$canonical_config" ]] || return 0
  localai_installer_update_config "$canonical_config" LOCALAI_TLS_ENABLED false || die "Could not update TLS lifecycle config."
}

disable_tls_user_linger() {
  [[ "$remove_user" == "1" ]] || return 0
  [[ -n "$tls_uid" ]] || return 0
  [[ "$remove_user_confirmed" == "1" ]] || die "Refusing to terminate TLS service-account processes without prior confirmation."

  log "Disabling linger for service user $tls_user"
  run0_pipe /usr/bin/loginctl disable-linger "$tls_user" || true
  log "Terminating all processes for the explicitly approved TLS service account removal"
  run0_pipe /usr/bin/loginctl terminate-user "$tls_user" || true
}

remove_tls_user() {
  [[ "$remove_user" == "1" ]] || return 0
  if getent passwd "$tls_user" >/dev/null; then
    [[ "$remove_user_confirmed" == "1" ]] || die "Refusing TLS service-account deletion without prior confirmation."
    log "Removing service user $tls_user"
    run0_pipe /usr/sbin/userdel "$tls_user" || true
  fi
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -y|--yes)
      assume_yes=1
      ;;
    --purge-state)
      purge_state=1
      ;;
    --remove-user)
      remove_user=1
      ;;
    --all)
      purge_state=1
      remove_user=1
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

elevate_once
resolve_tls_user
validate_names
preflight_removal_targets
confirm_tls_service_account_removal
stop_service
remove_container
remove_unit_and_config
restore_selinux_port_labels
disable_tls_lifecycle_config
remove_state
disable_tls_user_linger
remove_tls_user
log "Compose-based TLS proxy uninstall complete."
