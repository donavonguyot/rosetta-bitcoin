"""Sequential ARM64 uninstrumented component measurements with recorded identities."""
import argparse,time,shutil,fcntl,statistics
from common import *
def bench(name,phase='tuning'):
 package=WORK/name
 shutil.copy(HERE/'bench.zig',WORK/'bench.zig')
 start=time.monotonic()
 output=docker(['zig','build-exe','-O','ReleaseSafe','--dep','secp256k1','-Mroot=/work/bench.zig','-O','ReleaseSafe','-Msecp256k1=/work/'+name+'/src/root.zig','-femit-bin=/work/bench-'+name,'-femit-asm=/work/bench-'+name+'.s'])
 compile_seconds=time.monotonic()-start
 rows=[]
 for batch in range(2):
  out=docker(['/work/bench-'+name,'/work/'+phase+'.json',str(batch)])
  rows.extend(json.loads(line) for line in out.splitlines() if line.startswith('{'))
 result=dict(name=name,phase=phase,source_digest=source_digest(package),compile_seconds=compile_seconds,binary_bytes=(WORK/('bench-'+name)).stat().st_size,architecture='aarch64-linux',optimize='ReleaseSafe',measurements=rows)
 save(WORK/(name+'-'+phase+'-bench.json'),result)
 print(name,{op:round(statistics.median(r['total_ns']/1024 for r in rows if r['operation']==op)/1000,3) for op in ('ecdsa/valid','schnorr/valid','parse/valid','tweak/valid')},flush=True)
 return result
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('names',nargs='+');p.add_argument('--phase',default='tuning');a=p.parse_args()
 with (ROOT/'Project/.campaigns/crypto-lanes/node-benchmark.lock').open('a') as lock:
  fcntl.flock(lock,fcntl.LOCK_EX)
  for name in a.names:bench(name,a.phase)
