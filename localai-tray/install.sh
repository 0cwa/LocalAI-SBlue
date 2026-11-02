#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
bin_home="${XDG_BIN_HOME:-$HOME/.local/bin}"
install_dir="$data_home/localai-tray"
desktop_dir="$data_home/applications"
icon_dir="$data_home/icons/hicolor/scalable/apps"
bin_path="$bin_home/localai-tray"
desktop_path="$desktop_dir/localai.desktop"
icon_path="$icon_dir/localai.svg"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ -x /usr/bin/python3 ]] || die "/usr/bin/python3 is required."
/usr/bin/python3 -c 'import PyQt6' 2>/dev/null || die "PyQt6 is not installed. Install the host PyQt6 package before installing the tray client."
command -v run0 >/dev/null 2>&1 || die "run0 is required for the SecureBlue service-user boundary."
command -v systemctl >/dev/null 2>&1 || die "systemctl is required."
[[ -f "$script_dir/../bin/localaictl" ]] || die "localaictl is missing from the repository."
[[ -f "$script_dir/../lib/config.sh" ]] || die "shared config loader is missing from the repository."

install -d -m 0755 "$install_dir" "$bin_home" "$desktop_dir" "$icon_dir"
install -m 0644 "$script_dir/localai-tray.py" "$install_dir/localai-tray.py"
install -m 0644 "$script_dir/adapter.py" "$install_dir/adapter.py"
install -m 0644 "$script_dir/localai.svg" "$install_dir/localai.svg"
install -m 0755 "$script_dir/../bin/localaictl" "$install_dir/localaictl"
install -m 0644 "$script_dir/../lib/config.sh" "$install_dir/config.sh"
# The controller reads the shared /etc/localai/localai.conf on each command.
# Do not install a per-user copy that becomes stale after config changes.
install -m 0644 "$script_dir/localai.svg" "$icon_path"

wrapper="$(mktemp)"
trap 'rm -f "$wrapper"' EXIT
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' "exec /usr/bin/python3 '$install_dir/localai-tray.py' \"\$@\"" >"$wrapper"
install -m 0755 "$wrapper" "$bin_path"

sed "s|@EXEC@|$bin_path|g" "$script_dir/localai-tray.desktop.in" >"$desktop_path"
chmod 0644 "$desktop_path"

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$desktop_dir" >/dev/null 2>&1 || true
fi

printf 'Installed LocalAI tray launcher.\n'
printf 'Application entry: %s\n' "$desktop_path"
printf 'Binary: %s\n' "$bin_path"
printf 'Launch it from the application launcher, or run: %s --start\n' "$bin_path"
