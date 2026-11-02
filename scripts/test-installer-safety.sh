#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
TEST_REPO_ROOT="$repo_root"
source "$repo_root/scripts/test-support.sh"
test_sanitize_localai_environment
scratch="$(test_mktemp_dir installer-safety)"
trap 'rm -rf -- "$scratch"' EXIT

source "$repo_root/lib/config.sh"
source "$repo_root/lib/installer_safety.sh"

fail() {
  printf 'installer safety test failed: %s\n' "$*" >&2
  exit 1
}

# Register each fixture root so only expected scratch paths can cross a test
# host boundary. The state/project paths are canonical allowed names used only
# for validation and the run0 argument probe; the test never creates them.
declare -A SYNTHETIC_ROOTS=()
declare -A SYNTHETIC_FILES=()
register_synthetic_root() {
  local role="$1" path="$2"
  [[ "$path" == /* ]] || fail "synthetic root must be absolute: $role"
  [[ -z "${SYNTHETIC_ROOTS[$role]+registered}" ]] || fail "duplicate synthetic root role: $role"
  SYNTHETIC_ROOTS["$role"]="$path"
}

register_synthetic_file() {
  local role="$1" path="$2"
  [[ "$path" == "$scratch/"* ]] || fail "synthetic file must stay under task scratch: $role"
  [[ -z "${SYNTHETIC_FILES[$role]+registered}" ]] || fail "duplicate synthetic file role: $role"
  SYNTHETIC_FILES["$role"]="$path"
}

synthetic_root() {
  local role="$1"
  [[ -n "${SYNTHETIC_ROOTS[$role]+registered}" ]] || fail "unregistered synthetic root: $role"
  printf '%s\n' "${SYNTHETIC_ROOTS[$role]}"
}

is_registered_synthetic_root() {
  local role="$1" path="$2"
  [[ -n "${SYNTHETIC_ROOTS[$role]+registered}" && "${SYNTHETIC_ROOTS[$role]}" == "$path" ]]
}

synthetic_file() {
  local role="$1"
  [[ -n "${SYNTHETIC_FILES[$role]+registered}" ]] || fail "unregistered synthetic file: $role"
  printf '%s\n' "${SYNTHETIC_FILES[$role]}"
}

is_registered_synthetic_file() {
  local role="$1" path="$2"
  [[ -n "${SYNTHETIC_FILES[$role]+registered}" && "${SYNTHETIC_FILES[$role]}" == "$path" ]]
}

register_synthetic_root state "/var/lib/localai-test-${BASHPID}"
register_synthetic_root project "$(synthetic_root state)/build/localai-oci"
register_synthetic_root backend_volume "$scratch/backend-volume"
register_synthetic_root backend_bind "$scratch/backends"
register_synthetic_root old_backend_bind "$scratch/old-backends"
register_synthetic_root unrelated_bind "$scratch/models"
register_synthetic_file selinux_metadata "$scratch/selinux.state"
register_synthetic_file invalid_selinux_metadata "$scratch/invalid.state"
register_synthetic_file duplicate_selinux_metadata "$scratch/duplicate.state"
register_synthetic_file readability_config "$scratch/readability.conf"
synthetic_state_root="$(synthetic_root state)"
synthetic_project_root="$(synthetic_root project)"
synthetic_backend_volume="$(synthetic_root backend_volume)"
synthetic_backend_bind="$(synthetic_root backend_bind)"
synthetic_old_backend_bind="$(synthetic_root old_backend_bind)"
synthetic_unrelated_bind="$(synthetic_root unrelated_bind)"
synthetic_container_id=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
metadata="$(synthetic_file selinux_metadata)"
invalid_metadata="$(synthetic_file invalid_selinux_metadata)"
duplicate_metadata="$(synthetic_file duplicate_selinux_metadata)"
readability_config="$(synthetic_file readability_config)"

expect_reject() {
  local description="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "expected rejection: $description"; fi
}

# This only examines /etc metadata; no host state is created or modified.
localai_installer_check_config_parent /etc/localai/localai.conf || fail "canonical config parent was rejected"
expect_reject noncanonical-config-parent localai_installer_check_config_parent /etc/unrelated/localai.conf
expect_reject service-data-under-etc localai_installer_validate_managed_path /etc/localai state

expect_reject_with_message() {
  local description="$1" expected_message="$2" output
  shift 2
  if output="$("$@" 2>&1)"; then fail "expected rejection: $description"; fi
  [[ "$output" == *"$expected_message"* ]] || fail "wrong rejection reason for $description: $output"
}

assert_call_order() {
  local file="$1" first="$2" second="$3" third="$4" first_line second_line third_line
  first_line="$(/usr/bin/grep -n -x "$first" "$file" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
  second_line="$(/usr/bin/grep -n -x "$second" "$file" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
  third_line="$(/usr/bin/grep -n -x "$third" "$file" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
  [[ -n "$first_line" && -n "$second_line" && -n "$third_line" ]] || fail "missing lifecycle guard call in $file"
  (( first_line < second_line && second_line < third_line )) || fail "unsafe lifecycle guard order in $file"
}

printf 'Managed path and service account checks\n'
localai_installer_validate_managed_path /var/lib/localai-test state || fail "ordinary dedicated state path rejected"
localai_installer_validate_managed_path /var/lib/localai/models models || fail "LocalAI state descendant rejected"
localai_installer_validate_managed_path "$synthetic_state_root" fixture-state || fail "registered synthetic state root rejected"
localai_installer_validate_managed_path "$synthetic_project_root" fixture-project || fail "registered synthetic project root rejected"
if [[ "$(/usr/bin/realpath -m -- /srv/localai-data)" == /srv/localai-data ]]; then
  localai_installer_validate_managed_path /srv/localai-data data || fail "custom /srv state path rejected"
fi
if [[ "$(/usr/bin/realpath -m -- /opt/localai-data)" == /opt/localai-data ]]; then
  localai_installer_validate_managed_path /opt/localai-data data || fail "custom /opt state path rejected"
fi
expect_reject filesystem-root localai_installer_validate_managed_path / root
expect_reject shared-var-root localai_installer_validate_managed_path /var var
expect_reject system-state-root localai_installer_validate_managed_path /var/lib lib
expect_reject non-localai-var-lib localai_installer_validate_managed_path /var/lib/containers/storage data
expect_reject forbidden-var-lib-sibling localai_installer_validate_managed_path /var/lib/postgresql data
expect_reject etc-descendant localai_installer_validate_managed_path /etc/ssl/private data
expect_reject usr-descendant localai_installer_validate_managed_path /usr/lib/systemd data
expect_reject proc-descendant localai_installer_validate_managed_path /proc/sys data
expect_reject dev-descendant localai_installer_validate_managed_path /dev/dri data
expect_reject run-descendant localai_installer_validate_managed_path /run/user/1000 data
expect_reject tmp-descendant localai_installer_validate_managed_path /tmp/localai data
expect_reject user-home-descendant localai_installer_validate_managed_path /home/test-user/data data
expect_reject logs-descendant localai_installer_validate_managed_path /var/log/journal data
expect_reject traversal localai_installer_validate_managed_path /var/lib/localai/../other traversal
expect_reject root-account localai_installer_validate_service_account_name root service
expect_reject numeric-root-account localai_installer_validate_service_account_name 0 service
mkdir -p "$scratch/real"
ln -s "$scratch/real" "$scratch/link"
expect_reject symlink-path localai_installer_validate_managed_path "$scratch/link/data" symlink

mkdir -p "$scratch/no-op-on-failure"
chmod 0710 "$scratch/no-op-on-failure"
before_owner="$(/usr/bin/stat -c '%u' -- "$scratch/no-op-on-failure")"
before_mode="$(/usr/bin/stat -c '%a' -- "$scratch/no-op-on-failure")"
(
  source "$repo_root/lib/installer_safety.sh"
  localai_installer_validate_managed_path() { return 1; }
  localai_installer_ensure_service_directory "$scratch/no-op-on-failure" blocked "$(id -un)" "$(id -gn)" "$(id -u)" 0700 && exit 1
  [[ "$(/usr/bin/stat -c '%u' -- "$scratch/no-op-on-failure")" == "$before_owner" ]]
  [[ "$(/usr/bin/stat -c '%a' -- "$scratch/no-op-on-failure")" == "$before_mode" ]]
) || fail "service-directory helper changed ownership or mode after path rejection"

printf 'Legacy user-unit parent migration checks\n'
(
  legacy_parent="$scratch/legacy-systemd"
  mkdir -p "$legacy_parent/user"
  chmod 0750 "$legacy_parent"
  chmod 0700 "$legacy_parent/user"
  printf 'managed unit\n' >"$legacy_parent/user/localai.service"
  test_uid="$(id -u)" test_user="$(id -un)" test_group="$(id -gn)"
  # The fixture is in task scratch; only this exact synthetic path is allowed.
  # shellcheck disable=SC2329
  localai_installer_validate_managed_path() {
    [[ "$1" == "$legacy_parent" || "$1" == "$legacy_parent/user" ]]
  }
  # Simulate the legacy root owner while retaining a user-owned scratch fixture.
  # shellcheck disable=SC2329
  localai_installer_systemd_stat() {
    if [[ "$1" == -c && "$2" == %u && "$4" == "$legacy_parent" ]]; then
      printf '0\n'
    else
      /usr/bin/stat "$@"
    fi
  }
  localai_installer_check_user_systemd_parent "$legacy_parent" legacy "$test_uid"
  localai_installer_ensure_user_systemd_parent "$legacy_parent" legacy "$test_user" "$test_group" "$test_uid"
  [[ "$(stat -c %a "$legacy_parent")" == 751 ]]
  [[ "$(<"$legacy_parent/user/localai.service")" == 'managed unit' ]]
  chmod 0750 "$legacy_parent"
  : >"$legacy_parent/unknown"
  expect_reject unknown-legacy-entry localai_installer_check_user_systemd_parent "$legacy_parent" legacy "$test_uid"
  [[ "$(stat -c %a "$legacy_parent")" == 750 ]]
  rm "$legacy_parent/unknown"
  chmod 0755 "$legacy_parent/user"
  expect_reject public-legacy-user-dir localai_installer_check_user_systemd_parent "$legacy_parent" legacy "$test_uid"
  [[ "$(stat -c %a "$legacy_parent")" == 750 ]]
)

printf 'Installer lifecycle guard ordering checks\n'
assert_call_order "$repo_root/secureblue-localai-install/install.sh" \
  preflight_existing_backend_state preflight_user_systemd_parent stop_existing_managed_service
assert_call_order "$repo_root/secureblue-localai-install/install.sh" \
  stop_existing_managed_service remove_preflighted_existing_container ensure_container_userns
assert_call_order "$repo_root/localai-podman-compose/install.sh" \
  preflight_localai_backend_state ensure_user_manager ensure_container_userns
assert_call_order "$repo_root/localai-podman-compose/install.sh" \
  pull_image label_container_state write_caddyfile
assert_call_order "$repo_root/localai-podman-compose/install.sh" \
  label_container_state write_caddyfile validate_caddyfile
assert_call_order "$repo_root/secureblue-localai-install/uninstall.sh" \
  preflight_backend_state stop_service remove_container
assert_call_order "$repo_root/secureblue-localai-install/uninstall.sh" \
  preflight_backend_state confirm_service_account_removal stop_service
assert_call_order "$repo_root/secureblue-localai-install/uninstall.sh" \
  remove_user_subids disable_user_linger remove_state_dir
assert_call_order "$repo_root/localai-podman-compose/uninstall.sh" \
  preflight_removal_targets confirm_tls_service_account_removal stop_service
assert_call_order "$repo_root/localai-podman-compose/uninstall.sh" \
  remove_state disable_tls_user_linger remove_tls_user
! rg -q 'podman_migrate\(\)|/usr/bin/podman system migrate' \
  "$repo_root/secureblue-localai-install/install.sh" "$repo_root/localai-podman-compose/install.sh" || fail "installer still runs automatic account-wide Podman migration"
! rg -q 'podman image rm -f' "$repo_root/secureblue-localai-install/uninstall.sh" || fail "image removal still force-removes containers that use the image"
! rg -q '^ExecStartPre=.*podman rm' "$repo_root/secureblue-localai-install/localai.service.in" || fail "generated LocalAI unit still removes a same-name container unconditionally"
rg -F -q -- '--label=io.localai.secureblue.managed=localai' "$repo_root/secureblue-localai-install/localai.service.in" || fail "generated LocalAI unit is missing its managed-role label"
rg -F -q -- '--label=io.localai.secureblue.state=${LOCALAI_STATE_DIR}' "$repo_root/secureblue-localai-install/localai.service.in" || fail "generated LocalAI unit is missing its state-specific ownership label"
rg -F -q -- '--label=io.localai.secureblue.container=${LOCALAI_CONTAINER_NAME}' "$repo_root/secureblue-localai-install/localai.service.in" || fail "generated LocalAI unit is missing its container-name ownership label"
rg -F -q -- '--filter=label=io.localai.secureblue.managed=localai' "$repo_root/secureblue-localai-install/localai.service.in" || fail "generated LocalAI stop command is missing the managed-role filter"
rg -F -q -- '--filter=label=io.localai.secureblue.state=${LOCALAI_STATE_DIR}' "$repo_root/secureblue-localai-install/localai.service.in" || fail "generated LocalAI stop command is missing the state filter"
rg -F -q -- '--filter=label=io.localai.secureblue.container=${LOCALAI_CONTAINER_NAME}' "$repo_root/secureblue-localai-install/localai.service.in" || fail "generated LocalAI stop command is missing the container-name filter"
unit_state_dir=/var/lib/localai-unit-test
unit_container_name=localai-unit-test
stop_command="$(sed -n 's/^ExecStop=//p' "$repo_root/secureblue-localai-install/localai.service.in" | \
  sed -e "s|\${LOCALAI_STATE_DIR}|$unit_state_dir|g" \
      -e "s|\${LOCALAI_CONTAINER_NAME}|$unit_container_name|g")"
read -r -a actual_stop_argv <<<"$stop_command"
expected_stop_argv=(
  /usr/bin/podman stop -t 30
  --filter=label=io.localai.secureblue.managed=localai
  "--filter=label=io.localai.secureblue.state=$unit_state_dir"
  "--filter=label=io.localai.secureblue.container=$unit_container_name"
)
[[ "${#actual_stop_argv[@]}" -eq "${#expected_stop_argv[@]}" ]] || fail "generated ExecStop argv has an unexpected shape"
for index in "${!expected_stop_argv[@]}"; do
  [[ "${actual_stop_argv[$index]}" == "${expected_stop_argv[$index]}" ]] || fail "generated ExecStop argv does not match the managed label filters"
done

printf 'SELinux rollback metadata parser checks\n'
cat >"$metadata" <<'EOF'
version=1
action=modify
port=8443
previous_type=http_port_t
new_type=systemd_socket_proxyd_port_t
EOF
chmod 0600 "$metadata"
if [[ "$(id -u)" != 0 ]]; then
  expect_reject non-root-owned-rollback-metadata localai_installer_check_root_file "$metadata" "SELinux rollback metadata"
fi
localai_installer_check_root_file() {
  if [[ "$#" == 2 ]]; then
    case "$2" in
      'SELinux rollback metadata')
        if is_registered_synthetic_file selinux_metadata "$1" || \
          is_registered_synthetic_file invalid_selinux_metadata "$1" || \
          is_registered_synthetic_file duplicate_selinux_metadata "$1"; then
          [[ -f "$1" && ! -L "$1" ]]
          return
        fi
        ;;
      'installed configuration')
        if is_registered_synthetic_file readability_config "$1"; then
          [[ -f "$1" && ! -L "$1" ]]
          return
        fi
        ;;
    esac
  fi
  /usr/bin/bash -c 'source "$1"; shift; localai_installer_check_root_file "$@"' \
    -- "$repo_root/lib/installer_safety.sh" "$@"
}
[[ "$(localai_installer_read_selinux_port_state "$metadata")" == 'modify|8443|http_port_t|systemd_socket_proxyd_port_t' ]] || fail "valid rollback metadata was not parsed"
printf 'LOCALAI_BIND_HOST=127.0.0.1\n' >"$readability_config"
chmod 0640 "$readability_config"
expect_reject group-only-readable-config localai_installer_check_root_config_file "$readability_config"
chmod 0644 "$readability_config"
localai_installer_check_root_config_file "$readability_config" || fail "world-readable shared config rejected"
sed 's/new_type=/unknown=/' "$metadata" >"$invalid_metadata"
chmod 0600 "$invalid_metadata"
expect_reject unknown-metadata-key localai_installer_read_selinux_port_state "$invalid_metadata"
cat >"$duplicate_metadata" <<'EOF'
version=1
action=add
action=modify
port=8443
previous_type=
new_type=systemd_socket_proxyd_port_t
EOF
chmod 0600 "$duplicate_metadata"
expect_reject duplicate-metadata-key localai_installer_read_selinux_port_state "$duplicate_metadata"

printf 'Legacy TLS alias precedence checks\n'
cat >"$scratch/config" <<'EOF'
LOCALAI_TLS_ENABLED=false
LOCALAI_TLS_PUBLIC_HOST=canonical-file.example
LOCALAI_TLS_PUBLIC_PORT=9443
EOF
(
  export LOCALAI_TLS_PUBLIC_HOST=canonical-env.example
  export LOCALAI_TLS_BIND_HOST=legacy-env.example
  export LOCALAI_TLS_PUBLIC_PORT=9444
  export LOCALAI_TLS_BIND_PORT=9445
  source "$repo_root/lib/config.sh"
  source "$repo_root/lib/installer_safety.sh"
  localai_installer_load_config "$scratch/config" canonical
  [[ "$LOCALAI_TLS_PUBLIC_HOST" == canonical-env.example ]] || exit 1
  [[ "$LOCALAI_TLS_PUBLIC_PORT" == 9444 ]] || exit 1
) || fail "canonical TLS environment keys did not win over legacy aliases"

printf 'Backend volume preflight checks with multiple mounts\n'
(
  # The test scratch directory is under /var/home, which production correctly
  # rejects as a managed path. Stub only the two path checks for this exact
  # synthetic Podman volume so these assertions exercise its contents. Real
  # protected-path and symlink checks above still use the production helpers.
  localai_installer_validate_managed_path() {
    if [[ "$#" == 2 && "$2" == "legacy backend volume path" ]] && is_registered_synthetic_root backend_volume "$1"; then
      return 0
    fi
    /usr/bin/bash -c 'source "$1"; shift; localai_installer_validate_managed_path "$@"' \
      -- "$repo_root/lib/installer_safety.sh" "$@"
  }
  localai_installer_check_directory_chain() {
    if [[ "$#" == 3 && "$2" == "legacy backend volume path" && "$3" == "$(id -u)" ]] && is_registered_synthetic_root backend_volume "$1"; then
      return 0
    fi
    /usr/bin/bash -c 'source "$1"; shift; localai_installer_check_directory_chain "$@"' \
      -- "$repo_root/lib/installer_safety.sh" "$@"
  }
  expect_reject_with_message unregistered-scratch-volume-path \
    'legacy backend volume path may not be inside a protected system tree' \
    localai_installer_validate_managed_path "$scratch/unregistered-volume" "legacy backend volume path"

  mkdir -p "$synthetic_backend_volume"
  printf 'existing-backend\n' >"$synthetic_backend_volume/marker"
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  fake_podman() {
    [[ "$1" == /usr/bin/podman ]] || return 90
    shift
    case "$1" in
      ps)
        printf 'localai\n'
        ;;
      inspect)
        case "$3" in
          '{{.Id}}') printf '%s\n' "$synthetic_container_id" ;;
          '{{json .Config.Labels}}') printf '{"io.localai.secureblue.managed":"localai","io.localai.secureblue.state":"%s","io.localai.secureblue.container":"localai"}\n' "$synthetic_state_root" ;;
          '{{json .Mounts}}')
            printf '[{"Type":"bind","Name":"","Source":"%s","Destination":"/models"},' "$synthetic_unrelated_bind"
            printf '{"Type":"volume","Name":"backends-id","Source":"%s","Destination":"/backends/models"}]\n' "$synthetic_backend_volume"
            ;;
          *) return 91 ;;
        esac
        ;;
      volume)
        [[ "$2" == inspect ]] || return 92
        printf 'volume-inspect %s\n' "$5" >>"$scratch/podman.calls"
        printf '"%s"\n' "$synthetic_backend_volume"
        ;;
      diff)
        printf 'diff\n' >>"$scratch/podman.calls"
        printf ''
        ;;
      *) return 93 ;;
    esac
  }
  expect_reject_with_message populated-anonymous-backend-volume \
    'has data in anonymous or named /backends volume backends-id' \
    localai_installer_preflight_backend_containers fake_podman "$synthetic_backend_bind" "$(id -u)" "$synthetic_state_root" localai
  rm -f "$synthetic_backend_volume/marker"
  localai_installer_preflight_backend_containers fake_podman "$synthetic_backend_bind" "$(id -u)" "$synthetic_state_root" localai || fail "empty /backends volume was not allowed"
  [[ "$(/usr/bin/grep -c '^volume-inspect backends-id$' "$scratch/podman.calls")" == 2 ]] || fail "both volume-content fixtures did not inspect the synthetic volume"
  [[ "$(/usr/bin/grep -c '^diff$' "$scratch/podman.calls")" == 1 ]] || fail "the empty-volume positive control did not reach the writable-layer check"
) || fail "backend volume preflight fixtures failed"

fake_missing_destination_podman() {
  [[ "$1" == /usr/bin/podman ]] || return 90
  shift
  case "$1" in
    ps) printf 'localai\n' ;;
    inspect)
      case "$3" in
        '{{.Id}}') printf '%s\n' "$synthetic_container_id" ;;
        '{{json .Config.Labels}}') printf '{"io.localai.secureblue.managed":"localai","io.localai.secureblue.state":"%s","io.localai.secureblue.container":"localai"}\n' "$synthetic_state_root" ;;
        '{{json .Mounts}}') printf '[{"Type":"bind","Name":"","Source":"%s/backends"}]\n' "$scratch" ;;
        *) return 91 ;;
      esac
      ;;
    diff) printf '' ;;
    *) return 93 ;;
  esac
}
expect_reject_with_message missing-mount-destination 'has malformed mount metadata' \
localai_installer_preflight_backend_containers fake_missing_destination_podman "$synthetic_backend_bind" "$(id -u)" "$synthetic_state_root" localai

fake_nonlist_mounts_podman() {
  [[ "$1" == /usr/bin/podman ]] || return 90
  shift
  case "$1" in
    ps) printf 'localai\n' ;;
    inspect)
      case "$3" in
        '{{.Id}}') printf '%s\n' "$synthetic_container_id" ;;
        '{{json .Config.Labels}}') printf '{"io.localai.secureblue.managed":"localai","io.localai.secureblue.state":"%s","io.localai.secureblue.container":"localai"}\n' "$synthetic_state_root" ;;
        '{{json .Mounts}}') printf 'false\n' ;;
        *) return 91 ;;
      esac
      ;;
    diff) printf '' ;;
    *) return 93 ;;
  esac
}
expect_reject_with_message non-list-mount-metadata 'has malformed mount metadata' \
  localai_installer_preflight_backend_containers fake_nonlist_mounts_podman "$synthetic_backend_bind" "$(id -u)" "$synthetic_state_root" localai

# The function is called indirectly by a helper or test.
# shellcheck disable=SC2329
fake_podman() {
  [[ "$1" == /usr/bin/podman ]] || return 90
  shift
  case "$1" in
    ps) printf 'localai\n' ;;
    inspect)
      case "$3" in
        '{{.Id}}') printf '%s\n' "$synthetic_container_id" ;;
        '{{json .Config.Labels}}') printf '{"io.localai.secureblue.managed":"localai","io.localai.secureblue.state":"%s","io.localai.secureblue.container":"localai"}\n' "$synthetic_state_root" ;;
        '{{json .Mounts}}') printf '[{"Type":"bind","Name":"","Source":"%s","Destination":"/backends"}]\n' "$synthetic_backend_bind" ;;
        *) return 91 ;;
      esac
      ;;
    diff) printf '' ;;
    *) return 93 ;;
  esac
}
localai_installer_preflight_backend_containers fake_podman "$synthetic_backend_bind" "$(id -u)" "$synthetic_state_root" localai || fail "canonical host-backed /backends mount was rejected"

# The function is called indirectly by a helper or test.
# shellcheck disable=SC2329
fake_podman() {
  [[ "$1" == /usr/bin/podman ]] || return 90
  shift
  case "$1" in
    ps) printf 'localai\n' ;;
    inspect)
      case "$3" in
        '{{.Id}}') printf '%s\n' "$synthetic_container_id" ;;
        '{{json .Config.Labels}}') printf '{"io.localai.secureblue.managed":"localai","io.localai.secureblue.state":"%s","io.localai.secureblue.container":"localai"}\n' "$synthetic_state_root" ;;
        '{{json .Mounts}}') printf '[{"Type":"bind","Name":"","Source":"%s","Destination":"/backends"}]\n' "$synthetic_old_backend_bind" ;;
        *) return 91 ;;
      esac
      ;;
    diff) printf '' ;;
    *) return 93 ;;
  esac
}
expect_reject_with_message changed-bind-source \
  "stores backends at $synthetic_old_backend_bind for /backends, while the new service uses $synthetic_backend_bind" \
  localai_installer_preflight_backend_containers fake_podman "$synthetic_backend_bind" "$(id -u)" "$synthetic_state_root" localai

fake_podman() {
  [[ "$1" == /usr/bin/podman ]] || return 90
  shift
  case "$1" in
    ps) printf 'localai\n' ;;
    inspect)
      case "$3" in
        '{{.Id}}') printf '%s\n' "$synthetic_container_id" ;;
        '{{json .Config.Labels}}') printf '{"io.localai.secureblue.managed":"localai","io.localai.secureblue.state":"%s","io.localai.secureblue.container":"localai"}\n' "$synthetic_state_root" ;;
        '{{json .Mounts}}') printf '[]\n' ;;
        *) return 91 ;;
      esac
      ;;
    diff) printf 'C /backends/downloaded.gguf\n' ;;
    *) return 93 ;;
  esac
}
expect_reject_with_message writable-layer-backend-data 'has writable-layer data under /backends' \
  localai_installer_preflight_backend_containers fake_podman "$synthetic_backend_bind" "$(id -u)" "$synthetic_state_root" localai

printf 'Managed-container ownership integration checks\n'
source_production_function() {
  local source_file="$1" function_name="$2"
  # The source path is selected or generated at runtime.
  # shellcheck disable=SC1090
  source <(/usr/bin/sed -n "/^${function_name}() {$/,/^}/p" "$source_file")
}

printf 'User unit directory ownership checks\n'
(
  source_production_function "$repo_root/secureblue-localai-install/install.sh" install_systemd_service
  source_production_function "$repo_root/localai-podman-compose/install.sh" write_compose_service
  # These stubs keep generated files in scratch and record service-owned directories.
  # shellcheck disable=SC2329
  localai_installer_mktemp_var() { printf -v "$1" '%s' "$scratch/generated-unit"; }
  # shellcheck disable=SC2329
  localai_installer_ensure_service_directory() { printf '%s %s %s %s\n' "$1" "$3" "$4" "$6" >>"$scratch/unit-directories"; }
  # shellcheck disable=SC2329
  localai_installer_ensure_user_systemd_parent() { printf '%s %s %s 0700\n' "$1" "$3" "$4" >>"$scratch/unit-directories"; }
  # shellcheck disable=SC2329
  localai_installer_check_managed_file() { :; }
  # shellcheck disable=SC2329
  localai_tls_render_compose_service_template() { printf '[Service]\n'; }
  # shellcheck disable=SC2329
  run0_pipe() { :; }
  # shellcheck disable=SC2329
  run_as_localai() { :; }
  # shellcheck disable=SC2329
  run_as_tls() { :; }
  # shellcheck disable=SC2329
  restore_existing_service() { :; }
  # shellcheck disable=SC2329
  log() { :; }
  # shellcheck disable=SC2329
  die() { exit 1; }
  # shellcheck disable=SC2329
  localai_image_ref() { printf 'example.invalid/image:cpu\n'; }
  for name in models app_home backends download_staging backend_temp data config generated_content upload cache log; do
    eval "localai_${name}_path() { printf '%s\\n' '$scratch/data'; }"
  done
  # The installer calls these two helpers with different names.
  # shellcheck disable=SC2329
  localai_config_dir() { localai_config_path; }
  # shellcheck disable=SC2329
  localai_backend_temp_dir() { localai_backend_temp_path; }
  # shellcheck disable=SC2329
  localai_cache_dir() { localai_cache_path; }
  # shellcheck disable=SC2329
  localai_log_dir() { localai_log_path; }
  state_dir="$scratch/backend" service_user=test-service service_uid=12345
  # The extracted installer reads this directory indirectly.
  # shellcheck disable=SC2034
  script_dir="$repo_root/secureblue-localai-install"
  : >"$scratch/unit-directories"
  install_systemd_service
  [[ "$(<"$scratch/unit-directories")" == $"$scratch/backend/.config/systemd test-service test-service 0700"$'\n'$"$scratch/backend/.config/systemd/user test-service test-service 0700" ]]
  install_service=1 tls_state_dir="$scratch/tls" tls_user=test-tls tls_uid=12346
  # The extracted TLS installer reads these values indirectly.
  # shellcheck disable=SC2034
  tls_compose_dir="$scratch/compose" tls_compose_file_name=compose.yaml tls_service_name=tls.service tls_project_name=test
  : >"$scratch/unit-directories"
  write_compose_service
  [[ "$(<"$scratch/unit-directories")" == $"$scratch/tls/.config/systemd test-tls test-tls 0700"$'\n'$"$scratch/tls/.config/systemd/user test-tls test-tls 0700" ]]
) || fail "generated user units lack service-owned parent directories"

printf 'Backend install and upgrade state checks\n'
(
  source_production_function "$repo_root/secureblue-localai-install/install.sh" snapshot_existing_service_state
  source_production_function "$repo_root/secureblue-localai-install/install.sh" stop_existing_managed_service
  source_production_function "$repo_root/secureblue-localai-install/install.sh" restore_existing_service
  # The functions below are called by the production helpers.
  # shellcheck disable=SC2329
  log() { :; }
  # shellcheck disable=SC2329
  die() { return 1; }
  # shellcheck disable=SC2329
  run_as_localai() {
    case "${*:3}" in
      'is-active localai.service') printf '%s\n' "$mock_active"; [[ "$mock_active" == active ]] && return 0; return 3 ;;
      'stop localai.service'|'start localai.service') printf '%s\n' "${*:3}" >>"$scratch/state-calls" ;;
      *) return 1 ;;
    esac
  }
  install_service=1 start_service=1 existing_service_unit=1
  for mock_enabled in enabled disabled; do
    for mock_active in active inactive; do
      : >"$scratch/state-calls"
      existing_service_active=0
      snapshot_existing_service_state
      stop_existing_managed_service
      restore_existing_service
      if [[ "$mock_active" == active ]]; then
        [[ "$(<"$scratch/state-calls")" == $'stop localai.service\nstart localai.service' ]]
      else
        [[ ! -s "$scratch/state-calls" ]]
      fi
      [[ "$mock_enabled" == enabled || "$mock_enabled" == disabled ]]
    done
  done
  existing_service_unit=0 existing_service_active=0
  : >"$scratch/state-calls"
  snapshot_existing_service_state
  stop_existing_managed_service
  restore_existing_service
  [[ ! -s "$scratch/state-calls" ]]
  existing_service_unit=1 mock_active=activating
  if snapshot_existing_service_state; then exit 1; fi
) || fail "backend fresh or upgrade state changed unexpectedly"

printf 'TLS install and upgrade state checks\n'
(
  source_production_function "$repo_root/localai-podman-compose/install.sh" localai_service_lifecycle_requested
  source_production_function "$repo_root/localai-podman-compose/install.sh" guard_tls_manager_start
  source_production_function "$repo_root/localai-podman-compose/install.sh" preserve_linked_service_states
  # These functions are called by the production helpers.
  # shellcheck disable=SC2329
  log() { :; }
  # shellcheck disable=SC2329
  die() { exit 1; }
  # shellcheck disable=SC2329
  run_as_tls() { exit 1; }
  # shellcheck disable=SC2329
  run_as_localai() { exit 1; }
  # shellcheck disable=SC2329
  run0_pipe() { exit 1; }
  # shellcheck disable=SC2329
  localai_installer_user_manager_is_active() { return "$manager_status"; }
  install_service=1 start_service=1 rebind_localai_loopback=0
  if localai_service_lifecycle_requested; then exit 1; fi
  # The production helper consumes this value indirectly.
  # shellcheck disable=SC2034
  rebind_localai_loopback=1
  localai_service_lifecycle_requested
  for enabled in enabled disabled; do
    for running in active inactive; do
      preserve_linked_service_states
      [[ "$enabled" == enabled || "$enabled" == disabled ]]
      [[ "$running" == active || "$running" == inactive ]]
    done
  done
  tls_state_dir="$scratch/tls-state" tls_service_name=localai-tls-compose.service legacy_tls_service_name=localai-tls.service tls_uid=955
  mkdir -p "$tls_state_dir/.config/systemd/user"
  manager_status=3
  guard_tls_manager_start
  : >"$tls_state_dir/.config/systemd/user/$tls_service_name"
  if (guard_tls_manager_start); then exit 1; fi
  rm "$tls_state_dir/.config/systemd/user/$tls_service_name"
  : >"$tls_state_dir/.config/systemd/user/$legacy_tls_service_name"
  if (guard_tls_manager_start); then exit 1; fi
  manager_status=0
  guard_tls_manager_start
  manager_status=1
  if (guard_tls_manager_start); then exit 1; fi
) || fail "TLS fresh or upgrade state changed unexpectedly"

TEST_CONTAINER_STATE_DIR="$synthetic_state_root"
TEST_CONTAINER_BACKENDS="$synthetic_state_root/backends"
TEST_CONTAINER_ID="$synthetic_container_id"
TEST_REPLACEMENT_CONTAINER_ID=fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210
TEST_CONTAINER_LABELS='{}'
TEST_CONTAINER_CALLS="$scratch/container-lifecycle.calls"

fake_container_runner() {
  [[ "$1" == /usr/bin/podman ]] || return 90
  shift
  # Separate redirects keep the test operations explicit.
  # shellcheck disable=SC2129
  printf 'podman' >>"$TEST_CONTAINER_CALLS"
  printf ' %q' "$@" >>"$TEST_CONTAINER_CALLS"
  printf '\n' >>"$TEST_CONTAINER_CALLS"
  case "$1" in
    ps)
      printf 'localai\n'
      ;;
    inspect)
      case "$3" in
        '{{.Id}}') printf '%s\n' "$TEST_CONTAINER_ID" ;;
        '{{json .Config.Labels}}') printf '%s\n' "$TEST_CONTAINER_LABELS" ;;
        '{{json .Mounts}}')
          printf '[{"Type":"bind","Name":"","Source":"%s","Destination":"/backends"}]\n' "$TEST_CONTAINER_BACKENDS"
          ;;
        *) return 91 ;;
      esac
      ;;
      diff)
      # Ordinary unmounted cache/temp writes are ephemeral for a managed
      # --rm container; they do not establish ownership of a name collision.
      printf 'C /tmp/localai-cache-entry\n'
      ;;
    rm)
      return 0
      ;;
    *) return 92 ;;
  esac
}

run_install_preflight_sequence() {
  (
    TEST_CONTAINER_LABELS="$1"
    TEST_CONTAINER_CALLS="$2"
    TEST_CONTAINER_ID="$synthetic_container_id"
    source_production_function "$repo_root/secureblue-localai-install/install.sh" preflight_existing_backend_state
    source_production_function "$repo_root/secureblue-localai-install/install.sh" stop_existing_managed_service
    source_production_function "$repo_root/secureblue-localai-install/install.sh" remove_preflighted_existing_container
    service_uid=955
    # The value is consumed by a sourced or dynamically extracted helper.
    # shellcheck disable=SC2034
    service_user_created=0
    state_dir="$TEST_CONTAINER_STATE_DIR"
    # The value is consumed by a sourced or dynamically extracted helper.
    # shellcheck disable=SC2034
    existing_service_unit=0
    # Simulate a running managed service after the ownership preflight.
    # shellcheck disable=SC2034
    existing_service_active=1
    # The value is consumed by a sourced or dynamically extracted helper.
    # shellcheck disable=SC2034
    install_service=1
    # The value is consumed by a sourced or dynamically extracted helper.
    # shellcheck disable=SC2034
    start_service=1
    LOCALAI_CONTAINER_NAME=localai
    # The function is called indirectly by a helper or test.
    # shellcheck disable=SC2329
    localai_backends_path() { printf '%s\n' "$TEST_CONTAINER_BACKENDS"; }
    # The function is called indirectly by a helper or test.
    # shellcheck disable=SC2329
    localai_installer_user_manager_is_active() { return 0; }
    # The function is called indirectly by a helper or test.
    # shellcheck disable=SC2329
    run_as_localai() { fake_container_runner "$@"; }
    # The function is called indirectly by a helper or test.
    # shellcheck disable=SC2329
    log() { :; }
    # The function is called indirectly by a helper or test.
    # shellcheck disable=SC2329
    die() { printf 'ERROR: %s\n' "$*" >&2; return 1; }
    ensure_user_manager() { printf 'manager-start\n' >>"$TEST_CONTAINER_CALLS"; }
    preflight_existing_backend_state && ensure_user_manager && \
      stop_existing_managed_service && {
        TEST_CONTAINER_ID="$TEST_REPLACEMENT_CONTAINER_ID"
        remove_preflighted_existing_container
      }
  )
}

run_uninstall_preflight_sequence() {
  (
    TEST_CONTAINER_LABELS="$1"
    # The subshell change is isolated deliberately.
    # shellcheck disable=SC2030
    TEST_CONTAINER_CALLS="$2"
    TEST_CONTAINER_ID="$synthetic_container_id"
    source_production_function "$repo_root/secureblue-localai-install/uninstall.sh" preflight_backend_state
    source_production_function "$repo_root/secureblue-localai-install/uninstall.sh" stop_service
    source_production_function "$repo_root/secureblue-localai-install/uninstall.sh" run_localai_unit
    source_production_function "$repo_root/secureblue-localai-install/uninstall.sh" remove_container
    service_uid=955
    service_user=localai
    # The value is consumed by a sourced or dynamically extracted helper.
    # shellcheck disable=SC2034
    container_name=localai
    state_dir="$TEST_CONTAINER_STATE_DIR"
    # The value is consumed by a sourced or dynamically extracted helper.
    # shellcheck disable=SC2034
    purge_state=1
    # The value is consumed by a sourced or dynamically extracted helper.
    # shellcheck disable=SC2034
    purge_state_confirmed=0
    # The value is consumed by a sourced or dynamically extracted helper.
    # shellcheck disable=SC2034
    LOCALAI_CONTAINER_NAME=localai
    # The function is called indirectly by a helper or test.
    # shellcheck disable=SC2329
    localai_installer_user_manager_is_active() { return 0; }
    # The function is called indirectly by a helper or test.
    # shellcheck disable=SC2329
    run_as_localai() {
      if [[ "$1" == /usr/bin/podman ]]; then
        fake_container_runner "$@"
      else
        # Separate redirects keep the test operations explicit.
        # shellcheck disable=SC2129
        printf 'lifecycle %q' "$1" >>"$TEST_CONTAINER_CALLS"
        printf ' %q' "${@:2}" >>"$TEST_CONTAINER_CALLS"
        printf '\n' >>"$TEST_CONTAINER_CALLS"
        return 0
      fi
    }
    # The function is called indirectly by a helper or test.
    # shellcheck disable=SC2329
    confirm() { printf 'purge-confirmed\n' >>"$TEST_CONTAINER_CALLS"; return 0; }
    # The function is called indirectly by a helper or test.
    # shellcheck disable=SC2329
    log() { :; }
    # The function is called indirectly by a helper or test.
    # shellcheck disable=SC2329
    die() { printf 'ERROR: %s\n' "$*" >&2; return 1; }
    preflight_backend_state && {
      TEST_CONTAINER_ID="$TEST_REPLACEMENT_CONTAINER_ID"
      stop_service && remove_container
    }
  )
}

managed_state_labels="$(printf '{"io.localai.secureblue.managed":"localai","io.localai.secureblue.state":"%s","io.localai.secureblue.container":"localai"}' "$TEST_CONTAINER_STATE_DIR")"
wrong_state_labels='{"io.localai.secureblue.managed":"localai","io.localai.secureblue.state":"/var/lib/localai-other","io.localai.secureblue.container":"localai"}'

# The subshell change is isolated deliberately.
# shellcheck disable=SC2031
: >"$TEST_CONTAINER_CALLS"
# The subshell change is isolated deliberately.
# shellcheck disable=SC2031
expect_reject_with_message install-unowned-name-collision \
  "container localai is not marked for LocalAI state $TEST_CONTAINER_STATE_DIR" \
  run_install_preflight_sequence '{}' "$TEST_CONTAINER_CALLS"
# The subshell change is isolated deliberately.
# shellcheck disable=SC2031
! rg -q 'podman diff|podman rm|podman stop|podman run|manager-start|lifecycle' "$TEST_CONTAINER_CALLS" || fail "install continued past unowned container collision"

# The subshell change is isolated deliberately.
# shellcheck disable=SC2031
: >"$TEST_CONTAINER_CALLS"
# The subshell change is isolated deliberately.
# shellcheck disable=SC2031
expect_reject_with_message install-wrong-state-container \
  "container localai is not marked for LocalAI state $TEST_CONTAINER_STATE_DIR" \
  run_install_preflight_sequence "$wrong_state_labels" "$TEST_CONTAINER_CALLS"
# The subshell change is isolated deliberately.
# shellcheck disable=SC2031
! rg -q 'podman diff|podman rm|podman stop|podman run|manager-start|lifecycle' "$TEST_CONTAINER_CALLS" || fail "install accepted container state for another deployment"

# The subshell change is isolated deliberately.
# shellcheck disable=SC2031
: >"$TEST_CONTAINER_CALLS"
wrong_role_labels="$(printf '{\"io.localai.secureblue.managed\":\"other\",\"io.localai.secureblue.state\":\"%s\",\"io.localai.secureblue.container\":\"localai\"}' "$TEST_CONTAINER_STATE_DIR")"
# The subshell change is isolated deliberately.
# shellcheck disable=SC2031
expect_reject_with_message install-wrong-role-container \
  "container localai is not marked for LocalAI state $TEST_CONTAINER_STATE_DIR" \
  run_install_preflight_sequence "$wrong_role_labels" "$TEST_CONTAINER_CALLS"
# The subshell change is isolated deliberately.
# shellcheck disable=SC2031
! rg -q 'podman diff|podman rm|podman stop|podman run|manager-start|lifecycle' "$TEST_CONTAINER_CALLS" || fail "install accepted a container with a different role label"

# The subshell change is isolated deliberately.
# shellcheck disable=SC2031
: >"$TEST_CONTAINER_CALLS"
wrong_container_labels="$(printf '{\"io.localai.secureblue.managed\":\"localai\",\"io.localai.secureblue.state\":\"%s\",\"io.localai.secureblue.container\":\"other\"}' "$TEST_CONTAINER_STATE_DIR")"
# The subshell change is isolated deliberately.
# shellcheck disable=SC2031
expect_reject_with_message install-wrong-container-label \
  "container localai is not marked for LocalAI state $TEST_CONTAINER_STATE_DIR" \
  run_install_preflight_sequence "$wrong_container_labels" "$TEST_CONTAINER_CALLS"
# The subshell change is isolated deliberately.
# shellcheck disable=SC2031
! rg -q 'podman diff|podman rm|podman stop|podman run|manager-start|lifecycle' "$TEST_CONTAINER_CALLS" || fail "install accepted a different container-name ownership label"

# The subshell change is isolated deliberately.
# shellcheck disable=SC2031
: >"$TEST_CONTAINER_CALLS"
# The subshell change is isolated deliberately.
# shellcheck disable=SC2031
run_install_preflight_sequence "$managed_state_labels" "$TEST_CONTAINER_CALLS" || fail "install rejected a matching managed container with ephemeral /tmp data"
# The subshell change is isolated deliberately.
# shellcheck disable=SC2031
rg -q "^podman diff $synthetic_container_id$" "$TEST_CONTAINER_CALLS" || fail "matching managed install did not reach writable-layer validation by ID"
# The subshell change is isolated deliberately.
# shellcheck disable=SC2031
rg -q '^manager-start$' "$TEST_CONTAINER_CALLS" || fail "matching managed install did not proceed after preflight"
# The subshell change is isolated deliberately.
# shellcheck disable=SC2031
rg -q "^podman rm -f $synthetic_container_id$" "$TEST_CONTAINER_CALLS" || fail "matching managed install did not remove its preflight-checked container ID"

# The subshell change is isolated deliberately.
# shellcheck disable=SC2031
: >"$TEST_CONTAINER_CALLS"
# The subshell change is isolated deliberately.
# shellcheck disable=SC2031
expect_reject_with_message uninstall-unowned-name-collision-even-with-purge \
  "container localai is not marked for LocalAI state $TEST_CONTAINER_STATE_DIR" \
  run_uninstall_preflight_sequence '{}' "$TEST_CONTAINER_CALLS"
# The subshell change is isolated deliberately.
# shellcheck disable=SC2031
rg -q '^purge-confirmed$' "$TEST_CONTAINER_CALLS" || fail "purge fixture did not exercise the explicit confirmation path"
# The subshell change is isolated deliberately.
# shellcheck disable=SC2031
! rg -q 'podman diff|podman rm|podman stop|podman run|lifecycle' "$TEST_CONTAINER_CALLS" || fail "uninstall purge bypassed container ownership preflight"

# The subshell change is isolated deliberately.
# shellcheck disable=SC2031
: >"$TEST_CONTAINER_CALLS"
# The subshell change is isolated deliberately.
# shellcheck disable=SC2031
expect_reject_with_message uninstall-wrong-state-container-even-with-purge \
  "container localai is not marked for LocalAI state $TEST_CONTAINER_STATE_DIR" \
  run_uninstall_preflight_sequence "$wrong_state_labels" "$TEST_CONTAINER_CALLS"
# The subshell change is isolated deliberately.
# shellcheck disable=SC2031
! rg -q 'podman diff|podman rm|podman stop|podman run|lifecycle' "$TEST_CONTAINER_CALLS" || fail "uninstall accepted a container owned by another state path"

# The subshell change is isolated deliberately.
# shellcheck disable=SC2031
: >"$TEST_CONTAINER_CALLS"
# The subshell change is isolated deliberately.
# shellcheck disable=SC2031
run_uninstall_preflight_sequence "$managed_state_labels" "$TEST_CONTAINER_CALLS" || fail "uninstall rejected a matching managed container with ephemeral /tmp data"
# The subshell change is isolated deliberately.
# shellcheck disable=SC2031
rg -q "^podman diff $synthetic_container_id$" "$TEST_CONTAINER_CALLS" || fail "matching managed uninstall did not reach writable-layer validation by ID"
# The subshell change is isolated deliberately.
# shellcheck disable=SC2031
rg -q '^lifecycle /usr/bin/systemctl --user disable --now localai.service$' "$TEST_CONTAINER_CALLS" || fail "matching managed uninstall did not stop its service"
# The subshell change is isolated deliberately.
# shellcheck disable=SC2031
rg -q "^podman rm -f $synthetic_container_id$" "$TEST_CONTAINER_CALLS" || fail "matching managed uninstall did not remove its preflight-checked container ID"

printf 'No account-wide migration or image-force cleanup checks\n'
! rg -q '/usr/bin/podman system migrate|podman_migrate\(\)' \
  "$repo_root/secureblue-localai-install/install.sh" "$repo_root/localai-podman-compose/install.sh" || fail "automatic account-wide Podman migration remains active"

TEST_SUBID_CALLS="$scratch/subid.calls"
run_backend_existing_storage_subid_guard() (
  source_production_function "$repo_root/secureblue-localai-install/install.sh" ensure_subids
  state_dir="$scratch/backend-existing-storage"
  mkdir -p "$state_dir/.local/share/containers/storage"
  service_user=localai
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  has_subid() { return 1; }
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  find_common_subid_range() { printf '200000-265535\n'; }
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  subid_line() { :; }
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  confirm() { printf 'unexpected-confirm\n' >>"$TEST_SUBID_CALLS"; return 0; }
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  log() { :; }
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  run0_pipe() { printf '%s\n' "$*" >>"$TEST_SUBID_CALLS"; }
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
  ensure_subids
)

run_tls_existing_storage_subid_guard() (
  source_production_function "$repo_root/localai-podman-compose/install.sh" ensure_subids
  tls_state_dir="$scratch/tls-existing-storage"
  mkdir -p "$tls_state_dir/.local/share/containers/storage"
  tls_user=localai-tls
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  has_subid() { return 1; }
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  find_common_subid_range() { printf '200000-265535\n'; }
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  subid_line() { :; }
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  confirm() { printf 'unexpected-confirm\n' >>"$TEST_SUBID_CALLS"; return 0; }
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  log() { :; }
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  run0_pipe() { printf '%s\n' "$*" >>"$TEST_SUBID_CALLS"; }
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
  ensure_subids
)

run_backend_fresh_subid_add() (
  source_production_function "$repo_root/secureblue-localai-install/install.sh" ensure_subids
  state_dir="$scratch/backend-fresh-account"
  service_user=localai
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  has_subid() { return 1; }
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  find_common_subid_range() { printf '200000-265535\n'; }
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  subid_line() { :; }
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  confirm() { return 0; }
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  log() { :; }
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  run0_pipe() { printf '%s\n' "$*" >>"$TEST_SUBID_CALLS"; }
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
  ensure_subids
)

run_tls_fresh_subid_add() (
  source_production_function "$repo_root/localai-podman-compose/install.sh" ensure_subids
  tls_state_dir="$scratch/tls-fresh-account"
  tls_user=localai-tls
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  has_subid() { return 1; }
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  find_common_subid_range() { printf '200000-265535\n'; }
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  subid_line() { :; }
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  confirm() { return 0; }
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  log() { :; }
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  run0_pipe() { printf '%s\n' "$*" >>"$TEST_SUBID_CALLS"; }
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
  ensure_subids
)

: >"$TEST_SUBID_CALLS"
expect_reject_with_message backend-existing-storage-needs-manual-id-migration \
  "Existing Podman storage for localai needs subordinate IDs" run_backend_existing_storage_subid_guard
expect_reject_with_message tls-existing-storage-needs-manual-id-migration \
  "Existing Podman storage for localai-tls needs subordinate IDs" run_tls_existing_storage_subid_guard
[[ ! -s "$TEST_SUBID_CALLS" ]] || fail "existing-storage migration refusal prompted or changed subordinate IDs"
: >"$TEST_SUBID_CALLS"
run_backend_fresh_subid_add || fail "fresh backend account could not add subordinate IDs"
run_tls_fresh_subid_add || fail "fresh TLS account could not add subordinate IDs"
rg -q '^/usr/sbin/usermod --add-subuids 200000-265535 --add-subgids 200000-265535 localai$' "$TEST_SUBID_CALLS" || fail "fresh backend account did not use the expected scoped usermod call"
rg -q '^/usr/sbin/usermod --add-subuids 200000-265535 --add-subgids 200000-265535 localai-tls$' "$TEST_SUBID_CALLS" || fail "fresh TLS account did not use the expected scoped usermod call"

TEST_ACCOUNT_CALLS="$scratch/account.calls"
run_backend_disable_linger_only() (
  source_production_function "$repo_root/secureblue-localai-install/uninstall.sh" disable_user_linger
  service_uid=955
  service_user=localai
  disable_linger=1
  remove_user=0
  remove_user_confirmed=0
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  log() { :; }
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  run0_pipe() { printf '%s\n' "$*" >>"$TEST_ACCOUNT_CALLS"; }
  disable_user_linger
)

run_backend_approved_user_removal() (
  source_production_function "$repo_root/secureblue-localai-install/uninstall.sh" disable_user_linger
  service_uid=955
  service_user=localai
  disable_linger=1
  remove_user=1
  remove_user_confirmed=1
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  log() { :; }
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  run0_pipe() { printf '%s\n' "$*" >>"$TEST_ACCOUNT_CALLS"; }
  disable_user_linger
)

run_backend_unapproved_user_removal() (
  source_production_function "$repo_root/secureblue-localai-install/uninstall.sh" disable_user_linger
  service_uid=955
  service_user=localai
  # The value is consumed by a sourced or dynamically extracted helper.
  # shellcheck disable=SC2034
  disable_linger=1
  remove_user=1
  remove_user_confirmed=0
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  log() { :; }
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  run0_pipe() { printf '%s\n' "$*" >>"$TEST_ACCOUNT_CALLS"; }
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
  disable_user_linger
)

run_tls_approved_user_removal() (
  source_production_function "$repo_root/localai-podman-compose/uninstall.sh" disable_tls_user_linger
  tls_uid=956
  tls_user=localai-tls
  remove_user=1
  remove_user_confirmed=1
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  log() { :; }
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  run0_pipe() { printf '%s\n' "$*" >>"$TEST_ACCOUNT_CALLS"; }
  disable_tls_user_linger
)

run_tls_unapproved_user_removal() (
  source_production_function "$repo_root/localai-podman-compose/uninstall.sh" disable_tls_user_linger
  tls_uid=956
  tls_user=localai-tls
  remove_user=1
  remove_user_confirmed=0
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  log() { :; }
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  run0_pipe() { printf '%s\n' "$*" >>"$TEST_ACCOUNT_CALLS"; }
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
  disable_tls_user_linger
)

run_backend_user_delete_after_approval() (
  source_production_function "$repo_root/secureblue-localai-install/uninstall.sh" remove_service_user
  service_uid=955
  service_user=localai
  remove_user=1
  remove_user_confirmed=1
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  getent() { return 0; }
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  confirm() { printf 'unexpected-late-confirmation\n' >>"$TEST_ACCOUNT_CALLS"; return 1; }
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  log() { :; }
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  run0_pipe() { printf '%s\n' "$*" >>"$TEST_ACCOUNT_CALLS"; }
  remove_service_user
)

run_tls_user_delete_after_approval() (
  source_production_function "$repo_root/localai-podman-compose/uninstall.sh" remove_tls_user
  tls_uid=956
  tls_user=localai-tls
  remove_user=1
  remove_user_confirmed=1
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  getent() { return 0; }
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  confirm() { printf 'unexpected-late-confirmation\n' >>"$TEST_ACCOUNT_CALLS"; return 1; }
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  log() { :; }
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  run0_pipe() { printf '%s\n' "$*" >>"$TEST_ACCOUNT_CALLS"; }
  remove_tls_user
)

: >"$TEST_ACCOUNT_CALLS"
run_backend_disable_linger_only || fail "disable-linger-only path failed"
rg -qx '/usr/bin/loginctl disable-linger localai' "$TEST_ACCOUNT_CALLS" || fail "disable-linger-only did not disable linger"
! rg -q 'terminate-user' "$TEST_ACCOUNT_CALLS" || fail "disable-linger-only terminated all service-user processes"

: >"$TEST_ACCOUNT_CALLS"
expect_reject_with_message backend-process-termination-requires-confirmation \
  "Refusing to terminate service-account processes without prior confirmation" \
  run_backend_unapproved_user_removal
[[ ! -s "$TEST_ACCOUNT_CALLS" ]] || fail "backend user removal changed logind state before account confirmation"

: >"$TEST_ACCOUNT_CALLS"
run_backend_approved_user_removal || fail "explicit backend account removal lifecycle failed"
[[ "$(wc -l <"$TEST_ACCOUNT_CALLS")" -eq 2 ]] || fail "explicit backend account removal emitted an unexpected process-lifecycle command count"
rg -qx '/usr/bin/loginctl terminate-user localai' "$TEST_ACCOUNT_CALLS" || fail "approved backend account removal did not terminate service-user processes"
[[ "$(sed -n '1p' "$TEST_ACCOUNT_CALLS")" == '/usr/bin/loginctl disable-linger localai' ]] || fail "backend removal did not disable linger before termination"
[[ "$(sed -n '2p' "$TEST_ACCOUNT_CALLS")" == '/usr/bin/loginctl terminate-user localai' ]] || fail "backend removal did not terminate only after explicit approval"
: >"$TEST_ACCOUNT_CALLS"
run_backend_user_delete_after_approval || fail "approved backend account deletion failed"
rg -qx '/usr/sbin/userdel localai' "$TEST_ACCOUNT_CALLS" || fail "backend account was not deleted after approval"
! rg -q 'unexpected-late-confirmation' "$TEST_ACCOUNT_CALLS" || fail "backend uninstaller prompted after process termination"

: >"$TEST_ACCOUNT_CALLS"
expect_reject_with_message tls-process-termination-requires-confirmation \
  "Refusing to terminate TLS service-account processes without prior confirmation" \
  run_tls_unapproved_user_removal
[[ ! -s "$TEST_ACCOUNT_CALLS" ]] || fail "TLS user removal changed logind state before account confirmation"

: >"$TEST_ACCOUNT_CALLS"
run_tls_approved_user_removal || fail "explicit TLS account removal lifecycle failed"
[[ "$(wc -l <"$TEST_ACCOUNT_CALLS")" -eq 2 ]] || fail "explicit TLS account removal emitted an unexpected process-lifecycle command count"
[[ "$(sed -n '1p' "$TEST_ACCOUNT_CALLS")" == '/usr/bin/loginctl disable-linger localai-tls' ]] || fail "TLS removal did not disable linger before termination"
[[ "$(sed -n '2p' "$TEST_ACCOUNT_CALLS")" == '/usr/bin/loginctl terminate-user localai-tls' ]] || fail "TLS removal did not terminate after explicit approval"
: >"$TEST_ACCOUNT_CALLS"
run_tls_user_delete_after_approval || fail "approved TLS account deletion failed"
rg -qx '/usr/sbin/userdel localai-tls' "$TEST_ACCOUNT_CALLS" || fail "TLS account was not deleted after approval"
! rg -q 'unexpected-late-confirmation' "$TEST_ACCOUNT_CALLS" || fail "TLS uninstaller prompted after process termination"

run_backend_account_removal_confirmation() (
  source_production_function "$repo_root/secureblue-localai-install/uninstall.sh" confirm_service_account_removal
  service_uid=955
  service_user=localai
  remove_user=1
  remove_user_confirmed=0
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  confirm() { printf 'PROMPT: %s\n' "$1"; return 0; }
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
  confirm_service_account_removal
  [[ "$remove_user_confirmed" == 1 ]]
)

run_tls_account_removal_confirmation() (
  source_production_function "$repo_root/localai-podman-compose/uninstall.sh" confirm_tls_service_account_removal
  tls_uid=956
  tls_user=localai-tls
  remove_user=1
  remove_user_confirmed=0
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  confirm() { printf 'PROMPT: %s\n' "$1"; return 0; }
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
  confirm_tls_service_account_removal
  [[ "$remove_user_confirmed" == 1 ]]
)

run_backend_yes_account_removal_confirmation() (
  source_production_function "$repo_root/secureblue-localai-install/uninstall.sh" confirm
  source_production_function "$repo_root/secureblue-localai-install/uninstall.sh" confirm_service_account_removal
  assume_yes=1
  service_uid=955
  service_user=localai
  remove_user=1
  remove_user_confirmed=0
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
  confirm_service_account_removal
  printf 'confirmed=%s\n' "$remove_user_confirmed"
)

run_tls_yes_account_removal_confirmation() (
  source_production_function "$repo_root/localai-podman-compose/uninstall.sh" confirm
  source_production_function "$repo_root/localai-podman-compose/uninstall.sh" confirm_tls_service_account_removal
  # The value is consumed by a sourced or dynamically extracted helper.
  # shellcheck disable=SC2034
  assume_yes=1
  # The value is consumed by a sourced or dynamically extracted helper.
  # shellcheck disable=SC2034
  tls_uid=956
  # The value is consumed by a sourced or dynamically extracted helper.
  # shellcheck disable=SC2034
  tls_user=localai-tls
  # The value is consumed by a sourced or dynamically extracted helper.
  # shellcheck disable=SC2034
  remove_user=1
  remove_user_confirmed=0
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
  confirm_tls_service_account_removal
  printf 'confirmed=%s\n' "$remove_user_confirmed"
)

backend_account_prompt="$(run_backend_account_removal_confirmation)"
tls_account_prompt="$(run_tls_account_removal_confirmation)"
[[ "$backend_account_prompt" == *"terminates every process running as the account, including unrelated containers and services"* ]] || fail "backend account-removal confirmation omitted its account-wide scope"
[[ "$tls_account_prompt" == *"terminates every process running as the account, including unrelated containers and services"* ]] || fail "TLS account-removal confirmation omitted its account-wide scope"
[[ "$(run_backend_yes_account_removal_confirmation)" == 'confirmed=1' ]] || fail "--yes did not supply the explicit backend account-removal confirmation"
[[ "$(run_tls_yes_account_removal_confirmation)" == 'confirmed=1' ]] || fail "--yes did not supply the explicit TLS account-removal confirmation"

TEST_IMAGE_CALLS="$scratch/image-remove.calls"
TEST_IMAGE_OUTPUT="$scratch/image-remove.output"
run_image_removal_with_in_use_container() (
  source_production_function "$repo_root/secureblue-localai-install/uninstall.sh" remove_local_image
  # The value is consumed by a sourced or dynamically extracted helper.
  # shellcheck disable=SC2034
  remove_image=1
  # The value is consumed by a sourced or dynamically extracted helper.
  # shellcheck disable=SC2034
  service_uid=955
  # The value is consumed by a sourced or dynamically extracted helper.
  # shellcheck disable=SC2034
  image_ref=docker.io/localai/localai:test
  # The value is consumed by a sourced or dynamically extracted helper.
  # shellcheck disable=SC2034
  service_user=localai
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  confirm() { return 0; }
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  log() { printf '%s\n' "$*" >>"$TEST_IMAGE_OUTPUT"; }
  # The function is called indirectly by a helper or test.
  # shellcheck disable=SC2329
  run_localai_unit() {
    printf '%s\n' "$*" >>"$TEST_IMAGE_CALLS"
    printf 'Error: image is in use by another container\n' >&2
    return 2
  }
  remove_local_image
)
: >"$TEST_IMAGE_CALLS"
: >"$TEST_IMAGE_OUTPUT"
run_image_removal_with_in_use_container || fail "optional image removal did not preserve an image used by a container"
rg -qx '/usr/bin/podman image rm docker.io/localai/localai:test' "$TEST_IMAGE_CALLS" || fail "image removal argv was not scoped to the selected image without force"
! rg -q ' -f( |$)|--force' "$TEST_IMAGE_CALLS" || fail "image removal could still force-delete containers"
rg -q 'Podman retained the image.*No containers were force-removed' "$TEST_IMAGE_OUTPUT" || fail "in-use image refusal was not reported clearly"

printf 'run0 login-shell re-exec environment propagation\n'
[[ "$(id -u)" != 0 ]] || fail "run this stubbed elevation test as the normal desktop user, not root"
mkdir -p "$scratch/bin"
cat >"$scratch/probe.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${LOCALAI_TEST_ELEVATED:-}" == 1 ]]
[[ "${LOCALAI_TEST_UNEXPECTED+x}" != x ]]
[[ "${LOCALAI_BIND_HOST:-}" == 192.0.2.43 ]]
[[ "${LOCALAI_TLS_PUBLIC_HOST:-}" == canonical-env.example ]]
[[ "${LOCALAI_TLS_BIND_HOST:-}" == legacy-env.example ]]
[[ "${LOCALAI_CONFIG_FILE:-}" == "$LOCALAI_TEST_EXPECTED_CONFIG" ]]
[[ "${LOCALAI_STATE_DIR:-}" == "$LOCALAI_TEST_EXPECTED_STATE" ]]
[[ "${LOCALAI_ASSET_DIR:-}" == "$LOCALAI_TEST_EXPECTED_ASSET" ]]
[[ "${LOCALAI_PROJECT_DIR:-}" == "$LOCALAI_TEST_EXPECTED_PROJECT" ]]
EOF
cat >"$scratch/bin/run0" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == -i ]] || exit 90
shift
[[ "${1:-}" == /usr/bin/env ]] || exit 91
shift
env_args=()
while [[ "$#" -gt 0 && "$1" != /usr/bin/bash ]]; do
  env_args+=("$1")
  shift
done
[[ "${1:-}" == /usr/bin/bash ]] || exit 92
shift
[[ "${1:-}" == "$LOCALAI_TEST_EXPECTED_SCRIPT" ]] || exit 93
shift
exec /usr/bin/env -i \
  "${env_args[@]}" \
  LOCALAI_TEST_ELEVATED=1 \
  "LOCALAI_TEST_EXPECTED_CONFIG=$LOCALAI_TEST_EXPECTED_CONFIG" \
  "LOCALAI_TEST_EXPECTED_STATE=$LOCALAI_TEST_EXPECTED_STATE" \
  "LOCALAI_TEST_EXPECTED_ASSET=$LOCALAI_TEST_EXPECTED_ASSET" \
  "LOCALAI_TEST_EXPECTED_PROJECT=$LOCALAI_TEST_EXPECTED_PROJECT" \
  /usr/bin/bash "$LOCALAI_TEST_PROBE" "$@"
EOF
chmod 0755 "$scratch/bin/run0" "$scratch/probe.sh"
cp "$repo_root/config/localai.conf.example" "$scratch/config-for-install"
PATH="$scratch/bin:/usr/bin:/bin" \
LOCALAI_CONFIG_FILE="$scratch/config-for-install" \
LOCALAI_STATE_DIR="$synthetic_state_root" \
LOCALAI_PROJECT_DIR="$synthetic_project_root" \
LOCALAI_BIND_HOST=192.0.2.43 \
LOCALAI_TLS_PUBLIC_HOST=canonical-env.example \
LOCALAI_TLS_BIND_HOST=legacy-env.example \
LOCALAI_TEST_UNEXPECTED=should-not-cross \
LOCALAI_TEST_PROBE="$scratch/probe.sh" \
LOCALAI_TEST_EXPECTED_SCRIPT="$repo_root/secureblue-localai-install/install.sh" \
LOCALAI_TEST_EXPECTED_CONFIG="$scratch/config-for-install" \
LOCALAI_TEST_EXPECTED_STATE="$synthetic_state_root" \
LOCALAI_TEST_EXPECTED_ASSET="$repo_root/localai" \
LOCALAI_TEST_EXPECTED_PROJECT="$synthetic_project_root" \
/usr/bin/bash "$repo_root/secureblue-localai-install/install.sh" --no-pull --no-service

printf 'Installer safety checks passed.\n'
