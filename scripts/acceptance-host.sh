#!/usr/bin/env bash
# Root-owned, reboot-persistent host acceptance runner.
set -euo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

state=/var/lib/localai-acceptance-run
unit=/etc/systemd/system/localai-acceptance.service
unit_name=localai-acceptance.service
RUN_PHASE_STARTED=0
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$repo_root/lib/acceptance.sh"
fail() {
  printf 'acceptance: %s\n' "$*" >&2
  if [[ "${RUN_PHASE_STARTED:-0}" == 1 && ${1:-} != *$'\n'* && -f "$state/receipt" && ! -L "$state/receipt" ]]; then
    printf 'acceptance: %s\n' "$*" >>"$state/receipt"
  fi
  exit 1
}
valid_state() {
  [[ -d "$state" && ! -L "$state" && -f "$state/initial-clean" && ! -L "$state/initial-clean" ]] || return 1
  [[ "$(stat -c '%u:%a' "$state")" == 0:700 && "$(stat -c '%u:%a' "$state/initial-clean")" == 0:600 ]]
}
write_phase() {
  printf '%s\n' "$1" >"$state/phase.new"
  mv -f -- "$state/phase.new" "$state/phase"
}
disable_runner() { systemctl disable "$unit_name" >/dev/null 2>&1 || :; }

begin() {
  local source_root="$1" archive version
  [[ ! -e "$state" && ! -L "$state" && ! -e "$unit" && ! -L "$unit" ]] || fail 'an acceptance run or unit already exists; inspect it before starting.'
  [[ "$(getenforce)" == Enforcing ]] || fail 'host SELinux must be enforcing.'
  systemctl is-active --quiet debug-shell.service && fail 'debug shell must be inactive.'
  localai_acceptance_clean_install / || fail 'host acceptance requires an isolated clean installation.'
  umask 077
  mkdir -- "$state" || fail 'cannot create private run state.'
  begin_started=0
  cleanup_incomplete_begin() {
    if [[ "$begin_started" == 0 && -d "$state" && ! -L "$state" ]]; then
      if [[ -f "$unit" && ! -L "$unit" ]] && grep -Fqx '# Managed by LocalAI secureblue host acceptance.' "$unit"; then
        rm -f -- "$unit"
        systemctl daemon-reload >/dev/null 2>&1 || :
      fi
      rm -rf -- "$state"
    fi
  }
  trap cleanup_incomplete_begin EXIT
  printf 'clean\n' >"$state/initial-clean"
  : >"$state/receipt"
  mkdir "$state/dist" "$state/package" "$state/source"
  LOCALAI_PACKAGE_DIST_DIR="$state/dist" LOCALAI_PACKAGE_SCRATCH_DIR="$state/package" \
    "$source_root/scripts/package-release.sh" >/dev/null 2>&1 || fail 'could not prepare the source package.'
  version="$(<"$source_root/VERSION")"
  [[ "$version" =~ ^[0-9A-Za-z.+-]+$ ]] || fail 'invalid package version.'
  archive="$state/dist/localai-secureblue-$version.tar.gz"
  tar -xz --strip-components=1 -C "$state/source" <"$archive" || fail 'could not extract the source package.'
  write_phase prepared
  cat >"$unit" <<'UNIT'
# Managed by LocalAI secureblue host acceptance.
[Unit]
Description=LocalAI isolated host acceptance
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/bin/bash /var/lib/localai-acceptance-run/source/scripts/acceptance-host.sh run
TimeoutStartSec=10800
StandardOutput=null
StandardError=null
[Install]
WantedBy=multi-user.target
UNIT
  chmod 0644 "$unit"
  systemctl daemon-reload
  systemctl enable "$unit_name" >/dev/null
  begin_started=1
  systemctl start --no-block "$unit_name"
  printf 'Acceptance started; the machine will reboot. Read the sanitized receipt with: run0 cat /var/lib/localai-acceptance-run/receipt\n'
}

resume() {
  valid_state || fail 'no trusted host acceptance state exists.'
  [[ -f "$unit" && ! -L "$unit" ]] || fail 'host acceptance unit is unavailable.'
  grep -Fqx '# Managed by LocalAI secureblue host acceptance.' "$unit" || fail 'host acceptance unit is not managed by this run.'
  [[ "$(<"$state/phase")" != complete ]] || fail 'host acceptance is already complete.'
  systemctl enable "$unit_name" >/dev/null
  systemctl start --no-block "$unit_name"
  printf 'Acceptance resumed; read the sanitized receipt with: run0 cat /var/lib/localai-acceptance-run/receipt\n'
}

run_worker() {
  local phase="$1" limit="$2" status=0 result
  timeout --kill-after=10s "${limit}s" bash "$state/source/scripts/acceptance-guest.sh" "$phase" >/dev/null 2>&1 || status=$?
  case "$status" in
    0) result=pass ;;
    124) result=timeout ;;
    137) result=fail ;; # A killed command is not necessarily a timeout.
    *) result=fail ;;
  esac
  printf 'step host-%s: %s\n' "$phase" "$result" >>"$state/receipt"
  [[ "$status" == 0 ]]
}

run() {
  local phase old_boot current_boot
  valid_state || fail 'host acceptance state is not trusted.'
  RUN_PHASE_STARTED=1
  [[ -f "$state/phase" && ! -L "$state/phase" ]] || fail 'host acceptance phase is missing.'
  phase="$(<"$state/phase")"
  export LOCALAI_ACCEPTANCE_MODE=host
  case "$phase" in
    prepared|install-failed)
      printf 'waiting: install and fresh idle checks\n' >>"$state/receipt"
      if ! run_worker install 1800; then
        write_phase install-failed
        disable_runner
        exit 1
      fi
      cat /proc/sys/kernel/random/boot_id >"$state/boot-id"
      write_phase awaiting-reboot
      printf 'waiting: reboot\n' >>"$state/receipt"
      systemctl reboot --no-block
      ;;
    awaiting-reboot|verify-failed)
      [[ -f "$state/boot-id" && ! -L "$state/boot-id" ]] || fail 'original boot marker is missing.'
      old_boot="$(<"$state/boot-id")"
      current_boot="$(</proc/sys/kernel/random/boot_id)"
      [[ "$old_boot" =~ ^[0-9a-f-]{36}$ && "$current_boot" =~ ^[0-9a-f-]{36}$ ]] || fail 'invalid host boot marker.'
      if [[ "$old_boot" == "$current_boot" ]]; then
        printf 'waiting: reboot\n' >>"$state/receipt"
        systemctl reboot --no-block
        return
      fi
      printf 'waiting: post-reboot lifecycle checks\n' >>"$state/receipt"
      if ! run_worker verify 7200; then
        write_phase verify-failed
        disable_runner
        exit 1
      fi
      write_phase complete
      printf 'acceptance: complete\n' >>"$state/receipt"
      disable_runner
      ;;
    complete) disable_runner ;;
    *) fail 'invalid host acceptance phase.' ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  [[ "${EUID:-$(id -u)}" == 0 ]] || fail 'host runner requires one root elevation.'
  case "${1:-}" in
    begin) [[ "$#" == 2 ]] || exit 2; begin "$2" ;;
    resume) [[ "$#" == 1 ]] || exit 2; resume ;;
    run) [[ "$#" == 1 ]] || exit 2; run ;;
    *) exit 2 ;;
  esac
fi
