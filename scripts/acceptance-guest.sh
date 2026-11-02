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
fail() {
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

cpu_image=docker.io/localai/localai:latest-cpu
service_podman() {
  local uid
  uid="$(id -u localai)" || return 1
  systemd-run --user --machine=localai@.host --wait --pipe --collect \
    --setenv=HOME=/var/lib/localai --setenv="XDG_RUNTIME_DIR=/run/user/$uid" \
    --setenv="DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus" \
    --setenv=PATH=/usr/bin:/bin -- /usr/bin/podman "$@"
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
[[ "$#" == 1 && ( "$phase" == install || "$phase" == verify ) ]] || fail 'expected install or verify phase.'
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
  work="$(mktemp -d "$scratch/guest.XXXXXX")"
  progress=''
  receipt="$work/receipt"
  : >"$receipt"
  trap 'cat "$receipt"; rm -rf -- "$work"' EXIT
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
    create-unrelated-container) description='podman create unrelated test container' ;;
    upgrade-disabled-running|upgrade-enabled-running|upgrade-enabled-stopped|upgrade-disabled-stopped)
      description='backend installer --yes --no-pull' ;;
    enable-boot) description='systemctl --user enable localai.service' ;;
    disable-boot) description='systemctl --user disable localai.service' ;;
    preserve-config) description='compare installed config with pre-upgrade copy' ;;
    preserve-data|uninstall-preserves-data) description='check persistent test marker' ;;
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
installer="$repo_root/secureblue-localai-install/install.sh"
controller="$repo_root/bin/localaictl"

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
  step upgrade-disabled-running 1200 env LOCALAI_IMAGE_REF_OVERRIDE="$cpu_image" bash "$installer" --yes --no-pull
  check upgrade-disabled-running-state active disabled
  step enable-boot 30 "$0" --set-unit-enabled enable
  step upgrade-enabled-running 1200 env LOCALAI_IMAGE_REF_OVERRIDE="$cpu_image" bash "$installer" --yes --no-pull
  check upgrade-enabled-running-state active enabled
  step explicit-stop 300 "$controller" stop
  check enabled-stopped-state inactive enabled
  step upgrade-enabled-stopped 1200 env LOCALAI_IMAGE_REF_OVERRIDE="$cpu_image" bash "$installer" --yes --no-pull
  check upgrade-enabled-stopped-state inactive enabled
  step disable-boot 30 "$0" --set-unit-enabled disable
  step upgrade-disabled-stopped 1200 env LOCALAI_IMAGE_REF_OVERRIDE="$cpu_image" bash "$installer" --yes --no-pull
  check upgrade-disabled-stopped-state inactive disabled
  step preserve-config 30 cmp -s /etc/localai/localai.conf "$work/config-before"
  step preserve-data 30 grep -qx 'localai acceptance marker' /var/lib/localai/models/.acceptance-marker
  step conservative-uninstall 900 bash "$repo_root/secureblue-localai-install/uninstall.sh" --yes
  step uninstall-preserves-data 30 grep -qx 'localai acceptance marker' /var/lib/localai/models/.acceptance-marker
  step uninstall-preserves-unrelated-container 120 "$0" --verify-unrelated "$run_id"
fi
