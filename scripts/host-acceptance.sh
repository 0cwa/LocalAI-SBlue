#!/usr/bin/env bash
# Run acceptance in an isolated VM; never use an existing deployment.
set -euo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
diagnostic_control_created=0
diagnostic_control_scratch=''
diagnostic_connection_created=0
usage() {
  printf '%s\n' 'Usage: host-acceptance.sh --vm BASE.qcow2 SSH_KEY UEFI_VARS SSH_HOST_PUBLIC_KEY'
  printf '%s\n' '       host-acceptance.sh --host [--resume]'
  printf '%s\n' '       host-acceptance.sh --diagnose-vm-backup'
  printf '%s\n' '       host-acceptance.sh --release-vm-diagnostic-pause'
  printf '%s\n' 'VM receipts go to stdout; host mode writes a receipt after reboot.'
}
fail() { printf 'step %s: fail\n' "${failure_scope:-vm-orchestration}"; printf 'acceptance: %s\n' "$*" >&2; exit 1; }
release_vm_diagnostic_pause() {
  local scratch active release
  [[ "$#" == 1 ]] || { usage >&2; exit 2; }
  scratch="${HOME:?}/agent-scratch/LocalAI-SBlue/acceptance-vm"
  active="$scratch/diagnostic-active"
  release="$scratch/diagnostic-release"
  [[ -d "$scratch" && ! -L "$scratch" && "$(stat -c '%u:%a' -- "$scratch")" == "$(id -u):700" ]] || fail 'VM diagnostic pause is not active.'
  [[ -f "$active" && ! -L "$active" && "$(stat -c '%u:%a' -- "$active")" == "$(id -u):600" ]] || fail 'VM diagnostic pause is not active.'
  [[ ! -e "$release" && ! -L "$release" ]] || fail 'VM diagnostic release is already pending.'
  (umask 077; set -o noclobber; : >"$release") || fail 'could not release VM diagnostic pause.'
  printf 'diagnostic-pause: release-requested\n'
}
diagnose_vm_backup() {
  local scratch active connection port key known_hosts worker output line status=0 reason
  local -a connection_fields=() ssh_args=()
  [[ "$#" == 1 ]] || { usage >&2; exit 2; }
  scratch="${HOME:?}/agent-scratch/LocalAI-SBlue/acceptance-vm"
  active="$scratch/diagnostic-active"
  connection="$scratch/diagnostic-connection"
  [[ -d "$scratch" && ! -L "$scratch" && "$(stat -c '%u:%a' -- "$scratch")" == "$(id -u):700" ]] || fail 'VM diagnostic pause is not active.'
  [[ -f "$active" && ! -L "$active" && "$(stat -c '%u:%a' -- "$active")" == "$(id -u):600" ]] || fail 'VM diagnostic pause is not active.'
  [[ -f "$connection" && ! -L "$connection" && "$(stat -c '%u:%a' -- "$connection")" == "$(id -u):600" ]] || fail 'VM diagnostic connection is unavailable.'
  mapfile -t connection_fields <"$connection"
  [[ "${#connection_fields[@]}" == 3 ]] || fail 'VM diagnostic connection is invalid.'
  port="${connection_fields[0]}"
  key="${connection_fields[1]}"
  known_hosts="${connection_fields[2]}"
  if [[ ! "$port" =~ ^[0-9]{1,5}$ ]]; then fail 'VM diagnostic connection is invalid.'; fi
  if (( 10#$port == 0 || 10#$port > 65535 )); then fail 'VM diagnostic connection is invalid.'; fi
  [[ "$key" == /* && ! -L "$key" && -f "$key" && "$(stat -c '%u' -- "$key")" == "$(id -u)" ]] || fail 'VM diagnostic identity is unavailable.'
  case "$(stat -c '%a' -- "$key")" in 400|600) ;; *) fail 'VM diagnostic identity is not private.' ;; esac
  [[ "$known_hosts" == "$scratch"/run.*/known_hosts && ! -L "$known_hosts" && -f "$known_hosts" && "$(realpath -e -- "$known_hosts")" == "$known_hosts" && "$(stat -c '%u:%a' -- "$known_hosts")" == "$(id -u):600" ]] || fail 'VM diagnostic host key is unavailable.'
  ssh-keygen -F "[127.0.0.1]:$port" -f "$known_hosts" >/dev/null 2>&1 || fail 'VM diagnostic host key is invalid.'
  worker=/root/agent-scratch/LocalAI-SBlue/acceptance-source/scripts/acceptance-guest.sh
  ssh_args=(-i "$key" -p "$port" -o BatchMode=yes -o ConnectTimeout=5
    -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known_hosts")
  if output="$(timeout 1800s ssh "${ssh_args[@]}" root@127.0.0.1 "bash $worker diagnose-backup" 2>&1)"; then
    status=0
  else
    status=$?
  fi
  while IFS= read -r line; do
    case "$line" in
      'command backup-restore-backup: localaictl backup with root-owned config and persistent marker'|'waiting backup-restore-backup: timeout 1800s'|'step backup-restore-backup: pass'|'step backup-restore-backup: fail'|'step backup-restore-backup: timeout')
        printf '%s\n' "$line" ;;
      'diagnostic backup-restore-backup-reason: '*)
        reason="${line#diagnostic backup-restore-backup-reason: }"
        case "$reason" in
          service-stop|unit-ownership|capacity|unsafe-name|traversal-path|duplicate-member|link-cross-root|link-escape|hardlink|system-manager-tree|path-outside-roots|special-member|nested-member|privileged-mode|file-capability|config-member|persistent-root-type|missing-metadata|archive-read|unit-tree-validation|symlink|archive-validation|tar|lock-contention|config-guard|other)
            printf 'diagnostic backup-restore-backup-reason: %s\n' "$reason" ;;
          *) printf 'diagnostic backup-restore-backup-reason: unknown\n' ;;
        esac ;;
      'Acceptance step backup-restore-backup: fail ('*) printf 'step backup-restore-backup: fail\n' ;;
      'acceptance: '*) printf 'acceptance: fail\n' ;;
    esac
  done <<<"$output"
  unset output
  return "$status"
}
bounded_vm_diagnostic_pause() {
  local scratch="$1" duration="$2" active release elapsed=0
  (( duration > 0 )) || return 0
  active="$scratch/diagnostic-active"
  release="$scratch/diagnostic-release"
  [[ ! -e "$active" && ! -L "$active" && ! -e "$release" && ! -L "$release" ]] || fail 'VM diagnostic control path is already occupied.'
  (umask 077; set -o noclobber; : >"$active") || fail 'could not prepare VM diagnostic pause.'
  diagnostic_control_created=1
  chmod 0600 -- "$active"
  printf 'diagnostic-pause: active\n'
  while (( elapsed < duration )); do
    kill -0 "$qemu_pid" 2>/dev/null || fail 'VM exited during diagnostic pause.'
    if [[ -e "$release" || -L "$release" ]]; then
      [[ -f "$release" && ! -L "$release" && "$(stat -c '%u:%a' -- "$release")" == "$(id -u):600" ]] || fail 'VM diagnostic release path is unsafe.'
      break
    fi
    sleep 1
    ((elapsed += 1))
  done
  if [[ -f "$release" && ! -L "$release" && "$(stat -c '%u:%a' -- "$release")" == "$(id -u):600" ]]; then
    printf 'diagnostic-pause: released\n'
  else
    printf 'diagnostic-pause: expired\n'
  fi
  rm -f -- "$active" "$release"
  diagnostic_control_created=0
}
main() {
if [[ "${1:-}" == --release-vm-diagnostic-pause ]]; then
  release_vm_diagnostic_pause "$@"
  return 0
fi
if [[ "${1:-}" == --diagnose-vm-backup ]]; then
  diagnose_vm_backup "$@"
  return $?
fi
if [[ "${1:-}" == --host ]]; then
  failure_scope=host-orchestration
  [[ "$#" == 1 || ( "$#" == 2 && "$2" == --resume ) ]] || { usage >&2; exit 2; }
  if ! command -v run0 >/dev/null || ! command -v timeout >/dev/null; then
    fail 'host mode requires run0 and timeout.'
  fi
  printf 'Host acceptance requires an isolated installation and will reboot the machine.\n' >&2
  local -a elevation=()
  if [[ "$EUID" != 0 ]]; then
    elevation=(run0 -i)
    printf 'Waiting for one host authorization (timeout 120s)...\n' >&2
  fi
  if [[ "${2:-}" == --resume ]]; then
    timeout --kill-after=10s 120s "${elevation[@]}" /usr/bin/bash "$repo_root/scripts/acceptance-host.sh" resume || fail 'host authorization or resume failed.'
  else
    timeout --kill-after=10s 120s "${elevation[@]}" /usr/bin/bash "$repo_root/scripts/acceptance-host.sh" begin "$repo_root" || fail 'host authorization or setup failed.'
  fi
  return 0
fi
[[ "$#" == 5 && "$1" == --vm ]] || { usage >&2; exit 2; }
local diagnostic_pause_seconds="${LOCALAI_ACCEPTANCE_DIAGNOSTIC_PAUSE_SECONDS:-0}"
if [[ ! "$diagnostic_pause_seconds" =~ ^[0-9]{1,4}$ ]] || (( diagnostic_pause_seconds > 1800 )); then
  fail 'VM diagnostic pause must be an integer from 0 through 1800 seconds.'
fi
base="$(realpath -e -- "$2")" || fail 'base image does not exist.'
key="$(realpath -e -- "$3")" || fail 'SSH key does not exist.'
vars="$(realpath -e -- "$4")" || fail 'UEFI variables file does not exist.'
hostkey="$(realpath -e -- "$5")" || fail 'SSH host public key does not exist.'
[[ -f "$base" && -f "$key" && -f "$vars" && -f "$hostkey" ]] || fail 'VM inputs must be regular files.'
for cmd in qemu-img qemu-system-x86_64 ssh ssh-keygen python3 timeout tar; do
  command -v "$cmd" >/dev/null || fail "missing dependency: $cmd"
done
# A single standalone qcow2 base prevents accidental use of a backing chain.
qemu-img info --output=json "$base" | python3 -c '
import json, sys
image = json.load(sys.stdin)
data = image.get("format-specific", {}).get("data", {})
children = image.get("children", [])
if (image.get("format") != "qcow2" or image.get("backing-filename")
        or image.get("full-backing-filename") or data.get("data-file")
        or any(child.get("name") != "file" for child in children)):
    sys.exit(1)
' || fail 'base must be a standalone qcow2 image.'

# Pin a supplied public key before connecting; a port race must never direct
# installation commands to a different local SSH server.
ssh-keygen -l -f "$hostkey" >/dev/null 2>&1 || fail 'invalid SSH host public key.'
read -r hostkey_type hostkey_data _ < "$hostkey" || fail 'cannot read SSH host public key.'
[[ "$hostkey_type" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)$ && "$hostkey_data" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || fail 'unsupported SSH host public key.'
scratch="${HOME:?}/agent-scratch/LocalAI-SBlue/acceptance-vm"
umask 077
mkdir -p "$scratch"
[[ ! -L "$scratch" && "$(stat -c '%u:%a' -- "$scratch")" == "$(id -u):700" ]] || fail 'VM scratch directory must be owned and private.'
diagnostic_control_scratch="$scratch"
work="$(mktemp -d "$scratch/run.XXXXXX")"
qemu_pid=''
cleanup() {
  if [[ -n "$qemu_pid" ]]; then
    kill "$qemu_pid" 2>/dev/null || :
    wait "$qemu_pid" 2>/dev/null || :
  fi
  if [[ "$diagnostic_control_created" == 1 ]]; then
    rm -f -- "$diagnostic_control_scratch/diagnostic-active" "$diagnostic_control_scratch/diagnostic-release"
  fi
  if [[ "$diagnostic_connection_created" == 1 ]]; then
    rm -f -- "$diagnostic_control_scratch/diagnostic-connection"
  fi
  rm -rf -- "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

qemu-img create -q -f qcow2 -F qcow2 -b "$base" "$work/overlay.qcow2" || fail 'cannot create VM overlay.'
cp -- "$vars" "$work/vars.fd"
port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
connection="$scratch/diagnostic-connection"
[[ ! -e "$connection" && ! -L "$connection" ]] || fail 'VM diagnostic connection path is already occupied.'
(umask 077; set -o noclobber; printf '%s\n%s\n%s\n' "$port" "$key" "$work/known_hosts" >"$connection") || fail 'could not prepare VM diagnostic connection.'
diagnostic_connection_created=1
chmod 0600 -- "$connection"
# QEMU's comma-separated drive syntax escapes a literal comma as two commas.
overlay_arg="${work//,/,,}/overlay.qcow2"
vars_arg="${work//,/,,}/vars.fd"
qemu-system-x86_64 -machine q35,accel=kvm -cpu host -m 6144 -smp 4 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/ovmf/OVMF_CODE.fd \
  -drive "if=pflash,format=raw,file=$vars_arg" \
  -drive "file=$overlay_arg,if=virtio,format=qcow2" \
  -nic "user,hostfwd=tcp:127.0.0.1:$port-:22" \
  -display none -audio none -serial none -monitor none >"$work/qemu.log" 2>&1 &
qemu_pid=$!
printf '[127.0.0.1]:%s %s %s\n' "$port" "$hostkey_type" "$hostkey_data" > "$work/known_hosts"
ssh_args=(-i "$key" -p "$port" -o BatchMode=yes -o ConnectTimeout=3
  -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$work/known_hosts")
wait_for_guest() {
  local deadline=$((SECONDS + 300))
  printf 'Waiting for the disposable VM to accept SSH (timeout 300s)...\n' >&2
  kill -0 "$qemu_pid" 2>/dev/null || fail 'VM exited before SSH was ready.'
  until timeout 5s ssh "${ssh_args[@]}" root@127.0.0.1 true >/dev/null 2>&1; do
    kill -0 "$qemu_pid" 2>/dev/null || fail 'VM exited before SSH was ready.'
    (( SECONDS < deadline )) || fail 'timed out waiting for VM SSH.'
    sleep 2
  done
}
wait_for_guest

LOCALAI_PACKAGE_DIST_DIR="$work/dist" LOCALAI_PACKAGE_SCRATCH_DIR="$work/package" \
  "$repo_root/scripts/package-release.sh" >"$work/package.log" 2>&1 || fail 'could not prepare public source archive.'
version="$(<"$repo_root/VERSION")"
[[ "$version" =~ ^[0-9A-Za-z.+-]+$ ]] || fail 'invalid package version.'
archive="$work/dist/localai-secureblue-$version.tar.gz"
read -r archive_digest _ <"$archive.sha256" || fail 'could not read package digest.'
[[ "$archive_digest" =~ ^[a-f0-9]{64}$ ]] || fail 'invalid package digest.'
printf 'project-version: %s\nproject-archive-sha256: %s\n' "$version" "$archive_digest"
timeout 120s ssh "${ssh_args[@]}" root@127.0.0.1 'mkdir -p /root/agent-scratch/LocalAI-SBlue/acceptance-source && tar -xz --strip-components=1 -C /root/agent-scratch/LocalAI-SBlue/acceptance-source' <"$archive" >/dev/null 2>&1 || fail 'could not copy source into the VM.'
worker=/root/agent-scratch/LocalAI-SBlue/acceptance-source/scripts/acceptance-guest.sh
printf 'Waiting for VM install and initial idle checks...\n' >&2
# The worker path is a fixed path inside the disposable VM.
# shellcheck disable=SC2029
timeout 1800s ssh "${ssh_args[@]}" root@127.0.0.1 "bash $worker install" || fail 'VM install phase failed.'
old_boot="$(timeout 15s ssh "${ssh_args[@]}" root@127.0.0.1 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null)" || fail 'could not read VM boot state.'
[[ "$old_boot" =~ ^[0-9a-f-]{36}$ ]] || fail 'invalid VM boot state.'
timeout 20s ssh "${ssh_args[@]}" root@127.0.0.1 'systemctl reboot --no-block' >/dev/null 2>&1 || :
deadline=$((SECONDS + 300))
printf 'Waiting for the disposable VM to reboot (timeout 300s)...\n' >&2
while :; do
  kill -0 "$qemu_pid" 2>/dev/null || fail 'VM exited during reboot.'
  new_boot="$(timeout 5s ssh "${ssh_args[@]}" root@127.0.0.1 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || :)"
  [[ "$new_boot" =~ ^[0-9a-f-]{36}$ && "$new_boot" != "$old_boot" ]] && break
  (( SECONDS < deadline )) || fail 'timed out waiting for VM reboot.'
  sleep 2
done
printf 'Waiting for post-reboot VM acceptance...\n' >&2
# The worker path is a fixed path inside the disposable VM.
# shellcheck disable=SC2029
if ! timeout 7200s ssh "${ssh_args[@]}" root@127.0.0.1 "bash $worker verify"; then
  if (( diagnostic_pause_seconds > 0 )); then
    printf 'diagnostic-recheck: started\n'
    # The guest emits only allowlisted backup failure categories from this
    # bounded diagnostic retry; the disposable overlay remains alive.
    timeout 1800s ssh "${ssh_args[@]}" root@127.0.0.1 "bash $worker diagnose-backup" || :
    printf 'diagnostic-recheck: complete\n'
    bounded_vm_diagnostic_pause "$scratch" "$diagnostic_pause_seconds"
  fi
  fail 'post-reboot VM acceptance failed.'
fi

}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
