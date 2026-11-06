#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_REPO_ROOT="$repo_root"
source "$repo_root/scripts/test-support.sh"
test_sanitize_localai_environment
work_dir="$(test_mktemp_dir tray-install)"
trap 'rm -rf -- "$work_dir"' EXIT

home_dir="$work_dir/home"
data_home="$work_dir/data"
bin_home="$work_dir/bin"
mkdir -p "$home_dir"
install_dir="$data_home/localai-tray"

if ! /usr/bin/python3 -c 'import PyQt6' >/dev/null 2>&1; then
  rg -q 'install -m 0644 .*lib/backup_archive\.py.*backup_archive\.py' "$repo_root/localai-tray/install.sh"
  rg -q 'rm -rf --one-file-system "\$install_dir"' "$repo_root/localai-tray/uninstall.sh"
  printf 'Tray install dependency unavailable; helper install/uninstall declarations passed.\n'
  exit 0
fi

HOME="$home_dir" XDG_DATA_HOME="$data_home" XDG_BIN_HOME="$bin_home" \
  bash "$repo_root/localai-tray/install.sh" >/dev/null
[[ -f "$install_dir/backup_archive.py" && ! -L "$install_dir/backup_archive.py" ]]
[[ "$(stat -c '%a' "$install_dir/backup_archive.py")" == 644 ]]
cmp -s "$repo_root/lib/backup_archive.py" "$install_dir/backup_archive.py"
[[ -x "$install_dir/localaictl" ]]

HOME="$home_dir" XDG_DATA_HOME="$data_home" XDG_BIN_HOME="$bin_home" \
  bash "$repo_root/localai-tray/uninstall.sh" >/dev/null
[[ ! -e "$install_dir" && ! -L "$install_dir" ]]
[[ ! -e "$data_home/applications/localai.desktop" ]]
[[ ! -e "$data_home/icons/hicolor/scalable/apps/localai.svg" ]]
[[ ! -e "$bin_home/localai-tray" ]]
printf 'Tray helper install and uninstall tests passed.\n'
