#!/usr/bin/env python3
"""Inventory a clean standalone Git checkout without rewriting export provenance."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args], text=True)


def main():
    if Path(git('rev-parse', '--show-toplevel').strip()).resolve() != ROOT:
        raise SystemExit('snapshot requires a standalone repository root')
    if git('status', '--porcelain', '--untracked-files=no').strip():
        raise SystemExit('snapshot requires a clean tracked checkout')
    entries = []
    for name in sorted(filter(None, git('ls-files', '-z').split('\0'))):
        path = ROOT / name
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(ROOT):
            raise SystemExit(f'nonportable tracked input: {name}')
        entries.append({'path': name, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
    manifest = {'schema': 'zigbitnode.standalone_source.v1', 'source_commit': git('rev-parse', 'HEAD').strip(),
                'source_dirty': False, 'zig_version': '0.16.0', 'files': entries}
    destination = ROOT / '.zig-cache/ci-source-manifest.json'
    destination.parent.mkdir(exist_ok=True)
    destination.write_text(json.dumps(manifest, indent=2) + '\n')
    print(destination)


if __name__ == '__main__':
    main()
