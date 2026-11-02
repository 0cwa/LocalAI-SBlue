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
    124) result=timeout ;;
    137) result=fail ;; # A killed command is not necessarily a timeout.
    *) result=fail ;;
  esac
  printf 'step %s: %s\n' "$label" "$result" >>"$receipt"
  if [[ "$status" -ne 0 ]]; then
    printf 'Acceptance step %s: %s (exit %s).\n' "$label" "$result" "$status" >&2
    return 1
  fi
}

# Refuse existing installations before any destructive host operation. The
# optional root is used by tests; production callers pass /.
localai_acceptance_clean_install() {
  local root="${1:?}" account path status
  for account in localai localai-tls; do
    if getent passwd "$account" >/dev/null 2>&1; then
      printf 'Acceptance requires an isolated install: account %s exists.\n' "$account" >&2
      return 1
    else
      status=$?
      if [[ "$status" != 2 ]]; then
        printf 'Could not check acceptance service accounts.\n' >&2
        return 1
      fi
    fi
  done
  for path in etc/localai etc/localai.conf var/lib/localai var/lib/localai-tls var/lib/localai-installer \
    etc/systemd/system/localai-tls-forward.socket \
    etc/systemd/system/localai-tls-forward.service; do
    if [[ -e "${root%/}/$path" || -L "${root%/}/$path" ]]; then
      printf 'Acceptance requires an isolated install: existing LocalAI state.\n' >&2
      return 1
    fi
  done
}
