#!/usr/bin/env python3
"""Install the pinned compiler into a new directory, verifying archive bytes."""
import hashlib
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import urllib.request

VERSION = '0.16.0'
HASHES = {
    'x86_64-linux': '70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00',
    'aarch64-linux': 'ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17',
    'x86_64-macos': '0387557ed1877bc6a2e1802c8391953baddba76081876301c522f52977b52ba7',
    'aarch64-macos': 'b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489',
}


def main():
    machine = {'arm64': 'aarch64', 'AMD64': 'x86_64'}.get(platform.machine(), platform.machine())
    system = {'Darwin': 'macos', 'Linux': 'linux'}[platform.system()]
    key = f'{machine}-{system}'
    destination = Path(sys.argv[1]).resolve()
    if destination.exists():
        raise SystemExit(f'destination already exists: {destination}')
    with tempfile.TemporaryDirectory() as temp:
        archive = Path(temp) / 'zig.tar.xz'
        urllib.request.urlretrieve(f'https://ziglang.org/download/{VERSION}/zig-{key}-{VERSION}.tar.xz', archive)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != HASHES[key]:
            raise SystemExit('compiler archive checksum mismatch')
        destination.mkdir(parents=True)
        subprocess.run(['tar', '-xJf', str(archive), '-C', str(destination), '--strip-components=1'], check=True)
    if subprocess.check_output([str(destination / 'zig'), 'version'], text=True).strip() != VERSION:
        raise SystemExit('unexpected compiler version')
    print(destination / 'zig')


if __name__ == '__main__':
    main()
