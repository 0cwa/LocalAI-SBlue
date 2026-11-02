#!/usr/bin/env bash
# TLS Compose rendering and static certificate selection helpers.

# Return success only when a fullchain's first certificate matches a private key.
# Public-key material is compared in memory; private-key contents are never printed.
localai_tls_static_key_matches() {
  if (( $# != 2 )); then
    return 2
  fi

  local fullchain="$1" key_path="$2" certificate_public_key key_public_key
  command -v openssl >/dev/null 2>&1 || return 2
  command -v base64 >/dev/null 2>&1 || return 2
  command -v tr >/dev/null 2>&1 || return 2
  [[ -f "$fullchain" && -r "$fullchain" && -f "$key_path" && -r "$key_path" ]] || return 2

  certificate_public_key="$(openssl x509 -in "$fullchain" -pubkey -noout 2>/dev/null)" || return 2
  [[ -n "$certificate_public_key" ]] || return 2
  certificate_public_key="$(
    set -o pipefail
    printf '%s\n' "$certificate_public_key" |
      openssl pkey -pubin -outform DER 2>/dev/null |
      base64 | tr -d '\n'
  )" || return 2
  [[ -n "$certificate_public_key" ]] || return 2

  key_public_key="$(
    set -o pipefail
    openssl pkey -in "$key_path" -pubout -outform DER -passin pass: 2>/dev/null |
      base64 | tr -d '\n'
  )" || return 2
  [[ -n "$key_public_key" ]] || return 2
  [[ "$certificate_public_key" == "$key_public_key" ]]
}

# Resolve the explicit/preferred leaf key or migrate an existing single matching
# key file without relying on a private hostname as its filename.
# Return codes: 1 no static material (normal internal-CA fallback),
# 2 incomplete, invalid, or unreadable input, 3 no matching key,
# 4 multiple matching keys.
localai_tls_resolve_static_key() {
  if (( $# != 5 )); then
    return 2
  fi

  local cert_dir="$1" fullchain="$2" leaf_name="$3"
  local explicit_key="$4" explicit_fullchain="$5"
  local preferred_key="${cert_dir%/}/$leaf_name.key" candidate match_status
  local -a matching_keys=()

  if [[ ! -e "$fullchain" && ! -L "$fullchain" ]]; then
    [[ "$explicit_fullchain" == 1 || -n "$explicit_key" ]] && return 2
    if [[ -e "$cert_dir" || -L "$cert_dir" ]]; then
      [[ -d "$cert_dir" && ! -L "$cert_dir" && -r "$cert_dir" && -x "$cert_dir" ]] || return 2
      while IFS= read -r -d '' candidate; do
        return 2
      done < <(find -P "$cert_dir" -maxdepth 1 \
        \( -name '*.key' -o -name '*.crt' -o -name '*.pem' \) -print0 2>/dev/null)
    fi
    printf '%s\n' "$preferred_key"
    return 1
  fi
  [[ -f "$fullchain" && -r "$fullchain" ]] || return 2

  if [[ -n "$explicit_key" ]]; then
    localai_tls_static_key_matches "$fullchain" "$explicit_key" || return 2
    printf '%s\n' "$explicit_key"
    return 0
  fi

  if [[ -e "$preferred_key" || -L "$preferred_key" ]]; then
    localai_tls_static_key_matches "$fullchain" "$preferred_key" || return 2
    printf '%s\n' "$preferred_key"
    return 0
  fi

  [[ -d "$cert_dir" && ! -L "$cert_dir" && -r "$cert_dir" && -x "$cert_dir" ]] || return 2
  while IFS= read -r -d '' candidate; do
    [[ -f "$candidate" && ! -L "$candidate" && -r "$candidate" ]] || return 2
    if localai_tls_static_key_matches "$fullchain" "$candidate"; then
      matching_keys+=("$candidate")
    else
      match_status=$?
      [[ "$match_status" == 1 ]] || return 2
    fi
  done < <(find -P "$cert_dir" -maxdepth 1 -name '*.key' -print0 2>/dev/null)

  case "${#matching_keys[@]}" in
    0) return 3 ;;
    1) printf '%s\n' "${matching_keys[0]}"; return 0 ;;
    *) return 4 ;;
  esac
}

# Return the canonical file path only when it is covered by an existing bind mount.
localai_tls_resolve_mounted_file() {
  if (( $# < 2 )); then
    return 2
  fi

  local file_path="$1" canonical_file mount_dir canonical_mount
  shift
  [[ "$file_path" == /* ]] || return 2
  canonical_file="$(/usr/bin/realpath -e -- "$file_path" 2>/dev/null)" || return 2
  [[ -f "$canonical_file" && -r "$canonical_file" ]] || return 2

  for mount_dir in "$@"; do
    [[ -d "$mount_dir" && ! -L "$mount_dir" ]] || return 2
    canonical_mount="$(/usr/bin/realpath -e -- "$mount_dir" 2>/dev/null)" || return 2
    [[ -d "$canonical_mount" && -r "$canonical_mount" && -x "$canonical_mount" ]] || return 2
    case "$canonical_file" in
      "$canonical_mount"/*)
        printf '%s\n' "$canonical_file"
        return 0
        ;;
    esac
  done
  return 1
}

localai_tls_compose_yaml_quote() {
  local value="$1"
  value="${value//\'/\'\'}"
  printf "'%s'" "$value"
}

localai_tls_compose_mount_dirs() {
  local path
  local -A seen=()
  for path in "$@"; do
    [[ -n "$path" ]] || continue
    if [[ -z "${seen[$path]+present}" ]]; then
      seen["$path"]=1
      printf '%s\n' "$path"
    fi
  done
}

localai_tls_compose_volume_entries() {
  local mount_dir
  while IFS= read -r mount_dir; do
    [[ -n "$mount_dir" ]] || continue
    printf '      - type: bind\n'
    printf '        source: %s\n' "$(localai_tls_compose_yaml_quote "$mount_dir")"
    printf '        target: %s\n' "$(localai_tls_compose_yaml_quote "$mount_dir")"
  done < <(localai_tls_compose_mount_dirs "$@")
}

# Render the production compose template with the same path list used by
# validation and installation. Arguments are:
# template image container state app-home storage data config-home cache
# config certs caddyfile.
localai_tls_render_compose_template() {
  if (( $# != 12 )); then
    printf 'localai_tls_render_compose_template expects 12 arguments\n' >&2
    return 2
  fi

  local template="$1" image_ref="$2" container_name="$3" state_dir="$4"
  local app_home_dir="$5" storage_dir="$6" data_home="$7" config_home="$8"
  local cache_dir="$9" config_dir="${10}" cert_dir="${11}" caddyfile_path="${12}"
  local volume_entries line token replacement index
  local -a tokens=(
    '@TLS_IMAGE_REF@' '@TLS_CONTAINER_NAME@' '@TLS_STATE_DIR@'
    '@TLS_APP_HOME_DIR@' '@TLS_STORAGE_DIR@' '@TLS_DATA_HOME@'
    '@TLS_CONFIG_HOME@' '@TLS_CACHE_DIR@' '@TLS_CONFIG_DIR@'
    '@TLS_CERT_DIR@' '@TLS_CADDYFILE_PATH@'
  )
  local -a replacements=(
    "$(localai_tls_compose_yaml_quote "$image_ref")"
    "$(localai_tls_compose_yaml_quote "$container_name")"
    "$(localai_tls_compose_yaml_quote "$state_dir")"
    "$(localai_tls_compose_yaml_quote "$app_home_dir")"
    "$(localai_tls_compose_yaml_quote "$storage_dir")"
    "$(localai_tls_compose_yaml_quote "$data_home")"
    "$(localai_tls_compose_yaml_quote "$config_home")"
    "$(localai_tls_compose_yaml_quote "$cache_dir")"
    "$(localai_tls_compose_yaml_quote "$config_dir")"
    "$(localai_tls_compose_yaml_quote "$cert_dir")"
    "$(localai_tls_compose_yaml_quote "$caddyfile_path")"
  )
  volume_entries="$(localai_tls_compose_volume_entries \
    "$config_dir" "$storage_dir" "$data_home" "$config_home" \
    "$cache_dir" "$cert_dir" "$app_home_dir")"

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == *'@TLS_VOLUME_ENTRIES@'* ]]; then
      local prefix="${line%%@TLS_VOLUME_ENTRIES@*}"
      local suffix="${line#*@TLS_VOLUME_ENTRIES@}"
      printf '%s%s%s\n' "$prefix" "$volume_entries" "$suffix"
      continue
    fi
    for index in "${!tokens[@]}"; do
      token="${tokens[$index]}"
      replacement="${replacements[$index]}"
      line="${line//"$token"/$replacement}"
    done
    printf '%s\n' "$line"
  done < "$template"
}

# Render the production user-unit template. Arguments are:
# template uid state-dir compose-file project-name.
localai_tls_render_compose_service_template() {
  if (( $# != 5 )); then
    printf 'localai_tls_render_compose_service_template expects 5 arguments\n' >&2
    return 2
  fi

  local template="$1" line token replacement index
  local -a tokens=(
    '@TLS_UID@' '@TLS_STATE_DIR@' '@TLS_COMPOSE_FILE@'
    '@TLS_COMPOSE_PROJECT_NAME@'
  )
  local -a replacements=("$2" "$3" "$4" "$5")

  while IFS= read -r line || [[ -n "$line" ]]; do
    for index in "${!tokens[@]}"; do
      token="${tokens[$index]}"
      replacement="${replacements[$index]}"
      line="${line//"$token"/$replacement}"
    done
    printf '%s\n' "$line"
  done < "$template"
}
