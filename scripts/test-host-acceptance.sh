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
  case "$command" in
    true) return 0 ;;
    mkdir*) cat >/dev/null ;;
    *' install')
      if [[ "${MOCK_INSTALL_FAIL:-0}" == 1 ]]; then
        printf 'step install: fail\n'; return 1
      fi
      printf 'step install: pass\n' ;;
    *' verify') printf 'step verify: pass\n' ;;
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
result="$(HOME="$vm_mock_dir/test-home" main --vm "$vm_mock_dir/base.qcow2" "$vm_mock_dir/key" "$vm_mock_dir/vars" "$vm_mock_dir/hostkey.pub")"
[[ "$result" == "project-version: $(<"$repo_root/VERSION")"$'\n'project-archive-sha256:\ *$'\nstep install: pass\nstep verify: pass' ]]
grep -Eq '^project-archive-sha256: [a-f0-9]{64}$' <<<"$result"
[[ -e "$vm_mock_dir/rebooted" ]]
[[ -z "$(find "$vm_mock_dir/test-home/agent-scratch/LocalAI-SBlue/acceptance-vm" -mindepth 1 -print -quit)" ]]
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
