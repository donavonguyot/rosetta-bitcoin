#!/usr/bin/env python3
"""Select and pin external Zigibit inputs for RB consumers; never fall back."""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from state_root import ROOT, PATHS, primary_root


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def selected_source(source=None, manifest=None):
    value = source or os.environ.get('RB_ZIG_SOURCE')
    require(bool(value), 'set RB_ZIG_SOURCE or pass --source; no bundled-source fallback')
    source = Path(value).expanduser().resolve()
    inventory = manifest or os.environ.get('RB_ZIG_MANIFEST') or source / 'standalone-manifest.json'
    return source, Path(inventory).expanduser().resolve()


def require_bundled(consumer):
    require(not os.environ.get('RB_ZIG_SOURCE') and not os.environ.get('RB_ZIG_MANIFEST'),
            f'{consumer} is an RB-only historical campaign; external checkout mode is unsupported. '
            'Use run_zig_external_lab.py for external acceptance.')


def verify_source(source: Path, manifest_path: Path, workspace: Path) -> dict:
    source, manifest_path, workspace = source.resolve(), manifest_path.resolve(), workspace.resolve()
    require(not source.is_relative_to(workspace), 'source must be outside RB, including its worktrees')
    manifest = json.loads(manifest_path.read_text())
    require(manifest.get('schema') == 'zigbitnode.standalone_source.v1', 'unsupported source inventory')
    require(manifest.get('source_dirty') is False, 'source inventory must describe clean source')
    require(re.fullmatch(r'[0-9a-f]{40}', manifest.get('source_commit', '')) is not None, 'invalid source revision')
    require(manifest.get('zig_version') == '0.16.0', 'unsupported Zig version')
    seen = set()
    for row in manifest['files']:
        relative = Path(row['path'])
        require(not relative.is_absolute() and '..' not in relative.parts, 'unsafe inventory path')
        require(row['path'] not in seen, 'duplicate inventory entry')
        seen.add(row['path'])
        path = source / relative
        require(path.resolve().is_relative_to(source) and not path.is_symlink(), 'escaping source path')
        require(digest(path) == row['sha256'], f'source checksum mismatch: {relative}')
    ignored = {'.git', '.zig-cache', 'zig-out', '__pycache__'}
    for directory, children, files in os.walk(source):
        children[:] = [name for name in children if name not in ignored]
        for name in children + files:
            path = Path(directory) / name
            require(not path.is_symlink(), f'symlink in source: {path}')
            if path.is_file() and path != manifest_path and path.name != 'standalone-manifest.json':
                require(path.relative_to(source).as_posix() in seen, f'uninventoried source: {path}')
    for name in ('docker/Dockerfile', 'build.zig', 'src/cli/main.zig', 'libsecp256k1-zig/build.zig',
                 'fixtures/conformance/fixtures/scripts/manifest.json'):
        require(name in seen, f'required input missing from inventory: {name}')
    return manifest



def fixture_checkout(package):
    """Publish once, then verify without rewriting fixtures used by other runs."""
    from build_fixture_package import unpack
    parent = PATHS['root'] / 'fixture-checkouts'
    parent.mkdir(parents=True, exist_ok=True)
    destination = parent / package['fixture_hash']
    with (parent / (package['fixture_hash'] + '.lock')).open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if not destination.exists():
            with tempfile.TemporaryDirectory(prefix='.extract-', dir=parent) as scratch:
                staged = Path(scratch) / 'fixtures'
                unpack(package['fixture_hash'], staged)
                staged.rename(destination)
        expected = {entry['path']: entry['sha256'] for entry in package['files']}
        observed = {}
        require(not destination.is_symlink(), 'symlink fixture checkout')
        for path in destination.rglob('*'):
            require(not path.is_symlink(), 'symlink fixture input')
            if path.is_file():
                observed[path.relative_to(destination).as_posix()] = digest(path)
        require(observed == expected, 'retained fixture checkout changed; preserve and investigate')
    return destination


def prepare(run_ref=None):
    """Build or reuse a verified external runtime and return campaign pins and env."""
    from build_fixture_package import build, publish
    from provenance import image_id, receipt_path, for_image
    source, inventory = selected_source()
    manifest = verify_source(source, inventory, primary_root())
    inventory_hash = digest(inventory)
    store, crypto = os.environ.get('STORE', 'both'), os.environ.get('CRYPTO_BACKEND', 'c_binding')
    require(store in ('both', 'rocksdb', 'native'), 'unsupported store')
    require(crypto in ('c_binding', 'own_curve'), 'unsupported crypto backend')
    package = build(source / 'fixtures')
    start = {'source_commit': manifest['source_commit'], 'fixture_hash': package['fixture_hash']}
    tag = f'rb/zig-external:{inventory_hash}-{store}-{crypto}'
    try:
        identity = image_id(tag)
        for_image(identity, run_ref, start)
    except (ValueError, subprocess.CalledProcessError):
        subprocess.run(['docker', 'build', '--target', 'runtime', '-f', str(source / 'docker/Dockerfile'),
                        '--build-arg', 'NODE_SOURCE=.', '--build-arg', 'CRYPTO_SOURCE=libsecp256k1-zig',
                        '--build-arg', f'SOURCE_COMMIT={start["source_commit"]}',
                        '--build-arg', f'STORE={store}', '--build-arg', f'CRYPTO_BACKEND={crypto}',
                        '-t', tag, str(source)], check=True, stdout=sys.stderr)
        identity = image_id(tag)
    info = json.loads(subprocess.check_output(['docker', 'run', '--rm', '--network', 'none',
                                               identity, 'zigbitnode', '--build-info'], text=True))
    for key, expected in {'source_commit': start['source_commit'], 'store_mode': store, 'crypto_backend': crypto}.items():
        require(info.get(key) == expected, f'external binary {key} mismatch')
    binary_hash = subprocess.check_output(['docker', 'run', '--rm', '--network', 'none', identity,
                                          'sha256sum', '/usr/local/bin/zigbitnode'], text=True).split()[0]
    require(info.get('binary_sha256') == binary_hash, 'external binary hash mismatch')
    require(verify_source(source, inventory, primary_root()) == manifest and digest(inventory) == inventory_hash,
            'external source changed during build')
    receipt = {'schema': 'rb.build_receipt.v1', **start, 'binary_sha256': identity.removeprefix('sha256:'),
               'subject_type': 'image', 'source_manifest_sha256': inventory_hash, 'node_binary_sha256': binary_hash}
    destination = receipt_path(identity, start)
    destination.parent.mkdir(parents=True, exist_ok=True)
    # Existing receipts are immutable; validate their binding before reuse.
    if destination.exists():
        require(json.loads(destination.read_text()) == receipt, 'external receipt mismatch')
    else:
        publish(destination, (json.dumps(receipt, sort_keys=True, indent=2) + '\n').encode())
    extracted = fixture_checkout(package)
    return for_image(identity, run_ref, start), {
        'RB_PROVENANCE_IMAGE': identity, 'RB_FIXTURE_SHARED': str(extracted), 'DOCKER_REBUILD': '0',
        'RB_ZIG_CONTEXT': str(source), 'RB_ZIG_DOCKERFILE': 'docker/Dockerfile',
        'RB_ZIG_NODE_SOURCE': '.', 'RB_ZIG_CRYPTO_SOURCE': 'libsecp256k1-zig',
        'RB_ZIG_COMMIT': start['source_commit'],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['verify', 'prepare', 'compose'])
    parser.add_argument('args', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command == 'verify':
        source, inventory = selected_source()
        verify_source(source, inventory, primary_root())
        return
    pins, env = prepare()
    if args.command == 'prepare':
        print(json.dumps({'provenance': pins, 'environment': env}, sort_keys=True))
        return
    # Build has already completed with checked provenance. Never let Compose rebuild.
    command = args.args
    if command == ['build']:
        return
    require('--build' not in command and 'build' not in command, 'use make docker-build for a pinned build')
    subprocess.run(['docker', 'compose', *command], env={**os.environ, **env}, check=True)


if __name__ == '__main__':
    main()
