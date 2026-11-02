#!/usr/bin/env bash
# Bound the secureblue container user-namespace policy operation during acceptance.
set -euo pipefail

acceptance_policy_apply() {
  local timeout_command="$1" ujust_command="$2" receipt="$3" status=0 result
  shift 3
  [[ "$#" == 2 && "$1" == set-container-userns && "$2" == on ]] || return 2
  printf 'waiting container-userns-policy: timeout 180s\n' >>"$receipt"
  "$timeout_command" --kill-after=10s 180s "$ujust_command" "$@" >/dev/null 2>&1 || status=$?
  case "$status" in
    0) result=pass ;;
    124) result=timeout ;;
    137) result=fail ;; # A killed command is not necessarily a timeout.
    *) result=fail ;;
  esac
  printf 'step container-userns-policy: %s\n' "$result" >>"$receipt"
  return "$status"
}

acceptance_semodule_apply() {
  local timeout_command="$1" semodule_command="$2" receipt="$3" status=0 result
  shift 3
  [[ "$#" -gt 0 ]] || return 2
  printf 'waiting selinux-module-reconciliation: timeout 120s\n' >>"$receipt"
  # The installer may inspect semodule output; its enclosing acceptance step
  # discards that output instead of putting it in the receipt.
  "$timeout_command" --kill-after=10s 120s "$semodule_command" "$@" || status=$?
  case "$status" in
    0) result=pass ;;
    124) result=timeout ;;
    137) result=fail ;; # A killed command is not necessarily a timeout.
    *) result=fail ;;
  esac
  printf 'step selinux-module-reconciliation: %s\n' "$result" >>"$receipt"
  return "$status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  receipt="${LOCALAI_ACCEPTANCE_RECEIPT:-}"
  [[ "$EUID" == 0 && "$receipt" == /* && -f "$receipt" && ! -L "$receipt" ]] || exit 2
  [[ "$(stat -c '%u:%a' "$receipt")" == 0:600 ]] || exit 2
  case "${0##*/}" in
    ujust) acceptance_policy_apply /usr/bin/timeout /usr/bin/ujust "$receipt" "$@" ;;
    semodule) acceptance_semodule_apply /usr/bin/timeout /usr/bin/semodule "$receipt" "$@" ;;
    *) exit 2 ;;
  esac
fi
