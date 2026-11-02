#!/usr/bin/env bash
set -euo pipefail

service_user="${LOCALAI_SERVICE_USER:-localai}"
service_uid="$(id -u "$service_user" 2>/dev/null || true)"
if [[ -z "$service_uid" || "$(id -u)" != "$service_uid" ]]; then
  printf 'Run this probe as the %s service account.\n' "$service_user" >&2
  exit 2
fi

confirm_probe=0
container_name="${LOCALAI_CONTAINER_NAME:-localai}"
if [[ "${1:-}" == "--confirm-write-probe" ]]; then
  confirm_probe=1
  container_name="${2:-$container_name}"
elif [[ -n "${1:-}" ]]; then
  container_name="$1"
fi

if ! podman container exists "$container_name"; then
  printf 'Container is not present: %s\n' "$container_name" >&2
  exit 1
fi

if [[ "$confirm_probe" != "1" ]]; then
  printf 'Write-probe candidates in existing container %s (missing directories are skipped):\n' "$container_name" >&2
  podman exec "$container_name" /bin/sh -eu -c '
for dir in "$HOME" \
  "${LOCALAI_MODELS_PATH:-/models}" \
  "${LOCALAI_DATA_PATH:-/data}" \
  "${LOCALAI_CONFIG_DIR:-/configuration}" \
  "${LOCALAI_GENERATED_CONTENT_PATH:-${TMPDIR:-/tmp}/localai-generated}" \
  "${LOCALAI_UPLOAD_PATH:-${TMPDIR:-/tmp}/localai-upload}" \
  "${LOCALAI_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}}" \
  "${LOCALAI_LOG_DIR:-}" \
  "${LOCALAI_BACKENDS_PATH:-}" \
  /backends \
  "${LOCALAI_DOWNLOAD_STAGING_PATH:-/downloading}" \
  "${LOCALAI_BACKEND_TEMP_DIR:-${TMPDIR:-/tmp}}" \
  /tmp; do
  [ -n "$dir" ] && printf "%s\\n" "$dir"
done | awk "NF && !seen[\\$0]++"
' >&2
  printf 'The system-backend fallback /var/lib/local-ai/backends is not write-probed.\n' >&2
  printf 'Rerun with --confirm-write-probe [container] to create, read, and remove one unique file per existing candidate.\n' >&2
  exit 2
fi

podman exec "$container_name" /bin/sh -eu -c '
nonce="$(date +%s%N)-$$"
created=""
seen=""
failures=0
cleanup() {
  for file in $created; do
    rm -f -- "$file"
  done
}
trap cleanup EXIT HUP INT TERM

for dir in "$HOME" \
  "${LOCALAI_MODELS_PATH:-/models}" \
  "${LOCALAI_DATA_PATH:-/data}" \
  "${LOCALAI_CONFIG_DIR:-/configuration}" \
  "${LOCALAI_GENERATED_CONTENT_PATH:-${TMPDIR:-/tmp}/localai-generated}" \
  "${LOCALAI_UPLOAD_PATH:-${TMPDIR:-/tmp}/localai-upload}" \
  "${LOCALAI_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}}" \
  "${LOCALAI_LOG_DIR:-}" \
  "${LOCALAI_BACKENDS_PATH:-}" \
  /backends \
  "${LOCALAI_DOWNLOAD_STAGING_PATH:-/downloading}" \
  "${LOCALAI_BACKEND_TEMP_DIR:-${TMPDIR:-/tmp}}" \
  /tmp; do
  [ -n "$dir" ] || continue
  case " $seen " in
    *" $dir "*) continue ;;
  esac
  seen="$seen $dir"
  if [ ! -d "$dir" ]; then
    printf "skipped missing directory: %s\n" "$dir"
    continue
  fi
  if ! file="$(mktemp "$dir/.localai-write-probe.XXXXXXXXXX" 2>/dev/null)"; then
    printf "write failed: %s\n" "$dir"
    failures=$((failures + 1))
    continue
  fi
  created="$created $file"
  if ! printf "%s\n" "$nonce" > "$file" || [ "$(cat "$file" 2>/dev/null || true)" != "$nonce" ]; then
    printf "readback failed: %s\n" "$dir"
    failures=$((failures + 1))
  elif rm -f -- "$file"; then
    printf "write/read/remove succeeded: %s\n" "$dir"
  else
    printf "remove failed: %s\n" "$dir"
    failures=$((failures + 1))
  fi
done

exit "$failures"
'
