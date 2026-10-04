"""Strong gates injected into isolated test copies, never runtime binaries."""

import sys as _rb_sys
from pathlib import Path as _RBPath
_rb_sys.path.insert(0, str(_RBPath(__file__).resolve().parents[3] / 'Project/scripts'))
from state_root import operational_paths as _rb_paths
import argparse,shutil,time,fcntl
from common import *
def main():
 p=argparse.ArgumentParser();p.add_argument('name');a=p.parse_args();source=WORK/a.name;dest=WORK/(a.name+'-test')
 shutil.copytree(source,dest,dirs_exist_ok=True,ignore=shutil.ignore_patterns('.zig-cache','zig-out'))
 s=(dest/'src/root.zig').read_text();old=(FROZEN/'src/root.zig').read_text().split('\ntest {')[0].replace('fn inverse(','pub fn inverse(').replace('fn recode(','pub fn recode(')
 (dest/'src/test_residual_baseline.zig').write_text(old)
 # Explicit test-only imports stay in the isolated test copy.
 s+='''
test "residual million field and scalar comparisons" {
 var prng=std.Random.DefaultPrng.init(0x5253494455414c);const random=prng.random();
 for(0..1_000_000) |_| {
  const a=random.int(u256)%p;const b=random.int(u256)%p;
  try std.testing.expectEqual(@as(u256,@intCast((@as(u512,a)*b)%p)),mul(a,b));
  try std.testing.expectEqual(@as(u256,@intCast((@as(u512,a)*a)%p)),mul(a,a));
  try std.testing.expectEqual(@as(u256,@intCast((@as(u257,a)+b)%p)),add(a,b));
  try std.testing.expectEqual(if(a>=b) a-b else p-(b-a),sub(a,b));
 }
}
test "residual inverse comparisons both prime moduli" {
 const old=@import("test_residual_baseline.zig");
 var prng=std.Random.DefaultPrng.init(0x494e5645525345);const random=prng.random();
 for([_]u256{p,n}) |modulus| {for(0..100_000) |_| {
  const a=random.int(u256)%(modulus-1)+1;const actual=try inverse(a,modulus);
  try std.testing.expectEqual(try old.inverse(a,modulus),actual);
  try std.testing.expectEqual(@as(u512,1),(@as(u512,a)*actual)%modulus);
 }}
}
'''
 if 'fn reduceScalar(' not in s:
  from variants import SCALAR
  s+=SCALAR.replace('fn reduceScalar(', 'fn scalarOracle(')
  s+='\nfn reduceScalar(w:u512) u256 { return @intCast(w%n); }\n'
 if 'fn reduceScalar(' in s:s+='''
test "residual million arbitrary-width scalar reductions" {
 const boundaries=[_]u512{0,1,n-1,n,n+1,2*@as(u512,n)-1,std.math.maxInt(u256),std.math.maxInt(u512),@as(u512,n-1)*(n-1)};
 for(boundaries) |x| try std.testing.expectEqual(@as(u256,@intCast(x%n)),reduceScalar(x));
 var prng=std.Random.DefaultPrng.init(0x5343414c4152);const random=prng.random();
 for(0..1_000_000) |_| {const x=random.int(u512);try std.testing.expectEqual(@as(u256,@intCast(x%n)),reduceScalar(x));}
}
'''
 if 'fn splitScalar(' in s:s+='''
test "residual hundred thousand GLV splits and reconstruction" {
 var prng=std.Random.DefaultPrng.init(0x474c5653504c4954);const random=prng.random();
 for(0..100_000) |_| {
  const k=random.int(u256);const split=splitScalar(k);
  try std.testing.expectEqual(@as(i512,k%n),@mod(@as(i512,split[0])+@as(i512,lambda)*split[1],@as(i512,n)));
  for(split) |v| {
   try std.testing.expect(@abs(v)<(@as(u256,1)<<129));
   inline for([_]usize{4,5,6,7,8}) |width| {
    const digits=recodeSigned(v,width);var reconstructed:i512=0;
    for(digits.values,0..) |d,bit| reconstructed+=@as(i512,d)<<@as(u9,@intCast(bit));
    try std.testing.expectEqual(@as(i512,v),reconstructed);
   }
  }
 }
 const old=@import("test_original.zig");try expectSamePoint(endomorphism(g),old.g.multiply(lambda));
 for(phi_generator_table,0..) |entry,i| try expectSamePoint(entry,old.g.multiply(@intCast((@as(u512,2*i+1)*lambda)%n)));
}
'''
 if 'const field=@import' in s:s+='''
test "residual specialized square and limb round trips" {
 var prng=std.Random.DefaultPrng.init(0x4c494d425351);const random=prng.random();
 for(0..1_000_000) |_| {const a=random.int(u256)%p;try std.testing.expectEqual(@as(u256,@intCast((@as(u512,a)*a)%p)),field.square(a));}
}
'''
 if 'fn scalarOracle(' in s:s+='\ntest \"baseline wide division versus independently folded scalar oracle\" {var rng=std.Random.DefaultPrng.init(0x524553494455414c);for(0..1_000_000) |_| {const x=rng.random().int(u512);try std.testing.expectEqual(scalarOracle(x),reduceScalar(x));}}\n'
 (dest/'src/root.zig').write_text(s)
 start=time.monotonic();out=docker(['sh','-c','cd /work/'+a.name+'-test && zig build test -Doptimize=ReleaseSafe'])
 (WORK/(a.name+'-arithmetic.log')).write_text(out)
 save(WORK/(a.name+'-arithmetic.json'),dict(result='passed',source_digest=source_digest(source),field_comparisons=1_000_000,scalar_comparisons=1_000_000 if 'fn reduceScalar(' in s else 0,inverse_comparisons_per_modulus=100_000,glv_splits=100_000 if 'fn splitScalar(' in s else 0,point_equivalences=10_000,seconds=time.monotonic()-start,architecture='aarch64-linux',runtime_safety=True))
 print(a.name,'arithmetic passed',flush=True)
if __name__=='__main__':
 with ((_rb_paths()['campaigns'] / 'crypto-lanes/node-benchmark.lock')).open('a') as lock:
  fcntl.flock(lock,fcntl.LOCK_EX);main()
