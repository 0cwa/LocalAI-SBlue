#!/usr/bin/env bash
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
[[ "$result" == $'step install: pass\nstep verify: pass' ]]
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
