#!/usr/bin/env bash

test_mktemp_dir() {
  local name="$1" git_dir scratch_root repo_root
  repo_root="${TEST_REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[1]}")/.." && pwd)}"
  if [[ -n "${TEST_SCRATCH_DIR:-}" ]]; then
    scratch_root="$TEST_SCRATCH_DIR"
  elif git_dir="$(git -C "$repo_root" rev-parse --absolute-git-dir 2>/dev/null)"; then
    scratch_root="$git_dir/tmp/public-readiness/tests"
  else
    scratch_root="${HOME:?HOME must be set}/agent-scratch/LocalAI-SBlue/tests"
  fi
  mkdir -p "$scratch_root"
  mktemp -d "$scratch_root/$name.XXXXXX"
}

test_sanitize_localai_environment() {
  local variable
  for variable in $(compgen -e); do
    case "$variable" in LOCALAI_*|SERVICE_BIND_*) unset "$variable" ;; esac
  done
}
