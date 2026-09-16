"""Separate GLV comb streams sharing the variable-point doubling loop."""
import argparse
import importlib.util
import shutil
from common import ROOT, WORK, save, digest


def main():
    p=argparse.ArgumentParser();p.add_argument('--teeth',type=int,choices=(4,6,8),default=6);a=p.parse_args()
    spec=importlib.util.spec_from_file_location('math_source',ROOT/'Libraries/Zig/libsecp256k1-zig/tools/derive_constants.py')
    math=importlib.util.module_from_spec(spec);spec.loader.exec_module(math)
    beta,_,_,_=math.derive();rows=(129+a.teeth-1)//a.teeth
    points=[None];bases=[math.multiply(1<<(i*rows)) for i in range(a.teeth)]
    for index in range(1,1<<a.teeth):
        low=index&-index;points.append(math.plus(points[index-low],bases[low.bit_length()-1]))
    data=bytearray();phi=bytearray()
    for i,point in enumerate(points):
        if point is None:data.extend(bytes(64));phi.extend(bytes(64));continue
        x,y=point
        assert (y*y-x*x*x-7)%math.P==0
        if i in (1,2,len(points)//2,len(points)-1):assert point==math.multiply(sum(1<<(j*rows) for j in range(a.teeth) if i>>j&1))
        data.extend(x.to_bytes(32,'big')+y.to_bytes(32,'big'));phi.extend((beta*x%math.P).to_bytes(32,'big')+y.to_bytes(32,'big'))
    name='comb-'+str(a.teeth);dest=WORK/name
    shutil.copytree(WORK/'shared-z',dest,dirs_exist_ok=True,ignore=shutil.ignore_patterns('.zig-cache','zig-out'))
    path=dest/'src/root.zig';source=path.read_text();start=source.index('fn joint(');end=source.index('\nfn schnorrPoint',start)
    joint=source[start:end].replace('recodeSigned(left[0], g_width), recodeSigned(left[1], g_width)','ShortDigits{}, ShortDigits{}').replace('var length: usize = 0;','var length: usize = if (a == 0) 0 else comb_rows;')
    line0='if (streams[0].values[length] != 0) result = result.mixed(scaleAffine(signedPoint(&generator_table, streams[0].values[length]), scale2, scale3));'
    line1='if (streams[1].values[length] != 0) result = result.mixed(scaleAffine(signedPoint(&phi_generator_table, streams[1].values[length]), scale2, scale3));'
    assert line0 in joint and line1 in joint
    joint=joint.replace(line0,'if (length < comb_rows) result = result.mixed(scaleAffine(combPoint(left[0], length, false), scale2, scale3));').replace(line1,'if (length < comb_rows) result = result.mixed(scaleAffine(combPoint(left[1], length, true), scale2, scale3));')
    source=source[:start]+joint+source[end:]
    source+='''
const comb_teeth:usize=TEETH;
const comb_rows:usize=ROWS;
const comb_bytes=@embedFile("comb.bin");
const comb_phi_bytes=@embedFile("comb-phi.bin");
fn combPoint(scalar:i256,row:usize,phi:bool) Point {
    const magnitude=@abs(scalar);var index:usize=0;
    for(0..comb_teeth) |tooth| {
        const bit=row+tooth*comb_rows;
        if(bit<129) index |= @as(usize,@intCast((magnitude>>@as(u8,@intCast(bit)))&1))<<@as(u6,@intCast(tooth));
    }
    if(index==0) return Point.infinity();
    const data=if(phi) comb_phi_bytes else comb_bytes;
    const x=std.mem.readInt(u256,data[index*64..][0..32],.big);
    const y=std.mem.readInt(u256,data[index*64+32..][0..32],.big);
    return .{.x=x,.y=if(scalar<0) sub(0,y) else y};
}
'''.replace('TEETH',str(a.teeth)).replace('ROWS',str(rows))
    path.write_text(source);(dest/'src/comb.bin').write_bytes(data);(dest/'src/comb-phi.bin').write_bytes(phi)
    save(WORK/(name+'-tables.json'),dict(teeth=a.teeth,rows=rows,packed_bytes=len(data)+len(phi),generator_sha256=digest(dest/'src/comb.bin'),phi_sha256=digest(dest/'src/comb-phi.bin'),tweak_generator='unchanged width8 windows',zero_entry='infinity sentinel, skipped before field use'))
    print(name)

if __name__=='__main__':main()
