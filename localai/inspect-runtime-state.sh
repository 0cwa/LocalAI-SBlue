#!/usr/bin/env bash
set -euo pipefail

service_user="${LOCALAI_SERVICE_USER:-localai}"
service_home="$(getent passwd "$service_user" | cut -d: -f6)"
if [[ -z "$service_home" ]]; then
  printf 'Service account not found: %s\n' "$service_user" >&2
  exit 2
fi

service_uid="$(id -u "$service_user")"
if [[ "$(id -u)" != "$service_uid" ]]; then
  printf 'Run this inspector as %s (uid %s) so Podman reads the service account storage.\n' \
    "$service_user" "$service_uid" >&2
  exit 2
fi

container_name="${1:-${LOCALAI_CONTAINER_NAME:-localai}}"
state_dir="${2:-${LOCALAI_RUNTIME_STATE_DIR:-$service_home}}"
unit_name="${3:-localai.service}"

printf '=== LocalAI runtime metadata (read-only) ===\n'
printf 'account: '
id
printf 'container=%s\nstate_dir=%s\nunit=%s\n' "$container_name" "$state_dir" "$unit_name"

printf '\n=== user service state ===\n'
systemctl --user show "$unit_name" --no-pager \
  --property=LoadState,ActiveState,SubState,Result,ExecMainStatus,FragmentPath || true

printf '\n=== service-account processes (arguments omitted) ===\n'
ps -u "$service_uid" -o uid,gid,pid,ppid,stat,comm --sort=pid || true

printf '\n=== container image and runtime metadata ===\n'
if ! podman container exists "$container_name"; then
  printf 'container not present: %s\n' "$container_name"
  exit 0
fi

podman inspect --format \
  'name={{.Name}} status={{.State.Status}} pid={{.State.Pid}} image_name={{.ImageName}} image_id={{.Image}} configured_user={{if .Config.User}}{{.Config.User}}{{else}}<empty>{{end}} process_label={{.ProcessLabel}}' \
  "$container_name"
image_id="$(podman inspect --format '{{.Image}}' "$container_name")"
podman image inspect --format \
  'image_id={{.Id}} digest={{.Digest}} repo_digests={{json .RepoDigests}} created={{.Created}} os={{.Os}} arch={{.Architecture}} configured_user={{if .Config.User}}{{.Config.User}}{{else}}<empty>{{end}}' \
  "$image_id"

printf '\n=== container mounts (source, destination, read/write) ===\n'
podman inspect --format \
  '{{range .Mounts}}{{printf "%s -> %s | type=%s rw=%t\n" .Source .Destination .Type .RW}}{{end}}' \
  "$container_name"

printf '\n=== installed LocalAI version and storage defaults ===\n'
podman exec "$container_name" /local-ai --version 2>&1 | head -n 5 || true
podman exec "$container_name" /local-ai run --help 2>&1 \
  | grep -E 'backends-path|backends-system-path|download-staging-path|backend-temp-dir|models-path|data-path|localai-config-dir|generated-content-path|upload-path' \
  | head -n 40 || true

printf '\n=== in-container identity, selected path variables, and modes ===\n'
podman exec "$container_name" /bin/sh -eu -c '
printf "identity: uid=%s gid=%s groups=%s\n" "$(id -u)" "$(id -g)" "$(id -G)"
for key in HOME XDG_CACHE_HOME LOCALAI_MODELS_PATH MODELS_PATH LOCALAI_DATA_PATH \
  LOCALAI_CONFIG_DIR LOCALAI_GENERATED_CONTENT_PATH LOCALAI_UPLOAD_PATH \
  LOCALAI_CACHE_DIR LOCALAI_LOG_DIR LOCALAI_BACKENDS_PATH \
  LOCALAI_DOWNLOAD_STAGING_PATH LOCALAI_BACKEND_TEMP_DIR; do
  value="$(printenv "$key" 2>/dev/null || true)"
  [ -n "$value" ] || value="<unset>"
  printf "%s=%s\n" "$key" "$value"
done
state_dir="$1"
for path in "$HOME" "$state_dir" "$state_dir/app-home" \
  "$state_dir/models" "$state_dir/data" "$state_dir/config" \
  "$state_dir/generated" "$state_dir/uploads" "$state_dir/cache" \
  "$state_dir/logs" "$state_dir/backends" "$state_dir/downloading" \
  "$state_dir/tmp" /backends /var/lib/local-ai/backends /tmp; do
  if [ -e "$path" ]; then
    stat -c "mode=%a uid=%u gid=%g type=%F path=%n" "$path"
  else
    printf "missing path=%s\n" "$path"
  fi
done
for path in /backends /var/lib/local-ai/backends; do
  if [ -d "$path" ]; then
    printf "entries in %s (names and types only; first 40):\n" "$path"
    find "$path" -mindepth 1 -maxdepth 1 -printf "%f\t%y\n" | sort | head -n 40
    if ! timeout --foreground 5s du -sh "$path" 2>/dev/null; then
      printf "size not computed (5-second limit): %s\n" "$path"
    fi
  fi
done
' localai-runtime-inspector "$state_dir"

printf '\n=== host-side state directory modes and SELinux labels ===\n'
for path in "$state_dir" "$state_dir/app-home" "$state_dir/models" \
  "$state_dir/data" "$state_dir/config" "$state_dir/generated" \
  "$state_dir/uploads" "$state_dir/cache" "$state_dir/logs" \
  "$state_dir/backends" "$state_dir/downloading" "$state_dir/tmp"; do
  if [[ -e "$path" ]]; then
    stat -c 'mode=%a uid=%u gid=%g type=%F path=%n' "$path"
    ls -Zd -- "$path" 2>/dev/null || true
  else
    printf 'missing path=%s\n' "$path"
  fi
done
