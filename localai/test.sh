#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
lock_file="$script_dir/localai.lock"

# shellcheck source=./localai.lock
# The sourced helper is checked independently.
# shellcheck disable=SC1091
source "$lock_file"

image_ref="${LOCALAI_IMAGE_REF_OVERRIDE:-$LOCALAI_IMAGE_REF}"
if [[ -n "${LOCALAI_IMAGE_DIGEST:-}" ]]; then
  image_ref="${image_ref%@*}@${LOCALAI_IMAGE_DIGEST}"
fi

podman image exists "$image_ref" || {
  printf 'Image not present locally: %s\n' "$image_ref" >&2
  printf 'Run the installer or pull it first.\n' >&2
  exit 1
}

service_user="${LOCALAI_SERVICE_USER:-localai}"
service_uid="$(id -u "$service_user")"
service_gid="$(id -g "$service_user")"

container_args=(
  --rm
  --no-healthcheck
  --network=none
  --userns=keep-id
  --group-add=keep-groups
  --security-opt=no-new-privileges
  --pids-limit=128
  --memory=512m
  --cpus=1
)

printf 'Checking the LocalAI CLI in the cached image.\n'
podman run "${container_args[@]}" "$image_ref" local-ai --help >/dev/null

test_root=/tmp/localai-runtime-writable-test
tmpfs_args=(
  --tmpfs "/tmp:rw,nosuid,nodev,uid=$service_uid,gid=$service_gid,mode=1777,size=8m"
)

printf 'Checking create/read/remove access to isolated writable paths.\n'
write_container_args=("${container_args[@]}" --user="$service_uid:$service_gid")
podman run "${write_container_args[@]}" "${tmpfs_args[@]}" \
  --env "HOME=$test_root/app-home" \
  --env "XDG_CACHE_HOME=$test_root/cache" \
  --env "TMPDIR=$test_root/tmp" \
  --env "LOCALAI_MODELS_PATH=$test_root/models" \
  --env "LOCALAI_DATA_PATH=$test_root/data" \
  --env "LOCALAI_CONFIG_DIR=$test_root/config" \
  --env "LOCALAI_GENERATED_CONTENT_PATH=$test_root/generated" \
  --env "LOCALAI_UPLOAD_PATH=$test_root/uploads" \
  --env "LOCALAI_CACHE_DIR=$test_root/cache" \
  --env "LOCALAI_LOG_DIR=$test_root/logs" \
  --env "LOCALAI_BACKENDS_PATH=$test_root/backends" \
  --env "LOCALAI_DOWNLOAD_STAGING_PATH=$test_root/downloading" \
  --env "LOCALAI_BACKEND_TEMP_DIR=$test_root/tmp" \
  --entrypoint /bin/sh \
  "$image_ref" -eu -c '
test_root=/tmp/localai-runtime-writable-test
umask 077
for subdir in app-home models data config generated uploads cache logs backends downloading tmp; do
  mkdir -p "$test_root/$subdir"
done
trap '\''rm -rf -- "$test_root"'\'' EXIT HUP INT TERM
nonce="$(date +%s%N)-$$"
for path in "$HOME" "$LOCALAI_MODELS_PATH" "$LOCALAI_DATA_PATH" \
  "$LOCALAI_CONFIG_DIR" "$LOCALAI_GENERATED_CONTENT_PATH" \
  "$LOCALAI_UPLOAD_PATH" "$LOCALAI_CACHE_DIR" "$LOCALAI_LOG_DIR" \
  "$LOCALAI_BACKENDS_PATH" "$LOCALAI_DOWNLOAD_STAGING_PATH" \
  "$LOCALAI_BACKEND_TEMP_DIR" /tmp; do
  [ -d "$path" ] || { printf "missing directory: %s\\n" "$path" >&2; exit 1; }
  file="$(mktemp "$path/.localai-write-probe.XXXXXXXXXX")"
  printf "%s\\n" "$nonce" > "$file"
  [ "$(cat "$file")" = "$nonce" ]
  rm -f -- "$file"
  printf "writable: %s\\n" "$path"
done
[ -d /backends ] || { printf "missing image backend directory /backends\\n" >&2; exit 1; }
'

