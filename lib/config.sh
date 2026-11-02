#!/usr/bin/env bash
# Strict, non-evaluating LocalAI configuration loader.
#
# The file format is deliberately small:
#   KEY=VALUE
# with full-line comments beginning with '#'. Values are never sourced or
# eval'd. Callers should load this file before applying compatibility
# environment overrides and explicit command-line overrides.

LOCALAI_CONFIG_KEYS=(
  LOCALAI_IMAGE_REF
  LOCALAI_IMAGE_DIGEST
  LOCALAI_CONTAINER_NAME
  LOCALAI_SERVICE_USER
  LOCALAI_STATE_DIR
  LOCALAI_BIND_HOST
  LOCALAI_BIND_PORT
  LOCALAI_AUTH
  LOCALAI_REGISTRATION_MODE
  LOCALAI_LOG_LEVEL
  LOCALAI_MODELS_PATH
  LOCALAI_BACKENDS_PATH
  LOCALAI_DOWNLOAD_STAGING_PATH
  LOCALAI_BACKEND_TEMP_DIR
  LOCALAI_DATA_PATH
  LOCALAI_CONFIG_DIR
  LOCALAI_GENERATED_CONTENT_PATH
  LOCALAI_UPLOAD_PATH
  LOCALAI_CACHE_DIR
  LOCALAI_LOG_DIR
  LOCALAI_F16
  LOCALAI_TLS_ENABLED
  LOCALAI_TLS_USER
  LOCALAI_TLS_STATE_DIR
  LOCALAI_TLS_CONFIG_DIR
  LOCALAI_TLS_CACHE_DIR
  LOCALAI_TLS_CERT_DIR
  LOCALAI_TLS_COMPOSE_DIR
  LOCALAI_TLS_COMPOSE_FILE_NAME
  LOCALAI_TLS_COMPOSE_PROJECT_NAME
  LOCALAI_TLS_PUBLIC_SOCKET
  LOCALAI_TLS_PUBLIC_HOST
  LOCALAI_TLS_PUBLIC_PORT
  LOCALAI_TLS_INTERNAL_HOST
  LOCALAI_TLS_INTERNAL_PORT
  LOCALAI_TLS_HOSTNAMES
  LOCALAI_TLS_IMAGE_REF
  LOCALAI_TLS_IMAGE_DIGEST
  LOCALAI_TLS_CONTAINER_NAME
  LOCALAI_TLS_SERVICE_NAME
  LOCALAI_TLS_FORWARD_SERVICE_NAME
  LOCALAI_TLS_FORWARD_SOCKET_NAME
  LOCALAI_WEB_URL
  LOCALAI_HTTPS_URL
)

declare -Ag LOCALAI_CONFIG_SEEN=()
# Capture process environment once, before the first load writes defaults into
# exported variables. Later loads reuse this snapshot; callers that need a
# same-process change should use localai_config_override after loading.
declare -Ag LOCALAI_CONFIG_ENV_OVERRIDES=()
LOCALAI_CONFIG_ENV_SNAPSHOT_READY=0

localai_config_die() {
  printf 'LocalAI config error: %s\n' "$*" >&2
  return 1
}

localai_config_is_key() {
  local candidate="$1" key
  for key in "${LOCALAI_CONFIG_KEYS[@]}"; do
    [[ "$candidate" == "$key" ]] && return 0
  done
  return 1
}

localai_config_validate_key() {
  local key="$1"
  if ! [[ "$key" =~ ^[A-Z][A-Z0-9_]+$ ]]; then
    localai_config_die "invalid key '$key'"
    return 1
  fi
  if ! localai_config_is_key "$key"; then
    localai_config_die "unknown key '$key'"
    return 1
  fi
}

localai_config_validate_value_syntax() {
  local key="$1" value="$2"
  # No quoting, whitespace, shell metacharacters, percent signs, or control
  # characters. Percent is reserved because systemd expands specifiers in
  # Environment= values generated from this config.
  if [[ "$value" == *[[:space:][:cntrl:]]* ]]; then
    localai_config_die "$key contains whitespace or control characters"
    return 1
  fi
  if [[ "$value" == *%* ]]; then
    localai_config_die "$key may not contain '%' because systemd expands unit specifiers in generated Environment values"
    return 1
  fi
  if ! [[ "$value" =~ ^[A-Za-z0-9_./:@,+=-]*$ ]]; then
    localai_config_die "$key contains unsupported characters"
    return 1
  fi
}

localai_config_set() {
  local key="$1" value="$2"
  localai_config_validate_key "$key" || return 1
  localai_config_validate_value_syntax "$key" "$value" || return 1
  if [[ -n "${LOCALAI_CONFIG_SEEN[$key]+x}" ]]; then
    localai_config_die "duplicate key '$key'"
    return 1
  fi
  LOCALAI_CONFIG_SEEN["$key"]=1
  printf -v "$key" '%s' "$value"
}

localai_config_capture_environment() {
  [[ "$LOCALAI_CONFIG_ENV_SNAPSHOT_READY" == 1 ]] && return 0
  local key value
  for key in "${LOCALAI_CONFIG_KEYS[@]}" SERVICE_BIND_HOST SERVICE_BIND_PORT LOCALAI_TLS_BIND_HOST LOCALAI_TLS_BIND_PORT; do
    if value="$(printenv "$key" 2>/dev/null)" && [[ -n "$value" ]]; then
      LOCALAI_CONFIG_ENV_OVERRIDES["$key"]="$value"
    fi
  done
  LOCALAI_CONFIG_ENV_SNAPSHOT_READY=1
}

localai_config_load_file() {
  local config_file="$1" line number=0 key value
  [[ -f "$config_file" ]] || localai_config_die "config file is not a regular file: $config_file"
  while IFS= read -r line || [[ -n "$line" ]]; do
    number=$((number + 1))
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" != *=* ]]; then
      localai_config_die "$config_file:$number must be KEY=VALUE"
      return 1
    fi
    key="${line%%=*}"
    value="${line#*=}"
    if ! localai_config_set "$key" "$value"; then
      localai_config_die "$config_file:$number is invalid"
      return 1
    fi
  done < "$config_file"
}

localai_config_load_legacy_file() {
  local config_file="$1" line number=0 key value
  [[ -f "$config_file" ]] || localai_config_die "legacy config file is not a regular file: $config_file"
  while IFS= read -r line || [[ -n "$line" ]]; do
    number=$((number + 1))
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" != *=* ]]; then
      localai_config_die "$config_file:$number must be KEY=VALUE"
      return 1
    fi
    key="${line%%=*}"
    value="${line#*=}"
    # The historical lock uses shell-style double quotes. Remove only one
    # balanced pair; never evaluate the value as shell code.
    if [[ "$value" == \"*\" ]]; then
      value="${value:1:${#value}-2}"
    fi
    case "$key" in
      LOCK_SCHEMA) [[ "$value" == 1 ]] || localai_config_die "unsupported legacy LOCK_SCHEMA '$value'" || return 1 ;;
      SERVICE_BIND_HOST) localai_config_set LOCALAI_BIND_HOST "$value" || return 1 ;;
      SERVICE_BIND_PORT) localai_config_set LOCALAI_BIND_PORT "$value" || return 1 ;;
      *) localai_config_set "$key" "$value" || return 1 ;;
    esac
  done < "$config_file"
}

localai_config_defaults() {
  localai_config_capture_environment
  LOCALAI_CONFIG_SEEN=()
  LOCALAI_IMAGE_REF="docker.io/localai/localai:latest-gpu-hipblas"
  LOCALAI_IMAGE_DIGEST=""
  LOCALAI_CONTAINER_NAME="localai"
  LOCALAI_SERVICE_USER="localai"
  LOCALAI_STATE_DIR="/var/lib/localai"
  LOCALAI_BIND_HOST="127.0.0.1"
  LOCALAI_BIND_PORT="11455"
  LOCALAI_AUTH="true"
  LOCALAI_REGISTRATION_MODE="approval"
  LOCALAI_LOG_LEVEL="info"
  LOCALAI_MODELS_PATH="/var/lib/localai/models"
  LOCALAI_BACKENDS_PATH="/var/lib/localai/backends"
  LOCALAI_DOWNLOAD_STAGING_PATH="/var/lib/localai/downloading"
  LOCALAI_BACKEND_TEMP_DIR="/var/lib/localai/tmp"
  LOCALAI_DATA_PATH="/var/lib/localai/data"
  LOCALAI_CONFIG_DIR="/var/lib/localai/config"
  LOCALAI_GENERATED_CONTENT_PATH="/var/lib/localai/generated"
  LOCALAI_UPLOAD_PATH="/var/lib/localai/uploads"
  LOCALAI_CACHE_DIR="/var/lib/localai/cache"
  LOCALAI_LOG_DIR="/var/lib/localai/logs"
  LOCALAI_F16="true"
  LOCALAI_TLS_ENABLED="false"
  LOCALAI_TLS_USER="localai-tls"
  LOCALAI_TLS_STATE_DIR="/var/lib/localai-tls"
  # Empty TLS subpaths derive from LOCALAI_TLS_STATE_DIR after config/env
  # precedence has been applied.
  LOCALAI_TLS_CONFIG_DIR=""
  LOCALAI_TLS_CACHE_DIR=""
  LOCALAI_TLS_CERT_DIR=""
  LOCALAI_TLS_COMPOSE_DIR=""
  LOCALAI_TLS_COMPOSE_FILE_NAME="localai-tls-compose.yaml"
  LOCALAI_TLS_COMPOSE_PROJECT_NAME="localai-tls"
  LOCALAI_TLS_PUBLIC_SOCKET="true"
  LOCALAI_TLS_PUBLIC_HOST=""
  LOCALAI_TLS_PUBLIC_PORT="443"
  LOCALAI_TLS_INTERNAL_HOST="127.0.0.1"
  LOCALAI_TLS_INTERNAL_PORT="8443"
  LOCALAI_TLS_HOSTNAMES="localai.internal"
  LOCALAI_TLS_IMAGE_REF="docker.io/library/caddy:2-alpine"
  LOCALAI_TLS_IMAGE_DIGEST=""
  LOCALAI_TLS_CONTAINER_NAME="localai-tls"
  LOCALAI_TLS_SERVICE_NAME="localai-tls-compose.service"
  LOCALAI_TLS_FORWARD_SERVICE_NAME="localai-tls-forward.service"
  LOCALAI_TLS_FORWARD_SOCKET_NAME="localai-tls-forward.socket"
  # Retained as accepted compatibility keys for older config files. Endpoint
  # URLs are derived dynamically from bind and TLS settings by localaictl.
  LOCALAI_WEB_URL=""
  LOCALAI_HTTPS_URL=""
}

localai_config_apply_environment() {
  local key value
  # Apply the environment captured before defaults replaced exported values.
  for key in "${LOCALAI_CONFIG_KEYS[@]}"; do
    if [[ -n "${LOCALAI_CONFIG_ENV_OVERRIDES[$key]+x}" ]]; then
      value="${LOCALAI_CONFIG_ENV_OVERRIDES[$key]}"
      # Re-exec wrappers intentionally pass empty placeholders for optional
      # settings. Treat those as unset so they do not erase safe defaults;
      # an explicit empty value belongs in the canonical config file, where
      # normal validation still applies.
      localai_config_validate_value_syntax "$key" "$value" || return 1
      LOCALAI_CONFIG_SEEN["$key"]=1
      printf -v "$key" '%s' "$value"
    fi
  done
  # Preserve names used by existing installers during migration. Canonical
  # LOCALAI_* names take precedence when both forms are supplied.
  if [[ -z "${LOCALAI_CONFIG_ENV_OVERRIDES[LOCALAI_BIND_HOST]+x}" && -n "${LOCALAI_CONFIG_ENV_OVERRIDES[SERVICE_BIND_HOST]+x}" ]]; then
    value="${LOCALAI_CONFIG_ENV_OVERRIDES[SERVICE_BIND_HOST]}"
    localai_config_validate_value_syntax LOCALAI_BIND_HOST "$value" || return 1
    LOCALAI_BIND_HOST="$value"
    LOCALAI_CONFIG_SEEN[LOCALAI_BIND_HOST]=1
  fi
  if [[ -z "${LOCALAI_CONFIG_ENV_OVERRIDES[LOCALAI_BIND_PORT]+x}" && -n "${LOCALAI_CONFIG_ENV_OVERRIDES[SERVICE_BIND_PORT]+x}" ]]; then
    value="${LOCALAI_CONFIG_ENV_OVERRIDES[SERVICE_BIND_PORT]}"
    localai_config_validate_value_syntax LOCALAI_BIND_PORT "$value" || return 1
    LOCALAI_BIND_PORT="$value"
    LOCALAI_CONFIG_SEEN[LOCALAI_BIND_PORT]=1
  fi
  if [[ -z "${LOCALAI_CONFIG_ENV_OVERRIDES[LOCALAI_TLS_PUBLIC_HOST]+x}" && -n "${LOCALAI_CONFIG_ENV_OVERRIDES[LOCALAI_TLS_BIND_HOST]+x}" ]]; then
    value="${LOCALAI_CONFIG_ENV_OVERRIDES[LOCALAI_TLS_BIND_HOST]}"
    localai_config_validate_value_syntax LOCALAI_TLS_PUBLIC_HOST "$value" || return 1
    LOCALAI_TLS_PUBLIC_HOST="$value"
    LOCALAI_CONFIG_SEEN[LOCALAI_TLS_PUBLIC_HOST]=1
  fi
  if [[ -z "${LOCALAI_CONFIG_ENV_OVERRIDES[LOCALAI_TLS_PUBLIC_PORT]+x}" && -n "${LOCALAI_CONFIG_ENV_OVERRIDES[LOCALAI_TLS_BIND_PORT]+x}" ]]; then
    value="${LOCALAI_CONFIG_ENV_OVERRIDES[LOCALAI_TLS_BIND_PORT]}"
    localai_config_validate_value_syntax LOCALAI_TLS_PUBLIC_PORT "$value" || return 1
    LOCALAI_TLS_PUBLIC_PORT="$value"
    LOCALAI_CONFIG_SEEN[LOCALAI_TLS_PUBLIC_PORT]=1
  fi
}

localai_config_override() {
  local key="$1" value="$2"
  localai_config_validate_key "$key" || return 1
  localai_config_validate_value_syntax "$key" "$value" || return 1
  printf -v "$key" '%s' "$value"
  LOCALAI_CONFIG_SEEN["$key"]=1
}

localai_config_resolve_tls_paths() {
  [[ -n "$LOCALAI_TLS_CONFIG_DIR" ]] || LOCALAI_TLS_CONFIG_DIR="${LOCALAI_TLS_STATE_DIR%/}/caddy"
  [[ -n "$LOCALAI_TLS_CACHE_DIR" ]] || LOCALAI_TLS_CACHE_DIR="${LOCALAI_TLS_STATE_DIR%/}/cache"
  [[ -n "$LOCALAI_TLS_CERT_DIR" ]] || LOCALAI_TLS_CERT_DIR="${LOCALAI_TLS_STATE_DIR%/}/certs"
  [[ -n "$LOCALAI_TLS_COMPOSE_DIR" ]] || LOCALAI_TLS_COMPOSE_DIR="${LOCALAI_TLS_STATE_DIR%/}/.local/share/localai-tls-compose"
}

localai_config_validate() {
  local key value
  localai_config_resolve_tls_paths
  for key in "${LOCALAI_CONFIG_KEYS[@]}"; do
    value="${!key-}"
    localai_config_validate_value_syntax "$key" "$value" || return 1
  done
  for key in LOCALAI_BIND_PORT LOCALAI_TLS_PUBLIC_PORT LOCALAI_TLS_INTERNAL_PORT; do
    value="${!key}"
    if ! [[ "$value" =~ ^[0-9]+$ ]] || ! (( value >= 1 && value <= 65535 )); then
      localai_config_die "$key must be a port in [1,65535]"
      return 1
    fi
  done
  for key in LOCALAI_AUTH LOCALAI_F16 LOCALAI_TLS_ENABLED LOCALAI_TLS_PUBLIC_SOCKET; do
    value="${!key}"
    if [[ "$value" != true && "$value" != false ]]; then
      localai_config_die "$key must be true or false"
      return 1
    fi
  done
  for key in LOCALAI_SERVICE_USER LOCALAI_CONTAINER_NAME LOCALAI_TLS_USER LOCALAI_TLS_CONTAINER_NAME LOCALAI_TLS_SERVICE_NAME LOCALAI_TLS_FORWARD_SERVICE_NAME LOCALAI_TLS_FORWARD_SOCKET_NAME LOCALAI_TLS_COMPOSE_PROJECT_NAME; do
    value="${!key}"
    if ! [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]]; then
      localai_config_die "$key must be an identifier"
      return 1
    fi
    if [[ ( "$key" == LOCALAI_SERVICE_USER || "$key" == LOCALAI_TLS_USER ) && ( "$value" == root || "$value" == 0 ) ]]; then
      localai_config_die "$key must not name the root account"
      return 1
    fi
  done
  if ! [[ "$LOCALAI_TLS_COMPOSE_FILE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    localai_config_die "LOCALAI_TLS_COMPOSE_FILE_NAME must be a simple filename"
    return 1
  fi
  for key in LOCALAI_STATE_DIR LOCALAI_MODELS_PATH LOCALAI_BACKENDS_PATH LOCALAI_DOWNLOAD_STAGING_PATH LOCALAI_BACKEND_TEMP_DIR LOCALAI_DATA_PATH LOCALAI_CONFIG_DIR LOCALAI_GENERATED_CONTENT_PATH LOCALAI_UPLOAD_PATH LOCALAI_CACHE_DIR LOCALAI_LOG_DIR LOCALAI_TLS_STATE_DIR LOCALAI_TLS_CONFIG_DIR LOCALAI_TLS_CACHE_DIR LOCALAI_TLS_CERT_DIR LOCALAI_TLS_COMPOSE_DIR; do
    value="${!key}"
    if ! [[ "$value" == /* ]]; then
      localai_config_die "$key must be an absolute path"
      return 1
    fi
  done
  if [[ "$LOCALAI_TLS_ENABLED" == true && "$LOCALAI_TLS_PUBLIC_SOCKET" == true && -z "$LOCALAI_TLS_PUBLIC_HOST" ]]; then
    localai_config_die "LOCALAI_TLS_PUBLIC_HOST is required when the TLS public socket is enabled"
    return 1
  fi
}

localai_config_load() {
  local config_file="${1:-}"
  localai_config_defaults
  if [[ -n "$config_file" && -e "$config_file" ]]; then
    localai_config_load_file "$config_file" || return 1
  fi
  localai_config_apply_environment || return 1
  localai_config_validate
}

localai_config_load_compat() {
  local canonical_file="$1" legacy_file="$2"
  localai_config_defaults
  if [[ -f "$canonical_file" ]]; then
    localai_config_load_file "$canonical_file" || return 1
  elif [[ -f "$legacy_file" ]]; then
    localai_config_load_legacy_file "$legacy_file" || return 1
  fi
  localai_config_apply_environment || return 1
  localai_config_validate
}

localai_config_dump() {
  local key
  localai_config_resolve_tls_paths
  for key in "${LOCALAI_CONFIG_KEYS[@]}"; do
    printf '%s=%s\n' "$key" "${!key-}"
  done
}
