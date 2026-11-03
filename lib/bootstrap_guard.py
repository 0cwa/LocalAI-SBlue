#!/usr/bin/python3
# Managed by LocalAI secureblue installer.
"""Fail closed unless LocalAI's SQLite database has an active administrator."""

import json
import pathlib
import shlex
import sqlite3
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.request


def admin_state(database: str) -> str:
    try:
        path = pathlib.Path(database)
        if not path.is_absolute():
            return "unknown"
        try:
            info = path.lstat()
        except FileNotFoundError:
            return "incomplete"
        if not stat.S_ISREG(info.st_mode):
            return "unknown"
        with sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=2) as connection:
            result = connection.execute(
                "SELECT 1 FROM users WHERE role = ? AND status = ? LIMIT 1",
                ("admin", "active"),
            ).fetchone()
        return "ready" if result is not None else "incomplete"
    except (OSError, sqlite3.Error, ValueError):
        return "unknown"


def unit_matches(
    database: str, port: str, unit: str,
    expected_path: str = "/etc/localai/backend-unit.expected", expected_uid: int = 0,
) -> bool:
    if not port.isdecimal() or not 1 <= int(port) <= 65535:
        return False
    try:
        expected_file = pathlib.Path(expected_path)
        metadata = expected_file.lstat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != expected_uid or metadata.st_mode & 0o022:
            return False
        unit_text = pathlib.Path(unit).read_text(encoding="utf-8")
        if unit_text != expected_file.read_text(encoding="utf-8"):
            return False
        unit_lines = unit_text.splitlines()
    except (OSError, UnicodeError):
        return False
    required = (
        "Environment=LOCALAI_AUTH=true",
        f"Environment=LOCALAI_AUTH_DATABASE_URL={database}",
        f"Environment=LOCALAI_ADDRESS=127.0.0.1:{port}",
    )
    for expected in required:
        prefix = expected.rsplit("=", 1)[0] + "="
        if [line for line in unit_lines if line.startswith(prefix)] != [expected]:
            return False
    return True


def environment_matches(environment: str, database: str, port: str) -> bool:
    try:
        values = shlex.split(environment)
    except ValueError:
        return False
    required = (
        "LOCALAI_AUTH=true",
        f"LOCALAI_AUTH_DATABASE_URL={database}",
        f"LOCALAI_ADDRESS=127.0.0.1:{port}",
    )
    for expected in required:
        prefix = expected.split("=", 1)[0] + "="
        if [value for value in values if value.startswith(prefix)] != [expected]:
            return False
    return True


def dropins_safe(value: str) -> bool:
    try:
        paths = shlex.split(value)
        for name in paths:
            path = pathlib.Path(name)
            if path.parent != pathlib.Path("/usr/lib/systemd/user/service.d"):
                return False
            metadata = path.lstat()
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != 0 or metadata.st_mode & 0o022:
                return False
        return True
    except (OSError, ValueError):
        return False


def effective_unit_matches(database: str, port: str) -> bool:
    try:
        command = ["/usr/bin/systemctl", "--user", "show", "localai.service"]
        dropins = subprocess.run(command + ["--property=DropInPaths", "--value"], capture_output=True, text=True, timeout=3, check=True)
        if not dropins_safe(dropins.stdout):
            return False
        environment = subprocess.run(command + ["--property=Environment", "--value"], capture_output=True, text=True, timeout=3, check=True)
        return environment_matches(environment.stdout, database, port)
    except (OSError, subprocess.SubprocessError, UnicodeError):
        return False


def main() -> int:
    status_only = len(sys.argv) == 3 and sys.argv[1] == "--status"
    if status_only:
        state = admin_state(sys.argv[2])
        print(state)
        return 0
    if len(sys.argv) == 5 and sys.argv[1] == "--unit-safe":
        return 0 if unit_matches(*sys.argv[2:]) else 1
    if len(sys.argv) == 4 and sys.argv[1] == "--unit-environment":
        return 0 if environment_matches(sys.stdin.read(), sys.argv[2], sys.argv[3]) else 1
    if len(sys.argv) == 2 and sys.argv[1] == "--dropins-safe":
        return 0 if dropins_safe(sys.stdin.read()) else 1
    if len(sys.argv) not in (2, 4):
        return 2
    if admin_state(sys.argv[1]) != "ready":
        return 1
    if len(sys.argv) == 2:
        return 0
    port = sys.argv[2]
    if not unit_matches(sys.argv[1], port, sys.argv[3]) or not effective_unit_matches(sys.argv[1], port):
        return 1
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        try:
            with opener.open(f"http://127.0.0.1:{port}/api/auth/status", timeout=2) as response:
                status = json.loads(response.read(4097))
            if status.get("authEnabled") is True and status.get("hasUsers") is True:
                return 0
        except (OSError, ValueError, urllib.error.URLError, AttributeError):
            pass
        time.sleep(1)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
