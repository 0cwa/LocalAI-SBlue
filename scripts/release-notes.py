#!/usr/bin/env python3
"""Validate a release tag and print the matching qualified changelog section."""
from pathlib import Path
import re
import sys

version = Path('VERSION').read_text(encoding='utf-8').strip()
semver = r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
if len(sys.argv) != 2 or not re.fullmatch(semver, version) or sys.argv[1] != 'v' + version:
    sys.exit('Release tag must be v followed by the exact VERSION (X.Y.Z).')
text = Path('CHANGELOG.md').read_text(encoding='utf-8')
sections = re.split(r'^## ', text, flags=re.MULTILINE)
matches = [section.split('\n', 1)[1].strip() for section in sections[1:]
           if section.split('\n', 1)[0] == version and '\n' in section]
if len(matches) != 1 or not re.search(r'^Qualification:[ \t]*\S', matches[0], re.MULTILINE):
    sys.exit('The changelog needs exactly one version section with a Qualification: line.')
print(matches[0])
