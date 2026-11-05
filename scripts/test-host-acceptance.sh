#!/usr/bin/env bash
# The test intentionally runs functions in subshells and calls sourced mocks indirectly.
# shellcheck disable=SC1091,SC2030,SC2031,SC2269,SC2329
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# The sourced test helper uses this root for scratch placement.
# shellcheck disable=SC2034
TEST_REPO_ROOT="$repo_root"
# The helper is checked independently.
# shellcheck disable=SC1091
source "$repo_root/scripts/test-support.sh"
source "$repo_root/lib/acceptance.sh"
work="$(test_mktemp_dir acceptance-steps)"
trap 'rm -rf -- "$work"' EXIT
receipt="$work/receipt"
: >"$receipt"
# Guest backup destinations must use a canonical path even when HOME's
# agent-scratch prefix is a symlink alias.
(
  # shellcheck disable=SC1090
  source <(sed -n '/^acceptance_guest_work_dir() {$/,/^}/p' "$repo_root/scripts/acceptance-guest.sh")
  canonical_root="$work/real-scratch"
  alias_root="$work/scratch-alias"
  mkdir -m 0700 "$canonical_root"
  ln -s "$canonical_root" "$alias_root"
  created="$(acceptance_guest_work_dir "$alias_root")"
  canonical_root="$(realpath -e -- "$canonical_root")"
  [[ "$created" == "$canonical_root"/guest.* && -d "$created" && ! -L "$created" ]] || {
    printf 'acceptance guest scratch path was not canonicalized\n' >&2; exit 1;
  }
  rm -rf -- "$created"
)
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
# Host-mode checkpoints skip completed steps but retry failed steps.
(
  # shellcheck disable=SC1090
  # shellcheck disable=SC1090
  source <(sed -n '/^step() {$/,/^}/p' "$repo_root/scripts/acceptance-guest.sh")
  # These values are read by the extracted production helper.
  # shellcheck disable=SC2034
  mode=host progress="$work/progress" receipt="$work/checkpoint-receipt"
  mkdir -p "$progress"
  : >"$receipt"
  # shellcheck disable=SC2329
  fail() { exit 1; }
  # shellcheck disable=SC2329
  localai_acceptance_step() {
    printf 'called\n' >>"$work/checkpoint-calls"
    if [[ "${MOCK_STEP_FAIL:-0}" == 1 ]]; then return 1; fi
    printf 'step %s: pass\n' "$1" >>"$3"
  }
  step backend-install 2 true
  step backend-install 2 true
  [[ "$(wc -l <"$work/checkpoint-calls")" == 1 ]]
  [[ "$(<"$receipt")" == *'step backend-install: pass (earlier attempt)'* ]]
  if (MOCK_STEP_FAIL=1 step fresh-idle 2 true); then exit 1; fi
  [[ ! -e "$progress/fresh-idle" ]]
  step fresh-idle 2 true
  [[ -f "$progress/fresh-idle" ]]
)
# Host evidence fails closed when virtualization is not reliably detected.
(
  # shellcheck disable=SC1090
  source <(sed -n '/^evidence_mode_for_host() {$/,/^}/p' "$repo_root/scripts/acceptance-guest.sh")
  # shellcheck disable=SC2329
  systemd-detect-virt() { return "$VIRT_STATUS"; }
  [[ "$(VIRT_STATUS=0 evidence_mode_for_host)" == vm ]]
  [[ "$(VIRT_STATUS=1 evidence_mode_for_host)" == host-unverified ]]
  if VIRT_STATUS=2 evidence_mode_for_host >/dev/null; then exit 1; fi
)
# Recheck isolation at the start of a host install and retain the retry marker.
(
  # shellcheck disable=SC1090
  source <(sed -n '/^ensure_initial_isolation() {$/,/^}/p' "$repo_root/scripts/acceptance-guest.sh")
  # shellcheck disable=SC2034
  mode=host host_state="$work/host-isolation"
  mkdir -p "$host_state"
  # shellcheck disable=SC2329
  fail() { exit 1; }
  # shellcheck disable=SC2329
  localai_acceptance_clean_install() { [[ "${MOCK_CLEAN:-0}" == 1 ]]; }
  if (MOCK_CLEAN=0 ensure_initial_isolation); then exit 1; fi
  [[ ! -e "$host_state/install-started" ]]
  MOCK_CLEAN=1 ensure_initial_isolation
  [[ -f "$host_state/install-started" ]]
  MOCK_CLEAN=0 ensure_initial_isolation
)
# An interrupted create can reuse only the container labeled for this run.
(
  # shellcheck disable=SC1090
  source <(sed -n '/^ensure_unrelated_container() {$/,/^}/p' "$repo_root/scripts/acceptance-guest.sh")
  # shellcheck disable=SC1090
  source <(sed -n '/^unrelated_container_matches() {$/,/^}/p' "$repo_root/scripts/acceptance-guest.sh")
  # shellcheck disable=SC2034
  cpu_image=example.invalid/image:cpu
  run_id=0123456789abcdef0123456789abcdef
  # shellcheck disable=SC2329
  service_podman() {
    case "$1:$2" in
      container:exists) [[ -f "$work/container-label" ]] ;;
      inspect:*) cat "$work/container-label" ;;
      create:--name) printf '%s\n' "$run_id" >"$work/container-label"; printf 'created\n' >>"$work/container-creates" ;;
      *) return 2 ;;
    esac
  }
  ensure_unrelated_container "$run_id"
  ensure_unrelated_container "$run_id"
  unrelated_container_matches "$run_id"
  [[ "$(wc -l <"$work/container-creates")" == 1 ]]
  printf 'different\n' >"$work/container-label"
  if ensure_unrelated_container "$run_id"; then exit 1; fi
  if unrelated_container_matches "$run_id"; then exit 1; fi
  if ensure_unrelated_container invalid; then exit 1; fi
)
# The VM-only backup acceptance step is bounded, silent, and verifies both
# config metadata/labels and a persistent marker across a mocked round trip.
(
  # shellcheck disable=SC1090
  source <(sed -n '/^step() {$/,/^}/p' "$repo_root/scripts/acceptance-guest.sh")
  # shellcheck disable=SC1090
  source <(sed -n '/^backup_acceptance_step() {$/,/^}/p' "$repo_root/scripts/acceptance-guest.sh")
  # shellcheck disable=SC1090
  source <(sed -n '/^backup_restore_roundtrip() {$/,/^}/p' "$repo_root/scripts/acceptance-guest.sh")
  test_work="$work/backup-restore"
  mkdir -m 0700 "$test_work"
  mkdir -m 0700 "$test_work/config" "$test_work/state"
  mkdir -m 0700 "$test_work/state/data"
  mkdir -p "$test_work/state/.local/share/containers/storage"
  chmod 0700 "$test_work/state/.local/share/containers/storage"
  config_path="$test_work/config/localai.conf"
  printf 'LOCALAI_STATE_DIR=%s\nLOCALAI_MODELS_PATH=%s/models\nLOCALAI_BACKENDS_PATH=%s/backends\nLOCALAI_DOWNLOAD_STAGING_PATH=%s/downloading\nLOCALAI_BACKEND_TEMP_DIR=%s/tmp\nLOCALAI_DATA_PATH=%s/data\nLOCALAI_CONFIG_DIR=%s/config\nLOCALAI_GENERATED_CONTENT_PATH=%s/generated\nLOCALAI_UPLOAD_PATH=%s/uploads\nLOCALAI_CACHE_DIR=%s/cache\nLOCALAI_LOG_DIR=%s/logs\nLOCALAI_TLS_STATE_DIR=%s\nLOCALAI_TLS_CONFIG_DIR=%s/caddy\nLOCALAI_TLS_CACHE_DIR=%s/cache\nLOCALAI_TLS_CERT_DIR=%s/certs\nLOCALAI_TLS_COMPOSE_DIR=%s/compose\nLOCALAI_TLS_ENABLED=false\n' \
    "$test_work/state" "$test_work/state" "$test_work/state" "$test_work/state" "$test_work/state" "$test_work/state" "$test_work/state" "$test_work/state" "$test_work/state" "$test_work/state" "$test_work/state" "$test_work/tls" "$test_work/tls" "$test_work/tls" "$test_work/tls" "$test_work/tls" >"$config_path"
  chmod 0600 "$config_path"
  printf 'original config\n' >"$test_work/config-original"
  cp "$config_path" "$test_work/config-original"
  cat >"$test_work/fake-locaictl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  backup)
    if [[ "${TEST_BACKUP_FAIL:-0}" == 1 ]]; then
      if [[ "${TEST_BACKUP_SILENT:-0}" != 1 ]]; then printf 'localaictl: %s\n' "${TEST_BACKUP_MESSAGE:-backup contains system manager unit configuration}" >&2; fi
      exit 1
    fi
    cp -- "$TEST_CONFIG" "$TEST_WORK/saved-config"
    cp -- "$TEST_MARKER" "$TEST_WORK/saved-marker"
    cp -- "$TEST_GRAPH_MARKER" "$TEST_WORK/saved-graph-marker"
    : >"$2"
    chmod 0600 "$2"
    printf 'suppressed fixture output\n'
    ;;
  restore)
    cp -- "$TEST_WORK/saved-config" "$TEST_CONFIG"
    cp -- "$TEST_WORK/saved-marker" "$TEST_MARKER"
    cp -- "$TEST_WORK/saved-graph-marker" "$TEST_GRAPH_MARKER"
    printf 'suppressed fixture output\n'
    ;;
  *) exit 2 ;;
esac
EOF
  chmod 0755 "$test_work/fake-locaictl"
  export TEST_WORK="$test_work" TEST_CONFIG="$config_path" TEST_MARKER="$test_work/state/data/.localaictl-backup-restore-marker" TEST_GRAPH_MARKER="$test_work/state/.local/share/containers/storage/.localaictl-backup-restore-marker"
  # Functions and globals are consumed by the extracted production helpers.
  # shellcheck disable=SC2034
  repo_root="$repo_root" mode=vm receipt="$test_work/receipt" progress='' controller="$test_work/fake-locaictl" work="$test_work" host_receipt_ready=0
  : >"$receipt"
  fail() {
    case "$*" in
      *'cannot load configured persistent paths'*) printf 'test acceptance failure: config-load\n' >&2 ;;
      *'config path'*) printf 'test acceptance failure: config-path\n' >&2 ;;
      *'root-owned'*) printf 'test acceptance failure: config-owner\n' >&2 ;;
      *'group/world writable'*) printf 'test acceptance failure: config-mode\n' >&2 ;;
      *'SELinux label'*) printf 'test acceptance failure: config-label\n' >&2 ;;
      *'data path'*) printf 'test acceptance failure: data-path\n' >&2 ;;
      *'marker'*) printf 'test acceptance failure: marker\n' >&2 ;;
      *'active state'*) printf 'test acceptance failure: service-state\n' >&2 ;;
      *'backup'*) printf 'test acceptance failure: backup-step\n' >&2 ;;
      *'restore'*) printf 'test acceptance failure: restore-step\n' >&2 ;;
      *) printf 'test acceptance failure: fixture-check\n' >&2 ;;
    esac
    exit 1
  }
  check_unit() { [[ "$1:$2" == active:disabled ]]; }
  matchpathcon() { [[ "$1" == -V ]]; }
  stat() {
    if [[ " $* " == *" $TEST_CONFIG "* ]]; then printf '0:600\n'; else command stat "$@"; fi
  }
  : >"$test_work/step-output"
  # Use the actual shared step runner with its command output redirected.
  source "$repo_root/lib/acceptance.sh"
  if (backup_restore_roundtrip "$test_work" "$config_path") >"$test_work/step-output" 2>&1; then :; else cat "$test_work/step-output" >&2; exit 1; fi
  [[ ! -e "$TEST_MARKER" ]] || { printf 'acceptance fixture marker was not cleaned\n' >&2; exit 1; }
  [[ ! -e "$TEST_GRAPH_MARKER" ]] || { printf 'acceptance graph fixture marker was not cleaned\n' >&2; exit 1; }
  cmp -s "$config_path" "$test_work/config-original" || { printf 'acceptance fixture config was not restored\n' >&2; exit 1; }
  rg -q '^command backup-restore-backup:' "$receipt" || { printf 'backup acceptance command was not recorded\n' >&2; exit 1; }
  rg -q '^waiting backup-restore-backup: timeout 1800s$' "$receipt" || { printf 'backup acceptance timeout was not recorded\n' >&2; exit 1; }
  rg -q '^step backup-restore-backup: pass$' "$receipt" || { printf 'backup acceptance result was not recorded\n' >&2; exit 1; }
  rg -q '^step backup-restore-restore: pass$' "$receipt" || { printf 'restore acceptance result was not recorded\n' >&2; exit 1; }
  if TEST_BACKUP_FAIL=1 backup_acceptance_step "$test_work/failing-backup.tar.gz"; then
    printf 'failed backup diagnostic fixture was accepted\n' >&2; exit 1
  fi
  rg -q '^diagnostic backup-restore-backup-reason: system-manager-tree$' "$receipt" || { printf 'backup failure was not reduced to an allowlisted category\n' >&2; exit 1; }
  if TEST_BACKUP_FAIL=1 TEST_BACKUP_MESSAGE='backup destination parent must not contain symbolic links or traversal components' backup_acceptance_step "$test_work/symlinked-parent.tar.gz"; then
    printf 'unsafe backup destination parent diagnostic fixture was accepted\n' >&2; exit 1
  fi
  rg -q '^diagnostic backup-restore-backup-reason: destination-parent-unsafe$' "$receipt" || { printf 'backup destination parent failure was not classified\n' >&2; exit 1; }
  if TEST_BACKUP_FAIL=1 TEST_BACKUP_MESSAGE='backup weakens metadata on an installed user service unit ancestor' backup_acceptance_step "$test_work/unsafe-ancestor.tar.gz"; then
    printf 'unsafe unit ancestor diagnostic fixture was accepted\n' >&2; exit 1
  fi
  rg -q '^diagnostic backup-restore-backup-reason: unit-ancestor-metadata-weakened$' "$receipt" || { printf 'unit ancestor validation failure was not classified\n' >&2; exit 1; }
  if TEST_BACKUP_FAIL=1 TEST_BACKUP_MESSAGE='Traceback (most recent call last): ValueError: secret-path' backup_acceptance_step "$test_work/helper-exception.tar.gz"; then
    printf 'helper exception diagnostic fixture was accepted\n' >&2; exit 1
  fi
  rg -q '^diagnostic backup-restore-backup-reason: helper-exception$' "$receipt" || { printf 'helper exception was not classified\n' >&2; exit 1; }
  if TEST_BACKUP_FAIL=1 TEST_BACKUP_MESSAGE='shared backup archive helper is missing' backup_acceptance_step "$test_work/missing-helper.tar.gz"; then
    printf 'missing helper diagnostic fixture was accepted\n' >&2; exit 1
  fi
  rg -q '^diagnostic backup-restore-backup-reason: helper-invocation$' "$receipt" || { printf 'helper invocation failure was not classified\n' >&2; exit 1; }
  if TEST_BACKUP_FAIL=1 TEST_BACKUP_SILENT=1 backup_acceptance_step "$test_work/silent-failure.tar.gz"; then
    printf 'silent helper failure fixture was accepted\n' >&2; exit 1
  fi
  rg -q '^diagnostic backup-restore-backup-reason: helper-no-diagnostic$' "$receipt" || { printf 'silent helper failure was not distinguished\n' >&2; exit 1; }
  ! rg -q 'system manager unit configuration|suppressed fixture output|/var/home|secret' "$receipt" "$test_work/step-output" || { printf 'raw backup diagnostic escaped into acceptance output\n' >&2; exit 1; }
  ! rg -q 'suppressed fixture output|/var/home|secret' "$receipt" "$test_work/step-output" || { printf 'acceptance output leaked fixture data\n' >&2; exit 1; }
)
# Health checks retry a briefly unavailable service without recording output.
(
  # shellcheck disable=SC1090
  source <(sed -n '/^wait_for_health() {$/,/^}/p' "$repo_root/scripts/acceptance-guest.sh")
  cat >"$work/fake-doctor" <<'EOF'
#!/usr/bin/env bash
printf 'call\n' >>"${HEALTH_CALLS:?}"
if [[ "$(wc -l <"$HEALTH_CALLS")" -lt 2 ]]; then exit 1; fi
printf 'health result: HTTP 401\n'
EOF
  chmod 0755 "$work/fake-doctor"
  export HEALTH_CALLS="$work/health-calls"
  # shellcheck disable=SC2329
  sleep() { :; }
  wait_for_health "$work/fake-doctor"
  [[ "$(wc -l <"$HEALTH_CALLS")" == 2 ]]
)
printf 'Acceptance isolation, identity, and readiness tests passed\n'
printf 'Acceptance checkpoint tests passed\n'
# The policy operation has its own named timeout and never emits command output.
(
  source "$repo_root/scripts/acceptance-policy.sh"
  receipt="$work/policy-receipt"
  : >"$receipt"
  # shellcheck disable=SC2329
  fake_policy_timeout() { printf '%s\n' "$*" >"$work/policy-args"; if [[ "${MOCK_POLICY_OUTPUT:-0}" == 1 ]]; then printf 'simulated module list\n'; fi; return "${MOCK_POLICY_STATUS:-0}"; }
  # shellcheck disable=SC2329
  fake_policy_ujust() { return 0; }
  acceptance_policy_apply fake_policy_timeout fake_policy_ujust "$receipt" set-container-userns on
  [[ "$(<"$work/policy-args")" == '--kill-after=10s 180s fake_policy_ujust set-container-userns on' ]]
  if (MOCK_POLICY_STATUS=124 acceptance_policy_apply fake_policy_timeout fake_policy_ujust "$receipt" set-container-userns on); then exit 1; fi
  [[ "$(<"$receipt")" == *'step container-userns-policy: timeout'* ]]
  if acceptance_policy_apply fake_policy_timeout fake_policy_ujust "$receipt" unexpected on; then exit 1; fi
  module_output="$(MOCK_POLICY_OUTPUT=1 acceptance_semodule_apply fake_policy_timeout fake_policy_ujust "$receipt" -l)"
  [[ "$module_output" == 'simulated module list' ]]
  [[ "$(<"$receipt")" != *'simulated module list'* ]]
  [[ "$(<"$work/policy-args")" == '--kill-after=10s 120s fake_policy_ujust -l' ]]
  if (MOCK_POLICY_STATUS=124 acceptance_semodule_apply fake_policy_timeout fake_policy_ujust "$receipt" -i module); then exit 1; fi
  [[ "$(<"$receipt")" == *'step selinux-module-reconciliation: timeout'* ]]
  if acceptance_semodule_apply fake_policy_timeout fake_policy_ujust "$receipt"; then exit 1; fi
)
printf 'Acceptance policy timeout tests passed\n'
printf 'Acceptance step tests passed\n'
(
  # shellcheck disable=SC1090
  source <(sed -n '/^upgrade_step() {$/,/^}/p' "$repo_root/scripts/acceptance-guest.sh")
  # The mock writes a fixed stage and an unknown value to test filtering.
  # shellcheck disable=SC2329
  step() { printf 'backend-preflight\nunknown-stage\nsafety-refusal\n' > "$work/installer-stages"; return 1; }
  # Variables are consumed by the extracted function.
  # shellcheck disable=SC2034
  installer=unused cpu_image=unused receipt="$work/upgrade-receipt"
  : > "$receipt"
  if upgrade_step upgrade-disabled-running; then exit 1; fi
  rg -q '^diagnostic upgrade-stage: backend-preflight$' "$receipt"
  rg -q '^diagnostic upgrade-stage: safety-refusal$' "$receipt"
  ! rg -q 'unknown-stage' "$receipt"
)

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
touch "$work/root/etc/localai.conf"
if localai_acceptance_clean_install "$work/root" 2>/dev/null; then
  printf 'Existing legacy configuration was accepted\n' >&2; exit 1
fi
rm "$work/root/etc/localai.conf"
mkdir -p "$work/root/var/lib/localai-installer"
if localai_acceptance_clean_install "$work/root" 2>/dev/null; then
  printf 'Existing installer metadata was accepted\n' >&2; exit 1
fi
rmdir "$work/root/var/lib/localai-installer"
getent() { return 0; }
if localai_acceptance_clean_install "$work/root" 2>/dev/null; then
  printf 'Existing service account was accepted\n' >&2; exit 1
fi
getent() { return 1; }
if localai_acceptance_clean_install "$work/root" 2>/dev/null; then
  printf 'Account lookup error was accepted\n' >&2; exit 1
fi
printf 'Acceptance isolation checks passed\n'

# Exercise orchestration with a simulated VM and SSH; no host services run.
# The VM runner is sourced so only this test can substitute its commands.
source "$repo_root/scripts/host-acceptance.sh"
vm_mock_dir="$work/vm-mock"
mkdir -p "$vm_mock_dir/test-home"
touch "$vm_mock_dir/base.qcow2" "$vm_mock_dir/key" "$vm_mock_dir/vars"
ssh-keygen -q -t ed25519 -N '' -f "$vm_mock_dir/hostkey"
qemu-img() {
  case "$1" in
    info)
      if [[ "${MOCK_IMAGE_EXTERNAL:-0}" == 1 ]]; then
        printf '{"format":"qcow2","children":[{"name":"data-file"}]}\n'
      else
        printf '{"format":"%s"}\n' "${MOCK_IMAGE_FORMAT:-qcow2}"
      fi ;;
    create) : > "${@: -1}" ;;
    *) return 1 ;;
  esac
}
qemu-system-x86_64() { exec sleep 60; }
timeout() { if [[ "$1" == --kill-after=* ]]; then shift; fi; shift; "$@"; }
ssh() {
  local command="${*: -1}"
  local ssh_argv=" $* " required
  for required in '-F /dev/null' '-o ProxyCommand=none' '-o ProxyJump=none' \
    '-o IdentitiesOnly=yes' '-o ControlMaster=no' '-o ControlPath=none'; do
    [[ "$ssh_argv" == *" $required "* ]] || { : >"$vm_mock_dir/ssh-isolation-failure"; return 90; }
  done
  case "$command" in
    true) return 0 ;;
    mkdir*) cat >/dev/null ;;
    'install -o root -g root -m 0644 /dev/stdin /root/agent-scratch/LocalAI-SBlue/acceptance-source/scripts/acceptance-guest.sh')
      cat >/dev/null
      : >"$vm_mock_dir/diagnostic-worker-refreshed" ;;
    *'ps -eo comm=,etimes='*)
      printf 'vm-install-process: container-runtime count=1 max-elapsed=42s\n'
      printf 'untrusted process detail: /etc/passwd\n' ;;
    *'--rootless-archive-roundtrip'*)
      printf 'diagnostic graphroot-unshare-poc-run: pass\n'
      printf 'diagnostic graphroot-unshare-poc-reason: user-xattr-failed\n'
      printf 'diagnostic guest-worker-prerequisite: debug-shell-active\n'
      printf 'diagnostic graphroot-unshare-owner-mode: fail\n'
      printf 'diagnostic graphroot-unshare-xattr: fail\n'
      printf 'diagnostic graphroot-unshare-selinux: fail\n'
      printf 'diagnostic graphroot-unshare-host-mapping: fail\n' ;;
    *' install')
      if [[ "${MOCK_INSTALL_FAIL:-0}" == 1 ]]; then
        printf 'step install: fail\n'; return 1
      fi
      printf 'step install: pass\n' ;;
    *' diagnose-backup') : >"$vm_mock_dir/diagnose-command-seen"; printf 'step backup-restore-backup: fail\ndiagnostic backup-restore-backup-reason: %s\n' "${MOCK_BACKUP_REASON:-system-manager-tree}"; return 1 ;;
    *' verify')
      if [[ "${MOCK_VERIFY_FAIL:-0}" == 1 ]]; then : >"$vm_mock_dir/verify-failure-seen"; printf 'step verify: fail\n'; return 1; fi
      printf 'step verify: pass\n' ;;
    'systemctl reboot --no-block') : >"$vm_mock_dir/rebooted" ;;
    'cat /proc/sys/kernel/random/boot_id')
      if [[ -e "$vm_mock_dir/rebooted" ]]; then
        printf '22222222-2222-2222-2222-222222222222\n'
      else
        printf '11111111-1111-1111-1111-111111111111\n'
      fi ;;
    *) return 1 ;;
  esac
}
sleep() {
  local control_home="$vm_mock_dir/test-home" active="$vm_mock_dir/test-home/agent-scratch/LocalAI-SBlue/acceptance-vm/diagnostic-active"
  if [[ "${1:-}" == 60 ]]; then
    /usr/bin/sleep 0.1
  elif [[ -f "$active" ]]; then
    HOME="$control_home" main --release-vm-diagnostic-pause
  else
    /usr/bin/sleep "$@"
  fi
}
ssh_args=(-F /dev/null -o ProxyCommand=none -o ProxyJump=none -o IdentitiesOnly=yes
  -o ControlMaster=no -o ControlPath=none)
snapshot="$(install_process_snapshot)"
[[ "$snapshot" == 'vm-install-process: container-runtime count=1 max-elapsed=42s
vm-install-process: result-unavailable' ]] || {
  printf 'install process snapshot did not allowlist its output\n' >&2; exit 1;
}
if ! result="$(HOME="$vm_mock_dir/test-home" main --vm "$vm_mock_dir/base.qcow2" "$vm_mock_dir/key" "$vm_mock_dir/vars" "$vm_mock_dir/hostkey.pub")"; then
  printf 'mock VM success path failed\n' >&2; exit 1
fi
[[ "$result" == "project-version: $(<"$repo_root/VERSION")"$'\n'project-archive-sha256:\ *$'\nstep install: pass\nstep verify: pass' ]] || {
  printf 'mock VM success receipt did not match expected stages\n' >&2; exit 1;
}
grep -Eq '^project-archive-sha256: [a-f0-9]{64}$' <<<"$result" || { printf 'mock VM receipt digest was invalid\n' >&2; exit 1; }
[[ -e "$vm_mock_dir/rebooted" ]]
[[ -z "$(find "$vm_mock_dir/test-home/agent-scratch/LocalAI-SBlue/acceptance-vm" -mindepth 1 -print -quit)" ]]
printf 'Mock VM successful lifecycle flow passed.\n'
rm -f -- "$vm_mock_dir/rebooted" "$vm_mock_dir/verify-failure-seen" "$vm_mock_dir/diagnose-command-seen"
if result="$(LOCALAI_ACCEPTANCE_DIAGNOSTIC_PAUSE_SECONDS=5 MOCK_VERIFY_FAIL=1 HOME="$vm_mock_dir/test-home" main --vm "$vm_mock_dir/base.qcow2" "$vm_mock_dir/key" "$vm_mock_dir/vars" "$vm_mock_dir/hostkey.pub" 2>/dev/null)"; then
  printf 'VM verification failure was accepted during diagnostic hold\n' >&2; exit 1
fi
printf 'Mock VM failure diagnostic flow returned.\n'
if [[ ! -f "$vm_mock_dir/verify-failure-seen" ]]; then
  [[ ! -e "$vm_mock_dir/ssh-isolation-failure" ]] || { printf 'VM SSH argv omitted an isolation option\n' >&2; exit 1; }
  [[ "$result" == *'step install: pass'* ]] || printf 'VM install stage did not pass before mock failure\n' >&2
  [[ "$result" == *'step vm-orchestration: fail'* ]] || printf 'VM orchestration did not report a failure stage\n' >&2
  printf 'VM verification failure mock was not reached\n' >&2; exit 1
fi
[[ -f "$vm_mock_dir/diagnose-command-seen" ]] || { printf 'same-overlay diagnostic retry mock was not reached\n' >&2; exit 1; }
if [[ "$result" != *'diagnostic-recheck: started'* || "$result" != *'diagnostic backup-restore-backup-reason: system-manager-tree'* || "$result" != *'diagnostic-pause: active'* || "$result" != *'diagnostic-pause: released'* || "$result" != *'diagnostic-pause: release-requested'* ]]; then
  [[ "$result" == *'diagnostic-recheck: started'* ]] || printf 'missing diagnostic recheck stage\n' >&2
  [[ "$result" == *'diagnostic backup-restore-backup-reason: system-manager-tree'* ]] || printf 'missing categorized backup diagnostic\n' >&2
  [[ "$result" == *'diagnostic-pause: active'* ]] || printf 'missing diagnostic pause stage\n' >&2
  [[ "$result" == *'diagnostic-pause: released'* ]] || printf 'missing diagnostic release stage\n' >&2
  [[ "$result" == *'diagnostic-pause: release-requested'* ]] || printf 'missing diagnostic control response\n' >&2
  printf 'same-overlay diagnostic hold/release regression failed\n' >&2; exit 1
fi
[[ -z "$(find "$vm_mock_dir/test-home/agent-scratch/LocalAI-SBlue/acceptance-vm" -mindepth 1 -print -quit)" ]]
diagnostic_scratch="$vm_mock_dir/test-home/agent-scratch/LocalAI-SBlue/acceptance-vm"
ln -s "$vm_mock_dir/test-home" "$vm_mock_dir/test-home-alias"
diagnostic_run="$diagnostic_scratch/run.controltest"
mkdir -p "$diagnostic_run"
chmod 0700 "$diagnostic_run"
chmod 0700 "$diagnostic_scratch"
proc_fixture="$vm_mock_dir/proc-fixture"
fake_qemu_pid=43210
fake_qemu_start=987654
fake_qemu_exe="$(realpath -e -- "$(type -P qemu-system-x86_64)")"
mkdir -p "$proc_fixture/$fake_qemu_pid"
fake_stat_fields=(S)
for ((index = 1; index < 19; index++)); do fake_stat_fields+=(0); done
fake_stat_fields+=("$fake_qemu_start")
printf '%s (%s) %s\n' "$fake_qemu_pid" 'qemu mock ) name' "${fake_stat_fields[*]}" >"$proc_fixture/$fake_qemu_pid/stat"
ln -s "$fake_qemu_exe" "$proc_fixture/$fake_qemu_pid/exe"
printf '%s\0' "$fake_qemu_exe" -machine q35,accel=kvm -nic 'user,hostfwd=tcp:127.0.0.1:23456-:22' -display none >"$proc_fixture/$fake_qemu_pid/cmdline"
if [[ "$(proc_start_time "$fake_qemu_pid" "$proc_fixture")" != "$fake_qemu_start" ]]; then
  printf 'QEMU start-time parser did not match synthetic process stat\n' >&2; exit 1
fi
qemu_process_matches "$fake_qemu_pid" "$fake_qemu_start" 23456 "$fake_qemu_exe" "$proc_fixture" || {
  printf 'QEMU identity rejected the valid synthetic instance\n' >&2; exit 1;
}
if qemu_process_matches 43211 "$fake_qemu_start" 23456 "$fake_qemu_exe" "$proc_fixture"; then
  printf 'QEMU identity accepted a dead PID\n' >&2; exit 1
fi
if qemu_process_matches "$fake_qemu_pid" 987655 23456 "$fake_qemu_exe" "$proc_fixture"; then
  printf 'QEMU identity accepted a reused PID with a different start time\n' >&2; exit 1
fi
if qemu_process_matches "$fake_qemu_pid" "$fake_qemu_start" 23457 "$fake_qemu_exe" "$proc_fixture"; then
  printf 'QEMU identity accepted a process bound to another port\n' >&2; exit 1
fi
rm "$proc_fixture/$fake_qemu_pid/exe"
ln -s "$(type -P sleep)" "$proc_fixture/$fake_qemu_pid/exe"
if qemu_process_matches "$fake_qemu_pid" "$fake_qemu_start" 23456 "$fake_qemu_exe" "$proc_fixture"; then
  printf 'QEMU identity accepted the wrong executable\n' >&2; exit 1
fi
rm "$proc_fixture/$fake_qemu_pid/exe"
ln -s "$fake_qemu_exe" "$proc_fixture/$fake_qemu_pid/exe"
printf 'QEMU process identity mock cases passed.\n'
qemu_log_test_file="$work/qemu-startup.log"
assert_qemu_log_category() {
  local expected="$1" sample="$2" actual
  if [[ -z "$sample" ]]; then : >"$qemu_log_test_file"; else printf '%s\n' "$sample" >"$qemu_log_test_file"; fi
  actual="$(qemu_log_category "$qemu_log_test_file")"
  [[ "$actual" == "$expected" ]] || { printf 'QEMU startup log classifier mismatch\n' >&2; exit 1; }
}
assert_qemu_log_category qemu-empty-log ''
assert_qemu_log_category kvm-unavailable 'Could not access KVM kernel module: Permission denied'
assert_qemu_log_category kvm-device 'failed to open /dev/kvm'
assert_qemu_log_category memory-allocation 'Cannot allocate memory'
assert_qemu_log_category disk-capacity 'No space left on device'
assert_qemu_log_category host-forward 'failed to set up hostfwd rule'
assert_qemu_log_category input-open 'Could not open firmware input'
assert_qemu_log_category permission 'Permission denied during device setup'
assert_qemu_log_category qemu-unclassified 'synthetic qemu startup failure'
printf 'QEMU startup log classifier tests passed.\n'
assert_qemu_exit_category() {
  local status="$1" expected="$2" actual
  actual="$(qemu_exit_category "$status")"
  [[ "$actual" == "$expected" ]] || { printf 'QEMU exit classifier mismatch\n' >&2; exit 1; }
}
assert_qemu_exit_category 0 qemu-exit-success
assert_qemu_exit_category 1 qemu-startup-error
assert_qemu_exit_category 2 qemu-startup-error
assert_qemu_exit_category 126 qemu-exec-failure
assert_qemu_exit_category 127 qemu-exec-failure
assert_qemu_exit_category 137 qemu-killed
assert_qemu_exit_category 139 qemu-crash
assert_qemu_exit_category 143 qemu-exit-unknown
printf 'QEMU exit status classifier tests passed.\n'
read -r diagnostic_key_type diagnostic_key_data _ <"$vm_mock_dir/hostkey.pub"
printf '[127.0.0.1]:23456 %s %s\n' "$diagnostic_key_type" "$diagnostic_key_data" >"$diagnostic_run/known_hosts"
chmod 0600 "$diagnostic_run/known_hosts" "$vm_mock_dir/key"
printf '23456\n%s\n%s\n%s\n' \
  "$vm_mock_dir/test-home-alias/agent-scratch/LocalAI-SBlue/acceptance-vm/run.controltest/known_hosts" \
  "$fake_qemu_pid" "$fake_qemu_start" >"$diagnostic_scratch/diagnostic-connection"
: >"$diagnostic_scratch/diagnostic-active"
chmod 0600 "$diagnostic_scratch/diagnostic-connection" "$diagnostic_scratch/diagnostic-active"
[[ "$(<"$diagnostic_scratch/diagnostic-connection")" != *"$vm_mock_dir/key"* ]] || { printf 'VM diagnostic connection stored an SSH identity path\n' >&2; exit 1; }
rm -f -- "$vm_mock_dir/diagnose-command-seen"
if result="$(HOME="$vm_mock_dir/test-home-alias" main --diagnose-vm-backup "$vm_mock_dir/key" 2>&1)"; then
  printf 'VM diagnostic control accepted a nonexistent QEMU PID\n' >&2; exit 1
fi
[[ "$result" == *'step vm-orchestration: fail'* && "$result" == *'acceptance: VM diagnostic QEMU process identity is stale or mismatched.'* ]] || {
  printf 'diagnostic control did not refuse a dead PID before SSH\n' >&2; exit 1;
}
[[ ! -e "$vm_mock_dir/diagnose-command-seen" ]] || { printf 'diagnostic SSH ran for a dead PID\n' >&2; exit 1; }
if result="$(HOME="$vm_mock_dir/test-home-alias" diagnose_vm_backup_with_proc_root "$vm_mock_dir/key" "$proc_fixture" 2>/dev/null)"; then
  printf 'VM diagnostic control accepted a failed backup probe\n' >&2; exit 1
fi
[[ -e "$vm_mock_dir/diagnose-command-seen" ]] || { printf 'valid mocked QEMU identity did not reach diagnostic SSH\n' >&2; exit 1; }
[[ -e "$vm_mock_dir/diagnostic-worker-refreshed" ]] || { printf 'diagnostic worker refresh did not run after QEMU identity verification\n' >&2; exit 1; }
if [[ "$result" != $'diagnostic-worker: refreshed\ndiagnostic graphroot-unshare-poc-run: pass\ndiagnostic graphroot-unshare-poc-reason: user-xattr-failed\ndiagnostic guest-worker-prerequisite: debug-shell-active\ndiagnostic graphroot-unshare-owner-mode: fail\ndiagnostic graphroot-unshare-xattr: fail\ndiagnostic graphroot-unshare-selinux: fail\ndiagnostic graphroot-unshare-host-mapping: fail\nstep backup-restore-backup: fail\ndiagnostic backup-restore-backup-reason: system-manager-tree' ]]; then
  printf 'VM diagnostic control did not sanitize its fixed mock response\n' >&2; exit 1
fi
if result="$(MOCK_BACKUP_REASON=unit-ancestor-metadata-weakened HOME="$vm_mock_dir/test-home-alias" diagnose_vm_backup_with_proc_root "$vm_mock_dir/key" "$proc_fixture" 2>/dev/null)"; then
  printf 'VM diagnostic accepted a failed ancestor metadata probe\n' >&2; exit 1
fi
[[ "$result" == $'diagnostic-worker: refreshed\ndiagnostic graphroot-unshare-poc-run: pass\ndiagnostic graphroot-unshare-poc-reason: user-xattr-failed\ndiagnostic guest-worker-prerequisite: debug-shell-active\ndiagnostic graphroot-unshare-owner-mode: fail\ndiagnostic graphroot-unshare-xattr: fail\ndiagnostic graphroot-unshare-selinux: fail\ndiagnostic graphroot-unshare-host-mapping: fail\nstep backup-restore-backup: fail\ndiagnostic backup-restore-backup-reason: unit-ancestor-metadata-weakened' ]] || {
  printf 'VM diagnostic did not preserve a fixed detailed failure category\n' >&2; exit 1;
}
result="$(HOME="$vm_mock_dir/test-home-alias" main --release-vm-diagnostic-pause)" || { printf 'diagnostic pause release mock failed\n' >&2; exit 1; }
[[ "$result" == 'diagnostic-pause: release-requested' && -f "$diagnostic_scratch/diagnostic-release" && ! -L "$diagnostic_scratch/diagnostic-release" ]] || {
  printf 'diagnostic pause release state did not match expected\n' >&2; exit 1;
}
rm -f -- "$diagnostic_scratch/diagnostic-active" "$diagnostic_scratch/diagnostic-release" "$diagnostic_scratch/diagnostic-connection"
rm -rf -- "$diagnostic_run"
[[ -z "$(find "$diagnostic_scratch" -mindepth 1 -print -quit)" ]] || {
  printf 'diagnostic connection test left scratch state behind\n' >&2; exit 1;
}
if result="$(MOCK_INSTALL_FAIL=1 HOME="$vm_mock_dir/test-home" main --vm "$vm_mock_dir/base.qcow2" "$vm_mock_dir/key" "$vm_mock_dir/vars" "$vm_mock_dir/hostkey.pub" 2>/dev/null)"; then
  printf 'VM install failure was accepted\n' >&2; exit 1
fi
[[ "$result" == *'step install: fail'* && "$result" == *'step vm-orchestration: fail'* ]]
[[ -z "$(find "$vm_mock_dir/test-home/agent-scratch/LocalAI-SBlue/acceptance-vm" -mindepth 1 -print -quit)" ]]
if (MOCK_IMAGE_FORMAT=raw HOME="$vm_mock_dir/test-home" main --vm "$vm_mock_dir/base.qcow2" "$vm_mock_dir/key" "$vm_mock_dir/vars" "$vm_mock_dir/hostkey.pub" >/dev/null 2>&1); then
  printf 'Non-qcow2 base was accepted\n' >&2; exit 1
fi
if (MOCK_IMAGE_EXTERNAL=1 HOME="$vm_mock_dir/test-home" main --vm "$vm_mock_dir/base.qcow2" "$vm_mock_dir/key" "$vm_mock_dir/vars" "$vm_mock_dir/hostkey.pub" >/dev/null 2>&1); then
  printf 'External qcow2 data file was accepted\n' >&2; exit 1
fi
printf 'Acceptance VM orchestration tests passed\n'

# Host mode must request one elevation and never execute it in this mock.
run0() { printf '%s\n' "${@: -1}" >"$vm_mock_dir/host-call"; }
main --host >/dev/null
[[ "$(<"$vm_mock_dir/host-call")" == "$repo_root" ]]
main --host --resume >/dev/null
[[ "$(<"$vm_mock_dir/host-call")" == resume ]]
if (main --host unexpected >/dev/null 2>&1); then
  printf 'Invalid host mode arguments were accepted\n' >&2; exit 1
fi
printf 'Acceptance host authorization tests passed\n'

# Exercise the reboot journal with all system and elevation operations mocked.
(
  source "$repo_root/scripts/acceptance-host.sh"
  state="$work/host-state"
  unit="$work/host-acceptance.service"
# shellcheck disable=SC2034
unit_name=host-acceptance.service
  call_file="$work/host-systemctl.calls"
  : >"$call_file"
  getenforce() { printf 'Enforcing\n'; }
  localai_acceptance_clean_install() { [[ "${MOCK_DIRTY:-0}" == 0 ]]; }
  valid_state() { [[ -f "$state/initial-clean" && -f "$state/phase" ]]; }
  systemctl() {
    if [[ "${1:-}" == is-active ]]; then return 3; fi
    printf '%s\n' "$*" >>"$call_file"
  }
  timeout() {
    if [[ "${MOCK_STAGE_FAIL:-0}" == 1 ]]; then
      printf 'step simulated: fail\n'
      return 1
    fi
    printf 'step simulated: pass\n'
  }
  begin "$repo_root" >/dev/null
  [[ "$(<"$state/phase")" == prepared ]]
  [[ -f "$unit" && -f "$state/initial-clean" ]]
  if (MOCK_STAGE_FAIL=1 run); then exit 1; fi
  [[ "$(<"$state/phase")" == install-failed ]]
  run
  [[ "$(<"$state/phase")" == awaiting-reboot ]]
  [[ "$(<"$state/receipt")" == *'step host-install: fail'* ]]
  printf '00000000-0000-0000-0000-000000000000\n' >"$state/boot-id"
  if (MOCK_STAGE_FAIL=1 run); then exit 1; fi
  [[ "$(<"$state/phase")" == verify-failed ]]
  run
  [[ "$(<"$state/phase")" == complete ]]
  [[ "$(<"$state/receipt")" == *'acceptance: complete'* ]]
  grep -q '^reboot --no-block$' "$call_file"
  grep -q '^disable host-acceptance.service$' "$call_file"
)

(
  # The earlier state-machine test is isolated in its own subshell.
  # shellcheck disable=SC2031
  source "$repo_root/scripts/acceptance-host.sh"
  state="$work/dirty-host-state"
  unit="$work/dirty-host.service"
  getenforce() { printf 'Enforcing\n'; }
  systemctl() { return 3; }
  localai_acceptance_clean_install() { return 1; }
  if (begin "$repo_root" >/dev/null 2>&1); then exit 1; fi
  [[ ! -e "$state" && ! -e "$unit" ]]
)
printf 'Acceptance host state-machine tests passed\n'
