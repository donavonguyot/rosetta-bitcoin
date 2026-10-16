#!/usr/bin/env python3
"""Exercise CLI diagnostic JSON with an offline, deliberately invalid trace."""
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    # This is a regression input, not a published live/synthetic conformance claim.
    raw = (struct.pack('<i', 2) + b'\x01' + b'\x24' * 32 + struct.pack('<I', 0)
           + b'\x00' + b'\xff' * 4 + b'\x01' + struct.pack('<q', 1) + b'\x01\x51' + b'\x00' * 4)
    state_root = Path(os.environ.get('RB_STATE_ROOT', Path.home() / '.rblab'))
    scratch = state_root / 'zig/ci-diagnostics'
    scratch.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=scratch) as temporary:
        work = Path(temporary)
        trace = work / 'trace'
        trace.mkdir()
        (trace / 'manifest.json').write_text(json.dumps({'fixture': 'synthetic', 'start_height': 0, 'start_hash': '00' * 32}))
        (trace / 'events.bin').write_bytes(struct.pack('<IQBI', 1, 0, 1, len(raw)) + raw)
        (trace / 'annotations.jsonl').write_text(json.dumps({'apply_seq': 1, 'expected_layer1': 'input_spent_in_pool', 'out_of_order': True}) + '\n')
        (trace / 'mutations.json').write_text('{"mutations": []}')
        (trace / 'boundaries.jsonl').write_text('')
        mem = work / 'mempool.json'
        mining = work / 'mining.json'
        subprocess.run([str(ROOT / 'zig-out/bin/zigbitnode'), 'mempool-replay', '--trace', str(trace),
                        '--store', 'native', '--datadir', str(work / 'state'), '--output', str(mem),
                        '--template-output', str(mining)], check=True, cwd=ROOT)
        report = json.loads(mem.read_text())
        assert report['passed'] is False, report
        assert report['replacements'] == {'count': 1, 'verdicts': ['missing_input']}, report
        assert report['out_of_order_accepted'] == 0, report
        assert report['divergent_boundaries'] == [], report
        assert json.loads(mining.read_text())['boundaries'] == []
    print('replay diagnostic regression passed (no funded inputs or peers)')


if __name__ == '__main__':
    main()
