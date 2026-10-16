#!/usr/bin/env python3
"""Run RB's bounded lab checks against an inventoried external Zigibit checkout.

The node receives only its fixture snapshot, results directory and fresh volumes.
Project imports are a separate operation; a failed run retains its logs and state.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import uuid

from build_fixture_package import build as package_fixtures
from state_root import PATHS, ROOT, acquire_writer_lease, primary_root

TIP_5K = '000000000e3cb5b92e9765ed9c80c6b06f3d0a186478b330dd5e6b274acf03e2'
STATUS_FIELDS = ('validated_height', 'validated_hash', 'header_height', 'header_hash',
                 'stored_block_height', 'stored_block_hash', 'chainstate_utxo_count',
                 'chainstate_set_hash', 'chainstate_backend', 'chainstate_status',
                 'sync_status', 'native_crypto_backend')


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


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


def check_status(status: dict) -> None:
    for key, expected in {'validated_height': 5000, 'validated_hash': TIP_5K,
                          'header_height': 5000, 'stored_block_height': 5000,
                          'header_hash': TIP_5K, 'stored_block_hash': TIP_5K,
                          'chainstate_utxo_count': 4574, 'chainstate_backend': 'rocksdb',
                          'chainstate_status': 'usable', 'native_crypto_backend': 'libsecp256k1',
                          'sync_status': 'blocks_current', 'current_blocker': None}.items():
        require(key in status and status[key] == expected, f'status {key}: {status.get(key)!r}, expected {expected!r}')
    require(re.fullmatch(r'[0-9a-f]{64}', status.get('chainstate_set_hash', '')) is not None,
            'missing chainstate set hash')
    require(status['chainstate_set_hash'] != '0' * 64, 'empty chainstate set hash')


def check_restart(before: dict, after: dict, resumed: dict) -> None:
    check_status(before)
    check_status(after)
    for key in STATUS_FIELDS:
        require(before[key] == after[key], f'restart changed {key}')
    require(resumed.get('fresh_state') is False, 'resume unexpectedly started fresh')
    require(resumed.get('blocks_connected') == 0 and resumed.get('blocks_fetched') == 0,
            'resume replayed blocks instead of using persisted tip')
    for key in ('validated_height', 'validated_hash', 'chainstate_utxo_count', 'chainstate_set_hash'):
        require(resumed.get(key) == before[key], f'resume changed {key}')


class Lab:
    def __init__(self, source: Path, manifest_path: Path, run_id: str):
        self.source = source
        self.manifest_path = manifest_path
        self.manifest = verify_source(source, manifest_path, primary_root())
        self.manifest_hash = digest(manifest_path)
        self.run_id = run_id
        self.directory = PATHS['campaigns'] / run_id
        require(not self.directory.resolve().is_relative_to(primary_root()), 'campaign state must be outside RB')
        self.directory.mkdir(parents=True, exist_ok=False)
        self.commands = []
        self.image = ''
        self.volumes = []

    def run(self, name: str, argv: list[str], timeout: int = 1800) -> str:
        self.commands.append({'step': name, 'argv': argv})
        write_json(self.directory / 'commands.json', {'commands': self.commands})
        print(f'{name}: started', flush=True)
        with (self.directory / f'{name}.log').open('w') as log:
            result = subprocess.run(argv, cwd=self.source, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
        require(result.returncode == 0, f'{name} failed ({result.returncode}); see {self.directory / (name + ".log")}')
        print(f'{name}: passed', flush=True)
        return (self.directory / f'{name}.log').read_text()

    def container(self, name: str, command: list[str], volume: str | None = None,
                  network: str = 'none', node: bool = True) -> str:
        container_name = f'{self.run_id}-{name}'
        argv = ['docker', 'run', '--rm', '--name', container_name, '--network', network,
                '-e', 'ZIGBITNODE_RUNTIME_SURFACE=docker', '-e', 'PREFETCH_DEPTH=4',
                '--mount', f'type=bind,src={self.source / "fixtures"},dst=/fixtures,readonly',
                '--mount', f'type=bind,src={self.directory},dst=/results']
        if volume:
            argv += ['--mount', f'type=volume,src={volume},dst=/data']
        try:
            return self.run(name, argv + [self.image] + (['zigbitnode'] if node else []) + command)
        finally:
            # A client timeout must not leave a background writer on a proof volume.
            subprocess.run(['docker', 'rm', '-f', container_name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def volume(self, suffix: str) -> str:
        name = f'{self.run_id}-{suffix}'
        existing = subprocess.run(['docker', 'volume', 'inspect', name], capture_output=True)
        require(existing.returncode != 0, f'refusing existing volume: {name}')
        self.run(f'create-{suffix}', ['docker', 'volume', 'create', '--label', f'rb.external-lab={self.run_id}', name])
        self.volumes.append(name)
        write_json(self.directory / 'volumes.json', {'volumes': self.volumes, 'retention': 'proof scratch; retained for inspection'})
        return name

    def execute(self) -> dict:
        topology = dict(line.split('=', 1) for line in (ROOT / 'Nodes/Shared/docker/reference_topology.env').read_text().splitlines()
                        if line and not line.startswith('#'))
        network, peer = topology['REFERENCE_DOCKER_NETWORK'], topology['REFERENCE_P2P_PEER']
        package = package_fixtures(self.source / 'fixtures')
        build = ['docker', 'build', '--progress=plain', '-f', str(self.source / 'docker/Dockerfile'),
                 '--build-arg', 'NODE_SOURCE=.', '--build-arg', 'CRYPTO_SOURCE=libsecp256k1-zig',
                 '--build-arg', 'FIXTURE_SOURCE=fixtures', '--build-arg', 'STORE=both',
                 '--build-arg', 'CRYPTO_BACKEND=c_binding',
                 '--build-arg', f'SOURCE_COMMIT={self.manifest["source_commit"]}']
        self.run('offline-tests', build + ['--target', 'test', '-t', f'{self.run_id}:test', str(self.source)])
        self.run('runtime-build', build + ['--target', 'runtime', '-t', f'{self.run_id}:runtime', str(self.source)])
        self.image = self.run('image-id', ['docker', 'image', 'inspect', f'{self.run_id}:runtime', '--format', '{{.Id}}']).strip()
        require(re.fullmatch(r'sha256:[0-9a-f]{64}', self.image) is not None, 'invalid image ID')
        info = json.loads(self.container('build-info', ['--build-info']))
        for key, expected in {'source_commit': self.manifest['source_commit'], 'store_mode': 'both', 'crypto_backend': 'c_binding'}.items():
            require(info.get(key) == expected, f'build-info mismatch: {key}')
        binary_sha = self.container('binary-hash', ['sha256sum', '/usr/local/bin/zigbitnode'], node=False).split()[0]
        require(info.get('binary_sha256') == binary_sha, 'executed binary hash mismatch')
        write_json(self.directory / 'build-info.json', info)
        pins = {'source_commit': self.manifest['source_commit'], 'fixture_hash': package['fixture_hash'],
                'binary_sha256': binary_sha, 'run_ref': f'state:campaigns/{self.run_id}'}
        boundary = {'source_manifest_sha256': self.manifest_hash, 'source_file_count': len(self.manifest['files']),
                    'runtime_image': self.image, 'adapter_commit': subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip(),
                    'project_db_mounted': False, 'source_context': 'external_standalone_checkout'}
        codec = json.loads(self.container('codec-vectors', ['codec-vectors']))
        require(codec.get('passed') is True and codec.get('codec_version') == 2, 'codec vectors failed')
        self.container('script-corpus', ['script-corpus', '--manifest', '/fixtures/conformance/fixtures/scripts/manifest.json',
                                        '--output', '/results/corpus.raw.json'])
        corpus = json.loads((self.directory / 'corpus.raw.json').read_text())
        require(corpus.get('passed') == 45 and corpus.get('failed') == 0, 'script corpus is not 45/45')
        self.container('consensus-context', ['consensus-context', '--manifest', '/fixtures/conformance/fixtures/consensus/context/manifest.json'])
        smoke_volume = self.volume('storage')
        self.container('storage-smoke', ['storage-proof', '--datadir', '/data', '--output', '/results/storage.raw.json'], smoke_volume)
        smoke_status = json.loads(self.container('storage-reopen', ['status', '--datadir', '/data'], smoke_volume))
        require(smoke_status.get('validated_height') == 2 and smoke_status.get('chainstate_utxo_count') == 1
                and smoke_status.get('chainstate_backend') == 'rocksdb', 'storage smoke did not survive process exit')
        volume = self.volume('sync')
        self.container('peer-check', ['nc', '-z', '-w', '10', *peer.rsplit(':', 1)], network=network, node=False)
        sync_args = ['local-reference-proof', '--datadir', '/data', '--target', '5000', '--peer', peer]
        self.container('sync-5k', sync_args + ['--output', '/results/sync.raw.json'], volume, network)
        sync = json.loads((self.directory / 'sync.raw.json').read_text())
        require(sync.get('fresh_state') is True and sync.get('blocks_connected') == 5001, 'sync was not empty-state through 5000')
        before = json.loads(self.container('status-reopen', ['status', '--datadir', '/data'], volume))
        check_status(before)
        self.container('resume-5k', sync_args + ['--output', '/results/resume.raw.json'], volume, network)
        resumed = json.loads((self.directory / 'resume.raw.json').read_text())
        after = json.loads(self.container('status-after-resume', ['status', '--datadir', '/data'], volume))
        check_restart(before, after, resumed)
        require(verify_source(self.source, self.manifest_path, primary_root()) == self.manifest
                and digest(self.manifest_path) == self.manifest_hash, 'source changed during proof')
        captured = datetime.now(timezone.utc).isoformat()
        common = {'captured_at': captured, 'provenance': pins, 'external_checkout': boundary}
        corpus.update(common)
        write_json(self.directory / 'corpus.json', corpus)
        # Preserve the node's raw benchmark-shaped output without promoting a lab
        # extraction check into a campaign result or replacing a ranked baseline.
        bounded = {**common, 'schema': 'port.external_checkout_lab.v1', 'category': 'external_checkout_lab',
                   'port': 'zig', 'implementation': 'ZigNode', 'runtime_surface': 'docker', 'chain': 'testnet4',
                   'result': 'passed', 'proof_scope': 'bounded_sync_and_clean_restart', 'binary_gate_status': 'not_attempted',
                   'peer': peer, 'peer_mode': 'local_reference', 'fresh_state': True, 'target_height': 5000,
                   'prefetch_depth': 4, 'rocksdb_wal_disabled': False, 'script_runner_mode': 'parallel',
                   'blocks_connected': sync['blocks_connected'], 'resume_blocks_connected': resumed['blocks_connected'],
                   'status_before_resume': before, 'status_after_resume': after, 'volumes': self.volumes,
                   'script_corpus_passed': 45, 'codec_vectors': codec, 'storage_smoke_reopen': smoke_status,
                   'raw_artifacts': {p.name: digest(p) for p in self.directory.glob('*.raw.json')},
                   'does_not_prove': ['tip_once', 'tip_maintenance', 'power_loss_recovery', 'every_crash_point', 'serving', 'relay']}
        write_json(self.directory / 'bounded.json', bounded)
        storage = {**common, **after, 'schema': 'port.storage_gate_result.v1', 'category': 'storage',
                   'implementation': 'ZigNode', 'node_id': 'zig-external-lab-storage', 'chain': 'testnet4',
                   'commit': pins['source_commit'], 'runtime_truth_backend': 'rocksdb', 'rocksdb_runtime_truth': True,
                   'native_storage': True, 'result': 'passed', 'proof_scope': 'bounded_clean_process_restart',
                   'datadir': f'docker-volume:{volume}', 'verification': {'chainstate_codec_v2_vectors_run': True},
                   'project_export': {'project_db': 'Project/project.db', 'result': 'skipped',
                                      'script': 'Project/scripts/import_conformance_results.py', 'node_id': 'zig-external-lab-storage'},
                   'restart': {'before': before, 'after': after, 'resume_blocks_connected': 0},
                   'commands': [row['step'] for row in self.commands],
                   'does_not_prove': bounded['does_not_prove'], 'results': []}
        for fixture in ('storage.native_fresh_start', 'storage.native_restart', 'storage.rocksdb_runtime_truth'):
            storage['results'].append({'fixture_id': fixture, 'result': 'passed', 'validated_height': 5000,
                                       'validated_hash': TIP_5K, 'chainstate_backend': 'rocksdb', 'failure': ''})
        write_json(self.directory / 'storage.json', storage)
        return bounded


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, help='clean standalone inventory; defaults to source/standalone-manifest.json')
    parser.add_argument('--run-id', default='zig-external-' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ').lower() + '-' + uuid.uuid4().hex[:6])
    args = parser.parse_args()
    require(re.fullmatch(r'zig-external-[a-z0-9-]+', args.run_id) is not None and len(args.run_id) <= 80, 'invalid run ID')
    acquire_writer_lease()
    source = args.source.expanduser().resolve()
    lab = Lab(source, (args.manifest or source / 'standalone-manifest.json').resolve(), args.run_id)
    try:
        lab.execute()
    except BaseException as exc:
        write_json(lab.directory / 'failure.json', {'result': 'failed', 'error': str(exc), 'volumes': lab.volumes})
        raise
    print(f'passed: {lab.directory}; review artifacts before Project import', flush=True)


if __name__ == '__main__':
    main()
