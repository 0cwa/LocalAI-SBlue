#!/usr/bin/env bash
# Exercise first-admin and public-socket ordering only in an isolated VM.
set -euo pipefail
[[ "${EUID:-$(id -u)}" == 0 ]] && systemd-detect-virt --vm --quiet || exit 1
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
socket=/etc/systemd/system/localai-acceptance-bootstrap.socket
service=/etc/systemd/system/localai-acceptance-bootstrap.service
[[ ! -e "$socket" && ! -L "$socket" && ! -e "$service" && ! -L "$service" ]] || exit 1
cleanup() {
  systemctl stop localai-acceptance-bootstrap.socket >/dev/null 2>&1 || :
  rm -f -- "$socket" "$service"
  systemctl daemon-reload >/dev/null 2>&1 || :
}
trap cleanup EXIT
port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
sed -e 's|@DATA_PATH@|/var/lib/localai/data|g' \
    -e 's|@BACKEND_PORT@|11455|g' \
    -e 's|@STATE_DIR@|/var/lib/localai|g' \
    -e 's|@LOCALAI_SERVICE_USER@|localai|g' \
    -e "s|@LOCALAI_UID@|$(id -u localai)|g" \
    -e 's|@TLS_PUBLIC_HOST@|0.0.0.0|g' \
    -e "s|@TLS_PUBLIC_PORT@|$port|g" \
    "$repo_root/localai-podman-compose/localai-tls-forward.socket.in" >"$socket"
printf '[Service]\nExecStart=/usr/bin/true\n' >"$service"
systemctl daemon-reload
if systemctl start localai-acceptance-bootstrap.socket >/dev/null 2>&1; then exit 1; fi
if systemctl is-active --quiet localai-acceptance-bootstrap.socket; then exit 1; fi
python3 - <<'PY'
import json
import secrets
import urllib.request

payload = json.dumps({
    "email": "bootstrap@example.test",
    "name": "VM bootstrap",
    "password": "Aa9!" + secrets.token_urlsafe(32),
}).encode()
request = urllib.request.Request(
    "http://127.0.0.1:11455/api/auth/register",
    data=payload,
    headers={"Content-Type": "application/json"},
    method="POST",
)
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
with opener.open(request, timeout=30) as response:
    if response.status != 201:
        raise SystemExit(1)
PY
systemctl reset-failed localai-acceptance-bootstrap.socket
systemctl start localai-acceptance-bootstrap.socket
systemctl is-active --quiet localai-acceptance-bootstrap.socket
