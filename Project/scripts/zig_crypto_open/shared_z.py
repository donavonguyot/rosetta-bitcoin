"""Build an isolated common-Z experiment without modifying the shipped package."""
import shutil
from common import HERE, WORK, FROZEN, docker, exclusive


def main():
    dest=WORK/'shared-z'
    shutil.copytree(FROZEN,dest,dirs_exist_ok=True,ignore=shutil.ignore_patterns('.zig-cache','zig-out'))
    path=dest/'src/root.zig';source=path.read_text()
    start=source.index('fn joint(');end=source.index('\nfn schnorrPoint',start)
    joint=source[start:end]
    old='const table = if (b == 0) [_]Point{Point.infinity()} ** (1 << (p_width - 2)) else oddTableWidth(point, p_width);'
    assert old in joint
    joint=joint.replace(old,'const common = commonZTable(if (b == 0) Point.infinity() else point, p_width);\n    const table = common.table;\n    const scale2 = mul(common.scale, common.scale);\n    const scale3 = mul(scale2, common.scale);')
    joint=joint.replace('signedPoint(&generator_table, streams[0].values[length])','scaleAffine(signedPoint(&generator_table, streams[0].values[length]), scale2, scale3)').replace('signedPoint(&phi_generator_table, streams[1].values[length])','scaleAffine(signedPoint(&phi_generator_table, streams[1].values[length]), scale2, scale3)')
    joint=joint.replace('    return result;','    result.z = mul(result.z, common.scale);\n    return result;')
    path.write_text(source[:start]+joint+source[end:]+'\n'+(HERE/'shared_z.zig.in').read_text())
    with exclusive():
        print(docker(['sh','-c','cd /work/shared-z && zig build test -Doptimize=ReleaseSafe']))

if __name__=='__main__':main()
