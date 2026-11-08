#!/usr/bin/env python3
"""Reject tracked local configuration and obvious credential material."""
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parents[1]
paths = subprocess.check_output(['git', 'ls-files', '-z'], cwd=root).decode().split('\0')
# Construct patterns without embedding a matching example in this source.
home_path = re.compile('/' + r'(?:Users|home)/[^/\s\'"<>]+(?:/|\b)'
                       + r'|(?i:[A-Za-z]:\\Users\\[^\\\s\'"<>]+)')
private_key = re.compile(r'-{5}BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-{5}')
# Provider formats only; general secret detection belongs to Gitleaks in CI.
credential = re.compile(
    r'\b(?:AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{36}'
    r'|github_pat_[A-Za-z0-9_]{82}|sk-(?:proj-)?[A-Za-z0-9_-]{48,})\b'
)
problems = []
for name in filter(None, paths):
    path = root / name
    if path.is_symlink():
        problems.append(f'{name}: symlinks are not permitted in the public export')
        continue
    environment_file = (path.name == '.env' or path.name.startswith('.env.'))
    example_file = path.name.endswith(('.example', '.sample', '.template'))
    if (name.endswith(('.p8', '.p12', '.mobileprovision'))
            or path.name in ('GoogleService-Info.plist', 'Local.xcconfig')
            or (environment_file and not example_file)):
        problems.append(f'{name}: local credential/configuration file is tracked')
    try:
        text = path.read_text()
    except UnicodeDecodeError:
        continue
    for pattern, reason in ((home_path, 'absolute home directory path'),
                            (private_key, 'private key material'),
                            (credential, 'credential-like value')):
        if pattern.search(text):
            problems.append(f'{name}: {reason}')
if problems:
    raise SystemExit('\n'.join(problems))
print('Public source configuration check passed. Gitleaks supplies the full secret scan.')
