"""Compose the independent 30-step matrix experiment in a disposable package."""
import shutil
from common import HERE, WORK, docker, exclusive


def main():
    dest=WORK/'divsteps'
    shutil.copytree(WORK/'shared-z',dest,dirs_exist_ok=True,ignore=shutil.ignore_patterns('.zig-cache','zig-out'))
    path=dest/'src/root.zig';source=path.read_text()
    assert source.count('fn inverse(input:')==1
    source=source.replace('fn inverse(input:','fn binaryInverse(input:')
    path.write_text(source+'\n'+(HERE/'divsteps.zig.in').read_text())
    with exclusive():
        output=docker(['sh','-c','cd /work/divsteps && zig build test -Doptimize=ReleaseSafe'])
        (WORK/'divsteps-tests.log').write_text(output)
        print(output)

if __name__=='__main__':main()
