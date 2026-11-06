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
  printf '%s\n' '       host-acceptance.sh --diagnose-vm-backup SSH_KEY'
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
proc_start_time() {
  local pid="$1" proc_root="${2:-/proc}" stat_line stat_fields
  [[ "$pid" =~ ^[1-9][0-9]*$ && -r "$proc_root/$pid/stat" ]] || return 1
  IFS= read -r stat_line <"$proc_root/$pid/stat" || return 1
  stat_fields="${stat_line##*) }"
  local -a fields=()
  read -r -a fields <<<"$stat_fields"
  [[ "${#fields[@]}" -ge 20 && "${fields[19]}" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "${fields[19]}"
}

qemu_process_matches() {
  local pid="$1" expected_start="$2" port="$3" expected_exe="$4" proc_root="${5:-/proc}"
  local current_start exe_arg found_nic=0 found_display=0 index
  local -a process_args=()
  [[ "$pid" =~ ^[1-9][0-9]*$ && "$expected_start" =~ ^[0-9]+$ && "$port" =~ ^[0-9]{1,5}$ ]] || return 1
  (( 10#$port > 0 && 10#$port <= 65535 )) || return 1
  [[ "$expected_exe" == /* && -x "$expected_exe" ]] || return 1
  current_start="$(proc_start_time "$pid" "$proc_root")" || return 1
  [[ "$current_start" == "$expected_start" ]] || return 1
  exe_arg="$(readlink -f -- "$proc_root/$pid/exe" 2>/dev/null)" || return 1
  [[ "$exe_arg" == "$expected_exe" ]] || return 1
  [[ -r "$proc_root/$pid/cmdline" ]] || return 1
  mapfile -d '' -t process_args <"$proc_root/$pid/cmdline"
  for ((index = 0; index < ${#process_args[@]}; index++)); do
    if [[ "${process_args[$index]}" == -nic && "${process_args[$((index + 1))]:-}" == "user,hostfwd=tcp:127.0.0.1:$port-:22" ]]; then
      found_nic=1
    fi
    if [[ "${process_args[$index]}" == -display && "${process_args[$((index + 1))]:-}" == none ]]; then
      found_display=1
    fi
  done
  [[ "$found_nic" == 1 && "$found_display" == 1 ]]
}

isolated_ssh_args() {
  local -n result_ref="$1"
  local key="$2" port="$3" known_hosts="$4" connect_timeout="$5"
  # The caller consumes this nameref-backed output array.
  # shellcheck disable=SC2034
  result_ref=(-F /dev/null -o ProxyCommand=none -o ProxyJump=none
    -o IdentitiesOnly=yes -o ControlMaster=no -o ControlPath=none
    -i "$key" -p "$port" -o BatchMode=yes -o "ConnectTimeout=$connect_timeout"
    -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known_hosts")
}

install_process_snapshot() {
  local output line
  local snapshot_command="ps -eo comm=,etimes= | awk '{ name=\$1; elapsed=\$2; class=\"\"; if (name == \"rpm-ostree\" || name == \"rpm-ostreed\" || name == \"rpm\" || name == \"dnf\") class=\"package-manager\"; else if (name == \"podman\" || name == \"conmon\" || name == \"crun\" || name == \"localai\" || name == \"caddy\") class=\"container-runtime\"; else if (name == \"curl\" || name == \"wget\" || name == \"git\") class=\"network-transfer\"; else if (name == \"systemd\" || name == \"systemd-run\" || name == \"systemctl\" || name == \"dbus-broker\") class=\"service-manager\"; else if (name == \"bash\" || name == \"sh\" || name == \"timeout\" || name == \"python3\" || name == \"install\" || name == \"tar\" || name == \"cp\") class=\"installer\"; if (class != \"\") { count[class]++; if (elapsed > max_elapsed[class]) max_elapsed[class]=elapsed } } END { for (class in count) printf \"vm-install-process: %s count=%d max-elapsed=%ds\\n\", class, count[class], max_elapsed[class]; if (length(count) == 0) print \"vm-install-process: no-classified-processes count=0 max-elapsed=0s\" }'"
  if output="$(timeout 15s ssh "${ssh_args[@]}" root@127.0.0.1 "$snapshot_command" 2>/dev/null)"; then
    while IFS= read -r line; do
      if [[ "$line" =~ ^vm-install-process:\ (package-manager|container-runtime|network-transfer|service-manager|installer|no-classified-processes)\ count=[0-9]+\ max-elapsed=[0-9]+s$ ]]; then
        printf '%s\n' "$line"
      else
        printf 'vm-install-process: result-unavailable\n'
      fi
    done <<<"$output"
    [[ -n "$output" ]] || printf 'vm-install-process: result-unavailable\n'
  else
    printf 'vm-install-process: unavailable\n'
  fi
  unset output
}

qemu_log_category() {
  local log_path="$1"
  if [[ ! -s "$log_path" ]]; then
    printf 'qemu-empty-log\n'
  elif grep -Fqi -- 'Could not access KVM kernel module' "$log_path" ||
       grep -Fqi -- 'failed to initialize kvm' "$log_path" ||
       grep -Fqi -- 'KVM is not available' "$log_path"; then
    printf 'kvm-unavailable\n'
  elif grep -Fqi -- '/dev/kvm' "$log_path"; then
    printf 'kvm-device\n'
  elif grep -Fqi -- 'Cannot allocate memory' "$log_path" ||
       grep -Fqi -- 'cannot allocate memory' "$log_path"; then
    printf 'memory-allocation\n'
  elif grep -Fqi -- 'No space left on device' "$log_path"; then
    printf 'disk-capacity\n'
  elif grep -Fqi -- 'host forwarding rule' "$log_path" ||
       grep -Fqi -- 'hostfwd' "$log_path"; then
    printf 'host-forward\n'
  elif grep -Fqi -- 'Could not open' "$log_path" ||
       grep -Fqi -- 'No such file or directory' "$log_path"; then
    printf 'input-open\n'
  elif grep -Fqi -- 'Permission denied' "$log_path"; then
    printf 'permission\n'
  else
    printf 'qemu-unclassified\n'
  fi
}

qemu_exit_category() {
  case "$1" in
    0) printf 'qemu-exit-success\n' ;;
    126|127) printf 'qemu-exec-failure\n' ;;
    137) printf 'qemu-killed\n' ;;
    139) printf 'qemu-crash\n' ;;
    1|2) printf 'qemu-startup-error\n' ;;
    *) printf 'qemu-exit-unknown\n' ;;
  esac
}

report_qemu_exit() {
  local status=0
  if wait "$qemu_pid" 2>/dev/null; then status=0; else status=$?; fi
  qemu_pid=''
  printf 'vm-qemu-exit-category: %s\n' "$(qemu_exit_category "$status")"
}

diagnose_vm_backup_with_proc_root() {
  local key_arg="$1" proc_root="$2"
  local scratch canonical_scratch active connection port key known_hosts known_hosts_dir run_name canonical_known_hosts qemu_pid qemu_start expected_exe worker controller helper source_target source_file target_file target_dir mode output line site_name site_line status=0 reason
  local -a connection_fields=() ssh_args=()
  [[ "$key_arg" == /* ]] || { usage >&2; exit 2; }
  key="$(realpath -e -- "$key_arg")" || fail 'VM diagnostic identity is unavailable.'
  scratch="${HOME:?}/agent-scratch/LocalAI-SBlue/acceptance-vm"
  canonical_scratch="$(realpath -e -- "$scratch")" || fail 'VM diagnostic scratch is unavailable.'
  active="$scratch/diagnostic-active"
  connection="$scratch/diagnostic-connection"
  [[ -d "$scratch" && ! -L "$scratch" && "$(stat -c '%u:%a' -- "$scratch")" == "$(id -u):700" ]] || fail 'VM diagnostic pause is not active.'
  [[ -f "$active" && ! -L "$active" && "$(stat -c '%u:%a' -- "$active")" == "$(id -u):600" ]] || fail 'VM diagnostic pause is not active.'
  [[ -f "$connection" && ! -L "$connection" && "$(stat -c '%u:%a' -- "$connection")" == "$(id -u):600" ]] || fail 'VM diagnostic connection is unavailable.'
  mapfile -t connection_fields <"$connection"
  [[ "${#connection_fields[@]}" == 4 ]] || fail 'VM diagnostic connection is invalid.'
  port="${connection_fields[0]}"
  known_hosts="${connection_fields[1]}"
  qemu_pid="${connection_fields[2]}"
  qemu_start="${connection_fields[3]}"
  if [[ ! "$port" =~ ^[0-9]{1,5}$ ]]; then fail 'VM diagnostic connection is invalid.'; fi
  if (( 10#$port == 0 || 10#$port > 65535 )); then fail 'VM diagnostic connection is invalid.'; fi
  [[ "$key" == /* && ! -L "$key" && -f "$key" && "$(stat -c '%u' -- "$key")" == "$(id -u)" ]] || fail 'VM diagnostic identity is unavailable.'
  case "$(stat -c '%a' -- "$key")" in 400|600) ;; *) fail 'VM diagnostic identity is not private.' ;; esac
  known_hosts_dir="${known_hosts%/*}"
  run_name="${known_hosts_dir##*/}"
  [[ "$known_hosts" == "$scratch"/run.*/known_hosts && "$run_name" =~ ^run\.[A-Za-z0-9]+$ && ! -L "$known_hosts_dir" && -d "$known_hosts_dir" && "$(stat -c '%u:%a' -- "$known_hosts_dir")" == "$(id -u):700" && "$(realpath -e -- "$known_hosts_dir")" == "$canonical_scratch/$run_name" ]] || fail 'VM diagnostic host key is unavailable.'
  canonical_known_hosts="$canonical_scratch/$run_name/known_hosts"
  [[ ! -L "$known_hosts" && -f "$known_hosts" && "$(realpath -e -- "$known_hosts")" == "$canonical_known_hosts" && "$(stat -c '%u:%a' -- "$known_hosts")" == "$(id -u):600" ]] || fail 'VM diagnostic host key is unavailable.'
  ssh-keygen -F "[127.0.0.1]:$port" -f "$known_hosts" >/dev/null 2>&1 || fail 'VM diagnostic host key is invalid.'
  expected_exe="$(realpath -e -- "$(type -P qemu-system-x86_64)")" || fail 'VM diagnostic QEMU executable is unavailable.'
  qemu_process_matches "$qemu_pid" "$qemu_start" "$port" "$expected_exe" "$proc_root" || fail 'VM diagnostic QEMU process identity is stale or mismatched.'
  worker=/root/agent-scratch/LocalAI-SBlue/acceptance-source/scripts/acceptance-guest.sh
  controller=/root/agent-scratch/LocalAI-SBlue/acceptance-source/bin/localaictl
  helper=/root/agent-scratch/LocalAI-SBlue/acceptance-source/lib/backup_archive.py
  isolated_ssh_args ssh_args "$key" "$port" "$known_hosts" 5
  # Refresh only the acceptance diagnostic worker in this disposable guest.
  # The remote command and target are fixed, and the connection remains bound
  # to the recorded QEMU process and pinned host key.
  if ! timeout 30s ssh "${ssh_args[@]}" root@127.0.0.1 \
    "install -o root -g root -m 0644 /dev/stdin $worker" \
    <"$repo_root/scripts/acceptance-guest.sh" >/dev/null 2>&1; then
    fail 'could not refresh the fixed VM diagnostic worker.'
  fi
  printf 'diagnostic-worker: refreshed\n'
  for source_target in "$repo_root/bin/localaictl:$controller" "$repo_root/lib/backup_archive.py:$helper"; do
    source_file="${source_target%%:*}"
    target_file="${source_target#*:}"
    target_dir="${target_file%/*}"
    mode=0644
    [[ "$target_file" == */bin/localaictl ]] && mode=0755
    if ! timeout 30s ssh "${ssh_args[@]}" root@127.0.0.1 \
      "test -d $target_dir && test ! -L $target_dir && test ! -L $target_file && install -o root -g root -m $mode /dev/stdin $target_file" \
      <"$source_file" >/dev/null 2>&1; then
      fail 'could not refresh a fixed VM diagnostic component.'
    fi
  done
  local rootless_output=''
  local diagnostic_receipt=/root/agent-scratch/LocalAI-SBlue/acceptance-source/.diagnostic-receipt
  if rootless_output="$(timeout 240s ssh "${ssh_args[@]}" root@127.0.0.1 \
    "receipt=$diagnostic_receipt; if [ -L \$receipt ] || [ -e \$receipt ]; then printf 'diagnostic graphroot-unshare-poc-reason: receipt-occupied\\n'; exit 0; fi; umask 077; : >\$receipt || { printf 'diagnostic graphroot-unshare-poc-reason: receipt-create-failed\\n'; exit 0; }; chmod 0600 \$receipt || { rm -f -- \$receipt; printf 'diagnostic graphroot-unshare-poc-reason: receipt-mode-failed\\n'; exit 0; }; trap 'rm -f -- \$receipt' EXIT; env LOCALAI_ACCEPTANCE_MODE=vm LOCALAI_ACCEPTANCE_RECEIPT=\$receipt bash $worker --rootless-archive-roundtrip >/dev/null 2>&1; status=\$?; if [ \$status -eq 0 ]; then printf 'diagnostic graphroot-unshare-poc-run: pass\\n'; else printf 'diagnostic graphroot-unshare-poc-run: fail\\n'; fi; grep -E '^diagnostic (guest-worker-prerequisite|graphroot-unshare-(poc-reason|poc-output|poc-status|exception-line|setup-reason|owner-mode|xattr|selinux|host-mapping)): ' \$receipt | tail -n 10" 2>/dev/null)"; then
    printf '%s\n' "$rootless_output" | while IFS= read -r line; do
      if [[ "$line" == 'diagnostic graphroot-unshare-poc-reason: roundtrip-pass' ]]; then
        printf '%s\n' "$line"
        continue
      fi
      case "$line" in
        'diagnostic graphroot-unshare-poc-run: pass'|'diagnostic graphroot-unshare-poc-run: fail') printf '%s\n' "$line" ;;
        'diagnostic graphroot-unshare-setup-reason: config-load'|'diagnostic graphroot-unshare-setup-reason: state-directory'|'diagnostic graphroot-unshare-setup-reason: temp-directory'|'diagnostic graphroot-unshare-setup-reason: service-uid'|'diagnostic graphroot-unshare-setup-reason: directory-owner'|'diagnostic graphroot-unshare-setup-reason: directory-mode'|'diagnostic graphroot-unshare-setup-reason: probe-mode'|'diagnostic graphroot-unshare-setup-reason: probe-owner') printf '%s\n' "$line" ;;
        'diagnostic guest-worker-prerequisite: not-root'|'diagnostic guest-worker-prerequisite: host-state-missing'|'diagnostic guest-worker-prerequisite: host-state-permissions'|'diagnostic guest-worker-prerequisite: selinux-not-enforcing'|'diagnostic guest-worker-prerequisite: debug-shell-active'|'diagnostic guest-worker-prerequisite: receipt-private') printf '%s\n' "$line" ;;
        'diagnostic graphroot-unshare-poc-reason: receipt-occupied'|'diagnostic graphroot-unshare-poc-reason: receipt-create-failed'|'diagnostic graphroot-unshare-poc-reason: receipt-mode-failed'|'diagnostic graphroot-unshare-poc-reason: subgid-map-unavailable'|'diagnostic graphroot-unshare-poc-reason: tar-create-failed'|'diagnostic graphroot-unshare-poc-reason: tar-extract-failed'|'diagnostic graphroot-unshare-poc-reason: owner-mode-failed'|'diagnostic graphroot-unshare-poc-reason: user-xattr-failed'|'diagnostic graphroot-unshare-poc-reason: selinux-source-unavailable'|'diagnostic graphroot-unshare-poc-reason: selinux-label-failed'|'diagnostic graphroot-unshare-poc-reason: python-permission'|'diagnostic graphroot-unshare-poc-reason: python-file-missing'|'diagnostic graphroot-unshare-poc-reason: python-os-error'|'diagnostic graphroot-unshare-poc-reason: python-value-error'|'diagnostic graphroot-unshare-poc-reason: python-overflow'|'diagnostic graphroot-unshare-poc-reason: python-type-error'|'diagnostic graphroot-unshare-poc-reason: python-key-error'|'diagnostic graphroot-unshare-poc-reason: python-runtime-error'|'diagnostic graphroot-unshare-poc-reason: python-attribute-error'|'diagnostic graphroot-unshare-poc-reason: python-file-exists'|'diagnostic graphroot-unshare-poc-reason: python-not-directory'|'diagnostic graphroot-unshare-poc-reason: python-is-directory'|'diagnostic graphroot-unshare-poc-reason: python-blocking-io'|'diagnostic graphroot-unshare-poc-reason: python-interrupted'|'diagnostic graphroot-unshare-poc-reason: python-child-process'|'diagnostic graphroot-unshare-poc-reason: python-subprocess'|'diagnostic graphroot-unshare-poc-reason: python-unicode-decode'|'diagnostic graphroot-unshare-poc-reason: python-unicode-encode'|'diagnostic graphroot-unshare-poc-reason: python-unicode'|'diagnostic graphroot-unshare-poc-reason: python-index'|'diagnostic graphroot-unshare-poc-reason: python-assertion'|'diagnostic graphroot-unshare-poc-reason: python-name'|'diagnostic graphroot-unshare-poc-reason: python-eof'|'diagnostic graphroot-unshare-poc-reason: python-stop-iteration'|'diagnostic graphroot-unshare-poc-reason: python-not-implemented'|'diagnostic graphroot-unshare-poc-reason: python-import'|'diagnostic graphroot-unshare-poc-reason: python-module-missing'|'diagnostic graphroot-unshare-poc-reason: python-memory'|'diagnostic graphroot-unshare-poc-reason: python-other'|'diagnostic graphroot-unshare-poc-reason: no-poc-result'|'diagnostic graphroot-unshare-poc-reason: unshare-command-failed')
          printf '%s\n' "$line" ;;
        'diagnostic graphroot-unshare-owner-mode: pass'|'diagnostic graphroot-unshare-owner-mode: fail'|'diagnostic graphroot-unshare-xattr: pass'|'diagnostic graphroot-unshare-xattr: fail'|'diagnostic graphroot-unshare-selinux: pass'|'diagnostic graphroot-unshare-selinux: fail'|'diagnostic graphroot-unshare-selinux: unavailable'|'diagnostic graphroot-unshare-host-mapping: pass'|'diagnostic graphroot-unshare-host-mapping: fail')
          printf '%s\n' "$line" ;;
        'diagnostic graphroot-unshare-poc-output: empty'|'diagnostic graphroot-unshare-poc-output: present'|'diagnostic graphroot-unshare-poc-status: zero'|'diagnostic graphroot-unshare-poc-status: nonzero')
          printf '%s\n' "$line" ;;
        'diagnostic graphroot-unshare-exception-line: '*)
          exception_line="${line#diagnostic graphroot-unshare-exception-line: }"
          [[ "$exception_line" =~ ^[0-9]{1,6}$ ]] && printf 'diagnostic graphroot-unshare-exception-line: %s\n' "$exception_line" ;;
      esac
    done
    if [[ -z "$rootless_output" ]]; then printf 'diagnostic graphroot-unshare-poc-reason: no-poc-output\n'; fi
  else
    printf 'diagnostic graphroot-unshare-poc-reason: ssh-unavailable\n'
  fi
  unset rootless_output
  if output="$(timeout 1800s ssh "${ssh_args[@]}" root@127.0.0.1 "bash $worker diagnose-backup" 2>&1)"; then
    status=0
  else
    status=$?
  fi
  while IFS= read -r line; do
    case "$line" in
      'diagnostic backup-restore-backup-reason: graphroot-ancestor-owner'|'diagnostic backup-restore-backup-reason: graphroot-ancestor-mode'|'diagnostic backup-restore-backup-reason: graphroot-ancestor-special')
        printf '%s\n' "$line"
        continue ;;
      'diagnostic acceptance-marker-owner-before: root-mode-0600'|'diagnostic acceptance-marker-owner-after: service-mode-0600')
        printf '%s\n' "$line" ;;
      'diagnostic acceptance-marker-owner-retry: config-unavailable'|'diagnostic acceptance-marker-owner-retry: graphroot-unavailable'|'diagnostic acceptance-marker-owner-retry: graphroot-mismatch'|'diagnostic acceptance-marker-owner-retry: marker-metadata-mismatch'|'diagnostic acceptance-marker-owner-retry: marker-label-mismatch'|'diagnostic acceptance-marker-owner-retry: chown-failed'|'diagnostic acceptance-marker-owner-retry: chown-verification-failed'|'diagnostic acceptance-marker-owner-retry: relabel-required')
        printf '%s\n' "$line" ;;
    esac
    case "$line" in
      'command backup-restore-backup: localaictl backup with root-owned config and persistent marker'|'waiting backup-restore-backup: timeout 1800s'|'step backup-restore-backup: pass'|'step backup-restore-backup: fail'|'step backup-restore-backup: timeout')
        printf '%s\n' "$line" ;;
      'command backup-restore-backup-after-marker-owner: localaictl backup with root-owned config and persistent marker'|'waiting backup-restore-backup-after-marker-owner: timeout 1800s'|'step backup-restore-backup-after-marker-owner: pass'|'step backup-restore-backup-after-marker-owner: fail'|'step backup-restore-backup-after-marker-owner: timeout')
        printf '%s\n' "$line" ;;
      'diagnostic backup-restore-backup-reason: '*)
        reason="${line#diagnostic backup-restore-backup-reason: }"
        case "$reason" in
          service-stop|service-restart|unit-ownership|capacity|destination-parent-unsafe|destination-exists|destination-directory|destination-overlap|configured-paths|archive-file-type|unsafe-name|traversal-path|duplicate-member|link-cross-root|link-escape|hardlink|system-manager-tree|path-outside-roots|special-member|nested-member|privileged-mode|file-capability|config-member|persistent-root-type|missing-metadata|archive-read|persistent-root-metadata|unit-path-outside-roots|unit-ancestor-metadata-missing|unit-ancestor-metadata-weakened|unit-tree-omitted|unit-tree-extra-entry|unit-tree-type-mismatch|unit-tree-file-mismatch|unit-tree-link-mismatch|unit-tree-unsupported-link|unit-tree-unexpected|unit-tree-entries-differ|unit-tree-check-exception|unit-tree-validation|symlink|archive-validation|helper-invocation|helper-validation|helper-exception|helper-no-diagnostic|helper-unclassified|rootless-context|rootless-mapping|rootless-archive|rootless-tar-permission|rootless-tar-source-open-permission|rootless-tar-source-read-permission|rootless-tar-xattr-read-permission|rootless-tar-xattr-write-permission|rootless-tar-acl-read-permission|rootless-tar-acl-write-permission|rootless-tar-source-stat-permission|rootless-tar-ownership-permission|rootless-tar-capacity|rootless-tar-source-changed|rootless-tar-unsupported-option|rootless-tar-source-path|rootless-tar-operation-not-permitted|rootless-tar-service-manager|rootless-tar-xattr|rootless-tar-empty-error|rootless-tar-other|archive-metadata|compose-archive-read|compose-root-mismatch|compose-entry-mismatch|compose-metadata-mismatch|compose-file-mismatch|compose-xattrs-mismatch|compose-staged-xattrs-mismatch|compose-path-invalid|tar|lock-contention|config-guard|other)
            printf 'diagnostic backup-restore-backup-reason: %s\n' "$reason" ;;
          *) printf 'diagnostic backup-restore-backup-reason: unknown\n' ;;
        esac ;;
      'diagnostic backup-restore-backup-after-marker-owner-reason: '*)
        reason="${line#diagnostic backup-restore-backup-after-marker-owner-reason: }"
        case "$reason" in
          service-stop|service-restart|unit-ownership|capacity|destination-parent-unsafe|destination-exists|destination-directory|destination-overlap|configured-paths|archive-file-type|unsafe-name|traversal-path|duplicate-member|link-cross-root|link-escape|hardlink|system-manager-tree|path-outside-roots|special-member|nested-member|privileged-mode|file-capability|config-member|persistent-root-type|missing-metadata|archive-read|persistent-root-metadata|unit-path-outside-roots|unit-ancestor-metadata-missing|unit-ancestor-metadata-weakened|unit-tree-omitted|unit-tree-extra-entry|unit-tree-type-mismatch|unit-tree-file-mismatch|unit-tree-link-mismatch|unit-tree-unsupported-link|unit-tree-unexpected|unit-tree-entries-differ|unit-tree-check-exception|unit-tree-validation|symlink|archive-validation|helper-invocation|helper-validation|helper-exception|helper-no-diagnostic|helper-unclassified|rootless-context|rootless-mapping|rootless-archive|rootless-tar-permission|rootless-tar-source-open-permission|rootless-tar-source-read-permission|rootless-tar-xattr-read-permission|rootless-tar-xattr-write-permission|rootless-tar-acl-read-permission|rootless-tar-acl-write-permission|rootless-tar-source-stat-permission|rootless-tar-ownership-permission|rootless-tar-capacity|rootless-tar-source-changed|rootless-tar-unsupported-option|rootless-tar-source-path|rootless-tar-operation-not-permitted|rootless-tar-service-manager|rootless-tar-xattr|rootless-tar-empty-error|rootless-tar-other|archive-metadata|compose-archive-read|compose-root-mismatch|compose-entry-mismatch|compose-metadata-mismatch|compose-file-mismatch|compose-xattrs-mismatch|compose-staged-xattrs-mismatch|compose-path-invalid|tar|lock-contention|config-guard|other)
            printf 'diagnostic backup-restore-backup-after-marker-owner-reason: %s\n' "$reason" ;;
          *) printf 'diagnostic backup-restore-backup-after-marker-owner-reason: unknown\n' ;;
        esac ;;
      'diagnostic backup-restore-controller-site: '*|'diagnostic backup-restore-helper-site: '*)
        site_line="${line##*: }"
        if [[ "$site_line" =~ ^[0-9]{1,6}$ ]]; then
          site_name="${line#diagnostic }"
          site_name="${site_name%%:*}"
          printf 'diagnostic %s: %s\n' "$site_name" "$site_line"
        fi ;;
      'diagnostic backup-restore-rootless-tar-member: '*)
        if [[ "$line" =~ ^diagnostic\ backup-restore-rootless-tar-member:\ (member-acceptance-marker-owner-(service|subuid|host-root|other)-mode-([0-7]{4})-persistence-fixture|member-(regular|directory|symlink|special)-owner-(service|subuid|host-root|other)-mode-([0-7]{4})-path-(overlay-layer|image-metadata|container-metadata|layer-metadata|overlay-locks|volume-data|libpod-metadata|temporary-data|mount-metadata|container-state|storage-lock|storage-database|network-metadata|hidden-root-entry|root-lock-entry|root-database-entry|root-metadata-entry|other-root-entry|other-root-subtree)|member-unidentified|member-outside-graphroot|member-metadata-unavailable|member-path-unsafe)$ ]]; then
          printf '%s\n' "$line"
        fi ;;
      'diagnostic backup-restore-backup-member: '*|'diagnostic backup-restore-backup-after-marker-owner-member: '*)
        if [[ "$line" =~ ^diagnostic\ (backup-restore-backup|backup-restore-backup-after-marker-owner)-member:\ (member-acceptance-marker-owner-(service|subuid|host-root|other)-mode-([0-7]{4})-persistence-fixture|member-(regular|directory|symlink|special)-owner-(service|subuid|host-root|other)-mode-([0-7]{4})-path-(overlay-layer|image-metadata|container-metadata|layer-metadata|overlay-locks|volume-data|libpod-metadata|temporary-data|mount-metadata|container-state|storage-lock|storage-database|network-metadata|hidden-root-entry|root-lock-entry|root-database-entry|root-metadata-entry|other-root-entry|other-root-subtree)|member-unidentified|member-outside-graphroot|member-metadata-unavailable|member-path-unsafe)$ ]]; then
          printf '%s\n' "$line"
        fi ;;
      'diagnostic backup-restore-graphroot-ancestor-mode: '*)
        if [[ "$line" =~ ^diagnostic\ backup-restore-graphroot-ancestor-mode:\ depth-([0-9]{1,2})\ mode-([0-7]{4})$ ]]; then
          printf 'diagnostic backup-restore-graphroot-ancestor-mode: depth-%s mode-%s\n' \
            "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        fi ;;
      'Acceptance step backup-restore-backup: fail ('*) printf 'step backup-restore-backup: fail\n' ;;
      'acceptance: '*) printf 'acceptance: fail\n' ;;
    esac
  done <<<"$output"
  unset output
  return "$status"
}
diagnose_vm_backup() {
  [[ "$#" == 2 && "$2" == /* ]] || { usage >&2; exit 2; }
  diagnose_vm_backup_with_proc_root "$2" /proc
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
qemu_start_time="$(proc_start_time "$qemu_pid" /proc)" || fail 'could not record VM process identity.'
(umask 077; set -o noclobber; printf '%s\n%s\n%s\n%s\n' "$port" "$work/known_hosts" "$qemu_pid" "$qemu_start_time" >"$connection") || fail 'could not prepare VM diagnostic connection.'
diagnostic_connection_created=1
chmod 0600 -- "$connection"
printf '[127.0.0.1]:%s %s %s\n' "$port" "$hostkey_type" "$hostkey_data" > "$work/known_hosts"
isolated_ssh_args ssh_args "$key" "$port" "$work/known_hosts" 3
wait_for_guest() {
  local deadline=$((SECONDS + 300))
  printf 'Waiting for the disposable VM to accept SSH (timeout 300s)...\n' >&2
  if ! kill -0 "$qemu_pid" 2>/dev/null; then
    printf 'vm-qemu-log-category: %s\n' "$(qemu_log_category "$work/qemu.log")"
    report_qemu_exit
    fail 'VM exited before SSH was ready.'
  fi
  until timeout 5s ssh "${ssh_args[@]}" root@127.0.0.1 true >/dev/null 2>&1; do
    if ! kill -0 "$qemu_pid" 2>/dev/null; then
      printf 'vm-qemu-log-category: %s\n' "$(qemu_log_category "$work/qemu.log")"
      report_qemu_exit
      fail 'VM exited before SSH was ready.'
    fi
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
timeout 1800s ssh "${ssh_args[@]}" root@127.0.0.1 "bash $worker install" 2>/dev/null &
install_ssh_pid=$!
while kill -0 "$install_ssh_pid" 2>/dev/null; do
  sleep 60
  if kill -0 "$install_ssh_pid" 2>/dev/null; then install_process_snapshot; fi
done
wait "$install_ssh_pid" || fail 'VM install phase failed.'
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
