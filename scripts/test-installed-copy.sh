#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_REPO_ROOT="$repo_root"
source "$repo_root/scripts/test-support.sh"
test_sanitize_localai_environment
tmp_dir="$(test_mktemp_dir installed-controller-test)"
trap 'rm -rf "$tmp_dir"' EXIT

install_dir="$tmp_dir/localai-tray"
mkdir -p "$install_dir/config"
cp "$repo_root/bin/localaictl" "$install_dir/localaictl"
cp "$repo_root/lib/config.sh" "$install_dir/config.sh"
chmod 0755 "$install_dir/localaictl"

cat >"$install_dir/config/localai.conf" <<'EOF'
LOCALAI_TLS_ENABLED=true
LOCALAI_TLS_PUBLIC_SOCKET=true
LOCALAI_TLS_PUBLIC_HOST=stale.example.test
LOCALAI_TLS_PUBLIC_PORT=443
LOCALAI_BIND_HOST=127.0.0.1
LOCALAI_BIND_PORT=11455
LOCALAI_HTTPS_URL=https://stale.example.test
EOF

mkdir -p "$tmp_dir/shared"
cat >"$tmp_dir/shared/localai.conf" <<'EOF'
LOCALAI_TLS_ENABLED=true
LOCALAI_TLS_PUBLIC_SOCKET=true
LOCALAI_TLS_PUBLIC_HOST=first.example.test
LOCALAI_TLS_PUBLIC_PORT=443
LOCALAI_BIND_HOST=127.0.0.1
LOCALAI_BIND_PORT=11455
LOCALAI_HTTPS_URL=https://old-duplicate.example.test
EOF

cat >"$tmp_dir/run0" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'run0' >>"${LOCALAI_SYSTEMCTL_LOG:?}"
printf ' %s' "$@" >>"${LOCALAI_SYSTEMCTL_LOG:?}"
printf '\n' >>"${LOCALAI_SYSTEMCTL_LOG:?}"
while [[ "$#" -gt 0 ]]; do
  case "$1" in --pipe|-i) shift ;; *) break ;; esac
done
exec "$@"
EOF
cat >"$tmp_dir/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'systemctl' >>"${LOCALAI_SYSTEMCTL_LOG:?}"
printf ' %s' "$@" >>"${LOCALAI_SYSTEMCTL_LOG:?}"
printf '\n' >>"${LOCALAI_SYSTEMCTL_LOG:?}"
if [[ " $* " == *" is-active "* ]]; then
  printf 'active\n'
fi
EOF
cat >"$tmp_dir/id" <<'EOF'
#!/usr/bin/env bash
case "${2:-}" in
  localai) printf '1001\n' ;;
  localai-tls) printf '1002\n' ;;
  *) exit 1 ;;
esac
EOF
chmod 0755 "$tmp_dir/run0" "$tmp_dir/systemctl" "$tmp_dir/id"

export LOCALAI_CONFIG_FILE="$tmp_dir/shared/localai.conf"
export LOCALAI_RUN0_BIN="$tmp_dir/run0"
export LOCALAI_SYSTEMCTL_BIN="$tmp_dir/systemctl"
export LOCALAI_SYSTEMCTL_LOG="$tmp_dir/systemctl.log"
export LOCALAI_ID_BIN="$tmp_dir/id"
export LOCALAI_SYSTEM_UNIT_DIR="$tmp_dir/systemd"
mkdir -p "$tmp_dir/systemd"

status="$("$install_dir"/localaictl status --json)"
[[ "$status" == *'"backend":"active"'* ]]
[[ "$status" == *'"endpoint":"https://first.example.test"'* ]]
if rg -q -F 'run0 ' "$LOCALAI_SYSTEMCTL_LOG"; then
  printf 'Unexpected match in negative assertion\n' >&2
  exit 1
fi
rg -q -F 'systemctl --no-ask-password --user --machine=localai@.host is-active localai.service' "$LOCALAI_SYSTEMCTL_LOG"

# The installed controller rereads shared settings on each command; an old
# per-user snapshot and a legacy duplicate URL cannot freeze the tray endpoint.
sed -i 's/first\.example\.test/second\.example\.test/' "$tmp_dir/shared/localai.conf"
status="$("$install_dir"/localaictl status --json)"
[[ "$status" == *'"endpoint":"https://second.example.test"'* ]]
status="$("$install_dir"/localaictl status --json --elevated)"
[[ "$status" == *'"backend":"active"'* ]]
rg -q -F "run0 -i $tmp_dir/systemctl --no-ask-password --user --machine=localai@.host is-active localai.service" "$LOCALAI_SYSTEMCTL_LOG"

printf 'installed-copy tests passed\n'
