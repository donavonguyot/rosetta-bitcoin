"""Counters in disposable copies; operation totals never enter measured images."""
import argparse,re,shutil,hashlib
from common import *
def main():
 p=argparse.ArgumentParser();p.add_argument('names',nargs='+');a=p.parse_args()
 names=['mul','reduceField','double','plus','mixed','inverse','recode','recodeWidth','recodeSigned','oddTableWidth','joint','splitScalar','reduceScalar','sqrtPower','generatorMultiply']
 for name in a.names:
  src=WORK/name;dest=WORK/(name+'-counts');shutil.copytree(src,dest,dirs_exist_ok=True,ignore=shutil.ignore_patterns('.zig-cache','zig-out'))
  s=(dest/'src/root.zig').read_text()
  for index,fn in enumerate(names):s=re.sub(r'(fn '+fn+r'\([^\n]+\{)',lambda m:m[0]+f'\n if(!@inComptime()) residual_counts[{index}]+=1;',s)
  s+='\nvar residual_counts:['+str(len(names))+']u64=@splat(0);\npub fn countsReset() void {residual_counts=@splat(0);}\npub fn countsDump(op:usize) void {for(residual_counts,0..) |c,i| std.debug.print("COUNT {d} {d} {d}\\n",.{op,i,c});}\n'
  (dest/'src/root.zig').write_text(s)
  b=(ROOT/'Project/scripts/zig_crypto_campaign/bench.zig').read_text().replace('for (0..5) |repeat|','for (0..1) |repeat|').replace('for (0..1024)','for (0..1)').replace('const start = std.Io.Clock.awake','secp.countsReset();\n const start = std.Io.Clock.awake').replace('const elapsed = std.Io.Clock.awake','secp.countsDump(op);\n const elapsed = std.Io.Clock.awake')
  (dest/'src/bench.zig').write_text(b)
  docker(['zig','build-exe','-O','ReleaseSafe','--dep','secp256k1','-Mroot=/work/'+name+'-counts/src/bench.zig','-O','ReleaseSafe','-Msecp256k1=/work/'+name+'-counts/src/root.zig','-femit-bin=/work/counts-'+name])
  text=docker(['/work/counts-'+name]);rows={}
  for line in text.splitlines():
   if line.startswith('COUNT '):
    op,index,count=map(int,line.split()[1:]);rows.setdefault(str(op),{})[names[index]]=count
  save(WORK/(name+'-counts.json'),dict(source_digest=source_digest(src),operations=rows,fixture='first valid Shared ECDSA/Schnorr rows; old fixed-input continuity workload'))
if __name__=='__main__':main()
