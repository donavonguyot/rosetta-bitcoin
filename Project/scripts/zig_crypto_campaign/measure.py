"""Fresh-volume, rotated three-way measurements, separate from canonical claims."""

import sys as _rb_sys
from pathlib import Path as _RBPath
_rb_sys.path.insert(0, str(_RBPath(__file__).resolve().parents[3] / 'Project/scripts'))
from state_root import operational_paths as _rb_paths
import fcntl,json,subprocess,sys,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3];WORK=(_rb_paths()['campaigns'] / 'zig-opt')
sys.path.insert(0,str(ROOT/'Project/scripts'));from crypto_lanes import HASH

def run(cmd):
 p=subprocess.run(cmd,cwd=ROOT,capture_output=True,text=True)
 if p.returncode:raise RuntimeError(str(cmd)+'\n'+p.stdout+p.stderr)
 return p.stdout

def replay(meta,label):
 volume='rosetta-zig-opt-'+label+'-'+str(time.time_ns());run(['docker','volume','create',volume])
 filename='run-'+label+'.json';cmd=['docker','run','--rm','--user','0','--network','rosetta-reference-node_default','-v',volume+':/data','-v',str(WORK)+':/results','-e','ZIGBITNODE_RUNTIME_SURFACE=docker','-e','ZIGBITNODE_SCRIPT_THREADS=4','-e','PREFETCH_DEPTH=4',meta['image_id'],'zigbitnode','local-reference-proof','--datadir','/data','--target','5000','--peer','bitcoin-core-testnet4:48333','--output','/results/'+filename]
 started=time.monotonic();output=run(cmd);elapsed=time.monotonic()-started;(WORK/('run-'+label+'.log')).write_text(output)
 raw=json.loads((WORK/filename).read_text())
 for key,value in {'validated_height':5000,'validated_hash':HASH,'chainstate_utxo_count':4574,'chainstate_backend':'rocksdb','rocksdb_wal_disabled':False,'fresh_state':True,'prefetch_depth':4,'script_runner_mode':'parallel','script_threads':4,'utxo_accounting_policy':'core_spendable_v1','byte_source':'local_reference_p2p'}.items():assert raw.get(key)==value,(key,raw.get(key))
 progress=[json.loads(x.split('rb.port_progress ',1)[1]) for x in output.splitlines() if x.startswith('rb.port_progress ')][-1]
 assert progress['crypto_source_digest']==meta['source_digest'];assert progress['crypto_lane']==meta['lane']
 status=json.loads(run(['docker','run','--rm','--user','0','--network','none','-v',volume+':/data',meta['image_id'],'zigbitnode','status','--datadir','/data']))
 assert status['crypto_source_digest']==meta['source_digest'] and status['validated_height']==5000
 ticks=[json.loads(x.split('benchmark.telemetry_tick ',1)[1]) for x in output.splitlines() if x.startswith('benchmark.telemetry_tick ')]
 last=ticks[-1];buckets=raw['timing_summary']['stage_totals_ms']
 # New units are explicit even though legacy stage_totals_ms contains mixed-unit fields.
 metrics={key:buckets[key] for key in ('script_worker_elapsed_ns','script_worker_thread_cpu_ns')}
 assert all(v>0 for v in metrics.values());jobs=last['script_jobs'];assert jobs>0
 result={'variant':meta['variant'],'lane':meta['lane'],'implementation':progress['native_crypto_backend'],'source_digest':meta['source_digest'],'node_digest':meta['node_digest'],'image_id':meta['image_id'],'label':label,'command':cmd,'volume':volume,'fresh_state':True,'wall_seconds':elapsed,'node_elapsed_ms':raw['timing_summary']['total_ms'],'script_wall_ms':buckets['script_verify'],'script_jobs':jobs,**metrics,'worker_elapsed_ns_per_job':metrics['script_worker_elapsed_ns']/jobs,'worker_cpu_ns_per_job':metrics['script_worker_thread_cpu_ns']/jobs,'timing_coverage':'scheduler worker loops; excludes verifier lifecycle; includes interpreter/hash/scheduling','writer_progress':progress,'settled_status':status,'raw_proof':raw}
 run(['docker','volume','rm',volume]);return result

def main():
 metadata={v:json.loads((WORK/f'{v}-image.json').read_text()) for v in ('original','optimized','c_control')}
 assert len({v['node_digest'] for v in metadata.values()})==1
 result={'variants':metadata,'warmups':[],'runs':[],'components':{}}
 with ((_rb_paths()['campaigns'] / 'crypto-lanes/node-benchmark.lock')).open('w') as lock:
  fcntl.flock(lock,fcntl.LOCK_EX)
  for variant,meta in metadata.items():
   print('warmup',variant,flush=True);result['warmups'].append(replay(meta,variant+'-warmup'))
  for index,order in enumerate([('original','optimized','c_control'),('optimized','c_control','original'),('c_control','original','optimized')]):
   for variant in order:
    print('measure',index,variant,flush=True);result['runs'].append(replay(metadata[variant],variant+'-'+str(index)))
    (WORK/'measurements.json').write_text(json.dumps(result,indent=2)+'\n')
  for variant,meta in metadata.items():
   print('component',variant,flush=True)
   output=run(['docker','run','--rm','--network','none',meta['image_id'],'component-bench'])
   result['components'][variant]=[json.loads(x) for x in output.splitlines() if x.startswith('{')]
   assert len(result['components'][variant])==45
   result['variants'][variant]['build_packages']=run(['docker','run','--rm','--network','none',meta['image_id'],'cat','/usr/local/bin/build-packages.txt'])
   result['variants'][variant]['linkage']=run(['docker','run','--rm','--network','none',meta['image_id'],'ldd','/usr/local/bin/zigbitnode'])
   if variant=='c_control':result['variants'][variant]['c_library_sha256']=run(['docker','run','--rm','--network','none',meta['image_id'],'cat','/usr/local/bin/c-library-sha256.txt'])
  (WORK/'measurements.json').write_text(json.dumps(result,indent=2)+'\n')
if __name__=='__main__':main()
