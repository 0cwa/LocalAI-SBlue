#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

version="${1:-${VERSION:-0.1.0}}"
if (( ${#version} > 128 )) || ! [[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
  printf 'Invalid release version: %q\n' "$version" >&2
  printf 'Use semantic version syntax, for example 0.1.0 or 0.1.0-rc.1.\n' >&2
  exit 2
fi

package_name="localai-secureblue-${version}"
dist_dir="${LOCALAI_PACKAGE_DIST_DIR:-$repo_root/dist}"
if [[ -n "${LOCALAI_PACKAGE_SCRATCH_DIR:-}" ]]; then
  scratch_root="$LOCALAI_PACKAGE_SCRATCH_DIR"
elif git_dir="$(git -C "$repo_root" rev-parse --absolute-git-dir 2>/dev/null)"; then
  scratch_root="$git_dir/tmp/public-readiness/package-release"
else
  scratch_root="${HOME:?HOME must be set}/agent-scratch/LocalAI-SBlue/package-release"
fi
archive="$dist_dir/$package_name.tar.gz"
checksum_file="$archive.sha256"

# Keep this allowlist explicit. Historical host audits, private PKI notes,
# local config, certificates, and build output must never enter a release by
# being discovered under a broad directory.
manifest=(
  README.md
  SOURCE_PROVENANCE.md
  LICENSE
  SECURITY.md
  CONTRIBUTING.md
  CHANGELOG.md
  proposals.md
  Makefile
  bin/localaictl
  config/localai.conf.example
  lib/config.sh
  lib/installer_safety.sh
  lib/tls_compose_render.sh
  localai/localai.lock
  localai/localai-containers-policy.json
  localai/localai-tls-containers-policy.json
  localai/inspect-runtime-state.sh
  localai/probe-container-writable-paths.sh
  localai/test.sh
  secureblue-localai-install/install.sh
  secureblue-localai-install/uninstall.sh
  secureblue-localai-install/localai.service.in
  secureblue-localai-install/start-localai.sh
  secureblue-localai-install/stop-localai.sh
  secureblue-localai-install/status-localai.sh
  secureblue-localai-install/logs-localai.sh
  localai-podman-compose/install.sh
  localai-podman-compose/uninstall.sh
  localai-podman-compose/localai-tls-compose.yaml.in
  localai-podman-compose/localai-tls-compose.service.in
  localai-podman-compose/localai-tls-forward.service.in
  localai-podman-compose/localai-tls-forward.socket.in
  localai-podman-compose/start-localai-tls.sh
  localai-podman-compose/stop-localai-tls.sh
  localai-podman-compose/status-localai-tls.sh
  localai-podman-compose/logs-localai-tls.sh
  localai-tray/localai-tray.py
  localai-tray/adapter.py
  localai-tray/localai.svg
  localai-tray/localai-tray.desktop.in
  localai-tray/install.sh
  localai-tray/uninstall.sh
  scripts/check.sh
  scripts/check-public-tree.py
  scripts/test-public-tree.sh
  scripts/package-release.sh
  scripts/test-support.sh
  scripts/test-config.sh
  scripts/test-locaictl.sh
  scripts/test-installed-copy.sh
  scripts/test-render-config.sh
  scripts/test-tray-adapter.py
  scripts/test-uninstall-config.sh
  scripts/test-installer-safety.sh
  scripts/test-runtime-paths.sh
  scripts/test-package-relocation.sh
  docs/PUBLIC_BOUNDARIES.md
)

mkdir -p "$dist_dir" "$scratch_root"
work_dir="$(mktemp -d "${scratch_root%/}/package-release-${version}.XXXXXX")"
trap 'rm -rf -- "$work_dir"' EXIT
package_root="$work_dir/$package_name"
mkdir -p "$package_root"

for relative_path in "${manifest[@]}"; do
  if [[ ! -f "$relative_path" ]]; then
    printf 'Missing public release file: %s\n' "$relative_path" >&2
    exit 1
  fi
  destination="$package_root/$relative_path"
  mkdir -p "$(dirname -- "$destination")"
  cp "$relative_path" "$destination"
done

find "$package_root" -type f -name '*.sh' -exec chmod 0755 {} +
find "$package_root/bin" -type f -exec chmod 0755 {} +
python3 - "$work_dir" "$package_name" "$archive" <<'PY'
import sys
import tarfile
from pathlib import Path

work_dir = Path(sys.argv[1])
package_name = sys.argv[2]
archive = Path(sys.argv[3])
package_root = work_dir / package_name

for path in (package_root, *package_root.rglob("*")):
    if path.is_dir():
        path.chmod(0o755)
    else:
        executable = bool(path.stat().st_mode & 0o111)
        path.chmod(0o755 if executable else 0o644)

def normalize_owner(member):
    member.uid = 0
    member.gid = 0
    member.uname = "root"
    member.gname = "root"
    return member

with tarfile.open(archive, mode="w:gz", format=tarfile.PAX_FORMAT, compresslevel=6) as output:
    output.add(package_root, arcname=package_name, filter=normalize_owner)
PY

if command -v sha256sum >/dev/null 2>&1; then
  digest="$(sha256sum "$archive" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  digest="$(shasum -a 256 "$archive" | awk '{print $1}')"
elif command -v openssl >/dev/null 2>&1; then
  digest="$(openssl dgst -sha256 "$archive" | awk '{print $NF}')"
else
  printf 'A SHA-256 utility is required (sha256sum, shasum, or openssl).\n' >&2
  exit 1
fi
if ! [[ "$digest" =~ ^[0-9a-fA-F]{64}$ ]]; then
  printf 'Could not produce a valid SHA-256 digest for %s\n' "$archive" >&2
  exit 1
fi
printf '%s  %s\n' "$digest" "$(basename -- "$archive")" >"$checksum_file"

printf 'Wrote %s\n' "$archive"
printf 'Wrote %s\n' "$checksum_file"
