#!/usr/bin/env python3
"""Run the standalone acceptance commands against an immutable source export."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zig', default='zig')
    parser.add_argument('--store', choices=['both', 'rocksdb', 'native'], default='both')
    parser.add_argument('--crypto-backend', choices=['c_binding', 'own_curve'], default='c_binding')
    parser.add_argument('--manifest', type=Path, default=ROOT / 'standalone-manifest.json')
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    def run(command):
        print('+ ' + ' '.join(command), flush=True)
        subprocess.run(command, cwd=ROOT, check=True)
    verify = [sys.executable, 'scripts/verify_standalone.py', '--manifest', str(args.manifest)]
    run(verify)
    flags = ['-Doptimize=ReleaseSafe', f'-Dstore={args.store}', f'-Dcrypto-backend={args.crypto_backend}',
             f'-Dsource-commit={manifest["source_commit"]}']
    for target in ('', 'test', 'docs'):
        run([args.zig, 'build', *([target] if target else []), *flags, '--summary', 'all'])
    run([sys.executable, 'scripts/test_doc_coverage.py'])
    run([sys.executable, 'scripts/test_ci_source.py'])
    run([sys.executable, 'scripts/test_replay_diagnostics.py'])
    binary = str(ROOT / 'zig-out/bin/zigbitnode')
    for command in ('script-corpus', 'consensus-context', 'codec-vectors'):
        run([binary, command])
    run([binary, 'test-capability', '--kind', 'crypto-vectors', '--outcome-path', 'zig-out/crypto-vectors.json'])
    run(verify)


if __name__ == '__main__':
    main()
