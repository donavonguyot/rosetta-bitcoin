"""Instrument disposable test copies only; production never imports counters."""

import sys as _rb_sys
from pathlib import Path as _RBPath
_rb_sys.path.insert(0, str(_RBPath(__file__).resolve().parents[3] / 'Project/scripts'))
from state_root import operational_paths as _rb_paths
import json,re,shutil,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3];WORK=(_rb_paths()['campaigns'] / 'zig-opt')
for name in ('original','stage1','stage2','stage3','stage4'):
 src=WORK/name;dest=WORK/(name+'-counts')
 if dest.exists():shutil.rmtree(dest)
 shutil.copytree(src,dest,ignore=shutil.ignore_patterns('.zig-cache','zig-out'))
 p=dest/'src/root.zig';s=p.read_text()
 counters=['field_mul','double','plus','mixed','scalar_fermat','field_fermat','binary_inverse']
 s+='\nvar counts: [7]u64 = @splat(0);\n'
 for index,pattern in [(0,r'fn mul\([^\n]+\{'),(1,r'fn double\([^\n]+\{'),(2,r'fn plus\([^\n]+\{'),(3,r'fn mixed\([^\n]+\{'),(6,r'fn inverse\([^\n]+\{')]:
  s=re.sub(pattern,lambda m:m[0]+f'\n if (!@inComptime()) counts[{index}] += 1;',s)
 s=s.replace('var result: u256 = 1;','if (!@inComptime()) { if (modulus == n) counts[4] += 1; if (modulus == p and exponent == p-2) counts[5] += 1; }\n    var result: u256 = 1;')
 s+='''
test "operation counts" {
 const a = std.testing.allocator;
 const parsed = try std.json.parseFromSlice(std.json.Value,a,@embedFile("testdata/native.json"),.{});
 defer parsed.deinit();
 const row=parsed.value.object.get("vectors").?.array.items[0].object;
 var values: [3][]u8=undefined;
 for ([_][]const u8{"pubkey_hex","msg_hash_hex","signature_hex"},0..) |field,i| {
  const h=row.get(field).?.string; values[i]=try a.alloc(u8,h.len/2); _=try std.fmt.hexToBytes(values[i],h);
 }
 defer for(values) |value| a.free(value);
 counts=@splat(0);
 try std.testing.expect(try verifyEcdsa(values[0],values[1],values[2]));
 std.debug.print("COUNTS {d},{d},{d},{d},{d},{d},{d}\\n",.{counts[0],counts[1],counts[2],counts[3],counts[4],counts[5],counts[6]});
}
'''
 p.write_text(s)
 r=subprocess.run(['zig','build','test','-Doptimize=ReleaseSafe'],cwd=dest,capture_output=True,text=True)
 if r.returncode:raise RuntimeError(r.stdout+r.stderr)
 line=next(x for x in (r.stdout+r.stderr).splitlines() if x.startswith('COUNTS '))
 result=dict(zip(counters,map(int,line[7:].split(','))));(WORK/f'{name}-counts.json').write_text(json.dumps(result,indent=2)+'\n');print(name,result,flush=True)
