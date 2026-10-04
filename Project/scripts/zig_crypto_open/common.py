"""Pinned execution and shared exclusion for the open crypto campaign."""

import sys as _rb_sys
from pathlib import Path as _RBPath
_rb_sys.path.insert(0, str(_RBPath(__file__).resolve().parents[3] / 'Project/scripts'))
from state_root import operational_paths as _rb_paths
import contextlib
import fcntl
import hashlib
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).parent
WORK = (_rb_paths()['campaigns'] / 'zig-open')
BUILDER = 'sha256:fe102cac43fe57c51179c86b49660c2cf6b971056e9b71c4cc4290694e684955'
FROZEN = WORK / 'frozen/Libraries/Zig/libsecp256k1-zig'


def run(args, cwd=ROOT):
    result = subprocess.run(list(map(str, args)), cwd=cwd, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f'{args!r}\n{result.stdout}\n{result.stderr}')
    return result.stdout + result.stderr


def docker(args):
    cache = ['-v', f'{WORK}/compiler-cache:/root/.cache/zig'] if args[0] == 'zig' else []
    return run(['docker', 'run', '--rm', '--network', 'none', *cache, '-v', f'{WORK}:/work',
                '-v', f'{HERE}:/tooling:ro', '-w', '/work', BUILDER, *args])


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


@contextlib.contextmanager
def exclusive():
    path = (_rb_paths()['campaigns'] / 'crypto-lanes/node-benchmark.lock')
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield

import sys
sys.path.insert(0,str(ROOT/"Project/scripts"))
from crypto_lanes import source_digest
LIB = ROOT / "Libraries/Zig/libsecp256k1-zig"
