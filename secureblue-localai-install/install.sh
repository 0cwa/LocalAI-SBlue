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
localai_install_exit() {
  local status="$1"
  trap - EXIT
  if [[ "$status" != 0 && "${existing_service_stopped:-0}" == 1 ]]; then
    log "Upgrade failed; attempting to restore the previously running localai.service" || :
    if ! run_as_localai /usr/bin/systemctl --user start localai.service; then
      printf 'Failed to restore the previously running localai.service; inspect its user service state.\n' >&2 || :
    fi
  fi
  localai_installer_cleanup_temps || :
  exit "$status"
}
canonical_config="$LOCALAI_INSTALLER_CONFIG_DEST"
requested_config="${LOCALAI_CONFIG_FILE:-}"
original_args=("$@")
LOCALAI_INSTALLER_VALIDATED_CONTAINER_IDS=()
trap 'localai_install_exit "$?"' EXIT

service_user="${LOCALAI_SERVICE_USER:-localai}"
state_dir="${LOCALAI_STATE_DIR:-/var/lib/localai}"
project_dir="${LOCALAI_PROJECT_DIR:-$state_dir/build/localai-oci}"
subid_count="${LOCALAI_SUBID_COUNT:-65536}"
subid_min="${LOCALAI_SUBID_MIN:-1000000}"
run_pull=1
install_service=1
start_service=1
assume_yes=0
enable_container_userns=0
service_user_created=0
existing_service_unit=0
existing_service_active=0
existing_service_stopped=0

usage() {
  cat <<'EOF'
Usage:
  ./install.sh [options]

Installs the rootless LocalAI service on a secureblue host using run0.

Options:
  -y, --yes          Do not prompt before adding subordinate ID ranges.
  --no-pull         Install host state and service files, but do not pull image.
  --no-service      Do not install localai.service.
  --no-start        Install the service but do not enable or start it.
  --enable-container-userns
                    Enable secureblue container-domain user namespaces if needed.
  -h, --help        Show this help.

Environment:
  LOCALAI_SERVICE_USER  Default: localai
  LOCALAI_STATE_DIR     Default: /var/lib/localai
  LOCALAI_PROJECT_DIR   Default: /var/lib/localai/build/localai-oci
  LOCALAI_ASSET_DIR     Default: ../localai relative to this installer
  LOCALAI_BIND_HOST     Default: value from the shared config, then 127.0.0.1
  LOCALAI_BIND_PORT     Default: value from the shared config, then 11455
  LOCALAI_IMAGE_REF_OVERRIDE
                         Override LOCALAI_IMAGE_REF from localai.lock.
  LOCALAI_SUBID_MIN     Default: 1000000
  LOCALAI_SUBID_COUNT   Default: 65536
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
    "LOCALAI_SUBID_MIN=$subid_min" \
    "LOCALAI_SUBID_COUNT=$subid_count" \
    "LOCALAI_IMAGE_REF_OVERRIDE=${LOCALAI_IMAGE_REF_OVERRIDE-}" \
    /usr/bin/bash "$script_dir/install.sh" "${original_args[@]}"
}

user_runtime_dir() {
  printf '/run/user/%s\n' "$service_uid"
}

run_as_localai() {
  local -a command=(/usr/bin/systemd-run --user --machine="$service_user@.host" --wait --pipe --collect
    --setenv=HOME="$state_dir"
    --setenv=XDG_RUNTIME_DIR="$(user_runtime_dir)"
    --setenv=DBUS_SESSION_BUS_ADDRESS="unix:path=$(user_runtime_dir)/bus"
    --setenv=PATH=/usr/bin:/bin
    -- "$@")
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "${command[@]}"
  else
    run0 -i "${command[@]}"
  fi
}

run_localai_unit() {
  run_as_localai "$@"
}

shell_quote() {
  printf '%q' "$1"
}

asset_requirements() {
  local missing=0 file
  for file in \
    "$asset_dir/localai.lock" \
    "$asset_dir/localai-containers-policy.json" \
    "$repo_root/lib/bootstrap_guard.py" \
    "$script_dir/localai.service.in"; do
    if [[ ! -e "$file" ]]; then
      printf 'Missing required file: %s\n' "$file" >&2
      missing=1
    fi
  done
  [[ "$missing" == "0" ]] || exit 1
}

subid_line() {
  local file="$1"
  awk -F: -v user="$service_user" '$1 == user { print }' "$file" 2>/dev/null || true
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

localai_models_path() {
  printf '%s\n' "${LOCALAI_MODELS_PATH:-$state_dir/models}"
}

localai_app_home_path() {
  printf '%s\n' "$state_dir/app-home"
}

localai_backends_path() {
  printf '%s\n' "${LOCALAI_BACKENDS_PATH:-$state_dir/backends}"
}

localai_download_staging_path() {
  printf '%s\n' "${LOCALAI_DOWNLOAD_STAGING_PATH:-$state_dir/downloading}"
}

localai_backend_temp_dir() {
  printf '%s\n' "${LOCALAI_BACKEND_TEMP_DIR:-$state_dir/tmp}"
}

localai_data_path() {
  printf '%s\n' "${LOCALAI_DATA_PATH:-$state_dir/data}"
}

localai_config_dir() {
  printf '%s\n' "${LOCALAI_CONFIG_DIR:-$state_dir/config}"
}

localai_generated_content_path() {
  printf '%s\n' "${LOCALAI_GENERATED_CONTENT_PATH:-$state_dir/generated}"
}

localai_upload_path() {
  printf '%s\n' "${LOCALAI_UPLOAD_PATH:-$state_dir/uploads}"
}

localai_cache_dir() {
  printf '%s\n' "${LOCALAI_CACHE_DIR:-$state_dir/cache}"
}

localai_log_dir() {
  printf '%s\n' "${LOCALAI_LOG_DIR:-$state_dir/logs}"
}

localai_rootless_containers_dir() {
  printf '%s\n' "$state_dir/.local/share/containers"
}

localai_app_data_dirs() {
  {
    localai_app_home_path
    localai_models_path
    localai_backends_path
    localai_download_staging_path
    localai_backend_temp_dir
    localai_data_path
    localai_config_dir
    localai_generated_content_path
    localai_upload_path
    localai_cache_dir
    localai_log_dir
  } | awk 'NF && !seen[$0]++'
}

ensure_service_user() {
  local dirs=("$state_dir") dir
  localai_installer_validate_service_account_name "$service_user" "LOCALAI_SERVICE_USER" || die "Unsafe LocalAI service account name."
  if getent passwd "$service_user" >/dev/null; then
    service_user_created=0
    service_uid="$(localai_installer_validate_existing_service_account "$service_user" "$state_dir" "LocalAI service")" || die "Unsafe existing LocalAI service account."
    log "Using existing user: $service_user"
  else
    localai_installer_check_directory_chain "$state_dir" "LOCALAI_STATE_DIR" 0 || die "Unsafe LocalAI state path."
    log "Creating system user: $service_user"
    run0_pipe /usr/sbin/useradd \
      --system \
      --home-dir "$state_dir" \
      --shell /usr/sbin/nologin \
      "$service_user"
    service_user_created=1
  fi

  service_uid="$(localai_installer_validate_existing_service_account "$service_user" "$state_dir" "LocalAI service")" || die "Could not validate LocalAI service account."
  [[ -n "$service_uid" ]] || die "Could not resolve UID for $service_user"
  log "$service_user UID: $service_uid"

  localai_installer_ensure_service_directory "$state_dir" "LOCALAI_STATE_DIR" "$service_user" "$service_user" "$service_uid" 0750 || die "Unsafe LocalAI state directory."
  while IFS= read -r dir; do
    dirs+=("$dir")
  done < <(localai_app_data_dirs)
  for dir in "${dirs[@]}"; do
    localai_installer_ensure_service_directory "$dir" "LocalAI app data directory" "$service_user" "$service_user" "$service_uid" 0750 || die "Unsafe LocalAI app data directory: $dir"
  done
}

preflight_existing_backend_state() {
  local service_unit="$state_dir/.config/systemd/user/localai.service"
  local manager_active=0 manager_status=0 old_name
  local storage_root="$state_dir/.local/share/containers/storage"
  local storage_config="$state_dir/.config/containers/storage.conf"
  local -a container_names=("${LOCALAI_CONTAINER_NAME:-localai}")
  localai_installer_validate_identifier "${LOCALAI_CONTAINER_NAME:-localai}" "LOCALAI_CONTAINER_NAME" || die "Unsafe LocalAI container name."

  if [[ -e "$service_unit" || -L "$service_unit" ]]; then
    localai_installer_check_directory_chain "${service_unit%/*}" "LocalAI user-unit directory" "$service_uid" || die "Unsafe LocalAI user-unit path."
    localai_installer_check_managed_file "$service_unit" "LocalAI user unit" "$service_uid" \
      '# Managed by LocalAI secureblue installer.' 'Description=LocalAI OpenAI-compatible API and web UI container' || die "Refusing to inspect an unrelated LocalAI user unit."
    existing_service_unit=1
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

  if [[ "$service_user_created" == 1 ]]; then
    if [[ -e "$storage_root" || -e "$storage_config" || "$existing_service_unit" == 1 ]]; then
      die "A new service account would adopt pre-existing LocalAI Podman state; inspect or move that state before retrying."
    fi
    return 0
  fi

  if localai_installer_user_manager_is_active "$service_uid"; then
    manager_active=1
  else
    manager_status=$?
    [[ "$manager_status" -eq 3 ]] || die "Could not determine whether the LocalAI user manager is active."
  fi

  if [[ "$manager_active" == 0 ]]; then
    if [[ -e "$storage_root" || -e "$storage_config" || "$existing_service_unit" == 1 ]]; then
      die "Existing LocalAI Podman state cannot be inspected while its user manager is inactive; refusing any manager start that could auto-start an old --rm service. Inventory and back up all containers and volumes for this account, stop every running container, run 'podman system migrate' manually as $service_user only if Podman requires it, then retry."
    fi
    return 0
  fi

  localai_installer_preflight_backend_containers run_as_localai \
    "$(localai_backends_path)" "$service_uid" "$state_dir" "${container_names[@]}" || die "LocalAI backend state is not safe to stop or replace."
}

snapshot_existing_service_state() {
  local status state attempt
  [[ "$existing_service_unit" == 1 && "$install_service" == 1 ]] || return 0
  for ((attempt=0; attempt<30; attempt++)); do
    status=0
    state="$(run_as_localai /usr/bin/systemctl --user is-active localai.service)" || status=$?
    case "$state:$status" in
      active:0) existing_service_active=1; return 0 ;;
      inactive:3|failed:3) existing_service_active=0; return 0 ;;
      activating:3|deactivating:3|reloading:0|refreshing:0) sleep 1 ;;
      *) die "Cannot upgrade while the existing LocalAI service state is unknown." ;;
    esac
  done
  die "Cannot upgrade while the existing LocalAI service state keeps changing."
}

stop_existing_managed_service() {
  [[ "$existing_service_unit" == 1 && "$existing_service_active" == 1 && "$install_service" == 1 && "$start_service" == 1 ]] || return 0
  log "Stopping the checked existing LocalAI service for upgrade"
  existing_service_stopped=1
  run_as_localai /usr/bin/systemctl --user stop localai.service
}

remove_preflighted_existing_container() {
  [[ "$existing_service_active" == 1 && "$install_service" == 1 && "$start_service" == 1 ]] || return 0
  local container_id
  for container_id in "${LOCALAI_INSTALLER_VALIDATED_CONTAINER_IDS[@]}"; do
    log "Removing preflight-checked LocalAI container $container_id if it remains after service stop"
    run_as_localai /usr/bin/podman rm -f "$container_id" || true
  done
}

ensure_subids() {
  local need_subuid=0 need_subgid=0 range
  local storage_root="$state_dir/.local/share/containers/storage"
  local storage_config="$state_dir/.config/containers/storage.conf"

  if ! has_subid /etc/subuid; then
    need_subuid=1
  fi
  if ! has_subid /etc/subgid; then
    need_subgid=1
  fi

  if [[ "$need_subuid" == "0" && "$need_subgid" == "0" ]]; then
    log "Subordinate IDs already exist for $service_user"
    subid_line /etc/subuid
    subid_line /etc/subgid
    return 0
  fi

  if [[ -e "$storage_root" || -L "$storage_root" || -e "$storage_config" || -L "$storage_config" ]]; then
    die "Existing Podman storage for $service_user needs subordinate IDs. The installer will not change mappings or stop all containers automatically. Inventory and back up this account's containers and volumes, stop every running container for the account, add the required mappings, run 'podman system migrate' manually as $service_user, then retry."
  fi

  range="$(find_common_subid_range)"
  log "Rootless Podman needs subordinate IDs for $service_user."
  log "Proposed non-overlapping range from /etc/subuid and /etc/subgid: $range"

  confirm "Add subordinate UID/GID range $range to $service_user?" || {
    die "Subordinate IDs are required for the rootless service-user design."
  }

  if [[ "$need_subuid" == "1" && "$need_subgid" == "1" ]]; then
    run0_pipe /usr/sbin/usermod --add-subuids "$range" --add-subgids "$range" "$service_user"
  elif [[ "$need_subuid" == "1" ]]; then
    run0_pipe /usr/sbin/usermod --add-subuids "$range" "$service_user"
  else
    run0_pipe /usr/sbin/usermod --add-subgids "$range" "$service_user"
  fi

  subid_line /etc/subuid
  subid_line /etc/subgid
}

ensure_gpu_groups() {
  local groups=()
  if getent group render >/dev/null; then
    groups+=(render)
  else
    log "Group render does not exist; GPU render-node access may fail."
  fi
  if getent group video >/dev/null; then
    groups+=(video)
  else
    log "Group video does not exist; GPU device access may fail."
  fi

  if [[ "${#groups[@]}" -gt 0 ]]; then
    local group_csv
    group_csv="$(IFS=,; printf '%s' "${groups[*]}")"
    log "Adding $service_user to supplementary groups: $group_csv"
    run0_pipe /usr/sbin/usermod -aG "$group_csv" "$service_user"
  fi
}

install_project_files() {
  local asset_real project_real legacy_assets=0 project_owner
  log "Installing LocalAI project files to $project_dir"
  asset_real="$(readlink -f "$asset_dir")"
  project_real="$(readlink -f "$project_dir" 2>/dev/null || true)"

  localai_installer_check_directory_chain "${project_dir%/*}" "LOCALAI_PROJECT_DIR parent" "$service_uid" || die "Unsafe LocalAI project parent."
  [[ ! -L "$project_dir" ]] || die "Unsafe LocalAI project path."
  if [[ -d "$project_dir" ]]; then
    project_owner="$(/usr/bin/stat -c '%u' -- "$project_dir")" || die "Cannot inspect LocalAI project path."
    if [[ "$project_owner" != 0 && "$project_owner" != "$service_uid" ]]; then
      log "Warning: leaving the existing project asset copy untouched because it has a different owner; installation uses the supplied asset bundle."
      return 0
    fi
  fi
  localai_installer_check_directory_chain "$project_dir" "LOCALAI_PROJECT_DIR" "$service_uid" || die "Unsafe LocalAI project path."
  if [[ -d "$project_dir" && ! -L "$project_dir" ]]; then
    project_owner="$(/usr/bin/stat -c '%u' -- "$project_dir")" || die "Cannot inspect LocalAI project path."
    if [[ "$project_owner" == 0 && "$service_uid" != 0 ]] && [[ -n "$(/usr/bin/find -P "$project_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
      localai_installer_check_legacy_assets "$project_dir" "$asset_dir" 0 || die "Refusing unknown contents in root-owned LocalAI project path."
      legacy_assets=1
    fi
  fi
  if [[ "$legacy_assets" == 0 ]]; then
    localai_installer_ensure_service_directory "$project_dir" "LOCALAI_PROJECT_DIR" "$service_user" "$service_user" "$service_uid" 0750 || die "Unsafe LocalAI project path."
  fi
  project_real="$(readlink -f "$project_dir")"

  if [[ "$asset_real" == "$project_real" ]]; then
    log "Source LocalAI asset bundle is already installed at $project_dir; skipping copy."
  else
    if [[ -n "$(/usr/bin/find -P "$project_dir" -mindepth 1 -type l -print -quit 2>/dev/null)" ]]; then
      die "Refusing to update project tree with symbolic links: $project_dir"
    fi
    localai_installer_copy_project_assets "$asset_dir" "$project_dir" || die "Could not update LocalAI project assets."
  fi

  if [[ -x /usr/sbin/restorecon ]]; then
    run0_pipe /usr/sbin/restorecon -RF "$state_dir"
  else
    log "restorecon not found; skipping SELinux relabel."
  fi
}

install_container_policy() {
  local policy_dir="$state_dir/.config/containers"
  log "Installing per-user containers policy"
  localai_installer_ensure_service_directory "$state_dir/.config" "LocalAI account config directory" "$service_user" "$service_user" "$service_uid" 0700 || die "Unsafe LocalAI account config path."
  localai_installer_ensure_service_directory "$policy_dir" "LocalAI containers policy directory" "$service_user" "$service_user" "$service_uid" 0700 || die "Unsafe LocalAI containers policy path."
  run0_pipe /usr/bin/install \
    -o "$service_user" \
    -g "$service_user" \
    -m 0600 \
    "$asset_dir/localai-containers-policy.json" \
    "$policy_dir/policy.json"
}

install_bootstrap_guard() {
  local target=/etc/localai/bootstrap-guard.py
  localai_installer_check_config_parent /etc/localai/localai.conf || die "Unsafe bootstrap guard directory."
  localai_installer_check_managed_file "$target" "bootstrap guard" 0 '# Managed by LocalAI secureblue installer.' || die "Refusing to replace an unrelated bootstrap guard."
  run0_pipe /usr/bin/install -o root -g root -m 0755 "$repo_root/lib/bootstrap_guard.py" "$target"
}

label_container_state() {
  local dir
  if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled; then
    command -v chcon >/dev/null 2>&1 || die "SELinux is enabled but chcon is not available."
    log "Labeling LocalAI app data directories for container volume access"
    while IFS= read -r dir; do
      /usr/bin/find -P "$dir" -xdev -exec "$(command -v chcon)" -h -t container_file_t -- {} +
    done < <(localai_app_data_dirs)
  else
    log "SELinux is not enabled; skipping container volume relabel."
  fi
}

preflight_user_systemd_parent() {
  [[ "$install_service" == 1 ]] || return 0
  localai_installer_check_user_systemd_parent "$state_dir/.config/systemd" "LocalAI systemd configuration directory" "$service_uid" || die "Unsafe LocalAI systemd configuration directory."
}

ensure_user_manager() {
  log "Enabling linger and starting user manager"
  run0_pipe /usr/bin/loginctl enable-linger "$service_user"
  run0_pipe /usr/bin/systemctl start "user@$service_uid.service"
}

ensure_container_userns() {
  local output status=0 ujust_cmd

  log "Checking rootless Podman user namespace support"
  output="$(run_localai_unit /usr/bin/podman unshare /usr/bin/true 2>&1)" || status=$?
  if [[ "$status" -eq 0 ]]; then
    return 0
  fi

  printf '%s\n' "$output" >&2
  if [[ "$output" != *"cannot clone"* && "$output" != *"cannot re-exec process"* ]]; then
    die "Rootless Podman preflight failed. If Podman reports that migration is required, inventory and back up this account's containers and volumes, stop every running container for the account, run 'podman system migrate' manually as $service_user, then retry. The installer does not run account-wide Podman migration."
  fi

  cat >&2 <<'EOF'

Rootless Podman cannot create a user namespace.

This fixes Podman/Distrobox-style rootless containers by relaxing secureblue's
container-domain user namespace control. Security cost: processes confined to
the container domain can create user namespaces, which secureblue disables by
default because user namespaces have a long kernel vulnerability history.
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
  run_localai_unit /usr/bin/podman unshare /usr/bin/true
}

localai_image_ref() {
  local image_ref="${LOCALAI_IMAGE_REF_OVERRIDE:-$LOCALAI_IMAGE_REF}"
  localai_config_validate_value_syntax LOCALAI_IMAGE_REF "$image_ref" || die "Unsafe LocalAI image reference."
  if [[ -n "${LOCALAI_IMAGE_DIGEST:-}" ]]; then
    image_ref="${image_ref%@*}@${LOCALAI_IMAGE_DIGEST}"
  fi
  printf '%s\n' "$image_ref"
}

pull_image() {
  local image_ref
  image_ref="$(localai_image_ref)"
  log "Pulling LocalAI image: $image_ref"
  run_localai_unit /usr/bin/podman pull "$image_ref"
}

restore_existing_service() {
  if [[ "$existing_service_active" == 1 && "$start_service" == 1 ]]; then
    log "Restoring the previously running localai.service"
    run_as_localai /usr/bin/systemctl --user start localai.service
    existing_service_stopped=0
  else
    log "Service installed without starting it; existing boot enablement is unchanged."
  fi
}

install_systemd_service() {
  local tmp_service image_ref bind_host bind_port user_unit_dir admin_gate=''
  local container_name models_path data_path config_dir generated_content_path upload_path cache_dir log_dir
  local gpu_device_args=""
  local app_home_path backends_path download_staging_path backend_temp_dir
  image_ref="$(localai_image_ref)"
  bind_host="${LOCALAI_BIND_HOST:-${SERVICE_BIND_HOST:-127.0.0.1}}"
  bind_port="${LOCALAI_BIND_PORT:-${SERVICE_BIND_PORT:-11455}}"
  container_name="${LOCALAI_CONTAINER_NAME:-localai}"
  models_path="$(localai_models_path)"
  app_home_path="$(localai_app_home_path)"
  backends_path="$(localai_backends_path)"
  download_staging_path="$(localai_download_staging_path)"
  backend_temp_dir="$(localai_backend_temp_dir)"
  data_path="$(localai_data_path)"
  if [[ "$bind_host" != 127.0.0.1 && "$bind_host" != ::1 ]]; then
    if [[ "$LOCALAI_AUTH" == true ]]; then
      admin_gate="ExecStartPre=/usr/bin/python3 /etc/localai/bootstrap-guard.py $data_path/database.db"
    else
      admin_gate='ExecStartPre=/usr/bin/false'
    fi
  fi
  config_dir="$(localai_config_dir)"
  generated_content_path="$(localai_generated_content_path)"
  upload_path="$(localai_upload_path)"
  cache_dir="$(localai_cache_dir)"
  log_dir="$(localai_log_dir)"
  user_unit_dir="$state_dir/.config/systemd/user"
  localai_installer_mktemp_var tmp_service localai.service.XXXXXX || die "Could not create a private service-unit temporary file."

  if [[ -e /dev/dri ]]; then
    gpu_device_args+=" --device=/dev/dri"
  else
    log "/dev/dri not found; generated service will not pass render devices."
  fi
  if [[ -e /dev/kfd ]]; then
    gpu_device_args+=" --device=/dev/kfd"
  else
    log "/dev/kfd not found; generated service will not pass AMD KFD."
  fi
  gpu_device_args="${gpu_device_args# }"

  log "Generating user systemd unit for UID $service_uid"
  printf '# Managed by LocalAI secureblue installer.\n' >"$tmp_service"
  sed \
    -e "s|@USER@|$service_user|g" \
    -e "s|@UID@|$service_uid|g" \
    -e "s|@STATE_DIR@|$state_dir|g" \
    -e "s|@APP_HOME_PATH@|$app_home_path|g" \
    -e "s|@BACKENDS_PATH@|$backends_path|g" \
    -e "s|@DOWNLOAD_STAGING_PATH@|$download_staging_path|g" \
    -e "s|@BACKEND_TEMP_DIR@|$backend_temp_dir|g" \
    -e "s|@IMAGE_REF@|$image_ref|g" \
    -e "s|@CONTAINER_NAME@|$container_name|g" \
    -e "s|@BIND_HOST@|$bind_host|g" \
    -e "s|@BIND_PORT@|$bind_port|g" \
    -e "s|@ADMIN_GATE@|$admin_gate|g" \
    -e "s|@LOCALAI_AUTH@|${LOCALAI_AUTH:-true}|g" \
    -e "s|@LOCALAI_REGISTRATION_MODE@|${LOCALAI_REGISTRATION_MODE:-approval}|g" \
    -e "s|@LOCALAI_LOG_LEVEL@|${LOCALAI_LOG_LEVEL:-info}|g" \
    -e "s|@MODELS_PATH@|$models_path|g" \
    -e "s|@DATA_PATH@|$data_path|g" \
    -e "s|@CONFIG_DIR@|$config_dir|g" \
    -e "s|@GENERATED_CONTENT_PATH@|$generated_content_path|g" \
    -e "s|@UPLOAD_PATH@|$upload_path|g" \
    -e "s|@CACHE_DIR@|$cache_dir|g" \
    -e "s|@LOG_DIR@|$log_dir|g" \
    -e "s|@LOCALAI_F16@|${LOCALAI_F16:-true}|g" \
    -e "s|@GPU_DEVICE_ARGS@|$gpu_device_args|g" \
    "$script_dir/localai.service.in" >>"$tmp_service"

  localai_installer_ensure_user_systemd_parent "$state_dir/.config/systemd" "LocalAI systemd configuration directory" "$service_user" "$service_user" "$service_uid" || die "Unsafe LocalAI systemd configuration directory."
  localai_installer_ensure_service_directory "$user_unit_dir" "LocalAI user-unit directory" "$service_user" "$service_user" "$service_uid" 0700 || die "Unsafe LocalAI user-unit directory."
  if [[ -e "$user_unit_dir/localai.service" || -L "$user_unit_dir/localai.service" ]]; then
    [[ ! -L "$user_unit_dir/localai.service" && -f "$user_unit_dir/localai.service" ]] || die "Refusing to replace a non-regular LocalAI service unit."
    grep -Fqx '# Managed by LocalAI secureblue installer.' "$user_unit_dir/localai.service" || grep -Fqx 'Description=LocalAI OpenAI-compatible API and web UI container' "$user_unit_dir/localai.service" || die "Refusing to replace an unrelated user service unit: $user_unit_dir/localai.service"
  fi
  localai_installer_check_managed_file /etc/localai/backend-unit.expected "expected backend unit" 0 '# Managed by LocalAI secureblue installer.' || die "Refusing to replace an unrelated expected backend unit."
  run0_pipe /usr/bin/install -o root -g root -m 0644 "$tmp_service" /etc/localai/backend-unit.expected
  run0_pipe /usr/bin/install -o "$service_user" -g "$service_user" -m 0644 "$tmp_service" "$user_unit_dir/localai.service"
  rm -f "$tmp_service"
  run_as_localai /usr/bin/systemctl --user daemon-reload

  restore_existing_service
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
    --enable-container-userns)
      enable_container_userns=1
      ;;
    --hide-direct-http|--rebind-localai-loopback)
      die "This is a TLS installer option. Run it from secureblue-localai-tls-install/install.sh, not secureblue-localai-install/install.sh."
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
asset_requirements
localai_installer_select_config "$canonical_config" "$requested_config" /etc/localai.conf "$repo_root/config/localai.conf" "$lock_file" || die "Cannot select a safe configuration source."
localai_installer_load_config "$LOCALAI_INSTALLER_CONFIG_SOURCE" "$LOCALAI_INSTALLER_CONFIG_FORMAT" || die "Invalid LocalAI configuration."
service_user="$LOCALAI_SERVICE_USER"
state_dir="$LOCALAI_STATE_DIR"
project_dir="${LOCALAI_PROJECT_DIR:-$state_dir/build/localai-oci}"
SERVICE_BIND_HOST="$LOCALAI_BIND_HOST"
SERVICE_BIND_PORT="$LOCALAI_BIND_PORT"
localai_installer_validate_service_account_name "$service_user" "LOCALAI_SERVICE_USER" || die "Unsafe LocalAI service account name."
localai_installer_validate_managed_path "$state_dir" "LOCALAI_STATE_DIR" || die "Unsafe LocalAI state path."
localai_installer_validate_managed_path "$project_dir" "LOCALAI_PROJECT_DIR" || die "Unsafe LocalAI project path."
[[ "$project_dir" == "$state_dir/"* ]] || die "LOCALAI_PROJECT_DIR must be inside LOCALAI_STATE_DIR."
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  localai_installer_validate_managed_path "$path" "LocalAI app data path" || die "Unsafe LocalAI app data path: $path"
  [[ "$path" != "$state_dir" && "$state_dir" != "$path/"* ]] || die "LocalAI app data paths must not cover the service home."
  for reserved in "$state_dir/.config" "$state_dir/.local/share/containers" "$state_dir/build"; do
    [[ "$path" != "$reserved" && "$path" != "$reserved/"* && "$reserved" != "$path/"* ]] || die "LocalAI app data paths must not overlap service configuration, Podman storage, or installer assets: $path"
  done
done < <(localai_app_data_dirs)
elevate_once
localai_installer_prepare_config "$canonical_config" "$LOCALAI_INSTALLER_CONFIG_SOURCE" "$LOCALAI_INSTALLER_CONFIG_FORMAT" || die "Could not safely persist the shared LocalAI configuration."
localai_installer_persist_environment_overrides "$canonical_config" || die "Could not safely persist explicit configuration overrides."
localai_installer_load_config "$canonical_config" canonical || die "Invalid persisted LocalAI configuration."
service_user="$LOCALAI_SERVICE_USER"
state_dir="$LOCALAI_STATE_DIR"
project_dir="${LOCALAI_PROJECT_DIR:-$state_dir/build/localai-oci}"
SERVICE_BIND_HOST="$LOCALAI_BIND_HOST"
SERVICE_BIND_PORT="$LOCALAI_BIND_PORT"
localai_installer_validate_service_account_name "$service_user" "LOCALAI_SERVICE_USER" || die "Unsafe LocalAI service account name."
localai_installer_validate_managed_path "$state_dir" "LOCALAI_STATE_DIR" || die "Unsafe LocalAI state path."
localai_installer_validate_managed_path "$project_dir" "LOCALAI_PROJECT_DIR" || die "Unsafe LocalAI project path."
[[ "$project_dir" == "$state_dir/"* ]] || die "LOCALAI_PROJECT_DIR must be inside LOCALAI_STATE_DIR."
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  localai_installer_validate_managed_path "$path" "LocalAI app data path" || die "Unsafe LocalAI app data path: $path"
  [[ "$path" != "$state_dir" && "$state_dir" != "$path/"* ]] || die "LocalAI app data paths must not cover the service home."
  for reserved in "$state_dir/.config" "$state_dir/.local/share/containers" "$state_dir/build"; do
    [[ "$path" != "$reserved" && "$path" != "$reserved/"* && "$reserved" != "$path/"* ]] || die "LocalAI app data paths must not overlap service configuration, Podman storage, or installer assets: $path"
  done
done < <(localai_app_data_dirs)
require_cmd run0

if ! /usr/bin/python3 "$repo_root/lib/bootstrap_guard.py" "$LOCALAI_DATA_PATH/database.db"; then
  /usr/bin/env -u LOCALAI_SYSTEM_UNIT_DIR -u LOCALAI_SYSTEMCTL_BIN -u LOCALAI_RUN0_BIN -u LOCALAI_ID_BIN \
    LOCALAI_CONFIG_FILE=/etc/localai/localai.conf /usr/bin/bash "$repo_root/bin/localaictl" __verify-bootstrap-isolation || die "Stop and disable existing TLS listeners before first administrator bootstrap."
fi
if [[ "$LOCALAI_BIND_HOST" != 127.0.0.1 && "$LOCALAI_BIND_HOST" != ::1 ]]; then
  [[ "$LOCALAI_AUTH" == true ]] || die "A non-loopback backend requires authentication."
  /usr/bin/python3 "$repo_root/lib/bootstrap_guard.py" "$LOCALAI_DATA_PATH/database.db" || die "Complete the first administrator bootstrap on loopback before configuring a public backend."
fi

log "Installing from LocalAI assets: $asset_dir"
ensure_service_user
ensure_subids
ensure_gpu_groups
install_project_files
install_container_policy
install_bootstrap_guard
label_container_state
preflight_existing_backend_state
preflight_user_systemd_parent
ensure_user_manager
snapshot_existing_service_state
stop_existing_managed_service
remove_preflighted_existing_container
ensure_container_userns

if [[ "$run_pull" == "1" ]]; then
  pull_image
fi

if [[ "$install_service" == "1" ]]; then
  install_systemd_service
fi

log "Install complete."
log "Check status with: localaictl status (use 'localaictl status --elevated' from a terminal if manager state is unavailable)."
