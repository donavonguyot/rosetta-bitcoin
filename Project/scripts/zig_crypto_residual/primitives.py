"""Separate primitive timings in disposable copies; runtime safety stays enabled."""

import sys as _rb_sys
from pathlib import Path as _RBPath
_rb_sys.path.insert(0, str(_RBPath(__file__).resolve().parents[3] / 'Project/scripts'))
from state_root import operational_paths as _rb_paths
import shutil,fcntl,re
from common import *
DRIVER='''const std=@import("std");const secp=@import("secp256k1");
pub fn main(init:std.process.Init) !void {
 var rng=std.Random.DefaultPrng.init(0x5052494d49544956);const random=rng.random();
 var inputs:[256]struct{a:u256,b:u256,w:u512}=undefined;
 for(&inputs) |*v| v.*=.{.a=random.int(u256)%0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364140+1,.b=random.int(u256)%0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364140+1,.w=random.int(u512)};
 const names=[_][]const u8{"field/multiply","field/square","field/reduce","field/convert","inverse/field","inverse/scalar","scalar/reduce","sqrt"};
 var buf:[4096]u8=undefined;var writer:std.Io.File.Writer=.init(.stdout(),init.io,&buf);const out=&writer.interface;
 for(0..5) |rep| {for(names,0..) |name,op| {
  const start=std.Io.Clock.awake.now(init.io).nanoseconds;
  for(0..1024) |i| {const v=inputs[(i+rep*37)%256];std.mem.doNotOptimizeAway(secp.primitive(op,v.a,v.b,v.w));}
  const elapsed=std.Io.Clock.awake.now(init.io).nanoseconds-start;
  try out.print("{{\\"operation\\":\\"{s}\\",\\"repetition\\":{d},\\"iterations\\":1024,\\"total_ns\\":{d}}}\\n",.{name,rep,elapsed});
 }}try out.flush();
}
'''
def main():
 shutil.copyfile(HERE/'bench.zig',WORK/'unused-bench-source.zig')
 (WORK/'primitive-main.zig').write_text(DRIVER)
 for name in ('baseline','candidate','limbs'):
  dest=WORK/(name+'-primitives');shutil.copytree(WORK/name,dest,dirs_exist_ok=True,ignore=shutil.ignore_patterns('.zig-cache','zig-out'))
  s=(dest/'src/root.zig').read_text()
  scalar='reduceScalar(w)' if 'fn reduceScalar(' in s else '@as(u256,@intCast(w%n))'
  sqrt='sqrtPower(a)' if 'fn sqrtPower(' in s else 'pow(a,(p+1)/4,p)'
  square='field.square(a)' if name=='limbs' else 'mul(a,a)'
  reduction='field.reduceWide(w)' if name=='limbs' else 'reduceField(w)'
  conversion='field.roundtrip(a)' if name=='limbs' else 'a'
  if name=='limbs':
   f=dest/'src/field.zig';f.write_text(f.read_text()+'''\npub fn reduceWide(w:u512) u256 {const input:[8]u64=@bitCast(w);var t:[9]u64=@splat(0);@memcpy(t[0..8],&input);return reduce(t);}\npub fn roundtrip(a:u256) u256 {return integer(words(a));}\n''')
  s+='\npub noinline fn primitive(op:usize,a:u256,b:u256,w:u512) u256 {return switch(op){0=>mul(a,b),1=>'+square+',2=>'+reduction+',3=>'+conversion+',4=>inverse(a,p) catch unreachable,5=>inverse(a,n) catch unreachable,6=>'+scalar+',7=>'+sqrt+',else=>unreachable};}\n'
  (dest/'src/root.zig').write_text(s)
  docker(['zig','build-exe','-O','ReleaseSafe','--dep','secp256k1','-Mroot=/work/primitive-main.zig','-O','ReleaseSafe','-Msecp256k1=/work/'+name+'-primitives/src/root.zig','-femit-bin=/work/primitive-'+name,'-femit-asm=/work/primitive-'+name+'.s'])
  output=docker(['/work/primitive-'+name]);rows=[json.loads(line) for line in output.splitlines() if line.startswith('{')]
  asm=(WORK/('primitive-'+name+'.s')).read_text()
  save(WORK/(name+'-primitives.json'),dict(source_digest=source_digest(WORK/name),rows=rows,safety='ReleaseSafe enabled; timings include generated checks; no safety-off counterfactual',conversion='bitcast roundtrip optimizes to identity; result includes dispatch/call cost',safety_assembly_trap_references=len(re.findall(r'bl\s+.*(?:Panic|panic)',asm)),safety_cost_attribution='not independently identifiable from inclusive cost without a counterfactual; trap references are static, not executed counts'))
 print('primitive measurements complete')
if __name__=='__main__':
 with ((_rb_paths()['campaigns'] / 'crypto-lanes/node-benchmark.lock')).open('a') as lock:
  fcntl.flock(lock,fcntl.LOCK_EX);main()
