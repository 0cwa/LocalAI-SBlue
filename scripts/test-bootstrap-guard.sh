#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_REPO_ROOT="$repo_root"
source "$repo_root/scripts/test-support.sh"
scratch="$(test_mktemp_dir bootstrap-guard)"
trap 'rm -rf -- "$scratch"' EXIT
guard="$repo_root/lib/bootstrap_guard.py"
if python3 "$guard" "$scratch/missing.db"; then
  printf 'missing database was accepted\n' >&2; exit 1
fi
python3 - "$scratch/auth.db" <<'PY'
import sqlite3, sys
with sqlite3.connect(sys.argv[1]) as db:
    db.execute('CREATE TABLE users (role TEXT, status TEXT)')
    db.execute('INSERT INTO users VALUES (?, ?)', ('user', 'active'))
    db.execute('INSERT INTO users VALUES (?, ?)', ('admin', 'pending'))
PY
if python3 "$guard" "$scratch/auth.db"; then
  printf 'database without an active administrator was accepted\n' >&2; exit 1
fi
python3 - "$scratch/auth.db" <<'PY'
import sqlite3, sys
with sqlite3.connect(sys.argv[1]) as db:
    db.execute('INSERT INTO users VALUES (?, ?)', ('admin', 'active'))
PY
python3 "$guard" "$scratch/auth.db" || { printf 'active administrator was rejected\n' >&2; exit 1; }
[[ "$(python3 "$guard" --status "$scratch/auth.db")" == ready ]]
[[ "$(python3 "$guard" --status "$scratch/missing.db")" == incomplete ]]
ln -s "$scratch/auth.db" "$scratch/link.db"
if python3 "$guard" "$scratch/link.db"; then
  printf 'linked database was accepted\n' >&2; exit 1
fi
printf 'not a database\n' > "$scratch/bad.db"
[[ "$(python3 "$guard" --status "$scratch/bad.db")" == unknown ]]
printf 'LOCALAI_AUTH=true LOCALAI_AUTH_DATABASE_URL=%s LOCALAI_ADDRESS=127.0.0.1:11455\n' "$scratch/auth.db" |
  python3 "$guard" --unit-environment "$scratch/auth.db" 11455
if printf 'LOCALAI_AUTH=true LOCALAI_AUTH=false LOCALAI_AUTH_DATABASE_URL=%s LOCALAI_ADDRESS=127.0.0.1:11455\n' "$scratch/auth.db" |
  python3 "$guard" --unit-environment "$scratch/auth.db" 11455; then
  printf 'conflicting effective authentication settings were accepted\n' >&2; exit 1
fi
python3 - "$guard" "$scratch/auth.db" "$scratch/backend.service" <<'PY'
import http.server
import importlib.util
import pathlib
import sys
import threading

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != '/api/auth/status':
            self.send_error(404)
            return
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{"authEnabled":true,"hasUsers":true}')

    def log_message(self, *args):
        pass

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
pathlib.Path(sys.argv[3]).write_text(
    'Environment=LOCALAI_AUTH=true\n'
    f'Environment=LOCALAI_AUTH_DATABASE_URL={sys.argv[2]}\n'
    f'Environment=LOCALAI_ADDRESS=127.0.0.1:{server.server_port}\n',
    encoding='utf-8',
)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    guard_path, database, unit = sys.argv[1:]
    spec = importlib.util.spec_from_file_location('bootstrap_guard', guard_path)
    guard = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(guard)
    guard.effective_unit_matches = lambda *args: True
    sys.argv = [guard_path, database, str(server.server_port), unit]
    assert guard.main() == 0
    pathlib.Path(sys.argv[3]).write_text('Environment=LOCALAI_AUTH=false\n', encoding='utf-8')
    assert guard.main() != 0
finally:
    server.shutdown()
    server.server_close()
PY
printf 'Bootstrap guard tests passed.\n'
