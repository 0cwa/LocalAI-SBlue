#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
asset_dir="${LOCALAI_ASSET_DIR:-$repo_root/localai}"
lock_file="$asset_dir/localai.lock"
config_lib="${LOCALAI_CONFIG_LIB:-$repo_root/lib/config.sh}"
source "$config_lib"
safety_lib="${LOCALAI_INSTALLER_SAFETY_LIB:-$repo_root/lib/installer_safety.sh}"
source "$safety_lib"
canonical_config="$LOCALAI_INSTALLER_CONFIG_DEST"
requested_config="${LOCALAI_CONFIG_FILE:-}"
original_args=("$@")
LOCALAI_INSTALLER_VALIDATED_CONTAINER_IDS=()
trap localai_installer_cleanup_temps EXIT

service_user="${LOCALAI_SERVICE_USER:-localai}"
state_dir="${LOCALAI_STATE_DIR:-/var/lib/localai}"
project_dir="${LOCALAI_PROJECT_DIR:-$state_dir/build/localai-oci}"

localai_installer_select_config "$canonical_config" "$requested_config" /etc/localai.conf "$repo_root/config/localai.conf" "$lock_file" || {
  localai_installer_error "cannot select a safe LocalAI configuration source"
  exit 1
}
localai_installer_load_config "$LOCALAI_INSTALLER_CONFIG_SOURCE" "$LOCALAI_INSTALLER_CONFIG_FORMAT" || {
  localai_installer_error "invalid LocalAI configuration"
  exit 1
}
service_user="$LOCALAI_SERVICE_USER"
state_dir="$LOCALAI_STATE_DIR"
project_dir="${LOCALAI_PROJECT_DIR:-$state_dir/build/localai-oci}"
SERVICE_BIND_HOST="$LOCALAI_BIND_HOST"
SERVICE_BIND_PORT="$LOCALAI_BIND_PORT"

image_ref="${LOCALAI_IMAGE_REF_OVERRIDE:-${LOCALAI_IMAGE_REF:-docker.io/localai/localai:latest-gpu-hipblas}}"
if [[ -n "${LOCALAI_IMAGE_DIGEST:-}" ]]; then
  image_ref="${image_ref%@*}@${LOCALAI_IMAGE_DIGEST}"
fi
container_name="${LOCALAI_CONTAINER_NAME:-localai}"

remove_image=0
remove_project=0
purge_state=0
remove_user=0
remove_user_confirmed=0
remove_subids=0
disable_linger=0
assume_yes=0
purge_state_confirmed=0

usage() {
  cat <<'EOF'
Usage:
  ./uninstall.sh [options]

Uninstalls the LocalAI rootless secureblue service.

Default behavior is conservative:
  - stop and disable localai.service in the localai user manager
  - remove the localai user service
  - remove the running localai container if present
  - preserve images, models, state, user, and subuid/subgid entries

Options:
  -y, --yes          Do not prompt for destructive options.
  --remove-image    Remove the image if no containers are using it; it never removes containers.
  --remove-project  Remove only the installed project copy under build/.
  --purge-state     Remove the entire LocalAI state directory.
  --disable-linger  Disable linger for the service user without terminating its processes.
  --remove-subids   Remove subuid/subgid entries for the service user.
  --remove-user     Confirm and terminate all service-user processes, then remove the service user.
  --all             Remove image, state, linger, subids, and user; confirms account-wide process termination.
  -h, --help        Show this help.

Environment:
  LOCALAI_SERVICE_USER  Default: localai
  LOCALAI_STATE_DIR     Default: /var/lib/localai
  LOCALAI_PROJECT_DIR   Default: /var/lib/localai/build/localai-oci
  LOCALAI_ASSET_DIR     Default: ../localai relative to this uninstaller
  LOCALAI_IMAGE_REF_OVERRIDE
                         Override LOCALAI_IMAGE_REF from localai.lock.
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

run0_pipe() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  else
    run0 -i "$@"
  fi
}

elevate_once() {
  local key
  local -a config_env=()
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    return 0
  fi

  require_cmd run0
  for key in "${!LOCALAI_CONFIG_ENV_OVERRIDES[@]}"; do
    config_env+=("$key=${LOCALAI_CONFIG_ENV_OVERRIDES[$key]}")
  done
  if [[ -n "${LOCALAI_PROJECT_DIR+x}" ]]; then
    config_env+=("LOCALAI_PROJECT_DIR=$LOCALAI_PROJECT_DIR")
  fi
  log "Elevating once with run0. Further root steps will run inside this session."
  exec run0 -i \
    /usr/bin/env \
    "${config_env[@]}" \
    "LOCALAI_ASSET_DIR=$asset_dir" \
    "LOCALAI_CONFIG_FILE=$requested_config" \
    "LOCALAI_IMAGE_REF_OVERRIDE=${LOCALAI_IMAGE_REF_OVERRIDE-}" \
    /usr/bin/bash "$script_dir/uninstall.sh" "${original_args[@]}"
}

resolve_user() {
  if getent passwd "$service_user" >/dev/null; then
    service_uid="$(localai_installer_validate_existing_service_account "$service_user" "$state_dir" "LocalAI service")" || die "Refusing unsafe account reuse or removal."
  else
    service_uid=""
  fi
}

confirm_service_account_removal() {
  [[ "$remove_user" == "1" && -n "$service_uid" ]] || return 0
  confirm "Remove dedicated service account $service_user? This terminates every process running as the account, including unrelated containers and services, before removing the account." || die "Service-account removal was not confirmed."
  remove_user_confirmed=1
}

preflight_removal_targets() {
  local expected_uid="${service_uid:-0}"
  local user_unit="$state_dir/.config/systemd/user/localai.service"
  local unit_dir="$state_dir/.config/systemd/user"
  if [[ -e "$state_dir" || -L "$state_dir" ]]; then
    localai_installer_check_directory_chain "$state_dir" "LOCALAI_STATE_DIR" "$expected_uid" || die "Unsafe LocalAI state path."
  fi
  if [[ -e "$unit_dir" || -L "$unit_dir" ]]; then
    localai_installer_check_directory_chain "$unit_dir" "LocalAI user-unit directory" "$expected_uid" || die "Unsafe LocalAI user-unit path."
  fi
  localai_installer_check_managed_file "$user_unit" "LocalAI user unit" "$expected_uid" \
    '# Managed by LocalAI secureblue installer.' 'Description=LocalAI OpenAI-compatible API and web UI container' || die "Refusing to remove an unrelated LocalAI user unit."
  if [[ "$remove_project" == "1" && "$purge_state" != "1" && -e "$project_dir" ]]; then
    [[ -n "$service_uid" ]] || die "Cannot verify project ownership without the service account."
    localai_installer_check_directory_chain "$project_dir" "LOCALAI_PROJECT_DIR" "$service_uid" || die "Unsafe LocalAI project path."
  fi
}

user_runtime_dir() {
  printf '/run/user/%s\n' "$service_uid"
}

run_as_localai() {
  [[ -n "$service_uid" ]] || return 0
  local -a command=(/usr/bin/systemd-run --user --machine="$service_user@.host" --wait --pipe --collect
    --setenv=HOME="$state_dir"
    --setenv=XDG_RUNTIME_DIR="$(user_runtime_dir)"
    --setenv=DBUS_SESSION_BUS_ADDRESS="unix:path=$(user_runtime_dir)/bus"
    --setenv=PATH=/usr/bin:/bin
    -- "$@")
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then "${command[@]}"; else run0 -i "${command[@]}"; fi
}

run_localai_unit() {
  [[ -n "$service_uid" ]] || return 0
  run_as_localai "$@"
}

preflight_backend_state() {
  [[ -n "$service_uid" ]] || return 0
  if [[ "$purge_state" == 1 ]]; then
    if confirm "Permanently remove all LocalAI state at $state_dir, including models/config/data?"; then
      purge_state_confirmed=1
    fi
    if [[ "$purge_state_confirmed" != 1 ]]; then
      purge_state=0
    fi
  fi
  local service_unit="$state_dir/.config/systemd/user/localai.service"
  local storage_root="$state_dir/.local/share/containers/storage"
  local storage_config="$state_dir/.config/containers/storage.conf"
  local manager_active=0 manager_status=0 old_name
  local -a container_names=("${LOCALAI_CONTAINER_NAME:-localai}")
  localai_installer_validate_identifier "${LOCALAI_CONTAINER_NAME:-localai}" "LOCALAI_CONTAINER_NAME" || die "Unsafe LocalAI container name."
  if [[ -e "$service_unit" || -L "$service_unit" ]]; then
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
  if localai_installer_user_manager_is_active "$service_uid"; then
    manager_active=1
  else
    manager_status=$?
    [[ "$manager_status" -eq 3 ]] || die "Could not determine whether the LocalAI user manager is active."
  fi
  if [[ "$manager_active" == 0 ]]; then
    if [[ -e "$storage_root" || -e "$storage_config" || -e "$service_unit" ]]; then
      die "Existing LocalAI Podman state cannot be inspected while its user manager is inactive; refusing to stop or terminate it. Inventory and back up all containers and volumes for this account, stop every running container, run 'podman system migrate' manually as $service_user only if Podman requires it, then retry."
    fi
    return 0
  fi
  localai_installer_preflight_backend_containers run_as_localai \
    "${LOCALAI_BACKENDS_PATH:-$state_dir/backends}" "$service_uid" "$state_dir" "${container_names[@]}" || die "LocalAI backend state is not safe to stop or remove."
}

subid_lines() {
  local file="$1"
  awk -F: -v user="$service_user" '$1 == user { print }' "$file" 2>/dev/null || true
}

stop_service() {
  if [[ -n "$service_uid" ]]; then
    log "Disabling and stopping localai.service in the $service_user user manager if present"
    run_as_localai /usr/bin/systemctl --user disable --now localai.service || true
  fi
}

remove_unit() {
  local user_unit="$state_dir/.config/systemd/user/localai.service"
  if [[ -e "$user_unit" ]]; then
    localai_installer_check_managed_file "$user_unit" "LocalAI user unit" "$service_uid" \
      '# Managed by LocalAI secureblue installer.' \
      'Description=LocalAI OpenAI-compatible API and web UI container' || die "Refusing to remove an unrelated user unit."
    log "Removing $user_unit"
    run0_pipe /usr/bin/rm -f "$user_unit"
    if [[ -n "$service_uid" ]]; then
      run_as_localai /usr/bin/systemctl --user daemon-reload || true
    fi
  fi
}

remove_container() {
  if [[ -z "$service_uid" ]]; then
    return 0
  fi

  local container_id
  for container_id in "${LOCALAI_INSTALLER_VALIDATED_CONTAINER_IDS[@]}"; do
    log "Removing preflight-checked LocalAI container $container_id"
    run_localai_unit /usr/bin/podman rm -f "$container_id" || true
  done
}

remove_local_image() {
  if [[ "$remove_image" != "1" || -z "$service_uid" ]]; then
    return 0
  fi

  confirm "Remove image $image_ref for $service_user if no containers are using it?" || return 0
  log "Removing image $image_ref without removing any containers"
  if ! run_localai_unit /usr/bin/podman image rm "$image_ref"; then
    log "Podman retained the image; review its message. No containers were force-removed."
  fi
}

remove_installed_project() {
  if [[ "$remove_project" != "1" || "$purge_state" == "1" ]]; then
    return 0
  fi

  confirm "Remove installed project directory $project_dir?" || return 0
  [[ -n "$service_uid" ]] || die "Cannot verify ownership of the project directory without the service account."
  localai_installer_check_directory_chain "$project_dir" "LOCALAI_PROJECT_DIR" "$service_uid" || die "Refusing to remove an unsafe project path."
  log "Removing installed project directory"
  run0_pipe /usr/bin/rm -rf --one-file-system "$project_dir"
}

remove_state_dir() {
  if [[ "$purge_state" != "1" ]]; then
    return 0
  fi
  localai_installer_validate_managed_path "$state_dir" "LOCALAI_STATE_DIR" || die "Refusing to purge an unsafe state directory."
  if [[ -d "$state_dir" ]]; then
    localai_installer_check_directory_chain "$state_dir" "LOCALAI_STATE_DIR" "${service_uid:-0}" || die "Refusing to purge a state directory with unsafe ownership or path components."
  elif [[ -e "$state_dir" || -L "$state_dir" ]]; then
    die "Refusing to purge a state path that is not a real directory: $state_dir"
  fi

  if [[ "$purge_state_confirmed" != 1 ]]; then
    confirm "Permanently remove all LocalAI state at $state_dir, including models/config/data?" || return 0
  fi
  log "Removing state directory $state_dir"
  run0_pipe /usr/bin/rm -rf --one-file-system "$state_dir"
}

disable_user_linger() {
  if [[ "$disable_linger" != "1" && "$remove_user" != "1" ]]; then
    return 0
  fi
  if [[ -z "$service_uid" ]]; then
    return 0
  fi
  if [[ "$remove_user" == "1" ]]; then
    [[ "$remove_user_confirmed" == "1" ]] || die "Refusing to terminate service-account processes without prior confirmation."
  fi

  log "Disabling linger for $service_user"
  run0_pipe /usr/bin/loginctl disable-linger "$service_user" || true
  if [[ "$remove_user" == "1" ]]; then
    log "Terminating all processes for the explicitly approved service account removal"
    run0_pipe /usr/bin/loginctl terminate-user "$service_user" || true
  fi
}

remove_user_subids() {
  local subuids subgids
  if [[ "$remove_subids" != "1" ]]; then
    return 0
  fi

  subuids="$(subid_lines /etc/subuid)"
  subgids="$(subid_lines /etc/subgid)"
  if [[ -z "$subuids" && -z "$subgids" ]]; then
    log "No subuid/subgid entries found for $service_user."
    return 0
  fi

  printf '%s\n%s\n' "$subuids" "$subgids" | sed '/^$/d'
  confirm "Remove all subuid/subgid entries shown above for $service_user?" || return 0

  if [[ -n "$subuids" ]]; then
    while IFS=: read -r _ start count; do
      [[ -n "${start:-}" && -n "${count:-}" ]] || continue
      run0_pipe /usr/sbin/usermod --del-subuids "$start-$((start + count - 1))" "$service_user" || true
    done <<<"$subuids"
  fi

  if [[ -n "$subgids" ]]; then
    while IFS=: read -r _ start count; do
      [[ -n "${start:-}" && -n "${count:-}" ]] || continue
      run0_pipe /usr/sbin/usermod --del-subgids "$start-$((start + count - 1))" "$service_user" || true
    done <<<"$subgids"
  fi
}

remove_service_user() {
  if [[ "$remove_user" != "1" ]]; then
    return 0
  fi
  if [[ -z "$service_uid" ]]; then
    log "User $service_user does not exist."
    return 0
  fi

  [[ "$remove_user_confirmed" == "1" ]] || die "Refusing service-account deletion without prior confirmation."
  log "Removing user $service_user"
  run0_pipe /usr/sbin/userdel "$service_user" || true
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -y|--yes)
      assume_yes=1
      ;;
    --remove-image)
      remove_image=1
      ;;
    --remove-project)
      remove_project=1
      ;;
    --purge-state)
      purge_state=1
      ;;
    --disable-linger)
      disable_linger=1
      ;;
    --remove-subids)
      remove_subids=1
      ;;
    --remove-user)
      remove_user=1
      disable_linger=1
      ;;
    --all)
      remove_image=1
      purge_state=1
      disable_linger=1
      remove_subids=1
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

localai_installer_validate_service_account_name "$service_user" "LOCALAI_SERVICE_USER" || die "Unsafe LocalAI service account name."
localai_installer_validate_managed_path "$state_dir" "LOCALAI_STATE_DIR" || die "Unsafe LocalAI state path."
localai_installer_validate_managed_path "$project_dir" "LOCALAI_PROJECT_DIR" || die "Unsafe LocalAI project path."
[[ "$project_dir" == "$state_dir/"* ]] || die "LOCALAI_PROJECT_DIR must be inside LOCALAI_STATE_DIR."

elevate_once
require_cmd run0
resolve_user
localai_installer_validate_service_account_name "$service_user" "LOCALAI_SERVICE_USER" || die "Unsafe LocalAI service account name."
localai_installer_validate_managed_path "$state_dir" "LOCALAI_STATE_DIR" || die "Unsafe LocalAI state path."
localai_installer_validate_managed_path "$project_dir" "LOCALAI_PROJECT_DIR" || die "Unsafe LocalAI project path."
[[ "$project_dir" == "$state_dir/"* ]] || die "LOCALAI_PROJECT_DIR must be inside LOCALAI_STATE_DIR."
preflight_removal_targets
preflight_backend_state
confirm_service_account_removal

stop_service
remove_unit
remove_container
remove_local_image
remove_installed_project
remove_user_subids
disable_user_linger
remove_state_dir
remove_service_user

log "Uninstall complete."
