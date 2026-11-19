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

# The quoted text is intentionally evaluated by another shell.
# shellcheck disable=SC2016
printf 'LOCK_SCHEMA=1\nLOCALAI_BIND_HOST=$(touch %s)\n' "$marker" >"$tmp_dir/assets/localai.lock"

# Exercise the production selector with fixture sources. A real installed
# configuration would otherwise win precedence and hide the legacy lock.
{
  printf 'source %q\n' "$repo_root/lib/installer_safety.sh"
  sed -n '/^localai_installer_select_config() {$/,/^}/p' "$repo_root/lib/installer_safety.sh" |
    sed '1s/localai_installer_select_config/select_fixture_config/'
  cat <<'EOF'
localai_installer_select_config() {
  select_fixture_config "$LOCALAI_FIXTURE_CONFIG_DIR/canonical" "" \
    "$LOCALAI_FIXTURE_CONFIG_DIR/system" "$LOCALAI_FIXTURE_CONFIG_DIR/checkout" "$5"
}
EOF
} >"$tmp_dir/installer-safety-fixture.sh"
if LOCALAI_ASSET_DIR="$tmp_dir/assets" \
  LOCALAI_INSTALLER_SAFETY_LIB="$tmp_dir/installer-safety-fixture.sh" \
  LOCALAI_FIXTURE_CONFIG_DIR="$tmp_dir" \
  bash "$repo_root/secureblue-localai-install/uninstall.sh" --help >"$tmp_dir/uninstall.log" 2>&1; then
  printf 'malicious legacy lock was unexpectedly accepted\n' >&2
  exit 1
fi
rg -q 'LOCALAI_BIND_HOST contains whitespace or control characters' "$tmp_dir/uninstall.log"
[[ ! -e "$marker" ]]

printf 'uninstall config safety tests passed\n'
