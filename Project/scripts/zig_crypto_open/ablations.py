"""Independent ablations on the selected table layout, confined to test copies."""
import argparse, shutil
from common import WORK, save


def main():
    p=argparse.ArgumentParser();p.add_argument('name');a=p.parse_args()
    original=(WORK/a.name/'src/root.zig').read_text();names=[]
    for mode in ('generator','variable','both','common-z'):
        name=a.name+'-without-'+mode;dest=WORK/name
        shutil.copytree(WORK/a.name,dest,dirs_exist_ok=True,ignore=shutil.ignore_patterns('.zig-cache','zig-out'))
        s=original
        if mode=='common-z':
            s=s.replace('const common = commonZTable(if (b == 0) Point.infinity() else point, p_width);','const common = .{ .table = if (b == 0) [_]Point{Point.infinity()} ** (1 << (p_width - 2)) else oddTableWidth(point, p_width), .scale = @as(u256,1) };')
        else:
            # A full scalar needs its sign plus a carry digit, independent of GLV.
            s=s.replace('[131]i16','[258]i16').replace('k: i256, comptime width','k: i257, comptime width').replace('var remaining: u130','var remaining: u258').replace('@as(u130,','@as(u258,')
            if mode in ('generator','both'):s=s.replace('const left = splitScalar(a);','const left = [_]i257{@intCast(a),0};')
            if mode in ('variable','both'):s=s.replace('const right = splitScalar(b);','const right = [_]i257{@intCast(b),0};')
        (dest/'src/root.zig').write_text(s);names.append(name)
    save(WORK/'ablation-roster.json',{'names':names,'baseline':a.name})
    print(' '.join(names))

if __name__=='__main__':main()
