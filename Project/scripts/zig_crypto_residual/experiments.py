"""Run mandatory experiments and width sweep under the shared campaign lock."""
import fcntl,shutil
from common import *
from variants import make
from bench import bench
if __name__=='__main__':
 archive=WORK/'exploratory-measurements';archive.mkdir(exist_ok=True)
 for path in WORK.glob('*-tuning-bench.json'):
  if not (archive/path.name).exists():shutil.copy(path,archive/path.name)
 with (ROOT/'Project/.campaigns/crypto-lanes/node-benchmark.lock').open('a') as lock:
  fcntl.flock(lock,fcntl.LOCK_EX)
  for name in ('baseline','scalar','chain','window','half','tweak','limb-inverse','limbs','glv','both'):bench(name)
  for gw in (5,6,7,8):
   for pw in (4,5,6):
    name=f'glv-g{gw}-p{pw}'
    make(name,scalar=True,sqrt='chain',inverse=True,tweak=True,glv=True,gw=gw,pw=pw)
    bench(name)
