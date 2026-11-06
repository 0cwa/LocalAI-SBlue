#!/usr/bin/env bash
# Runs only inside a disposable VM. Output is a sanitized receipt fragment.
set -euo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/acceptance.sh
# The helper is checked independently.
# shellcheck disable=SC1091
source "$repo_root/lib/acceptance.sh"

host_receipt_ready=0
rootless_poc_dir=''
ROOTLESS_TAR_ACCEPTANCE_MARKER=0
record_early_failure_category() {
  local category='' receipt_path="${LOCALAI_ACCEPTANCE_RECEIPT:-}"
  case "${LOCALAI_ACCEPTANCE_MODE:-vm}:$receipt_path" in
    "host:/var/lib/localai-acceptance-run/receipt") ;;
    "vm:$repo_root/.diagnostic-receipt") ;;
    *) return 0 ;;
  esac
  [[ -f "$receipt_path" && ! -L "$receipt_path" && "$(stat -c '%u:%a' "$receipt_path" 2>/dev/null)" == 0:600 ]] || return 0
  case "$*" in
    'acceptance worker requires root.') category=not-root ;;
    'host worker requires a prepared isolated run.') category=host-state-missing ;;
    'host run state is not root-owned and private.') category=host-state-permissions ;;
    'SELinux must be enforcing.') category=selinux-not-enforcing ;;
    'debug shell must be inactive during acceptance.') category=debug-shell-active ;;
    'host receipt is not root-owned and private.') category='receipt-private' ;;
    *) return 0 ;;
  esac
  printf 'diagnostic guest-worker-prerequisite: %s\n' "$category" >>"$receipt_path"
}
fail() {
  record_early_failure_category "$*"
  printf 'acceptance: %s\n' "$*" >&2
  if [[ "${host_receipt_ready:-0}" == 1 ]]; then printf 'acceptance: %s\n' "$*" >>"$receipt"; fi
  exit 1
}
[[ "${EUID:-$(id -u)}" == 0 ]] || fail 'acceptance worker requires root.'
mode="${LOCALAI_ACCEPTANCE_MODE:-vm}"
host_state=/var/lib/localai-acceptance-run
case "$mode" in
  vm) systemd-detect-virt --vm --quiet || fail 'VM worker requires a VM.' ;;
  host)
    [[ -d "$host_state" && ! -L "$host_state" && -f "$host_state/initial-clean" && ! -L "$host_state/initial-clean" ]] || fail 'host worker requires a prepared isolated run.'
    [[ "$(stat -c '%u:%a' "$host_state")" == 0:700 && "$(stat -c '%u:%a' "$host_state/initial-clean")" == 0:600 ]] || fail 'host run state is not root-owned and private.'
    ;;
  *) fail 'unknown acceptance mode.' ;;
esac
[[ "$(getenforce)" == Enforcing ]] || fail 'SELinux must be enforcing.'
if systemctl is-active --quiet debug-shell.service; then
  fail 'debug shell must be inactive during acceptance.'
fi

ensure_initial_isolation() {
  if [[ "$mode" == vm ]]; then
    localai_acceptance_clean_install / || fail 'pre-existing LocalAI state is not an isolated test install.'
  elif [[ ! -e "$host_state/install-started" && ! -L "$host_state/install-started" ]]; then
    localai_acceptance_clean_install / || fail 'pre-existing LocalAI state is not an isolated test install.'
    printf 'started\n' >"$host_state/install-started"
  elif [[ ! -f "$host_state/install-started" || -L "$host_state/install-started" ]]; then
    fail 'host install marker is not a regular file.'
  fi
}

evidence_mode_for_host() {
  local status=0
  systemd-detect-virt --vm --quiet || status=$?
  case "$status" in
    0) printf 'vm\n' ;;
    1) printf 'host-unverified\n' ;;
    *) return 1 ;;
  esac
}

acceptance_guest_work_dir() {
  local scratch="$1" canonical_scratch work
  canonical_scratch="$(realpath -e -- "$scratch")" || return 1
  [[ -d "$canonical_scratch" && ! -L "$canonical_scratch" ]] || return 1
  work="$(mktemp -d "$canonical_scratch/guest.XXXXXX")" || return 1
  realpath -e -- "$work"
}

wait_for_health() {
  local controller="$1" output deadline=$((SECONDS + 80))
  while (( SECONDS < deadline )); do
    output="$("$controller" doctor 2>&1)" || :
    if [[ "$output" == *"health result: HTTP 200"* || "$output" == *"health result: HTTP 401"* ]]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

service_systemctl() {
  local uid
  uid="$(id -u localai)" || return 1
  systemd-run --user --machine=localai@.host --wait --pipe --collect \
    --setenv=HOME=/var/lib/localai --setenv="XDG_RUNTIME_DIR=/run/user/$uid" \
    --setenv="DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus" \
    --setenv=PATH=/usr/bin:/bin -- /usr/bin/systemctl --user "$@"
}

cpu_image=docker.io/localai/localai:latest
service_podman() {
  local service_user="${LOCALAI_SERVICE_USER:-localai}" uid home
  uid="$(id -u "$service_user")" || return 1
  home="$(getent passwd "$service_user" | cut -d: -f6)" || return 1
  [[ -n "$home" && "$home" == /* ]] || return 1
  systemd-run --user --machine="${service_user}@.host" --wait --pipe --collect \
    --setenv="HOME=$home" --setenv="XDG_RUNTIME_DIR=/run/user/$uid" \
    --setenv="DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus" \
    --setenv=PATH=/usr/bin:/bin -- /usr/bin/podman "$@"
}

service_podman_graphroot() {
  local attempt output
  for attempt in 1 2 3; do
    if output="$(service_podman info --format '{{.Store.GraphRoot}}' 2>/dev/null)"; then
      printf '%s\n' "$output"
      return 0
    fi
    (( attempt < 3 )) || return 1
    sleep 1
  done
}

rootless_poc_failure_category() {
  local result="$1"
  case "$result" in
    *'poc: namespace-owner-mode-pass'*) printf 'roundtrip-pass' ;;
    *'poc: subgid-map-unavailable'*) printf 'subgid-map-unavailable' ;;
    *'poc: tar-create-failed'*) printf 'tar-create-failed' ;;
    *'poc: tar-extract-failed'*) printf 'tar-extract-failed' ;;
    *'poc: owner-mode-failed'*) printf 'owner-mode-failed' ;;
    *'poc: user-xattr-failed'*) printf 'user-xattr-failed' ;;
    *'poc: selinux-source-unavailable'*) printf 'selinux-source-unavailable' ;;
    *'poc: selinux-label-failed'*) printf 'selinux-label-failed' ;;
    *'poc: python-PermissionError'*) printf 'python-permission' ;;
    *'poc: python-FileNotFoundError'*) printf 'python-file-missing' ;;
    *'poc: python-OSError'*) printf 'python-os-error' ;;
    *'poc: python-ValueError'*) printf 'python-value-error' ;;
    *'poc: python-OverflowError'*) printf 'python-overflow' ;;
    *'poc: python-TypeError'*) printf 'python-type-error' ;;
    *'poc: python-KeyError'*) printf 'python-key-error' ;;
    *'poc: python-RuntimeError'*) printf 'python-runtime-error' ;;
    *'poc: python-AttributeError'*) printf 'python-attribute-error' ;;
    *'poc: python-FileExistsError'*) printf 'python-file-exists' ;;
    *'poc: python-NotADirectoryError'*) printf 'python-not-directory' ;;
    *'poc: python-IsADirectoryError'*) printf 'python-is-directory' ;;
    *'poc: python-BlockingIOError'*) printf 'python-blocking-io' ;;
    *'poc: python-InterruptedError'*) printf 'python-interrupted' ;;
    *'poc: python-CalledProcessError'*) printf 'python-child-process' ;;
    *'poc: python-SubprocessError'*) printf 'python-subprocess' ;;
    *'poc: python-UnicodeDecodeError'*) printf 'python-unicode-decode' ;;
    *'poc: python-UnicodeEncodeError'*) printf 'python-unicode-encode' ;;
    *'poc: python-UnicodeError'*) printf 'python-unicode' ;;
    *'poc: python-IndexError'*) printf 'python-index' ;;
    *'poc: python-AssertionError'*) printf 'python-assertion' ;;
    *'poc: python-NameError'*) printf 'python-name' ;;
    *'poc: python-EOFError'*) printf 'python-eof' ;;
    *'poc: python-StopIteration'*) printf 'python-stop-iteration' ;;
    *'poc: python-NotImplementedError'*) printf 'python-not-implemented' ;;
    *'poc: python-ImportError'*) printf 'python-import' ;;
    *'poc: python-ModuleNotFoundError'*) printf 'python-module-missing' ;;
    *'poc: python-MemoryError'*) printf 'python-memory' ;;
    *'poc: python-other'*) printf 'python-other' ;;
    *) printf 'no-poc-result' ;;
  esac
}

record_rootless_poc_setup_failure() {
  local receipt_path="$1" category="$2"
  [[ -f "$receipt_path" && ! -L "$receipt_path" ]] || return 1
  printf 'diagnostic graphroot-unshare-setup-reason: %s\n' "$category" >>"$receipt_path"
  return 1
}

rootless_archive_roundtrip_poc() {
  local receipt_path="${LOCALAI_ACCEPTANCE_RECEIPT:-}" probe_script result status=0 uid service_user
  [[ -n "$receipt_path" && -f "$receipt_path" && ! -L "$receipt_path" ]] || return 1
  # shellcheck disable=SC1091
  # shellcheck source=../lib/config.sh
  source "$repo_root/lib/config.sh"
  localai_config_load_compat /etc/localai/localai.conf "$repo_root/localai/localai.lock" || { record_rootless_poc_setup_failure "$receipt_path" config-load; return 1; }
  service_user="$LOCALAI_SERVICE_USER"
  [[ -d "$LOCALAI_STATE_DIR" && ! -L "$LOCALAI_STATE_DIR" ]] || { record_rootless_poc_setup_failure "$receipt_path" state-directory; return 1; }
  rootless_poc_dir="$(mktemp -d "$LOCALAI_STATE_DIR/.localaictl-unshare-poc.XXXXXX")" || { record_rootless_poc_setup_failure "$receipt_path" temp-directory; return 1; }
  uid="$(id -u "$service_user")" || { record_rootless_poc_setup_failure "$receipt_path" service-uid; return 1; }
  chown "$service_user:$service_user" "$rootless_poc_dir" || { record_rootless_poc_setup_failure "$receipt_path" directory-owner; return 1; }
  chmod 0700 "$rootless_poc_dir" || { record_rootless_poc_setup_failure "$receipt_path" directory-mode; return 1; }
  probe_script="$rootless_poc_dir/probe.py"
  cat >"$probe_script" <<'PY'
import os
import pathlib
import subprocess
import sys

def stop(category):
    print(f"poc: {category}")
    raise SystemExit(0)

try:
    print("poc: started", flush=True)
    base = pathlib.Path(sys.argv[1])
    source = base / "source"
    target = base / "target"
    source.mkdir(mode=0o700)
    target.mkdir(mode=0o700)
    fixture = source / "setgid-fixture"
    fixture.write_bytes(b"synthetic-backup-roundtrip")
    subgid_ranges = []
    for row in pathlib.Path("/etc/subgid").read_text(encoding="ascii").splitlines():
        fields = row.split(":")
        if len(fields) == 3 and fields[0] == sys.argv[2] and fields[1].isdigit() and fields[2].isdigit():
            subgid_ranges.append((int(fields[1]), int(fields[1]) + int(fields[2])))
    mapped_gid = None
    for row in pathlib.Path("/proc/self/gid_map").read_text(encoding="ascii").splitlines():
        inside, outside, length = map(int, row.split())
        for start, end in subgid_ranges:
            host_gid = max(outside, start)
            if host_gid < min(outside + length, end):
                mapped_gid = inside + host_gid - outside
                break
        if mapped_gid is not None:
            break
    if mapped_gid is None or mapped_gid == 0:
        stop("subgid-map-unavailable")
    os.chown(fixture, 0, mapped_gid)
    fixture.chmod(0o2750)
    os.setxattr(fixture, "user.issue20-probe", b"synthetic-xattr")
    try:
        source_selinux = os.getxattr(fixture, "security.selinux")
    except OSError:
        source_selinux = None
    archive = base / "fixture.tar"
    create = subprocess.run([
        "/usr/bin/tar", "--create", "--file", str(archive), "--xattrs", "--acls", "--selinux",
        "--numeric-owner", "--directory", str(source), ".",
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if create.returncode:
        stop("tar-create-failed")
    extract = subprocess.run([
        "/usr/bin/tar", "--extract", "--file", str(archive), "--xattrs", "--acls", "--selinux",
        "--numeric-owner", "--same-owner", "--same-permissions", "--directory", str(target),
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if extract.returncode:
        stop("tar-extract-failed")
    restored = target / "setgid-fixture"
    expected = fixture.stat()
    actual = restored.stat()
    if (expected.st_uid, expected.st_gid, expected.st_mode & 0o7777) != (actual.st_uid, actual.st_gid, actual.st_mode & 0o7777):
        stop("owner-mode-failed")
    if os.getxattr(fixture, "user.issue20-probe") != os.getxattr(restored, "user.issue20-probe"):
        stop("user-xattr-failed")
    if source_selinux is None:
        stop("selinux-source-unavailable")
    if os.getxattr(restored, "security.selinux") != source_selinux:
        stop("selinux-label-failed")
    print("poc: namespace-owner-mode-pass")
    print("poc: user-xattr-pass")
    print("poc: selinux-label-pass")
except SystemExit:
    raise
except BaseException as error:
    import traceback
    known = {"PermissionError", "FileNotFoundError", "OSError", "ValueError", "OverflowError", "TypeError", "KeyError", "RuntimeError", "AttributeError", "NameError", "EOFError", "StopIteration", "NotImplementedError", "AssertionError", "IndexError", "IsADirectoryError", "NotADirectoryError", "FileExistsError", "BlockingIOError", "InterruptedError", "UnicodeError", "MemoryError"}
    exception_name = type(error).__name__
    if exception_name in known:
        print("poc: python-" + exception_name)
    else:
        print("poc: python-other")
    frames = traceback.extract_tb(error.__traceback__)
    if frames:
        print("poc: exception-line-" + str(frames[-1].lineno))
    raise SystemExit(0)
PY
  chmod 0644 "$probe_script" || { rm -rf -- "$rootless_poc_dir"; record_rootless_poc_setup_failure "$receipt_path" probe-mode; return 1; }
  chown "$service_user:$service_user" "$probe_script" || { rm -rf -- "$rootless_poc_dir"; record_rootless_poc_setup_failure "$receipt_path" probe-owner; return 1; }
  if result="$(service_podman unshare /usr/bin/python3 "$probe_script" "$rootless_poc_dir" "$service_user" 2>&1)"; then
    status=0
  else
    status=$?
  fi
  local poc_reason
  poc_reason="$(rootless_poc_failure_category "$result")"
  if (( status != 0 )); then poc_reason=unshare-command-failed; fi
  printf 'diagnostic graphroot-unshare-poc-reason: %s\n' "$poc_reason" >>"$receipt_path"
  if [[ -n "$result" ]]; then
    printf 'diagnostic graphroot-unshare-poc-output: present\n' >>"$receipt_path"
  else
    printf 'diagnostic graphroot-unshare-poc-output: empty\n' >>"$receipt_path"
  fi
  if (( status == 0 )); then
    printf 'diagnostic graphroot-unshare-poc-status: zero\n' >>"$receipt_path"
  else
    printf 'diagnostic graphroot-unshare-poc-status: nonzero\n' >>"$receipt_path"
  fi
  if [[ "$result" =~ (^|$'\n')poc:\ exception-line-([0-9]{1,6})($|$'\n') ]]; then
    printf 'diagnostic graphroot-unshare-exception-line: %s\n' "${BASH_REMATCH[2]}" >>"$receipt_path"
  fi
  if [[ "$result" == *'poc: namespace-owner-mode-pass'* ]]; then
    printf 'diagnostic graphroot-unshare-owner-mode: pass\n' >>"$receipt_path"
  else
    printf 'diagnostic graphroot-unshare-owner-mode: fail\n' >>"$receipt_path"
  fi
  if [[ "$result" == *'poc: user-xattr-pass'* ]]; then
    printf 'diagnostic graphroot-unshare-xattr: pass\n' >>"$receipt_path"
  else
    printf 'diagnostic graphroot-unshare-xattr: fail\n' >>"$receipt_path"
  fi
  if [[ "$result" == *'poc: selinux-label-pass'* ]]; then
    printf 'diagnostic graphroot-unshare-selinux: pass\n' >>"$receipt_path"
  elif [[ "$result" == *'poc: selinux-source-unavailable'* ]]; then
    printf 'diagnostic graphroot-unshare-selinux: unavailable\n' >>"$receipt_path"
  else
    printf 'diagnostic graphroot-unshare-selinux: fail\n' >>"$receipt_path"
  fi
  if (( status != 0 )) || [[ "$result" != *'poc: namespace-owner-mode-pass'* || "$result" != *'poc: user-xattr-pass'* || "$result" != *'poc: selinux-label-pass'* ]]; then
    unset result
    rm -rf -- "$rootless_poc_dir"
    return 1
  fi
  local host_uid host_gid host_mode
  host_uid="$(stat -c %u -- "$rootless_poc_dir/target/setgid-fixture")" || status=1
  host_gid="$(stat -c %g -- "$rootless_poc_dir/target/setgid-fixture")" || status=1
  host_mode="$(stat -c %a -- "$rootless_poc_dir/target/setgid-fixture")" || status=1
  if (( status == 0 )) && [[ "$host_uid" == "$uid" && "$host_mode" == 2750 ]] &&
     python3 - "$host_gid" "$service_user" <<'PY'
import sys
gid = int(sys.argv[1])
for row in open("/etc/subgid", encoding="ascii"):
    fields = row.rstrip("\n").split(":")
    if len(fields) == 3 and fields[0] == sys.argv[2] and fields[1].isdigit() and fields[2].isdigit():
        start, length = int(fields[1]), int(fields[2])
        if start <= gid < start + length:
            raise SystemExit(0)
raise SystemExit(1)
PY
  then
    printf 'diagnostic graphroot-unshare-host-mapping: pass\n' >>"$receipt_path"
    unset result
    rm -rf -- "$rootless_poc_dir"
    rootless_poc_dir=''
    return 0
  fi
  printf 'diagnostic graphroot-unshare-host-mapping: fail\n' >>"$receipt_path"
  unset result
  rm -rf -- "$rootless_poc_dir"
  rootless_poc_dir=''
  return 1
}

unrelated_container_matches() {
  local run_id="$1" actual
  [[ "$run_id" =~ ^[a-f0-9]{32}$ ]] || return 2
  actual="$(service_podman inspect localai-acceptance-unrelated --format '{{index .Config.Labels "io.localai.acceptance.run"}}' 2>/dev/null)" || return 1
  [[ "$actual" == "$run_id" ]]
}

ensure_unrelated_container() {
  local run_id="$1" status=0
  [[ "$run_id" =~ ^[a-f0-9]{32}$ ]] || return 2
  service_podman container exists localai-acceptance-unrelated >/dev/null 2>&1 || status=$?
  case "$status" in
    0) unrelated_container_matches "$run_id" ;;
    1) service_podman create --name localai-acceptance-unrelated --label "io.localai.acceptance.run=$run_id" "$cpu_image" >/dev/null ;;
    *) return 1 ;;
  esac
}

check_unit() {
  local expected_active="$1" expected_enabled="$2" active enabled
  active="$(service_systemctl is-active localai.service 2>/dev/null || :)"
  enabled="$(service_systemctl is-enabled localai.service 2>/dev/null || :)"
  [[ "$active" == "$expected_active" && "$enabled" == "$expected_enabled" ]]
}

if [[ "${1:-}" == --check-unit && "$#" == 3 ]]; then
  check_unit "$2" "$3"
  exit $?
fi

if [[ "${1:-}" == --check-health && "$#" == 2 ]]; then
  wait_for_health "$2"
  exit $?
fi

if [[ "${1:-}" == --verify-unrelated && "$#" == 2 ]]; then
  unrelated_container_matches "$2"
  exit $?
fi

if [[ "${1:-}" == --ensure-unrelated && "$#" == 2 ]]; then
  ensure_unrelated_container "$2"
  exit $?
fi

if [[ "${1:-}" == --set-unit-enabled && "$#" == 2 ]]; then
  case "$2" in enable|disable) service_systemctl "$2" localai.service ;; *) exit 2 ;; esac
  exit $?
fi

phase="${1:-}"
[[ "$#" == 1 && ( "$phase" == install || "$phase" == verify || "$phase" == diagnose-backup || "$phase" == --rootless-archive-roundtrip ) ]] || fail 'expected install, verify, or backup diagnostic phase.'
umask 077
if [[ "$mode" == host ]]; then
  work="$host_state/work"
  progress="$host_state/progress"
  for path in "$work" "$progress"; do
    [[ ! -L "$path" && ( ! -e "$path" || -d "$path" ) ]] || fail 'host run scratch is not a real directory.'
    mkdir -p "$path"
    [[ "$(stat -c '%u:%a' "$path")" == 0:700 ]] || fail 'host run scratch is not root-owned and private.'
  done
  receipt="$host_state/receipt"
  [[ -f "$receipt" && ! -L "$receipt" && "$(stat -c '%u:%a' "$receipt")" == 0:600 ]] || fail 'host receipt is not root-owned and private.'
  host_receipt_ready=1
else
  scratch="${HOME:?}/agent-scratch/LocalAI-SBlue/host-acceptance"
  mkdir -p "$scratch"
  work="$(acceptance_guest_work_dir "$scratch")" || fail 'could not prepare canonical acceptance scratch.'
  progress=''
  receipt="$work/receipt"
  : >"$receipt"
  trap 'cat "$receipt"; [[ -z "${rootless_poc_dir:-}" ]] || rm -rf -- "$rootless_poc_dir"; rm -rf -- "$work"' EXIT
fi

if [[ "$phase" == --rootless-archive-roundtrip ]]; then
  rootless_archive_roundtrip_poc
  exit $?
fi

step() {
  local label="$1" limit="$2" description
  shift 2
  case "$label" in
    backend-install) description='backend installer --yes --enable-container-userns' ;;
    fresh-idle|after-reboot-idle|explicit-start-state|upgrade-*-state|enabled-stopped-state|stopped-state)
      description='systemctl --user is-active and is-enabled localai.service' ;;
    explicit-start) description='localaictl start' ;;
    explicit-stop) description='localaictl stop' ;;
    status) description='localaictl status --elevated' ;;
    backend-logs) description='localaictl logs backend (output discarded)' ;;
    inspect-image) description='podman image inspect CPU image digest' ;;
    container-running) description='podman inspect managed container running state' ;;
    doctor) description='localaictl doctor (HTTP 200 or 401)' ;;
    first-admin-bootstrap) description='VM first administrator and guarded socket ordering' ;;
    rootless-archive-roundtrip) description='podman unshare tar round trip for setgid ownership, xattrs, and SELinux labels' ;;
    create-unrelated-container) description='podman create unrelated test container' ;;
    upgrade-disabled-running|upgrade-enabled-running|upgrade-enabled-stopped|upgrade-disabled-stopped)
      description='backend installer --yes --no-pull' ;;
    enable-boot) description='systemctl --user enable localai.service' ;;
    disable-boot) description='systemctl --user disable localai.service' ;;
    preserve-config) description='compare installed config with pre-upgrade copy' ;;
    preserve-data|uninstall-preserves-data) description='check persistent test marker' ;;
    backup-restore-backup) description='localaictl backup with root-owned config and persistent marker' ;;
    backup-restore-restore) description='localaictl restore and verify config/SELinux and data markers' ;;
    conservative-uninstall) description='backend uninstaller --yes' ;;
    uninstall-preserves-unrelated-container) description='podman inspect unrelated test container ownership label' ;;
    *) fail 'unknown acceptance step.' ;;
  esac
  printf 'command %s: %s\n' "$label" "$description" >>"$receipt"
  printf 'waiting %s: timeout %ss\n' "$label" "$limit" >>"$receipt"
  if [[ "$mode" == host && -f "$progress/$label" && ! -L "$progress/$label" ]]; then
    printf 'step %s: pass (earlier attempt)\n' "$label" >>"$receipt"
    return 0
  fi
  localai_acceptance_step "$label" "$limit" "$receipt" "$@" || return 1
  if [[ "$mode" == host ]]; then
    printf 'pass\n' >"$progress/$label.tmp"
    mv -f -- "$progress/$label.tmp" "$progress/$label"
  fi
}
check() {
  local label="$1" active enabled detail status=0 category
  if step "$label" 30 "$0" --check-unit "$2" "$3"; then return 0; fi
  active="$(service_systemctl is-active localai.service 2>/dev/null || :)"
  enabled="$(service_systemctl is-enabled localai.service 2>/dev/null || :)"
  case "$active" in active|inactive|failed|activating|deactivating) ;; *) active=unknown ;; esac
  case "$enabled" in enabled|disabled|static|masked|indirect|generated|transient) ;; *) enabled=unknown ;; esac
  printf 'diagnostic %s-active: %s\ndiagnostic %s-enabled: %s\n' "$label" "$active" "$label" "$enabled" >>"$receipt"
  if [[ "$enabled" == unknown ]]; then
    detail="$(service_systemctl is-enabled localai.service 2>&1)" || status=$?
    case "$detail" in
      *'not found'*|*'No such file'*) category=unit-not-found ;;
      *'Permission denied'*|*'Access denied'*) category=access-denied ;;
      *'Failed to connect'*|*'Failed to open bus'*) category=bus-unavailable ;;
      *disabled*) category=disabled-with-extra-output ;;
      '') category=empty-output ;;
      *) category=other ;;
    esac
    printf 'diagnostic %s-enabled-query: %s exit-%s\n' "$label" "$category" "$status" >>"$receipt"
    if [[ -f /var/lib/localai/.config/systemd/user/localai.service ]]; then
      printf 'diagnostic %s-unit-file: present\n' "$label" >>"$receipt"
    else
      printf 'diagnostic %s-unit-file: absent\n' "$label" >>"$receipt"
    fi
    if service_systemctl show-environment 2>/dev/null | awk -F= '$1 == "HOME" && $2 == "/var/lib/localai" {ok=1} END {exit !ok}'; then
      printf 'diagnostic %s-manager-home: expected\n' "$label" >>"$receipt"
    else
      printf 'diagnostic %s-manager-home: unexpected-or-unavailable\n' "$label" >>"$receipt"
    fi
    detail="$(service_systemctl show -p LoadState --value localai.service 2>/dev/null || :)"
    case "$detail" in loaded|not-found|error|masked|bad-setting) ;; *) detail=unknown ;; esac
    printf 'diagnostic %s-unit-load: %s\n' "$label" "$detail" >>"$receipt"
    if service_systemctl cat localai.service >/dev/null 2>&1; then
      printf 'diagnostic %s-unit-readable: yes\n' "$label" >>"$receipt"
    else
      printf 'diagnostic %s-unit-readable: no\n' "$label" >>"$receipt"
    fi
  fi
  return 1
}

restore_acceptance_step() {
  local archive="$1" status=0 reason=other output=''
  printf 'command backup-restore-restore: localaictl restore and verify config/SELinux and data markers\n' >>"$receipt"
  printf 'waiting backup-restore-restore: timeout 1800s\n' >>"$receipt"
  if output="$(LOCALAI_ACCEPTANCE_DIAGNOSTIC=1 timeout --kill-after=10s 1800s "$controller" restore --yes "$archive" 2>&1)"; then
    printf 'step backup-restore-restore: pass\n' >>"$receipt"
    return 0
  else
    status=$?
  fi
  case "$output" in
    *"backup or restore is already running"*) reason=lock-contention ;;
    *"a previous backup restore is incomplete"*) reason=restore-pending ;;
    *"restore staging must be on a disk-backed filesystem"*) reason=staging-filesystem ;;
    *"insufficient disk space"*) reason=capacity ;;
    *"could not safely copy restore archive"*) reason=archive-copy ;;
    *"backup contains unsupported or unsafe filesystem entries"*) reason=archive-validation ;;
    *"could not extract backup into private staging"*) reason=archive-extraction ;;
    *"restore paths are unsafe"*) reason=destination-validation ;;
    *"backup rootless graphroot status could not be verified"*|*"backup rootless graphroot archive was not staged safely"*) reason=rootless-archive ;;
    *"rootless graphroot changed while services stopped"*|*"backup contents or LocalAI storage settings changed while services stopped"*) reason=storage-changed ;;
    *"could not prepare rollback snapshot"*) reason=rollback-snapshot ;;
    *"could not create the durable restore safety marker"*) reason=restore-marker ;;
    *"rootless graphroot extraction failed"*) reason=rootless-extraction ;;
    *"SELinux label"*|*"SELinux labels"*) reason=selinux-label ;;
    *"restore failed"*) reason=restore-copy ;;
    *"could not durably flush restored data"*) reason=sync ;;
    *"rollback was incomplete"*|*"could not safely remove the partially restored rootless graphroot"*|*"could not restore the previous rootless graphroot"*) reason=rollback-incomplete ;;
    *"restore completed but the durable safety marker could not be cleared"*) reason=restore-marker-clear ;;
    *"restore completed but one or more previously active services could not be restarted"*) reason=service-restart ;;
    *"cannot verify"*|*"Failed to start transient service unit"*|*"Connection reset by peer"*|*"Transport endpoint is not connected"*) reason=service-manager ;;
    "") reason=empty-error ;;
    *) reason=other ;;
  esac
  if [[ "$status" == 124 ]]; then
    printf 'step backup-restore-restore: timeout\n' >>"$receipt"
  else
    printf 'step backup-restore-restore: fail\n' >>"$receipt"
  fi
  printf 'diagnostic backup-restore-restore-reason: %s\n' "$reason" >>"$receipt"
  if [[ "$output" =~ diagnostic-controller-site:([0-9]{1,6}) ]]; then
    printf 'diagnostic backup-restore-restore-controller-site: %s\n' "${BASH_REMATCH[1]}" >>"$receipt"
  fi
  if [[ "$output" =~ diagnostic-helper-site:([0-9]{1,6}) ]]; then
    printf 'diagnostic backup-restore-restore-helper-site: %s\n' "${BASH_REMATCH[1]}" >>"$receipt"
  fi
  return 1
}

backup_acceptance_step() {
  local destination="$1" result_label="${2:-backup-restore-backup}" status=0 reason=other output=''
  ROOTLESS_TAR_ACCEPTANCE_MARKER=0
  printf 'command %s: localaictl backup with root-owned config and persistent marker\n' "$result_label" >>"$receipt"
  printf 'waiting %s: timeout 1800s\n' "$result_label" >>"$receipt"
  if output="$(LOCALAI_ACCEPTANCE_DIAGNOSTIC=1 timeout --kill-after=10s 1800s "$controller" backup "$destination" 2>&1)"; then
    printf 'step %s: pass\n' "$result_label" >>"$receipt"
  else
    status=$?
    case "$output" in
      *"diagnostic-rootless-tar-failure: source-open-permission"*) reason=rootless-tar-source-open-permission ;;
      *"diagnostic-rootless-tar-failure: source-read-permission"*) reason=rootless-tar-source-read-permission ;;
      *"diagnostic-rootless-tar-failure: xattr-read-permission"*) reason=rootless-tar-xattr-read-permission ;;
      *"diagnostic-rootless-tar-failure: xattr-write-permission"*) reason=rootless-tar-xattr-write-permission ;;
      *"diagnostic-rootless-tar-failure: acl-read-permission"*) reason=rootless-tar-acl-read-permission ;;
      *"diagnostic-rootless-tar-failure: acl-write-permission"*) reason=rootless-tar-acl-write-permission ;;
      *"diagnostic-rootless-tar-failure: source-stat-permission"*) reason=rootless-tar-source-stat-permission ;;
      *"diagnostic-rootless-tar-failure: ownership-permission"*) reason=rootless-tar-ownership-permission ;;
      *"diagnostic-rootless-tar-failure: permission"*) reason=rootless-tar-permission ;;
      *"diagnostic-rootless-tar-failure: capacity"*) reason=rootless-tar-capacity ;;
      *"diagnostic-rootless-tar-failure: source-changed"*) reason=rootless-tar-source-changed ;;
      *"diagnostic-rootless-tar-failure: unsupported-option"*) reason=rootless-tar-unsupported-option ;;
      *"diagnostic-rootless-tar-failure: source-path"*) reason=rootless-tar-source-path ;;
      *"diagnostic-rootless-tar-failure: operation-not-permitted"*) reason=rootless-tar-operation-not-permitted ;;
      *"diagnostic-rootless-tar-failure: service-manager"*) reason=rootless-tar-service-manager ;;
      *"diagnostic-rootless-tar-failure: xattr"*) reason=rootless-tar-xattr ;;
      *"diagnostic-rootless-tar-failure: empty-error"*) reason=rootless-tar-empty-error ;;
      *"diagnostic-rootless-tar-failure: other"*) reason=rootless-tar-other ;;
      *"could not stop "*|*"could not verify that "*|*"cannot determine a stable "*" service state"*) reason=service-stop ;;
      *"not verifiably managed"*|*"unit is not owned"*|*"unit owner"*|*"service unit is not"*) reason=unit-ownership ;;
      *"insufficient free disk space"*|*"No space left on device"*|*"quota exceeded"*) reason=capacity ;;
      *"backup destination parent must not contain symbolic links or traversal components"*) reason='destination-parent-unsafe' ;;
      *"backup destination already exists"*) reason='destination-exists' ;;
      *"backup destination directory does not exist"*) reason='destination-directory' ;;
      *"backup destination must be outside the configuration and persistent data paths"*) reason='destination-overlap' ;;
      *"configured backup paths must be distinct absolute paths"*) reason=configured-paths ;;
      *"backup must be a regular non-linked file"*) reason=archive-file-type ;;
      *"backup contains an unsafe member name"*) reason=unsafe-name ;;
      *"backup contains a traversal path"*) reason=traversal-path ;;
      *"backup contains duplicate member names"*) reason=duplicate-member ;;
      *"backup contains a symbolic link crossing configured persistent paths"*) reason=link-cross-root ;;
      *"backup contains a symbolic link escaping its archived tree"*) reason=link-escape ;;
      *"backup contains an invalid hard link"*) reason=hardlink ;;
      *"backup contains system manager unit configuration"*) reason=system-manager-tree ;;
      *"backup contains a path outside configured LocalAI paths"*) reason='path-outside-roots' ;;
      *"backup contains an unsupported special file"*) reason=special-member ;;
      *"backup contains a member nested below a non-directory entry"*) reason=nested-member ;;
      *"backup contains setuid or setgid permission bits"*) reason=privileged-mode ;;
      *"backup contains a file capability xattr"*) reason='file-capability' ;;
      *"backup configuration member must be"*) reason=config-member ;;
      *"configured persistent path must be archived as a directory"*) reason=persistent-root-type ;;
      *"backup metadata is missing"*) reason=missing-metadata ;;
      *"cannot read backup archive"*) reason=archive-read ;;
      *"cannot read configured TLS Compose tree from backup"*) reason=compose-archive-read ;;
      *"backup TLS Compose tree root differs from the installed tree"*) reason=compose-root-mismatch ;;
      *"backup TLS Compose tree entries differ from the installed tree"*) reason=compose-entry-mismatch ;;
      *"backup TLS Compose tree metadata differs from the installed tree"*) reason=compose-metadata-mismatch ;;
      *"backup TLS Compose file differs from the installed tree"*) reason=compose-file-mismatch ;;
      *"backup TLS Compose tree xattrs differ from the installed tree"*) reason=compose-xattrs-mismatch ;;
      *"staged TLS Compose tree xattrs differ from the installed tree"*) reason=compose-staged-xattrs-mismatch ;;
      *"configured TLS Compose tree path is invalid"*) reason=compose-path-invalid ;;
      *"backup weakens metadata on an installed persistent root"*) reason=persistent-root-metadata ;;
      *"backup unit path is outside configured persistent roots"*) reason=unit-path-outside-roots ;;
      *"backup omits directory metadata for the installed user service unit tree"*) reason=unit-ancestor-metadata-missing ;;
      *"backup weakens metadata on an installed user service unit ancestor"*) reason=unit-ancestor-metadata-weakened ;;
      *"backup omits an installed user service unit tree"*) reason=unit-tree-omitted ;;
      *"backup has a user unit absent from the installed tree"*) reason=unit-tree-extra-entry ;;
      *"backup user unit entry type differs from the installed tree"*) reason=unit-tree-type-mismatch ;;
      *"backup user unit file differs from the installed tree"*) reason=unit-tree-file-mismatch ;;
      *"backup user unit link differs from the installed tree"*) reason=unit-tree-link-mismatch ;;
      *"backup contains an unsupported user service unit link"*) reason=unit-tree-unsupported-link ;;
      *"backup user unit tree is absent from the installed tree"*) reason=unit-tree-unexpected ;;
      *"backup user unit tree entries differ"*) reason=unit-tree-entries-differ ;;
      *"cannot verify the installed user service unit tree ("*) reason=unit-tree-check-exception ;;
      *"backup contains unsafe or changed systemd unit configuration"*) reason=unit-tree-validation ;;
      *"backup contains an unsafe symbolic link"*) reason=symlink ;;
      *"archive creation failed"*|*"tar: "*|*"Unexpected EOF"*|*"Write error"*) reason=tar ;;
      *"already running"*) reason=lock-contention ;;
      *"configuration file must"*) reason=config-guard ;;
      *"shared backup archive helper is missing"*|*"command not found"*|*"No such file or directory"*|*"could not invoke"*) reason=helper-invocation ;;
      *"backup completed but one or more previously active services could not be restarted"*) reason=service-restart ;;
      *"cannot verify the LocalAI service account"*|*"cannot verify rootless"*|*"rootless service account does not exist"*) reason=rootless-context ;;
      *"service-home ancestry has unexpected ownership"*) reason='graphroot-ancestor-owner' ;;
      *"service-home ancestry is publicly traversable"*) reason='graphroot-ancestor-mode' ;;
      *"service-home ancestry has special permission bits"*) reason='graphroot-ancestor-special' ;;
      *"subordinate ID"*|*"user namespace mapping"*|*"rootless namespace"*) reason=rootless-mapping ;;
      *"rootless archive"*|*"rootless graphroot archive"*|*"rootless graphroot extraction"*) reason=rootless-archive ;;
      *"backup metadata"*) reason=archive-metadata ;;
      *"Traceback"*|*"TypeError"*|*"ValueError"*|*"PermissionError"*|*"AttributeError"*|*"FileNotFoundError"*|*"FileExistsError"*|*"NotADirectoryError"*|*"IsADirectoryError"*|*"OverflowError"*|*"UnicodeDecodeError"*|*"KeyError"*|*"IndexError"*|*"RuntimeError"*|*"MemoryError"*|*"AssertionError"*|*"ImportError"*|*"ModuleNotFoundError"*) reason=helper-exception ;;
      *"unsupported or unsafe filesystem entries"*|*"backup contains an unsafe"*|*"backup contains unsupported"*|*"symbolic link"*|*"file capability"*|*"setuid or setgid"*) reason=helper-validation ;;
      "") reason=helper-no-diagnostic ;;
      *) reason=helper-unclassified ;;
    esac
    printf 'step %s: %s\n' "$result_label" "$([[ "$status" == 124 ]] && printf timeout || printf fail)" >>"$receipt"
    printf 'diagnostic %s-reason: %s\n' "$result_label" "$reason" >>"$receipt"
    if [[ "$output" =~ diagnostic-rootless-tar-member:\ (member-acceptance-marker-owner-(service|subuid|host-root|other)-mode-([0-7]{4})-persistence-fixture|member-(regular|directory|symlink|special)-owner-(service|subuid|host-root|other)-mode-([0-7]{4})-path-(other-root-entry|other-root-subtree)|member-unidentified|member-outside-graphroot|member-metadata-unavailable|member-path-unsafe) ]]; then
      printf 'diagnostic %s-member: %s\n' "$result_label" "${BASH_REMATCH[1]}" >>"$receipt"
      if [[ "${BASH_REMATCH[1]}" == member-acceptance-marker-owner-host-root-mode-0600-persistence-fixture ]]; then
        ROOTLESS_TAR_ACCEPTANCE_MARKER=1
      fi
    fi
    if [[ "$output" =~ diagnostic-controller-site:([0-9]{1,6}) ]]; then
      printf 'diagnostic backup-restore-controller-site: %s\n' "${BASH_REMATCH[1]}" >>"$receipt"
    fi
    if [[ "$output" =~ diagnostic-helper-site:([0-9]{1,6}) ]]; then
      printf 'diagnostic backup-restore-helper-site: %s\n' "${BASH_REMATCH[1]}" >>"$receipt"
    fi
    if [[ "$output" =~ diagnostic-graphroot-ancestor-mode:depth-([0-9]{1,2}):mode-([0-7]{4}) ]]; then
      printf 'diagnostic backup-restore-graphroot-ancestor-mode: depth-%s mode-%s\n' \
        "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" >>"$receipt"
    fi
  fi
  unset output
  return "$status"
}

retry_backup_with_acceptance_marker_owner() {
  local marker_path marker_root service_user service_uid service_gid graphroot backup_path
  # shellcheck disable=SC1091
  source "$repo_root/lib/config.sh"
  localai_config_load_compat /etc/localai/localai.conf "$repo_root/localai/localai.lock" >/dev/null || {
    printf 'diagnostic acceptance-marker-owner-retry: config-unavailable\n' >>"$receipt"
    return 1
  }
  service_user="$LOCALAI_SERVICE_USER"
  service_uid="$(id -u "$service_user" 2>/dev/null)" || return 1
  service_gid="$(id -g "$service_user" 2>/dev/null)" || return 1
  marker_path="$LOCALAI_STATE_DIR/.local/share/containers/storage/.localaictl-backup-restore-marker"
  marker_root="${marker_path%/.localaictl-backup-restore-marker}"
  graphroot="$(service_podman info --format '{{.Store.GraphRoot}}' 2>/dev/null)" || {
    printf 'diagnostic acceptance-marker-owner-retry: graphroot-unavailable\n' >>"$receipt"
    return 1
  }
  [[ "$graphroot" == "$marker_root" && "$(realpath -m -- "$graphroot")" == "$graphroot" ]] || {
    printf 'diagnostic acceptance-marker-owner-retry: graphroot-mismatch\n' >>"$receipt"
    return 1
  }
  [[ -f "$marker_path" && ! -L "$marker_path" && "$(stat -c '%u:%a' -- "$marker_path" 2>/dev/null)" == 0:600 ]] || {
    printf 'diagnostic acceptance-marker-owner-retry: marker-metadata-mismatch\n' >>"$receipt"
    return 1
  }
  matchpathcon -V "$marker_path" >/dev/null 2>&1 || {
    printf 'diagnostic acceptance-marker-owner-retry: marker-label-mismatch\n' >>"$receipt"
    return 1
  }
  printf 'diagnostic acceptance-marker-owner-before: root-mode-0600\n' >>"$receipt"
  chown -- "$service_uid:$service_gid" "$marker_path" 2>/dev/null || {
    printf 'diagnostic acceptance-marker-owner-retry: chown-failed\n' >>"$receipt"
    return 1
  }
  [[ "$(stat -c '%u:%g:%a' -- "$marker_path" 2>/dev/null)" == "$service_uid:$service_gid:600" ]] || {
    printf 'diagnostic acceptance-marker-owner-retry: chown-verification-failed\n' >>"$receipt"
    return 1
  }
  matchpathcon -V "$marker_path" >/dev/null 2>&1 || {
    printf 'diagnostic acceptance-marker-owner-retry: relabel-required\n' >>"$receipt"
    return 1
  }
  printf 'diagnostic acceptance-marker-owner-after: service-mode-0600\n' >>"$receipt"
  backup_path="$work/diagnostic-backup-after-marker-owner.tar.gz"
  backup_acceptance_step "$backup_path" backup-restore-backup-after-marker-owner
}

backup_restore_roundtrip() {
  local test_work="$1" config_path="$2" backup_path
  backup_path="$test_work/backup-restore.tar.gz"
  local config_copy="$test_work/backup-restore-config.before" marker_path graph_marker marker_value graph_value config_stat marker_stat graph_stat config_mode
  local path existing covered bytes source_bytes=0 needed available graph_service_user graph_service_uid graph_service_gid graphroot
  local -a configured_paths backup_roots=()
  # shellcheck disable=SC1091
  source "$repo_root/lib/config.sh"
  localai_config_load_compat "$config_path" "$repo_root/localai/localai.lock" || fail 'cannot load configured persistent paths for backup acceptance.'
  [[ -f "$config_path" && ! -L "$config_path" && "$(realpath -m -- "$config_path")" == "$config_path" ]] || fail 'acceptance config path is not a regular canonical file.'
  config_stat="$(stat -c '%u:%a' -- "$config_path")"
  [[ "${config_stat%%:*}" == 0 ]] || fail 'acceptance config is not root-owned.'
  config_mode="${config_stat#*:}"
  (( (8#$config_mode & 8#22) == 0 )) || fail 'acceptance config is group/world writable.'
  matchpathcon -V "$config_path" >/dev/null 2>&1 || fail 'acceptance config SELinux label does not match policy.'
  [[ "$LOCALAI_DATA_PATH" == /* && "$(realpath -m -- "$LOCALAI_DATA_PATH")" == "$LOCALAI_DATA_PATH" ]] || fail 'acceptance data path is not canonical.'
  configured_paths=(
    "$LOCALAI_STATE_DIR" "$LOCALAI_MODELS_PATH" "$LOCALAI_BACKENDS_PATH"
    "$LOCALAI_DOWNLOAD_STAGING_PATH" "$LOCALAI_BACKEND_TEMP_DIR" "$LOCALAI_DATA_PATH"
    "$LOCALAI_CONFIG_DIR" "$LOCALAI_GENERATED_CONTENT_PATH" "$LOCALAI_UPLOAD_PATH"
    "$LOCALAI_CACHE_DIR" "$LOCALAI_LOG_DIR" "$LOCALAI_TLS_STATE_DIR"
    "$LOCALAI_TLS_CONFIG_DIR" "$LOCALAI_TLS_CACHE_DIR" "$LOCALAI_TLS_CERT_DIR"
    "$LOCALAI_TLS_COMPOSE_DIR"
  )
  while IFS= read -r path; do
    covered=0
    for existing in "${backup_roots[@]}"; do
      if [[ "$path" == "$existing" || "$path" == "$existing"/* ]]; then covered=1; break; fi
    done
    [[ "$covered" == 1 ]] || backup_roots+=("$path")
  done < <(printf '%s\0' "${configured_paths[@]}" | /usr/bin/python3 -c 'import sys; p=[x for x in sys.stdin.buffer.read().split(b"\0") if x]; [sys.stdout.buffer.write(x+b"\0") for x in sorted(p,key=lambda x:(len(x),x))]' | while IFS= read -r -d '' path; do printf '%s\n' "$path"; done)
  for path in "${backup_roots[@]}"; do
    [[ ! -e "$path" ]] && continue
    bytes="$(du -s -B1 --apparent-size -- "$path" 2>/dev/null | awk '{print $1}')" || fail 'cannot estimate configured data size for acceptance.'
    [[ "$bytes" =~ ^[0-9]+$ ]] || fail 'cannot estimate configured data size for acceptance.'
    source_bytes=$((source_bytes + bytes))
  done
  needed=$((source_bytes * 4 + 268435456))
  for path in "$test_work" /var/lib; do
    available="$(df -B1 --output=avail -- "$path" 2>/dev/null | tail -n 1)" || fail 'cannot check free disk space for acceptance.'
    if [[ ! "$available" =~ ^[0-9]+$ ]] || (( available < needed )); then
      fail 'insufficient disk space for the backup and restore acceptance run.'
    fi
  done
  mkdir -p -- "$LOCALAI_DATA_PATH"
  marker_path="$LOCALAI_DATA_PATH/.localaictl-backup-restore-marker"
  graph_marker="$LOCALAI_STATE_DIR/.local/share/containers/storage/.localaictl-backup-restore-marker"
  [[ ! -e "$marker_path" && ! -L "$marker_path" ]] || fail 'backup acceptance marker already exists.'
  [[ ! -e "$graph_marker" && ! -L "$graph_marker" ]] || fail 'graph storage acceptance marker already exists.'
  if grep -Fq '# localai backup restore acceptance marker' "$config_path"; then
    fail 'backup acceptance config marker already exists.'
  fi
  cp -a -- "$config_path" "$config_copy" || fail 'cannot save acceptance config metadata.'
  marker_value='localai backup restore acceptance marker'
  graph_service_user="$LOCALAI_SERVICE_USER"
  graph_service_uid="$(id -u "$graph_service_user")" || fail 'cannot identify graph storage service owner.'
  graph_service_gid="$(id -g "$graph_service_user")" || fail 'cannot identify graph storage service group.'
  create_service_marker() {
    local value="$1" path="$2" description="$3" owner
    (umask 077; printf '%s\n' "$value" >"$path") || fail "cannot create $description acceptance marker."
    chmod 0600 -- "$path" || fail "cannot protect $description acceptance marker."
    owner="$(stat -c '%u:%g' -- "$path")"
    if [[ "$owner" != "$graph_service_uid:$graph_service_gid" ]]; then
      chown -- "$graph_service_uid:$graph_service_gid" "$path" || fail "cannot set $description acceptance marker ownership."
    fi
    restorecon -F -- "$path" >/dev/null 2>&1 || fail "cannot label $description acceptance marker."
    matchpathcon -V "$path" >/dev/null 2>&1 || fail "$description acceptance marker label does not match policy."
    [[ "$(stat -c '%u:%g:%a' -- "$path")" == "$graph_service_uid:$graph_service_gid:600" ]] ||
      fail "$description acceptance marker owner or mode is incorrect."
  }
  create_service_marker "$marker_value" "$marker_path" 'persistent data'
  marker_stat="$(stat -c '%u:%g:%a' -- "$marker_path")"
  graphroot="$(service_podman_graphroot)" || fail 'cannot identify configured graph storage root.'
  [[ "$graphroot" == "${graph_marker%/*}" && "$(realpath -e -- "$graphroot")" == "$graphroot" && -d "$graphroot" && ! -L "$graphroot" ]] || fail 'graph storage acceptance marker is outside the configured graph root.'
  graph_value='localai graph storage backup restore acceptance marker'
  create_service_marker "$graph_value" "$graph_marker" 'graph storage'
  graph_stat="$(stat -c '%u:%g:%a' -- "$graph_marker")"
  printf '# localai backup restore acceptance marker\n' >>"$config_path"
  check_unit active disabled || fail 'backend was not active before backup acceptance.'
  backup_acceptance_step "$backup_path" || fail 'backup acceptance command failed.'
  [[ -f "$backup_path" && ! -L "$backup_path" && "$(stat -c '%a' -- "$backup_path")" == 600 ]] || fail 'backup archive is not a private regular file.'
  printf 'damaged marker\n' >"$marker_path"
  printf 'damaged graph marker\n' >"$graph_marker"
  printf '# damaged backup restore acceptance marker\n' >>"$config_path"
  restore_acceptance_step "$backup_path" || fail 'restore acceptance command failed.'
  check_unit active disabled || fail 'restore did not return the backend to its previous active state.'
  [[ "$(<"$marker_path")" == "$marker_value" && "$(stat -c '%u:%g:%a' -- "$marker_path")" == "$marker_stat" ]] || fail 'persistent data marker was not restored with its ownership and mode.'
  matchpathcon -V "$marker_path" >/dev/null 2>&1 || fail 'persistent data marker SELinux label does not match policy.'
  [[ "$(<"$graph_marker")" == "$graph_value" && "$(stat -c '%u:%g:%a' -- "$graph_marker")" == "$graph_stat" ]] || fail 'Podman graph storage marker was not restored with its ownership and mode.'
  matchpathcon -V "$graph_marker" >/dev/null 2>&1 || fail 'Podman graph storage marker SELinux label does not match policy.'
  grep -Fqx '# localai backup restore acceptance marker' "$config_path" || fail 'configuration marker was not restored.'
  if grep -Fq '# damaged backup restore acceptance marker' "$config_path"; then
    fail 'damaged configuration marker survived restore.'
  fi
  [[ "$(stat -c '%u:%a' -- "$config_path")" == "$config_stat" ]] || fail 'restored config ownership or mode changed.'
  matchpathcon -V "$config_path" >/dev/null 2>&1 || fail 'restored config SELinux label does not match policy.'
  cp -a -- "$config_copy" "$config_path" || fail 'cannot restore acceptance config after the round trip.'
  rm -f -- "$marker_path"
  rm -f -- "$graph_marker"
  matchpathcon -V "$config_path" >/dev/null 2>&1 || fail 'acceptance config label changed during cleanup.'
}

upgrade_step() {
  local label="$1" stage
  local trace="$work/installer-trace" stages="$work/installer-stages"
  cat >"$trace" <<'TRACE'
set -T
trap 'case "$BASH_COMMAND" in ensure_service_user) printf "service-user\n";; ensure_subids) printf "subids\n";; install_project_files) printf "project-files\n";; install_container_policy) printf "policy\n";; install_bootstrap_guard) printf "bootstrap-guard\n";; label_container_state) printf "labels\n";; preflight_existing_backend_state) printf "backend-preflight\n";; preflight_user_systemd_parent) printf "unit-preflight\n";; ensure_user_manager) printf "manager\n";; snapshot_existing_service_state) printf "snapshot\n";; stop_existing_managed_service) printf "stop\n";; remove_preflighted_existing_container) printf "remove\n";; ensure_container_userns) printf "userns\n";; install_systemd_service) printf "unit\n";; localai_installer_error*"writable-layer data"*) printf "writable-layer-data\n";; localai_installer_error*"writable-layer changes"*) printf "writable-layer-inspection\n";; localai_installer_error*"mount metadata"*) printf "mount-metadata\n";; localai_installer_error*"ownership labels"*) printf "ownership-inspection\n";; localai_installer_error*"not marked for LocalAI"*) printf "ownership-mismatch\n";; localai_installer_error*"multiple /backends mounts"*) printf "multiple-backend-mounts\n";; localai_installer_error*"stores backends at"*) printf "backend-mount-mismatch\n";; localai_installer_error*"data in anonymous or named"*) printf "backend-volume-data\n";; localai_installer_error\ *) printf "safety-refusal\n";; die\ *) printf "installer-refusal\n";; esac >> "$LOCALAI_ACCEPTANCE_STAGE_FILE"' DEBUG
TRACE
  : >"$stages"
  if ! step "$label" 1200 env BASH_ENV="$trace" LOCALAI_ACCEPTANCE_STAGE_FILE="$stages" LOCALAI_IMAGE_REF_OVERRIDE="$cpu_image" bash "$installer" --yes --no-pull; then
    while IFS= read -r stage; do
      case "$stage" in service-user|subids|project-files|policy|bootstrap-guard|labels|backend-preflight|unit-preflight|manager|snapshot|stop|remove|userns|unit|writable-layer-data|writable-layer-inspection|mount-metadata|ownership-inspection|ownership-mismatch|multiple-backend-mounts|backend-mount-mismatch|backend-volume-data|safety-refusal|installer-refusal)
        printf 'diagnostic upgrade-stage: %s\n' "$stage" >>"$receipt" ;;
      esac
    done < <(tail -n 8 "$stages")
    return 1
  fi
}
installer="$repo_root/secureblue-localai-install/install.sh"
controller="$repo_root/bin/localaictl"

if [[ "$phase" == diagnose-backup ]]; then
  if backup_acceptance_step "$work/diagnostic-backup.tar.gz"; then
    exit 0
  fi
  [[ "$ROOTLESS_TAR_ACCEPTANCE_MARKER" == 1 ]] || exit 1
  retry_backup_with_acceptance_marker_owner || exit 1
  exit 0
fi

if [[ "$phase" == install ]]; then
  ensure_initial_isolation
  os_id="$(awk -F= '$1 == "ID" {gsub(/"/, "", $2); print $2}' /etc/os-release)"
  os_version="$(awk -F= '$1 == "VERSION_ID" {gsub(/"/, "", $2); print $2}' /etc/os-release)"
  image_id="$(awk -F= '$1 == "IMAGE_ID" {gsub(/"/, "", $2); print $2}' /etc/os-release)"
  kernel="$(uname -r)"
  deployment="$(timeout 30s rpm-ostree status --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(x.get("checksum", "") for x in d["deployments"] if x.get("booted")))')"
  [[ "$deployment" =~ ^[a-f0-9]{64}$ ]] || fail 'cannot safely report the OS deployment checksum.'
  podman_version="$(timeout 15 podman --version | awk '{print $3}')"
  systemd_version="$(timeout 15 systemctl --version | awk 'NR == 1 {print $2}')"
  for value in "$os_id" "$os_version" "$image_id" "$kernel" "$podman_version" "$systemd_version"; do
    [[ "$value" =~ ^[A-Za-z0-9._+-]+$ ]] || fail 'cannot safely report software versions.'
  done
  [[ "$os_id" == secureblue ]] || fail 'acceptance requires secureblue.'
  {
    evidence_mode="$mode"
    if [[ "$mode" == host ]]; then
      evidence_mode="$(evidence_mode_for_host)" || fail 'could not determine host virtualization state.'
    fi
    printf 'mode: %s\nscope: backend only; TLS not exercised\nos: %s %s %s\nos-deployment: %s\nkernel: %s\npodman: %s\nsystemd: %s\nimage: %s\n' \
      "$evidence_mode" "$os_id" "$os_version" "$image_id" "$deployment" "$kernel" "$podman_version" "$systemd_version" "$cpu_image"
    printf 'security: SELinux enforcing; container-domain user namespaces requested\n'
    if [[ "$mode" == vm ]]; then
      printf 'guest-setup: SSH enabled for isolated test access\n'
      if [[ "$(systemctl is-enabled upgrade-on-boot.service 2>/dev/null || :)" == masked ]]; then
        printf 'guest-policy: automatic boot-time OS update masked in test image\n'
      fi
      if command -v firewall-cmd >/dev/null && firewall-cmd --quiet --query-service=ssh >/dev/null 2>&1; then
        printf 'guest-policy: guest firewall permits SSH for test access\n'
      fi
      if systemctl is-active --quiet localai-acceptance-ssh.service; then
        printf 'guest-policy: test service restores guest SSH firewall rule after cleanup\n'
      fi
    fi
  } >>"$receipt"
  mkdir -p "$work/policy-bin"
  ln -sf -- "$repo_root/scripts/acceptance-policy.sh" "$work/policy-bin/ujust"
  ln -sf -- "$repo_root/scripts/acceptance-policy.sh" "$work/policy-bin/semodule"
  if ! step backend-install 1200 env LOCALAI_IMAGE_REF_OVERRIDE="$cpu_image" \
    LOCALAI_ACCEPTANCE_RECEIPT="$receipt" PATH="$work/policy-bin:$PATH" \
    bash "$installer" --yes --enable-container-userns; then
    # Repeat read-only validation without retaining its potentially sensitive output.
    # shellcheck disable=SC1091
    source "$repo_root/lib/config.sh"
    # shellcheck disable=SC1091
    source "$repo_root/lib/installer_safety.sh"
    if localai_installer_select_config /etc/localai/localai.conf '' /etc/localai.conf "$repo_root/config/localai.conf" "$repo_root/localai/localai.lock" >/dev/null 2>&1 &&
       localai_installer_load_config "$LOCALAI_INSTALLER_CONFIG_SOURCE" "$LOCALAI_INSTALLER_CONFIG_FORMAT" >/dev/null 2>&1; then
      printf 'diagnostic config-validation: pass\n' >>"$receipt"
      if localai_installer_validate_managed_path "$LOCALAI_STATE_DIR" state >/dev/null 2>&1; then
        printf 'diagnostic state-path-validation: pass\n' >>"$receipt"
      else
        printf 'diagnostic state-path-validation: fail\n' >>"$receipt"
      fi
    else
      printf 'diagnostic config-validation: fail\n' >>"$receipt"
    fi
    for asset in localai/localai.lock localai/localai-containers-policy.json secureblue-localai-install/localai.service.in; do
      if [[ ! -f "$repo_root/$asset" ]]; then
        printf 'diagnostic required-asset: missing\n' >>"$receipt"
      fi
    done
    if [[ -d /etc/localai ]]; then
      printf 'diagnostic config-directory: present\n' >>"$receipt"
    else
      printf 'diagnostic config-directory: absent\n' >>"$receipt"
    fi
    if localai_installer_validate_managed_path "$LOCALAI_STATE_DIR/build/localai-oci" project >/dev/null 2>&1; then
      printf 'diagnostic project-path-validation: pass\n' >>"$receipt"
    else
      printf 'diagnostic project-path-validation: fail\n' >>"$receipt"
    fi
    if getent passwd localai >/dev/null; then
      printf 'diagnostic service-account: present\n' >>"$receipt"
    else
      printf 'diagnostic service-account: absent\n' >>"$receipt"
    fi
    if [[ -f /etc/localai/localai.conf ]]; then
      printf 'diagnostic config: present\n' >>"$receipt"
    else
      printf 'diagnostic config: absent\n' >>"$receipt"
    fi
    if [[ -f /var/lib/localai/.config/systemd/user/localai.service ]]; then
      printf 'diagnostic service-unit: present\n' >>"$receipt"
    else
      printf 'diagnostic service-unit: absent\n' >>"$receipt"
    fi
    exit 1
  fi
  check fresh-idle inactive disabled
else
  check after-reboot-idle inactive disabled
  if [[ "$mode" == vm ]]; then
    step rootless-archive-roundtrip 180 env LOCALAI_ACCEPTANCE_RECEIPT="$receipt" "$0" --rootless-archive-roundtrip
  fi
  step explicit-start 300 "$controller" start
  check explicit-start-state active disabled
  step status 30 "$controller" status --elevated
  step backend-logs 30 "$controller" logs backend
  # The inner shell expands its own positional parameters.
  # shellcheck disable=SC2016
  step inspect-image 60 bash -c '
    systemd-run --user --machine=localai@.host --wait --pipe --collect \
      --setenv=HOME=/var/lib/localai --setenv=PATH=/usr/bin:/bin -- \
      /usr/bin/podman image inspect "$2" --format "{{.Digest}}" > "$1"
  ' bash "$work/image-digest" "$cpu_image"
  digest="$(<"$work/image-digest")"
  [[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]] || fail 'backend image digest was unavailable.'
  printf 'image-digest: %s\n' "$digest" >>"$receipt"
  # The inner shell evaluates the container state returned by Podman.
  # shellcheck disable=SC2016
  step container-running 60 bash -c '
    state=$(systemd-run --user --machine=localai@.host --wait --pipe --collect \
      --setenv=HOME=/var/lib/localai --setenv=PATH=/usr/bin:/bin -- \
      /usr/bin/podman inspect localai --format "{{.State.Running}}")
    [[ "$state" == true ]]
  '
  step doctor 90 "$0" --check-health "$controller"
  if [[ "$mode" == vm ]]; then
    step first-admin-bootstrap 120 env LOCALAI_ACCEPTANCE_RECEIPT="$receipt" bash "$repo_root/scripts/acceptance-bootstrap.sh"
    backup_restore_roundtrip "$work" /etc/localai/localai.conf
  fi
  if [[ ! -e "$work/config-before" && ! -L "$work/config-before" ]]; then
    cp -- /etc/localai/localai.conf "$work/config-before"
  fi
  [[ -f "$work/config-before" && ! -L "$work/config-before" ]] || fail 'baseline config copy is not a regular file.'
  if [[ "$mode" != host || ! -f "$progress/test-marker-created" ]]; then
    if [[ ! -e /var/lib/localai/models/.acceptance-marker && ! -L /var/lib/localai/models/.acceptance-marker ]]; then
      printf 'localai acceptance marker\n' > /var/lib/localai/models/.acceptance-marker
    fi
    [[ -f /var/lib/localai/models/.acceptance-marker && ! -L /var/lib/localai/models/.acceptance-marker ]] || fail 'test-data marker is not a regular file.'
    grep -qx 'localai acceptance marker' /var/lib/localai/models/.acceptance-marker || fail 'test-data marker is not owned by this run.'
    if [[ "$mode" == host ]]; then printf 'created\n' >"$progress/test-marker-created"; fi
  fi
  if [[ ! -e "$work/container-run-id" && ! -L "$work/container-run-id" ]]; then
    id_tmp="$(mktemp "$work/container-run-id.XXXXXX")"
    od -An -N16 -tx1 /dev/urandom | tr -d ' \n' >"$id_tmp"
    mv -- "$id_tmp" "$work/container-run-id"
  fi
  [[ -f "$work/container-run-id" && ! -L "$work/container-run-id" ]] || fail 'test container identity is not a regular file.'
  run_id="$(<"$work/container-run-id")"
  [[ "$run_id" =~ ^[a-f0-9]{32}$ ]] || fail 'test container identity is invalid.'
  step create-unrelated-container 120 "$0" --ensure-unrelated "$run_id"
  upgrade_step upgrade-disabled-running
  check upgrade-disabled-running-state active disabled
  step enable-boot 30 "$0" --set-unit-enabled enable
  upgrade_step upgrade-enabled-running
  check upgrade-enabled-running-state active enabled
  step explicit-stop 300 "$controller" stop
  check enabled-stopped-state inactive enabled
  upgrade_step upgrade-enabled-stopped
  check upgrade-enabled-stopped-state inactive enabled
  step disable-boot 30 "$0" --set-unit-enabled disable
  upgrade_step upgrade-disabled-stopped
  check upgrade-disabled-stopped-state inactive disabled
  step preserve-config 30 cmp -s /etc/localai/localai.conf "$work/config-before"
  step preserve-data 30 grep -qx 'localai acceptance marker' /var/lib/localai/models/.acceptance-marker
  step conservative-uninstall 900 bash "$repo_root/secureblue-localai-install/uninstall.sh" --yes
  step uninstall-preserves-data 30 grep -qx 'localai acceptance marker' /var/lib/localai/models/.acceptance-marker
  step uninstall-preserves-unrelated-container 120 "$0" --verify-unrelated "$run_id"
fi
