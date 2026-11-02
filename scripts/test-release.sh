#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_REPO_ROOT="$root"
source "$root/scripts/test-support.sh"
work="$(test_mktemp_dir release-notes)"
trap 'rm -rf -- "$work"' EXIT
printf '1.2.3\n' >"$work/VERSION"
cat >"$work/CHANGELOG.md" <<'NOTES'
# Changelog
## Unreleased
- Not released yet.
## 1.2.3
Qualification: repository checks only.
- Released change.
## 1.2.2
Qualification: earlier.
- Older change.
NOTES
notes="$(cd "$work" && python3 "$root/scripts/release-notes.py" v1.2.3)"
[[ "$notes" == *'Released change.'* && "$notes" != *'Not released yet.'* && "$notes" != *'Older change.'* ]]
if (cd "$work" && python3 "$root/scripts/release-notes.py" v1.2.4 >/dev/null 2>&1); then
  printf 'Release notes accepted a mismatched tag\n' >&2; exit 1
fi
sed -i 's/^Qualification: repository checks only\./Qualification:/' "$work/CHANGELOG.md"
if (cd "$work" && python3 "$root/scripts/release-notes.py" v1.2.3 >/dev/null 2>&1); then
  printf 'Release notes accepted missing qualification\n' >&2; exit 1
fi
printf 'Release version and notes tests passed\n'
