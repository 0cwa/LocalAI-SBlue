#!/usr/bin/env python3
"""Reject deployment-specific material in files intended for publication."""
import ipaddress
import os
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
os.chdir(root)
result = subprocess.run(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], capture_output=True)
if result.returncode == 0:
    paths = [Path(os.fsdecode(p)) for p in result.stdout.split(b"\0") if p]
else:
    paths = [p for p in Path('.').rglob('*') if p.is_file() and '.git' not in p.parts]

suffixes = {'.crt', '.key', '.pem', '.p12', '.pfx', '.csr'}
host = re.compile(r'(?<![\w.-])(?:[a-z0-9][a-z0-9-]*\.)+(?:internal|local|lan|home|corp)(?![\w.-])', re.I)
home = re.compile(r'/(?:var/)?home/[^/\s\x00"\x27`$}]+')
address = re.compile(r'(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])')
ipv6 = re.compile(r'(?<![\w:])(?:[0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}(?![\w:])')
secret = re.compile(r'-----BEGIN (?:[A-Z ]*PRIVATE KEY|CERTIFICATE)-----')
errors = []
for path in sorted(set(paths)):
    if path.suffix.lower() in suffixes:
        errors.append(f'{path}: certificate or key file')
        continue
    if not path.is_file() or path.is_symlink():
        continue
    data = path.read_bytes()
    if b'\0' in data:
        continue
    contents = data.decode('utf-8', errors='replace')
    for line_no, line in enumerate(contents.splitlines(), 1):
        # These are generic, documented fixtures, not real deployment values.
        line = re.sub(r'(?<![\w.-])localai\.internal(?![\w.-])', '', line)
        line = re.sub(r'/home/test-user(?=/|[^\w.-]|$)', '', line)
        matches = [m.group() for m in address.finditer(line)]
        private = False
        for match in matches:
            try:
                ip = ipaddress.ip_address(match)
                a, b = ip.packed[:2]
                private |= a == 10 or (a == 172 and 16 <= b <= 31) or (a == 192 and b == 168) or (a == 169 and b == 254)
            except ValueError:
                pass
        for match in ipv6.finditer(line):
            try:
                ip = ipaddress.IPv6Address(match.group())
                private |= (ip.packed[0] & 0xfe) == 0xfc or (ip.packed[0] == 0xfe and (ip.packed[1] & 0xc0) == 0x80)
            except ValueError:
                pass
        if private or host.search(line) or home.search(line) or secret.search(line):
            errors.append(f'{path}:{line_no}: deployment-specific data or certificate material')
if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
