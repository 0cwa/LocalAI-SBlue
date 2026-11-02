#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_REPO_ROOT="$repo_root"
source "$repo_root/scripts/test-support.sh"
source "$repo_root/lib/acceptance.sh"
work="$(test_mktemp_dir acceptance-steps)"
trap 'rm -rf -- "$work"' EXIT
receipt="$work/receipt"
: >"$receipt"
localai_acceptance_step success 2 "$receipt" bash -c 'printf secret-value'
if localai_acceptance_step rejected 2 "$receipt" bash -c 'printf secret-value >&2; exit 7'; then
  printf 'Failed command was accepted\n' >&2; exit 1
fi
if localai_acceptance_step stalled 1 "$receipt" sleep 5; then
  printf 'Timed-out command was accepted\n' >&2; exit 1
fi
if localai_acceptance_step 'invalid label' 1 "$receipt" true; then
  printf 'Invalid step label was accepted\n' >&2; exit 1
fi
[[ "$(<"$receipt")" == $'step success: pass\nstep rejected: fail\nstep stalled: timeout' ]]
if rg -q 'secret-value' "$receipt"; then
  printf 'Command output leaked into receipt\n' >&2; exit 1
fi
printf 'Acceptance step tests passed\n'

getent() { return 2; }
mkdir -p "$work/root/etc"
localai_acceptance_clean_install "$work/root"
mkdir -p "$work/root/var/lib/localai"
if localai_acceptance_clean_install "$work/root" 2>/dev/null; then
  printf 'Existing LocalAI state was accepted\n' >&2; exit 1
fi
rmdir "$work/root/var/lib/localai"
ln -s missing "$work/root/etc/localai"
if localai_acceptance_clean_install "$work/root" 2>/dev/null; then
  printf 'Existing LocalAI symlink was accepted\n' >&2; exit 1
fi
rm "$work/root/etc/localai"
getent() { return 0; }
if localai_acceptance_clean_install "$work/root" 2>/dev/null; then
  printf 'Existing service account was accepted\n' >&2; exit 1
fi
getent() { return 1; }
if localai_acceptance_clean_install "$work/root" 2>/dev/null; then
  printf 'Account lookup error was accepted\n' >&2; exit 1
fi
printf 'Acceptance isolation checks passed\n'
