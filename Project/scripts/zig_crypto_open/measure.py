"""27 fresh-volume measurements; one lock, one instrumented node, three variants."""

import sys as _rb_sys
from pathlib import Path as _RBPath
_rb_sys.path.insert(0, str(_RBPath(__file__).resolve().parents[3] / 'Project/scripts'))
from state_root import operational_paths as _rb_paths
import fcntl,importlib.util,os
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
  info=json.loads(run(['docker','info','--format','{{json .}}']))
  result['environment']={'docker':{k:info.get(k) for k in ('NCPU','MemTotal','Architecture','KernelVersion','ServerVersion','OperatingSystem')},'host_load_before':os.getloadavg(),'thermal_power_observation':run(['pmset','-g','therm']),'affinity_note':'Default guest affinity; virtual CPU allocation does not guarantee physical performance-core placement.'}
  for variant,meta in metadata.items():
   meta['build_packages']=run(['docker','run','--rm','--network','none',meta['image_id'],'cat','/usr/local/bin/build-packages.txt'])
   meta['linkage']=run(['docker','run','--rm','--network','none',meta['image_id'],'ldd','/usr/local/bin/zigbitnode'])
   if variant=='c_control':meta['c_library_sha256']=run(['docker','run','--rm','--network','none',meta['image_id'],'cat','/usr/local/bin/c-library-sha256.txt'])
   if variant=='c_control':assert meta['c_library_sha256'].split()[0]==json.loads((WORK/'control-selection.json').read_text())['selected']['library_sha256']
   print('warmup',variant,flush=True);result['warmups'].append(previous.replay(meta,'open-'+variant+'-warmup'))
  orders=[('baseline','candidate','c_control'),('candidate','c_control','baseline'),('c_control','baseline','candidate')]
  for campaign in range(2):
   for index in range(9):
    for variant in orders[index%3]:
     round_id=campaign*9+index;print('measure',round_id,variant,flush=True)
     load=os.getloadavg();row=previous.replay(metadata[variant],f'open-{variant}-{round_id}');row['host_load_before']=load;row['host_load_after']=os.getloadavg();row['round']=round_id;result['runs'].append(row)
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
