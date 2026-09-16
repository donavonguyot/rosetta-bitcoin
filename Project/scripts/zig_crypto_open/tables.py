"""Generate packed tables from package-owned affine mathematics, never C data."""
import argparse
import hashlib
import importlib.util
import json
import shutil
from common import ROOT, WORK, save


def main():
    p=argparse.ArgumentParser();p.add_argument('--base',default='shared-z');p.add_argument('--width',type=int,default=15);p.add_argument('--variable-width',type=int,default=4);a=p.parse_args()
    if not 3<=a.width<=16 or not 3<=a.variable_width<=7:raise ValueError('Unsupported experimental width')
    spec=importlib.util.spec_from_file_location('math_source',ROOT/'Libraries/Zig/libsecp256k1-zig/tools/derive_constants.py')
    math=importlib.util.module_from_spec(spec);spec.loader.exec_module(math)
    beta,_,_,_=math.derive()
    count=1<<(a.width-2);point=math.G;step=math.plus(point,point);encoded=bytearray();phi=bytearray()
    for i in range(count):
        x,y=point
        assert (y*y-x*x*x-7)%math.P==0
        if i in (0,1,2,count//2,count-1):assert point==math.multiply(2*i+1)
        encoded.extend(x.to_bytes(32,'big')+y.to_bytes(32,'big'))
        phi.extend((beta*x%math.P).to_bytes(32,'big')+y.to_bytes(32,'big'))
        point=math.plus(point,step)
    name=f'{a.base}-g{a.width}-p{a.variable_width}';dest=WORK/name
    shutil.copytree(WORK/a.base,dest,dirs_exist_ok=True,ignore=shutil.ignore_patterns('.zig-cache','zig-out'))
    source=(dest/'src/root.zig').read_text()
    start=source.index('const generator_table = blk:');end=source.index('\nfn signedPoint',start)
    source=source[:start]+'''const PackedPoint=struct{x:u256,y:u256};
fn unpackTable(comptime data:[]const u8) [data.len/64]PackedPoint {
    @setEvalBranchQuota(20_000_000);
    var out:[data.len/64]PackedPoint=undefined;
    for(&out,0..) |*entry,i| entry.*=.{.x=std.mem.readInt(u256,data[i*64..][0..32],.big),.y=std.mem.readInt(u256,data[i*64+32..][0..32],.big)};
    return out;
}
const generator_table=unpackTable(@embedFile("generator.bin"));
'''+source[end:]
    start=source.index('const phi_generator_table = blk:');end=source.index('\nfn joint',start)
    source=source[:start]+'const phi_generator_table=unpackTable(@embedFile("phi-generator.bin"));\n'+source[end:]
    source=source.replace('var point = table[(magnitude - 1) / 2];', 'const stored = table[(magnitude - 1) / 2];\n    var point = Point{ .x = stored.x, .y = stored.y, .z = if (@hasField(@TypeOf(stored), \"z\")) stored.z else 1 };')
    source=source.replace('expectSamePoint(entry,', 'expectSamePoint(Point{ .x = entry.x, .y = entry.y },')
    source=source.replace('digit: i8','digit: i16').replace('const magnitude: u8','const magnitude: u16').replace('[131]i8','[131]i16').replace('const residue: i16','const residue: i32')
    source=source.replace('const g_width: usize = 8;',f'const g_width: usize = {a.width};').replace('const p_width: usize = 4;',f'const p_width: usize = {a.variable_width};')
    (dest/'src/root.zig').write_text(source)
    (dest/'src/generator.bin').write_bytes(encoded);(dest/'src/phi-generator.bin').write_bytes(phi)
    save(WORK/(name+'-tables.json'),dict(generator_width=a.width,variable_width=a.variable_width,entries_per_table=count,packed_bytes=len(encoded)+len(phi),generator_sha256=hashlib.sha256(encoded).hexdigest(),phi_sha256=hashlib.sha256(phi).hexdigest(),construction='independent affine recurrence using package mathematical generator',curve_checks=count,independent_scalar_spots=5))
    print(name)

if __name__=='__main__':main()
