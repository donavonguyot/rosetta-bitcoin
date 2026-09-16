"""Campaign-local evidence rules. Does not import or curate canonical evidence."""
import argparse,json,statistics,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3];sys.path.insert(0,str(ROOT/'Project/scripts'))
from crypto_lanes import HASH
SCHEMA='rb.crypto_optimization_comparison.v1'
VARIANTS=('original','optimized','c_control')
OPERATIONS=('ecdsa/valid','ecdsa/late_invalid','schnorr/valid','schnorr/late_invalid','parse/valid','parse/early_invalid','tweak/valid','tweak/early_invalid','ecdsa/scalar_early_invalid')
def validate(d):
 errors=[]
 def require(ok,msg):
  if not ok:errors.append(msg)
 require(d.get('schema')==SCHEMA,'schema');require(d.get('comparison_label')=='campaign_comparable','comparison label');require(d.get('binary_gate_status')=='not_attempted','tip gate')
 meta=d.get('variants',{});require(set(meta)==set(VARIANTS),'three variants')
 require(len({m.get('node_digest') for m in meta.values()})==1,'identical node source')
 checks=d.get('validation',{}).get('checks',{})
 require(d.get('validation',{}).get('source_digest')==meta.get('optimized',{}).get('source_digest'),'validated source digest')
 for k in ('arithmetic','shared_vectors','node_regression','isolated_build','external_consumer','malformed_subprocesses','differential','dependency_audit','script_corpus','adapter_usage','fault_injection','backend_selection','trace_differential'):
  require(checks.get(k,{}).get('result')=='passed',k)
 require(checks.get('arithmetic',{}).get('cases',0)>=10000,'10000 arithmetic cases')
 require(checks.get('differential',{}).get('cases',0)>=10000,'10000 differential cases')
 require(checks.get('shared_vectors',{}).get('cases')==52,'52 shared vectors')
 require(checks.get('script_corpus',{}).get('passed')==45,'45 script fixtures')
 for kind in ('differential','trace_differential'):
  require(not checks.get(kind,{}).get('failures'),'reference differences')
  require(checks.get(kind,{}).get('reference_commit')=='0cdc758a56360bf58a851fe91085a327ec97685a','reference pin')
 runs=d.get('runs',[]);require(len(runs)==9,'nine measured runs')
 expected=['original','optimized','c_control','optimized','c_control','original','c_control','original','optimized']
 require([r.get('variant') for r in runs]==expected,'rotated sequential order')
 require(len(d.get('warmups',[]))==3,'three warmups')
 allruns=d.get('warmups',[])+runs
 require(len({r.get('volume') for r in allruns})==12,'fresh distinct volumes')
 for r in allruns:
  m=meta.get(r.get('variant'),{});raw=r.get('raw_proof',{});progress=r.get('writer_progress',{})
  for key in ('source_digest','node_digest','image_id','lane'):require(r.get(key)==m.get(key),'run '+key)
  require(progress.get('crypto_source_digest')==r.get('source_digest'),'writer digest')
  require(r.get('settled_status',{}).get('crypto_source_digest')==r.get('source_digest'),'persisted digest')
  for key,val in {'validated_height':5000,'validated_hash':HASH,'chainstate_utxo_count':4574,'fresh_state':True,'prefetch_depth':4,'script_runner_mode':'parallel','script_threads':4,'rocksdb_wal_disabled':False,'chainstate_backend':'rocksdb','utxo_accounting_policy':'core_spendable_v1','byte_source':'local_reference_p2p'}.items():require(raw.get(key)==val,'proof '+key)
  require(r.get('script_worker_thread_cpu_ns',0)>0 and r.get('script_jobs',0)>0,'worker timing')
 for variant in VARIANTS:
  m=meta.get(variant,{});require(m.get('lane')==('c_binding' if variant=='c_control' else 'own_curve'),'variant lane')
  require(not m.get('probe') and not m.get('reject'),'uninstrumented crypto')
  digest=m.get('source_digest','');require(len(digest)==64 and all(c in '0123456789abcdef' for c in digest),'source hash')
  rows=d.get('components',{}).get(variant,[])
  for op in OPERATIONS:
   samples=[r for r in rows if r.get('operation')==op];require(len(samples)==5 and all(r.get('iterations')==1024 for r in samples),'component '+variant+' '+op)
 stages=d.get('stages',[]);require(len(stages)==4 and all(s.get('retained') for s in stages),'four measured retained stages')
 for index,stage in enumerate(stages):
  if index >= 4:break
  before=('original','stage1','stage2','stage3')[index];after='stage'+str(index+1)
  metric=('field_mul','scalar_fermat','binary_inverse','field_mul')[index]
  require(stage.get('stage')==after and stage.get('previous')==before,'stage order')
  require(stage.get('counts_after',{}).get(metric,float('inf'))<stage.get('counts_before',{}).get(metric,0),'stage operation improvement')
  batches=stage.get('batches',[]);require(len(batches)==2,'two independent batches')
  for batch in batches:
   for name in (before,after):
    sample=batch.get(name,{});values=sample.get('samples_ns',[])
    require(len(values)==5 and all(v>0 for v in values),'five stage samples')
    if values:require(statistics.median(values)==sample.get('median_ns'),'stage median')
   require(batch.get(after,{}).get('median_ns',float('inf'))<batch.get(before,{}).get('median_ns',0),'stage timing improvement')
 original=[r.get('wall_seconds',0) for r in runs if r.get('variant')=='original']
 optimized=[r.get('wall_seconds',0) for r in runs if r.get('variant')=='optimized']
 if original and optimized:require(statistics.median(optimized)<=max(original),'end-to-end retention')
 require(d.get('canonical_unchanged') is True,'canonical selection')
 return errors

def summary(d):
 print('| variant | elapsed median s | script median s | worker CPU µs/job | ECDSA µs/op |')
 print('| --- | ---: | ---: | ---: | ---: |')
 for name in VARIANTS:
  rows=[r for r in d['runs'] if r['variant']==name]
  bench=[r['total_ns']/r['iterations']/1000 for r in d['components'][name] if r['operation']=='ecdsa/valid']
  print(f"| {name} | {statistics.median(r['wall_seconds'] for r in rows):.3f} | {statistics.median(r['script_wall_ms'] for r in rows)/1000:.3f} | {statistics.median(r['worker_cpu_ns_per_job'] for r in rows)/1000:.3f} | {statistics.median(bench):.3f} |")
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('artifact',type=Path);a=p.parse_args();d=json.loads(a.artifact.read_text());errors=validate(d)
 if errors:raise SystemExit('\n'.join(errors))
 summary(d)
