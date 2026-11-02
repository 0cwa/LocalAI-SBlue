#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/scripts/test-support.sh"
TEST_REPO_ROOT="$root"
work="$(test_mktemp_dir public-tree)"
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/scripts"
cp "$root/scripts/check-public-tree.py" "$work/scripts/"
check() { (cd "$work" && python3 scripts/check-public-tree.py >/dev/null 2>&1); }
printf '%s\n' 'safe example' > "$work/example"
check
for value in '10.'"1.2.3" '172.'"16.1.1" '192.'"168.1.1" '169.'"254.1.1" 'fd'"00::1" 'fe'"80::1" 'machine.'"internal" '/home/'"alice/data" '/var/home/'"alice/data" '-----BEGIN '"CERTIFICATE-----"; do
  printf '%s\n' "$value" > "$work/example"
  if check; then printf 'Accepted forbidden fixture\n' >&2; exit 1; fi
done
printf '%s\n' safe > "$work/example"
touch "$work/fixture."'crt'
if check; then printf 'Accepted certificate file\n' >&2; exit 1; fi
printf 'Public tree safety tests passed\n'
