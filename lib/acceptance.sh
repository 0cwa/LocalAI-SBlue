#!/usr/bin/env bash
# Shared primitives for bounded, sanitized acceptance runs.

localai_acceptance_step() {
  local label="$1" limit="$2" receipt="$3" status=0 result
  shift 3
  [[ "$label" =~ ^[a-z0-9-]+$ && "$limit" =~ ^[1-9][0-9]*$ && "$#" -gt 0 ]] || return 2
  printf 'Waiting for %s (timeout %ss)...\n' "$label" "$limit" >&2
  timeout --kill-after=10s "${limit}s" "$@" >/dev/null 2>&1 || status=$?
  case "$status" in
    0) result=pass ;;
    124|137) result=timeout ;;
    *) result=fail ;;
  esac
  printf 'step %s: %s\n' "$label" "$result" >>"$receipt"
  if [[ "$status" -ne 0 ]]; then
    printf 'Acceptance step %s: %s (exit %s).\n' "$label" "$result" "$status" >&2
    return 1
  fi
}
