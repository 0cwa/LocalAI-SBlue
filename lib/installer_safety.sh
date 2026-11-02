#!/usr/bin/env bash
# Small, shared guards for privileged LocalAI installer operations.

# The value is consumed by a sourced or dynamically extracted helper.
# shellcheck disable=SC2034
LOCALAI_INSTALLER_CONFIG_DEST=/etc/localai/localai.conf
LOCALAI_INSTALLER_METADATA_DIR=/var/lib/localai-installer
LOCALAI_INSTALLER_TEMP_FILES=()

localai_installer_error() {
  printf 'LocalAI installer safety error: %s\n' "$*" >&2
}

localai_installer_require_root() {
  if [[ "${EUID:-$(/usr/bin/id -u)}" -ne 0 ]]; then
    localai_installer_error "this operation requires the elevated installer process"
    return 1
  fi
}

localai_installer_validate_identifier() {
  local value="$1" label="$2"
  if ! [[ "$value" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]]; then
    localai_installer_error "$label must be a service-account or resource identifier"
    return 1
  fi
  if [[ "$value" == root || "$value" == 0 ]]; then
    localai_installer_error "$label may not select the root account"
    return 1
  fi
}

localai_installer_validate_managed_path() {
  local path="$1" label="$2" normalized protected var_lib_root
  if [[ -z "$path" || "$path" != /* || ! "$path" =~ ^/[A-Za-z0-9._/-]*$ ]]; then
    localai_installer_error "$label must be an absolute path using only letters, digits, slash, dot, underscore, or hyphen"
    return 1
  fi
  if [[ "$path" == *//* ]]; then
    localai_installer_error "$label must use a canonical path: $path"
    return 1
  fi
  case "/$path/" in
    *"/../"*|*"/./"*)
      localai_installer_error "$label must not contain dot or parent components: $path"
      return 1
      ;;
  esac
  if [[ "$path" != / && "$path" == */ ]]; then
    localai_installer_error "$label must not end with a slash: $path"
    return 1
  fi

  normalized="$(/usr/bin/realpath -m -- "$path")" || {
    localai_installer_error "could not canonicalize $label: $path"
    return 1
  }
  if [[ "$normalized" != "$path" ]]; then
    localai_installer_error "$label contains a symlink or non-canonical component: $path"
    return 1
  fi

  for protected in /etc /usr /bin /sbin /lib /lib64 /boot /dev /proc /sys /run /tmp /root /home /media /mnt /var/cache /var/log /var/tmp /var/run /var/lock /var/home; do
    if [[ "$path" == "$protected" || "$path" == "$protected/"* ]]; then
      localai_installer_error "$label may not be inside a protected system tree: $path"
      return 1
    fi
  done
  case "$path" in
    /|/var|/var/lib|/srv|/opt)
      localai_installer_error "$label may not name a shared system parent directory: $path"
      return 1
      ;;
    /var/lib/*)
      var_lib_root="${path#/var/lib/}"
      var_lib_root="${var_lib_root%%/*}"
      if [[ "$var_lib_root" != localai && ( "$var_lib_root" != localai-* || "$var_lib_root" == localai- ) ]]; then
        localai_installer_error "$label under /var/lib must use a dedicated /var/lib/localai or /var/lib/localai-* subtree: $path"
        return 1
      fi
      ;;
    /var/*)
      localai_installer_error "$label under /var must use an approved /var/lib/localai subtree: $path"
      return 1
      ;;
  esac
  for protected in \
    /var/lib/containers /var/lib/flatpak /var/lib/ostree /var/lib/rpm \
    /var/lib/systemd /var/lib/secureblue /var/lib/NetworkManager \
    /var/lib/AccountsService /var/lib/PackageKit /var/lib/chrony \
    /var/lib/selinux /var/lib/sss /var/lib/pcp /var/lib/libvirt \
    /var/lib/machines /var/lib/private; do
    if [[ "$path" == "$protected" || "$path" == "$protected/"* ]]; then
      localai_installer_error "$label overlaps protected system state: $path"
      return 1
    fi
  done
  if [[ "$path" == "$LOCALAI_INSTALLER_METADATA_DIR" || "$path" == "$LOCALAI_INSTALLER_METADATA_DIR/"* || "$LOCALAI_INSTALLER_METADATA_DIR" == "$path/"* ]]; then
    localai_installer_error "$label overlaps reserved root-owned installer metadata: $path"
    return 1
  fi
}

# Check an existing path chain before install/chown/rm. Existing parent
# directories must be root- or service-owned, and no component may be a link.
localai_installer_check_directory_chain() {
  local path="$1" label="$2" expected_uid="$3"
  local current=/ part owner mode mode_number index=0 last
  local -a components=()
  localai_installer_validate_managed_path "$path" "$label" || return 1
  IFS='/' read -r -a components <<< "${path#/}"
  last=$((${#components[@]} - 1))
  for part in "${components[@]}"; do
    [[ -n "$part" ]] || continue
    current="${current%/}/$part"
    if [[ -L "$current" ]]; then
      localai_installer_error "$label traverses a symbolic link: $current"
      return 1
    fi
    if [[ -e "$current" ]]; then
      if [[ ! -d "$current" ]]; then
        localai_installer_error "$label has a non-directory path component: $current"
        return 1
      fi
      owner="$(/usr/bin/stat -c '%u' -- "$current")" || return 1
      mode="$(/usr/bin/stat -c '%a' -- "$current")" || return 1
      mode_number=$((8#$mode))
      if (( index < last )); then
        if [[ "$owner" != 0 && "$owner" != "$expected_uid" ]]; then
          localai_installer_error "$label parent is owned by unexpected UID $owner: $current"
          return 1
        fi
      elif [[ "$owner" != 0 && "$owner" != "$expected_uid" ]]; then
        localai_installer_error "$label already exists with unexpected UID $owner: $current"
        return 1
      fi
      if (( index < last && (mode_number & 0022) != 0 )); then
        localai_installer_error "$label has a group- or world-writable parent: $current"
        return 1
      fi
    fi
    index=$((index + 1))
  done
}

localai_installer_ensure_service_directory() {
  local path="$1" label="$2" owner="$3" group="$4" uid="$5" mode="$6"
  local parent="${path%/*}" current_owner entries
  [[ -n "$parent" ]] || parent=/
  localai_installer_check_directory_chain "$path" "$label" "$uid" || return 1
  if [[ -d "$path" && ! -L "$path" ]]; then
    current_owner="$(/usr/bin/stat -c '%u' -- "$path")" || return 1
    if [[ "$current_owner" == 0 && "$uid" != 0 ]]; then
      entries="$(/usr/bin/find -P "$path" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" || {
        localai_installer_error "$label is root-owned and its contents could not be checked: $path"
        return 1
      }
      if [[ -n "$entries" ]]; then
        localai_installer_error "$label is a non-empty root-owned directory; refusing service-account adoption: $path"
        return 1
      fi
    fi
  fi
  # The chain was checked above. Newly created parents stay root-owned; only
  # the exact managed directory is handed to the service account.
  /usr/bin/mkdir -p -- "$parent" || return 1
  /usr/bin/install -d -o "$owner" -g "$group" -m "$mode" -- "$path"
}

localai_installer_validate_service_account_name() {
  localai_installer_validate_identifier "$1" "$2"
}

localai_installer_validate_existing_service_account() {
  local name="$1" expected_home="$2" label="$3"
  local record account uid gid home shell group_record group_gid
  record="$(getent passwd "$name")" || {
    localai_installer_error "$label account does not exist: $name"
    return 1
  }
  IFS=: read -r account _ uid gid _ home shell <<< "$record"
  if [[ "$account" != "$name" || -z "$uid" || "$uid" == 0 ]]; then
    localai_installer_error "$label must resolve to a non-root account: $name"
    return 1
  fi
  if [[ "$home" != "$expected_home" ]]; then
    localai_installer_error "$label account home is $home, expected $expected_home; refusing account reuse"
    return 1
  fi
  case "$shell" in
    */nologin|/bin/false) ;;
    *)
      localai_installer_error "$label account has an interactive shell; refusing to use a human account"
      return 1
      ;;
  esac
  group_record="$(getent group "$name")" || {
    localai_installer_error "$label private primary group is missing: $name"
    return 1
  }
  IFS=: read -r _ _ group_gid _ <<< "$group_record"
  if [[ "$group_gid" != "$gid" ]]; then
    localai_installer_error "$label account does not use its private primary group: $name"
    return 1
  fi
  printf '%s\n' "$uid"
}

localai_installer_check_root_file() {
  local path="$1" label="$2" owner mode mode_number
  if [[ -L "$path" || ! -f "$path" ]]; then
    localai_installer_error "$label must be a regular, non-symlink file: $path"
    return 1
  fi
  owner="$(/usr/bin/stat -c '%u' -- "$path")" || return 1
  mode="$(/usr/bin/stat -c '%a' -- "$path")" || return 1
  mode_number=$((8#$mode))
  if [[ "$owner" != 0 ]] || (( (mode_number & 0022) != 0 )); then
    localai_installer_error "$label must be root-owned and not group- or world-writable: $path"
    return 1
  fi
}

localai_installer_check_root_config_file() {
  local path="$1" mode mode_number
  localai_installer_check_root_file "$path" "installed configuration" || return 1
  mode="$(/usr/bin/stat -c '%a' -- "$path")" || return 1
  mode_number=$((8#$mode))
  if (( (mode_number & 0004) == 0 )); then
    localai_installer_error "installed configuration must be readable by the tray and controller: $path"
    return 1
  fi
}

localai_installer_check_managed_file() {
  local path="$1" label="$2" expected_uid="$3" marker="$4" legacy_signature="${5:-}"
  local owner
  [[ -e "$path" || -L "$path" ]] || return 0
  if [[ -L "$path" || ! -f "$path" ]]; then
    localai_installer_error "$label must be a regular, non-symlink file: $path"
    return 1
  fi
  owner="$(/usr/bin/stat -c '%u' -- "$path")" || return 1
  if [[ "$owner" != 0 && "$owner" != "$expected_uid" ]]; then
    localai_installer_error "$label is owned by unexpected UID $owner: $path"
    return 1
  fi
  if ! /usr/bin/grep -Fqx -- "$marker" "$path" && { [[ -z "$legacy_signature" ]] || ! /usr/bin/grep -Fqx -- "$legacy_signature" "$path"; }; then
    localai_installer_error "refusing to replace or remove an unrelated file at $path"
    return 1
  fi
}

localai_installer_mktemp_var() {
  local variable="$1" template="$2" path
  path="$(/usr/bin/mktemp --tmpdir=/run "$template")" || return 1
  LOCALAI_INSTALLER_TEMP_FILES+=("$path")
  printf -v "$variable" '%s' "$path"
}

localai_installer_mktemp_at_var() {
  local variable="$1" directory="$2" template="$3" path
  path="$(/usr/bin/mktemp --tmpdir="$directory" "$template")" || return 1
  LOCALAI_INSTALLER_TEMP_FILES+=("$path")
  printf -v "$variable" '%s' "$path"
}

localai_installer_cleanup_temps() {
  local path
  for path in "${LOCALAI_INSTALLER_TEMP_FILES[@]-}"; do
    [[ -n "$path" ]] && /usr/bin/rm -f -- "$path"
  done
}

localai_installer_select_config() {
  local destination="$1" requested="$2" legacy_system="$3" repo_config="$4" legacy_lock="$5"
  local candidate format
  if [[ -e "$destination" || -L "$destination" ]]; then
    localai_installer_check_root_config_file "$destination" || return 1
    candidate="$destination"; format=canonical
  elif [[ -n "$requested" ]]; then
    candidate="$requested"; format=canonical
  elif [[ -e "$legacy_system" || -L "$legacy_system" ]]; then
    candidate="$legacy_system"; format=legacy
  elif [[ -e "$repo_config" || -L "$repo_config" ]]; then
    candidate="$repo_config"; format=canonical
  elif [[ -e "$legacy_lock" || -L "$legacy_lock" ]]; then
    candidate="$legacy_lock"; format=legacy
  else
    candidate=""; format=defaults
  fi
  if [[ -n "$candidate" && ( -L "$candidate" || ! -f "$candidate" ) ]]; then
    localai_installer_error "configuration source must be a regular, non-symlink file: $candidate"
    return 1
  fi
  if [[ "$candidate" == "$legacy_system" ]]; then
    localai_installer_check_root_config_file "$candidate" || return 1
  fi
  if [[ "$candidate" == "$destination" ]]; then
    localai_installer_check_root_config_file "$candidate" || return 1
  fi
  # The value is consumed by a sourced or dynamically extracted helper.
  # shellcheck disable=SC2034
  LOCALAI_INSTALLER_CONFIG_SOURCE="$candidate"
  # The value is consumed by a sourced or dynamically extracted helper.
  # shellcheck disable=SC2034
  LOCALAI_INSTALLER_CONFIG_FORMAT="$format"
}

localai_installer_load_config() {
  local source="$1" format="$2"
  localai_config_defaults
  case "$format" in
    canonical)
      [[ -n "$source" ]] && localai_config_load_file "$source" || [[ -z "$source" ]] || return 1
      ;;
    legacy)
      [[ -n "$source" ]] && localai_config_load_legacy_file "$source" || [[ -z "$source" ]] || return 1
      ;;
    defaults) ;;
    *) localai_installer_error "unknown configuration format: $format"; return 1 ;;
  esac
  localai_config_apply_environment || return 1
  localai_config_validate
}

localai_installer_validate_config_source() {
  local source="$1" format="$2"
  localai_config_defaults
  case "$format" in
    canonical)
      if [[ -n "$source" ]]; then localai_config_load_file "$source" || return 1; fi
      ;;
    legacy)
      if [[ -n "$source" ]]; then localai_config_load_legacy_file "$source" || return 1; fi
      ;;
    defaults) ;;
    *) localai_installer_error "unknown configuration format: $format"; return 1 ;;
  esac
  localai_config_validate
}

# The canonical configuration is deliberately under /etc, which is forbidden
# for service-owned state. Validate its root-owned parent separately rather
# than weakening the managed-state path guard.
localai_installer_check_config_parent() {
  local destination="$1" etc_owner etc_mode
  [[ "$destination" == "$LOCALAI_INSTALLER_CONFIG_DEST" && "$destination" == /etc/localai/localai.conf ]] || {
    localai_installer_error "refusing to create a noncanonical configuration directory"
    return 1
  }
  [[ -d /etc && ! -L /etc ]] || return 1
  etc_owner="$(/usr/bin/stat -c '%u' -- /etc)" || return 1
  etc_mode="$(/usr/bin/stat -c '%a' -- /etc)" || return 1
  (( etc_owner == 0 && (8#$etc_mode & 0022) == 0 ))
}

localai_installer_prepare_config() {
  local destination="$1" source="$2" format="$3"
  local parent tmp
  localai_installer_require_root || return 1
  parent="${destination%/*}"
  if [[ -e "$destination" || -L "$destination" ]]; then
    [[ -d "$parent" && ! -L "$parent" ]] || {
      localai_installer_error "configuration directory is not a real directory: $parent"
      return 1
    }
    localai_installer_check_root_config_file "$destination" || return 1
    localai_installer_validate_config_source "$destination" canonical || return 1
    return 0
  fi

  if [[ -e "$parent" || -L "$parent" ]]; then
    local parent_owner parent_mode
    [[ -d "$parent" && ! -L "$parent" ]] || {
      localai_installer_error "configuration directory must be a real directory: $parent"
      return 1
    }
    parent_owner="$(/usr/bin/stat -c '%u' -- "$parent")" || return 1
    parent_mode="$(/usr/bin/stat -c '%a' -- "$parent")" || return 1
    (( parent_owner == 0 && (8#$parent_mode & 0022) == 0 )) || {
      localai_installer_error "configuration directory must be root-owned and not group- or world-writable: $parent"
      return 1
    }
  else
    localai_installer_check_config_parent "$destination" || return 1
    /usr/bin/install -d -o root -g root -m 0755 -- "$parent" || return 1
  fi
  localai_installer_mktemp_at_var tmp "$parent" .localai.conf.XXXXXX || return 1
  if [[ "$format" == canonical && -n "$source" ]]; then
    /usr/bin/cat -- "$source" > "$tmp" || { /usr/bin/rm -f -- "$tmp"; return 1; }
    localai_installer_validate_config_source "$tmp" canonical || { /usr/bin/rm -f -- "$tmp"; return 1; }
  else
    localai_installer_validate_config_source "$source" "$format" || { /usr/bin/rm -f -- "$tmp"; return 1; }
    localai_config_defaults
    case "$format" in
      legacy) [[ -n "$source" ]] && localai_config_load_legacy_file "$source" || [[ -z "$source" ]] || { /usr/bin/rm -f -- "$tmp"; return 1; } ;;
    esac
    localai_config_dump > "$tmp" || { /usr/bin/rm -f -- "$tmp"; return 1; }
  fi
  /usr/bin/chown root:root -- "$tmp" || { /usr/bin/rm -f -- "$tmp"; return 1; }
  /usr/bin/chmod 0644 -- "$tmp" || { /usr/bin/rm -f -- "$tmp"; return 1; }
  # The parent is root-owned; `mv -n` preserves an administrator-created file
  # if one appears between the check and the final install.
  /usr/bin/mv -n -- "$tmp" "$destination" || { /usr/bin/rm -f -- "$tmp"; return 1; }
  /usr/bin/rm -f -- "$tmp"
  localai_installer_check_root_config_file "$destination" || return 1
  localai_installer_validate_config_source "$destination" canonical
}

localai_installer_update_config() {
  local destination="$1"; shift
  local tmp key value line found
  local -A updates=() applied=()
  [[ "$#" -gt 0 && $(( $# % 2 )) -eq 0 ]] || {
    localai_installer_error "configuration update requires key/value pairs"
    return 1
  }
  localai_installer_require_root || return 1
  localai_installer_check_root_config_file "$destination" || return 1
  while [[ "$#" -gt 0 ]]; do
    key="$1"; value="$2"; shift 2
    localai_config_validate_key "$key" || return 1
    localai_config_validate_value_syntax "$key" "$value" || return 1
    updates["$key"]="$value"
  done
  localai_config_defaults
  localai_config_load_file "$destination" || return 1
  for key in "${!updates[@]}"; do printf -v "$key" '%s' "${updates[$key]}"; done
  localai_config_validate || return 1

  localai_installer_mktemp_at_var tmp "${destination%/*}" .localai.conf.XXXXXX || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    found=0
    for key in "${!updates[@]}"; do
      if [[ "$line" == "$key="* ]]; then
        printf '%s=%s\n' "$key" "${updates[$key]}" >> "$tmp"
        applied["$key"]=1
        found=1
        break
      fi
    done
    (( found == 1 )) || printf '%s\n' "$line" >> "$tmp"
  done < "$destination"
  for key in "${!updates[@]}"; do
    if [[ -z "${applied[$key]+x}" ]]; then
      printf '%s=%s\n' "$key" "${updates[$key]}" >> "$tmp"
    fi
  done
  localai_installer_validate_config_source "$tmp" canonical || { /usr/bin/rm -f -- "$tmp"; return 1; }
  /usr/bin/chown root:root -- "$tmp" || { /usr/bin/rm -f -- "$tmp"; return 1; }
  /usr/bin/chmod 0644 -- "$tmp" || { /usr/bin/rm -f -- "$tmp"; return 1; }
  /usr/bin/mv -f -- "$tmp" "$destination" || { /usr/bin/rm -f -- "$tmp"; return 1; }
  localai_installer_check_root_file "$destination" "installed configuration" || return 1
  localai_installer_validate_config_source "$destination" canonical
}

localai_installer_persist_environment_overrides() {
  local destination="$1" key target
  local -a updates=()
  for key in "${!LOCALAI_CONFIG_ENV_OVERRIDES[@]}"; do
    case "$key" in
      SERVICE_BIND_HOST)
        [[ -n "${LOCALAI_CONFIG_ENV_OVERRIDES[LOCALAI_BIND_HOST]+x}" ]] && continue
        target=LOCALAI_BIND_HOST
        ;;
      SERVICE_BIND_PORT)
        [[ -n "${LOCALAI_CONFIG_ENV_OVERRIDES[LOCALAI_BIND_PORT]+x}" ]] && continue
        target=LOCALAI_BIND_PORT
        ;;
      LOCALAI_TLS_BIND_HOST)
        [[ -n "${LOCALAI_CONFIG_ENV_OVERRIDES[LOCALAI_TLS_PUBLIC_HOST]+x}" ]] && continue
        target=LOCALAI_TLS_PUBLIC_HOST
        ;;
      LOCALAI_TLS_BIND_PORT)
        [[ -n "${LOCALAI_CONFIG_ENV_OVERRIDES[LOCALAI_TLS_PUBLIC_PORT]+x}" ]] && continue
        target=LOCALAI_TLS_PUBLIC_PORT
        ;;
      *) target="$key" ;;
    esac
    localai_config_is_key "$target" || continue
    # This function declares a local indexed array with the same name as an associative array elsewhere.
    # shellcheck disable=SC2190
    updates+=("$target" "${LOCALAI_CONFIG_ENV_OVERRIDES[$key]}")
  done
  if [[ "${#updates[@]}" -gt 0 ]]; then
    localai_installer_update_config "$destination" "${updates[@]}"
  fi
}

localai_installer_prepare_metadata_dir() {
  local directory="$LOCALAI_INSTALLER_METADATA_DIR"
  local owner mode
  localai_installer_require_root || return 1
  if [[ -e "$directory" || -L "$directory" ]]; then
    [[ -d "$directory" && ! -L "$directory" ]] || {
      localai_installer_error "installer metadata directory must be a real directory"
      return 1
    }
    owner="$(/usr/bin/stat -c '%u' -- "$directory")" || return 1
    mode="$(/usr/bin/stat -c '%a' -- "$directory")" || return 1
    if [[ "$owner" != 0 ]] || (( (8#$mode & 0022) != 0 )); then
      localai_installer_error "installer metadata directory must be root-owned and not group- or world-writable"
      return 1
    fi
  else
    /usr/bin/install -d -o root -g root -m 0700 -- "$directory" || return 1
  fi
  /usr/bin/chmod 0700 -- "$directory"
}

localai_installer_selinux_state_file() {
  local role="$1"
  [[ "$role" == public || "$role" == internal ]] || return 1
  printf '%s/tls-selinux-%s-port.state\n' "$LOCALAI_INSTALLER_METADATA_DIR" "$role"
}

localai_installer_validate_selinux_state_values() {
  local action="$1" port="$2" previous="$3" current="$4"
  [[ "$action" == add || "$action" == modify ]] || return 1
  [[ "$port" =~ ^[0-9]{1,5}$ ]] && (( port >= 1 && port <= 65535 )) || return 1
  [[ -z "$previous" || "$previous" =~ ^[A-Za-z0-9_]+_t$ ]] || return 1
  [[ "$current" =~ ^[A-Za-z0-9_]+_t$ ]] || return 1
  if [[ "$action" == add && -n "$previous" ]]; then return 1; fi
  if [[ "$action" == modify && -z "$previous" ]]; then return 1; fi
}

localai_installer_write_selinux_port_state() {
  local role="$1" action="$2" port="$3" previous="$4" current="$5"
  local file tmp
  localai_installer_require_root || return 1
  localai_installer_validate_selinux_state_values "$action" "$port" "$previous" "$current" || {
    localai_installer_error "invalid SELinux port rollback values"
    return 1
  }
  localai_installer_prepare_metadata_dir || return 1
  file="$(localai_installer_selinux_state_file "$role")" || return 1
  localai_installer_mktemp_at_var tmp "$LOCALAI_INSTALLER_METADATA_DIR" .selinux-port.XXXXXX || return 1
  {
    printf 'version=1\n'
    printf 'action=%s\n' "$action"
    printf 'port=%s\n' "$port"
    printf 'previous_type=%s\n' "$previous"
    printf 'new_type=%s\n' "$current"
  } > "$tmp" || { /usr/bin/rm -f -- "$tmp"; return 1; }
  /usr/bin/chown root:root -- "$tmp" || { /usr/bin/rm -f -- "$tmp"; return 1; }
  /usr/bin/chmod 0600 -- "$tmp" || { /usr/bin/rm -f -- "$tmp"; return 1; }
  /usr/bin/mv -f -- "$tmp" "$file" || { /usr/bin/rm -f -- "$tmp"; return 1; }
}

localai_installer_read_selinux_port_state() {
  local file="$1" line key value
  local version='' action='' port='' previous='' current=''
  local seen_version=0 seen_action=0 seen_port=0 seen_previous=0 seen_current=0
  localai_installer_check_root_file "$file" "SELinux rollback metadata" || return 1
  if [[ "$(/usr/bin/stat -c '%a' -- "$file")" != 600 ]]; then
    localai_installer_error "SELinux rollback metadata must have mode 0600"
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* ]] || { localai_installer_error "malformed SELinux rollback metadata"; return 1; }
    key="${line%%=*}"; value="${line#*=}"
    case "$key" in
      version) (( seen_version == 0 )) || return 1; version="$value"; seen_version=1 ;;
      action) (( seen_action == 0 )) || return 1; action="$value"; seen_action=1 ;;
      port) (( seen_port == 0 )) || return 1; port="$value"; seen_port=1 ;;
      previous_type) (( seen_previous == 0 )) || return 1; previous="$value"; seen_previous=1 ;;
      new_type) (( seen_current == 0 )) || return 1; current="$value"; seen_current=1 ;;
      *) localai_installer_error "unknown SELinux rollback metadata field: $key"; return 1 ;;
    esac
  done < "$file"
  if [[ "$version" != 1 ]] || (( seen_version != 1 || seen_action != 1 || seen_port != 1 || seen_previous != 1 || seen_current != 1 )); then
    localai_installer_error "incomplete SELinux rollback metadata"
    return 1
  fi
  localai_installer_validate_selinux_state_values "$action" "$port" "$previous" "$current" || {
    localai_installer_error "invalid SELinux rollback metadata values"
    return 1
  }
  printf '%s|%s|%s|%s\n' "$action" "$port" "$previous" "$current"
}

localai_installer_remove_selinux_port_state() {
  local role="$1" file
  file="$(localai_installer_selinux_state_file "$role")" || return 1
  [[ -e "$file" || -L "$file" ]] || return 0
  localai_installer_check_root_file "$file" "SELinux rollback metadata" || return 1
  /usr/bin/rm -f -- "$file"
}

localai_installer_mktemp() {
  local template="${1:-localai-installer.XXXXXX}"
  local path
  path="$(/usr/bin/mktemp --tmpdir=/run "$template")" || return 1
  LOCALAI_INSTALLER_TEMP_FILES+=("$path")
  printf '%s\n' "$path"
}

localai_installer_user_manager_is_active() {
  /usr/bin/systemctl is-active --quiet "user@$1.service"
}

# Check every installer-owned container name before any operation can stop it
# or remove its container. The service manager runner must target the already
# active nologin account manager; starting a manager here could auto-start an
# old --rm unit before its anonymous /backends volume is checked.
localai_installer_preflight_backend_containers() {
  local runner="$1" backend_destination="$2" expected_uid="$3" expected_state_dir="$4"
  shift 4
  local names name target matched container_id labels_json mounts mounts_json type volume source destination suffix expected_source volume_path volume_path_json entries diff
  local backend_mounts
  LOCALAI_INSTALLER_VALIDATED_CONTAINER_IDS=()
  names="$("$runner" /usr/bin/podman ps --all --format '{{.Names}}')" || {
    localai_installer_error "could not read rootless container state before changing the service; if Podman requests migration, inventory and back up all containers and volumes for this account, stop every running container, run 'podman system migrate' manually as this account, then retry"
    return 1
  }
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    matched=0
    for target in "$@"; do
      if [[ "$name" == "$target" ]]; then matched=1; break; fi
    done
    (( matched == 1 )) || continue

    container_id="$("$runner" /usr/bin/podman inspect --format '{{.Id}}' "$name")" || {
      localai_installer_error "could not read the ID for container $name; refusing to stop or replace it"
      return 1
    }
    if [[ ! "$container_id" =~ ^[[:xdigit:]]{64}$ ]]; then
      localai_installer_error "container $name has an invalid ID; refusing to stop or replace it"
      return 1
    fi

    labels_json="$("$runner" /usr/bin/podman inspect --format '{{json .Config.Labels}}' "$container_id")" || {
      localai_installer_error "could not inspect container $container_id ownership labels; refusing to stop or replace it"
      return 1
    }
    if ! /usr/bin/python3 -c '
import json, sys
labels = json.load(sys.stdin)
if (
    not isinstance(labels, dict)
    or labels.get("io.localai.secureblue.managed") != "localai"
    or labels.get("io.localai.secureblue.state") != sys.argv[1]
    or labels.get("io.localai.secureblue.container") != sys.argv[2]
):
    raise SystemExit(1)
' "$expected_state_dir" "$name" <<< "$labels_json"; then
      localai_installer_error "container $name is not marked for LocalAI state $expected_state_dir; refusing to stop or replace it"
      return 1
    fi

    mounts_json="$("$runner" /usr/bin/podman inspect --format '{{json .Mounts}}' "$container_id")" || {
      localai_installer_error "could not inspect existing container $container_id; refusing to stop or replace it"
      return 1
    }
    mounts="$(/usr/bin/python3 -c '
import json, posixpath, re, sys
# Podman builds an empty inspect-mount list as [] for containers with no
# user-specified mounts; reject null and other non-list values as ambiguous.
mounts = json.load(sys.stdin)
if not isinstance(mounts, list):
    raise SystemExit(2)
for mount in mounts:
    if not isinstance(mount, dict):
        raise SystemExit(2)
    raw_destination = mount.get("Destination")
    if not isinstance(raw_destination, str) or not raw_destination.startswith("/"):
        raise SystemExit(7)
    destination = posixpath.normpath(raw_destination)
    if raw_destination != destination or destination == "/":
        raise SystemExit(8)
    if destination != "/backends" and not destination.startswith("/backends/"):
        continue
    kind = mount.get("Type", "")
    name = mount.get("Name", "") or ""
    source = mount.get("Source", "")
    if kind not in ("bind", "volume"):
        raise SystemExit(3)
    if not re.fullmatch(r"[A-Za-z0-9_.-]*", name):
        raise SystemExit(4)
    if not re.fullmatch(r"/[A-Za-z0-9._/-]+", source):
        raise SystemExit(5)
    print(f"{kind}|{name}|{source}|{destination}")
' <<< "$mounts_json")" || {
      localai_installer_error "existing container $container_id has malformed mount metadata; refusing to stop or replace it"
      return 1
    }
    backend_mounts=0
    while IFS='|' read -r type volume source destination; do
      [[ -n "$type" ]] || continue
      backend_mounts=$((backend_mounts + 1))
      (( backend_mounts == 1 )) || {
        localai_installer_error "container $name has multiple /backends mounts; refusing to choose one"
        return 1
      }
      case "$type" in
        bind)
          suffix="${destination#/backends}"
          expected_source="${backend_destination}${suffix}"
          if [[ "$source" != "$expected_source" ]]; then
            localai_installer_error "container $name stores backends at $source for $destination, while the new service uses $expected_source; preserve or migrate it before retrying"
            return 1
          fi
          ;;
        volume)
          if ! [[ "$volume" =~ ^[A-Za-z0-9_.-]+$ ]]; then
            localai_installer_error "container $name has an unreadable /backends volume name"
            return 1
          fi
          volume_path_json="$("$runner" /usr/bin/podman volume inspect --format '{{json .Mountpoint}}' "$volume")" || {
            localai_installer_error "could not locate container $name /backends volume $volume"
            return 1
          }
          volume_path="$(/usr/bin/python3 -c '
import json, re, sys
path = json.load(sys.stdin)
if not isinstance(path, str) or not re.fullmatch(r"/[A-Za-z0-9._/-]+", path):
    raise SystemExit(2)
print(path)
' <<< "$volume_path_json")" || {
            localai_installer_error "container $name has malformed /backends volume path data"
            return 1
          }
          localai_installer_validate_managed_path "$volume_path" "legacy backend volume path" || return 1
          localai_installer_check_directory_chain "$volume_path" "legacy backend volume path" "$expected_uid" || return 1
          entries="$(/usr/bin/find -P "$volume_path" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" || {
            localai_installer_error "could not read container $name /backends volume contents"
            return 1
          }
          if [[ -n "$entries" ]]; then
            localai_installer_error "container $name has data in anonymous or named /backends volume $volume at $volume_path; refusing to stop or replace it because Podman may remove the only copy"
            return 1
          fi
          ;;
        *)
          localai_installer_error "container $name has an unsupported /backends mount type: $type"
          return 1
          ;;
      esac
    done <<< "$mounts"

    diff="$("$runner" /usr/bin/podman diff "$container_id")" || {
      localai_installer_error "could not inspect container $container_id writable-layer changes"
      return 1
    }
    if /usr/bin/awk '$2 == "/backends" || index($2, "/backends/") == 1 { found=1 } END { exit found ? 0 : 1 }' <<< "$diff"; then
      localai_installer_error "container $container_id has writable-layer data under /backends; preserve or migrate it before retrying"
      return 1
    fi
    LOCALAI_INSTALLER_VALIDATED_CONTAINER_IDS+=("$container_id")
  done <<< "$names"
}
