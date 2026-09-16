"""One confirmation, no holdout-driven retuning."""
import fcntl,shutil
from common import *
from bench import bench
from selection import assess
if __name__=='__main__':
 if (WORK/'holdout-decision.json').exists():raise SystemExit('holdout already consumed')
 with (ROOT/'Project/.campaigns/crypto-lanes/node-benchmark.lock').open('a') as lock:
  fcntl.flock(lock,fcntl.LOCK_EX)
  baseline=bench('baseline','holdout');candidate=bench('candidate','holdout');decision=assess(baseline,candidate)
  decision['candidate_digest']=source_digest(WORK/'candidate');decision['holdout_identity']=json.loads((WORK/'holdout-identity.json').read_text())
  save(WORK/'holdout-decision.json',decision)
  if not decision['qualifies']:
   shutil.move(WORK/'candidate',WORK/'holdout-rejected-candidate')
   shutil.copytree(FROZEN,WORK/'candidate',ignore=shutil.ignore_patterns('.zig-cache','zig-out'))
   decision['rejected_candidate_digest']=decision['candidate_digest']
   decision['candidate_digest']=source_digest(WORK/'candidate');decision['selection']='baseline'
   save(WORK/'holdout-decision.json',decision)
  assert source_digest(LIB)==json.loads((HERE/'baseline.json').read_text())['package_digest'],'working package changed since freeze'
  shutil.copytree(WORK/'candidate',LIB,dirs_exist_ok=True,ignore=shutil.ignore_patterns('.zig-cache','zig-out'))
  assert source_digest(LIB)==decision['candidate_digest']
  print('selected package published',decision['scores'],flush=True)
