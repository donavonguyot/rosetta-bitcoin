"""Serialized post-selection gates and builds; abort on the first failed gate."""
import subprocess,sys,time
from common import *
if __name__=='__main__':
 steps=[('arithmetic.py',['candidate']),('counts.py',['baseline','candidate']),('build.py',['baseline']),('build.py',['candidate']),('build.py',['c_control']),('validate_candidate.py',[]),('x86.py',[])]
 for script,args in steps:
  print('START',script,*args,flush=True)
  with (WORK/(script+'.log')).open('w') as out:
   p=subprocess.run([sys.executable,HERE/script,*args],cwd=ROOT,stdout=out,stderr=subprocess.STDOUT)
  if p.returncode:raise SystemExit(f'{script} failed: {WORK/(script+".log")}')
  print('PASS',script,flush=True)
