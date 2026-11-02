#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_REPO_ROOT="$repo_root"
source "$repo_root/scripts/test-support.sh"
work_dir="$(test_mktemp_dir package-relocation)"
trap 'rm -rf -- "$work_dir"' EXIT

output_dir="$work_dir/output"
build_dir="$work_dir/build"
extract_dir="$work_dir/extract"
home_dir="$work_dir/home"
tmp_dir="$work_dir/tmp"
version="$(<"$repo_root/VERSION")"
mkdir -p "$build_dir" "$extract_dir" "$home_dir" "$tmp_dir"

if LOCALAI_PACKAGE_DIST_DIR="$output_dir" \
  LOCALAI_PACKAGE_SCRATCH_DIR="$build_dir" \
  "$repo_root/scripts/package-release.sh" '../bad-version' >/dev/null 2>&1; then
  printf 'package script accepted a path-like version\n' >&2
  exit 1
fi
[[ ! -e "$output_dir" ]]

LOCALAI_PACKAGE_DIST_DIR="$output_dir" \
LOCALAI_PACKAGE_SCRATCH_DIR="$build_dir" \
  "$repo_root/scripts/package-release.sh" "$version"

archive="$output_dir/localai-secureblue-$version.tar.gz"
checksum_file="$archive.sha256"
archive_name="$(basename -- "$archive")"
expected_digest="$(awk '{print $1}' "$checksum_file")"
checksum_name="$(awk '{print $2}' "$checksum_file")"
[[ "$checksum_name" == "$archive_name" ]]
if command -v sha256sum >/dev/null 2>&1; then
  actual_digest="$(sha256sum "$archive" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  actual_digest="$(shasum -a 256 "$archive" | awk '{print $1}')"
elif command -v openssl >/dev/null 2>&1; then
  actual_digest="$(openssl dgst -sha256 "$archive" | awk '{print $NF}')"
else
  printf 'No SHA-256 verifier is available\n' >&2
  exit 1
fi
[[ "$actual_digest" == "$expected_digest" ]]
python3 - "$archive" "$version" "$extract_dir" <<'PY'
import re
import sys
import tarfile
from pathlib import Path

archive_path = sys.argv[1]
version = sys.argv[2]
extract_root = Path(sys.argv[3]).resolve()
package_name = f"localai-secureblue-{version}"
required = {
    f"{package_name}/LICENSE",
    f"{package_name}/VERSION",
    f"{package_name}/README.md",
    f"{package_name}/SOURCE_PROVENANCE.md",
    f"{package_name}/proposals.md",
    f"{package_name}/docs/EVIDENCE_AND_SECRETS.md",
    f"{package_name}/docs/QUADLET_DECISION.md",
    f"{package_name}/docs/quadlet-spike/localai.container",
    f"{package_name}/lib/installer_safety.sh",
    f"{package_name}/lib/tls_compose_render.sh",
    f"{package_name}/localai/inspect-runtime-state.sh",
    f"{package_name}/localai/probe-container-writable-paths.sh",
    f"{package_name}/scripts/test-package-relocation.sh",
}
excluded = re.compile(
    r"(^|/)(audit|dist|\.git|pki|certs|private)(/|$)"
    r"|(^|/)docs/[^/]*(HANDOFF|PRIVATE|INTERNAL|AUDIT|PKI)[^/]*\.md$"
    r"|(^|/)[^/]+\.(crt|csr|key|pem|p12|pfx|srl)$"
    r"|(^|/)config/localai\.conf$|(^|/)\.directory$|__pycache__|\.py[co]$",
    re.IGNORECASE,
)
for path in (
    package_name,
    f"{package_name}/README.md",
    f"{package_name}/docs/PUBLIC_BOUNDARIES.md",
):
    if excluded.search(path):
        raise SystemExit("release exclusion rules rejected a generic public path")
for path in (
    f"{package_name}/.git/config",
    f"{package_name}/private/notes.md",
    f"{package_name}/pki/manifest.md",
    f"{package_name}/audit/summary.md",
):
    if not excluded.search(path):
        raise SystemExit("release exclusion rules accepted a private or audit path")

with tarfile.open(archive_path, mode="r:gz") as archive:
    members = archive.getmembers()
    if not members:
        raise SystemExit("release archive is empty")
    names = {member.name for member in members}
    if required - names:
        raise SystemExit("release archive is missing required public files")
    root_member = next((member for member in members if member.name == package_name), None)
    if root_member is None or not root_member.isdir():
        raise SystemExit("release archive is missing its package root directory")
    for member in members:
        if (member.uid, member.gid, member.uname, member.gname) != (0, 0, "root", "root"):
            raise SystemExit("release archive contains non-normalized ownership metadata")
        if member.isdir() and member.mode != 0o755:
            raise SystemExit("release archive contains non-normalized directory modes")
        if member.isfile() and member.mode not in (0o644, 0o755):
            raise SystemExit("release archive contains non-normalized file modes")
        if not (member.isdir() or member.isfile()):
            raise SystemExit("release archive contains an unsupported entry type")
        member_path = Path(member.name)
        if member_path.is_absolute() or ".." in member_path.parts:
            raise SystemExit("release archive contains an unsafe path")
        is_package_root = member.name == package_name and member.isdir()
        if not is_package_root and not member.name.startswith(f"{package_name}/"):
            raise SystemExit("release archive contains a path outside its package root")
        try:
            (extract_root / member_path).resolve().relative_to(extract_root)
        except ValueError as exc:
            raise SystemExit("release archive contains a path outside the extraction directory") from exc
        if excluded.search(member.name):
            raise SystemExit("release archive contains excluded local or historical material")
    by_name = {member.name: member for member in members}
    for relative_path in ("bin/localaictl", "scripts/package-release.sh"):
        member = by_name[f"{package_name}/{relative_path}"]
        if not member.mode & 0o111:
            raise SystemExit("release archive lost an executable file mode")
    archive.extractall(path=extract_root, members=members)
PY

extracted_root="$extract_dir/localai-secureblue-$version"
[[ -x "$extracted_root/bin/localaictl" ]]
[[ -x "$extracted_root/scripts/package-release.sh" ]]

printf 'Running checks from the extracted release tree\n'
HOME="$home_dir" TMPDIR="$tmp_dir" PYTHONDONTWRITEBYTECODE=1 \
  bash "$extracted_root/scripts/check.sh"

printf 'package relocation tests passed\n'
