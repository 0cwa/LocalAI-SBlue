#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_REPO_ROOT="$repo_root"
source "$repo_root/scripts/test-support.sh"
test_sanitize_localai_environment
tmp_dir="$(test_mktemp_dir uninstall-config)"
trap 'rm -rf -- "$tmp_dir"' EXIT
marker="$tmp_dir/localai-uninstall-config-pwned"
mkdir -p "$tmp_dir/assets"

printf 'LOCK_SCHEMA=1\nLOCALAI_BIND_HOST=$(touch %s)\n' "$marker" >"$tmp_dir/assets/localai.lock"

if LOCALAI_ASSET_DIR="$tmp_dir/assets" \
  LOCALAI_CONFIG_FILE="$tmp_dir/no-canonical.conf" \
  bash "$repo_root/secureblue-localai-install/uninstall.sh" --help >/dev/null 2>&1; then
  printf 'malicious legacy lock was unexpectedly accepted\n' >&2
  exit 1
fi
[[ ! -e "$marker" ]]

printf 'uninstall config safety tests passed\n'
