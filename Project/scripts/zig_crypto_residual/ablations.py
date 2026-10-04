"""Remove each retained subsystem before locking the holdout candidate."""

import sys as _rb_sys
from pathlib import Path as _RBPath
_rb_sys.path.insert(0, str(_RBPath(__file__).resolve().parents[3] / 'Project/scripts'))
from state_root import operational_paths as _rb_paths
import fcntl
from common import *
from variants import make
from bench import bench
if __name__=='__main__':
 with ((_rb_paths()['campaigns'] / 'crypto-lanes/node-benchmark.lock')).open('a') as lock:
  fcntl.flock(lock,fcntl.LOCK_EX)
  for helper in ('scalar','sqrt','inverse','tweak','glv'):
   cfg=dict(scalar=True,sqrt='chain',inverse=True,tweak=True,glv=True,gw=8,pw=4)
   cfg[helper]=None if helper=='sqrt' else False
   name='without-'+helper;make(name,**cfg);bench(name)
  bench('glv-g8-p4');bench('baseline')
