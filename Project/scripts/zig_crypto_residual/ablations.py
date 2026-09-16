"""Remove each retained subsystem before locking the holdout candidate."""
import fcntl
from common import *
from variants import make
from bench import bench
if __name__=='__main__':
 with (ROOT/'Project/.campaigns/crypto-lanes/node-benchmark.lock').open('a') as lock:
  fcntl.flock(lock,fcntl.LOCK_EX)
  for helper in ('scalar','sqrt','inverse','tweak','glv'):
   cfg=dict(scalar=True,sqrt='chain',inverse=True,tweak=True,glv=True,gw=8,pw=4)
   cfg[helper]=None if helper=='sqrt' else False
   name='without-'+helper;make(name,**cfg);bench(name)
  bench('glv-g8-p4');bench('baseline')
