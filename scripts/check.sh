#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
TEST_REPO_ROOT="$repo_root"
source "$repo_root/scripts/test-support.sh"
test_sanitize_localai_environment
check_tmp_dir="$(test_mktemp_dir repository-check)"
export TMPDIR="$check_tmp_dir"
export PYTHONDONTWRITEBYTECODE=1
trap 'rm -rf -- "$check_tmp_dir"' EXIT

status=0

while IFS= read -r script; do
  printf 'bash -n %s\n' "$script"
  bash -n "$script" || status=1
done < <(find bin lib localai secureblue-localai-install localai-podman-compose localai-tray scripts -type f -name '*.sh' | sort)

printf 'bash -n bin/localaictl\n'
bash -n bin/localaictl || status=1

printf 'Python syntax localai-tray/localai-tray.py\n'
python3 -c 'import ast, pathlib; ast.parse(pathlib.Path("localai-tray/localai-tray.py").read_text())'
printf 'Tray adapter tests\n'
python3 scripts/test-tray-adapter.py

if command -v desktop-file-validate >/dev/null 2>&1; then
  printf 'Desktop entry validation localai-tray/localai-tray.desktop.in\n'
  desktop_entry_tmp="$check_tmp_dir/desktop-entry.desktop"
  sed 's|@EXEC@|/home/test-user/.local/bin/localai-tray|g' localai-tray/localai-tray.desktop.in >"$desktop_entry_tmp"
  desktop-file-validate "$desktop_entry_tmp"
else
  printf 'desktop-file-validate not installed; checking required desktop keys.\n'
  rg -q '^Exec=@EXEC@ --start$' localai-tray/localai-tray.desktop.in
  rg -q '^Icon=localai$' localai-tray/localai-tray.desktop.in
fi

printf 'SVG parse localai-tray/localai.svg\n'
python3 -c 'import xml.etree.ElementTree as ET; ET.parse("localai-tray/localai.svg")'

printf 'Caddyfile validation runs inside the Caddy container during install.\n'

printf 'Strict configuration tests\n'
bash scripts/test-config.sh

printf 'Lifecycle facade tests\n'
bash scripts/test-locaictl.sh

printf 'Installed controller-copy tests\n'
bash scripts/test-installed-copy.sh

printf 'Rendered unit and TLS readiness checks\n'
bash scripts/test-render-config.sh

printf 'Writable runtime path checks\n'
bash scripts/test-runtime-paths.sh

printf 'Installer safety checks\n'
bash scripts/test-installer-safety.sh

printf 'Uninstall config safety tests\n'
bash scripts/test-uninstall-config.sh

exit "$status"
