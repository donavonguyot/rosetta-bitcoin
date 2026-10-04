"""27 fresh-volume measurements; one lock, one instrumented node, three variants."""

import sys as _rb_sys
from pathlib import Path as _RBPath
_rb_sys.path.insert(0, str(_RBPath(__file__).resolve().parents[3] / 'Project/scripts'))
from state_root import operational_paths as _rb_paths
import fcntl,importlib.util
from common import *
from selection import node_interval
spec=importlib.util.spec_from_file_location('previous_replay',ROOT/'Project/scripts/zig_crypto_campaign/measure.py')
previous=importlib.util.module_from_spec(spec);spec.loader.exec_module(previous)
previous.WORK=WORK

def main():
 metadata={v:json.loads((WORK/(v+'-image.json')).read_text()) for v in ('baseline','candidate','c_control')}
 assert len({m['node_digest'] for m in metadata.values()})==1
 assert all(not m['probe'] and not m['reject'] for m in metadata.values())
 result=dict(variants=metadata,warmups=[],runs=[],components={})
 with ((_rb_paths()['campaigns'] / 'crypto-lanes/node-benchmark.lock')).open('a') as lock:
  fcntl.flock(lock,fcntl.LOCK_EX)
  for variant,meta in metadata.items():
   print('warmup',variant,flush=True);result['warmups'].append(previous.replay(meta,'residual-'+variant+'-warmup'))
  orders=[('baseline','candidate','c_control'),('candidate','c_control','baseline'),('c_control','baseline','candidate')]
  for campaign in range(2):
   for index in range(9):
    for variant in orders[index%3]:
     round_id=campaign*9+index;print('measure',round_id,variant,flush=True)
     row=previous.replay(metadata[variant],f'residual-{variant}-{round_id}');row['round']=round_id;result['runs'].append(row)
     save(WORK/'measurements.json',result)
   ci=node_interval(result['runs']);result['elapsed_regression_95']=ci
   save(WORK/'measurements.json',result)
   if ci[1]<=.03 or ci[0]>.03:break
  result['elapsed_gate']='passed' if result['elapsed_regression_95'][1]<=.03 else 'rejected'
  for variant,meta in metadata.items():
   rows=[]
   for batch in range(2):
    output=run(['docker','run','--rm','--network','none','-v',str(WORK)+':/work',meta['image_id'],'component-bench','/work/holdout.json',str(batch)])
    rows.extend(json.loads(line) for line in output.splitlines() if line.startswith('{'))
   result['components'][variant]=rows
  save(WORK/'measurements.json',result)
 print('measured',len(result['runs']),'elapsed gate',result['elapsed_gate'],flush=True)
if __name__=='__main__':main()
