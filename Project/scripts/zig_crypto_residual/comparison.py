"""Residual campaign evidence only. Never eligible as canonical lane evidence."""
import argparse,re
from common import *
SCHEMA='rb.zig_crypto_residual_comparison.v1'
def validate(d):
 errors=[]
 def require(ok,message):
  if not ok:errors.append(message)
 require(d.get('schema')==SCHEMA,'wrong schema')
 require(d.get('report_label')=='campaign_comparable','wrong report label')
 require(d.get('binary_gate_status')=='not_attempted','binary gate')
 require(d.get('curated_current') is False,'must remain uncurated')
 variants=d.get('variants',{})
 require(set(variants)=={'baseline','candidate','c_control'},'variant roster')
 digests=[]
 for name,m in variants.items():
  require(bool(re.fullmatch('[0-9a-f]{64}',m.get('source_digest',''))),'invalid source digest '+name)
  require(m.get('lane')==('c_binding' if name=='c_control' else 'own_curve'),'wrong lane '+name)
  require(bool(re.fullmatch('sha256:[0-9a-f]{64}',m.get('image_id',''))),'missing immutable image '+name)
  require(not m.get('probe') and not m.get('reject'),'instrumented benchmark '+name)
  digests.append(m.get('node_digest'))
 require(len(set(digests))==1 and None not in digests,'inconsistent node digest')
 rows=d.get('runs',[]);require(len(rows) in (27,54),'must contain 27 or 54 measurements')
 orders=[('baseline','candidate','c_control'),('candidate','c_control','baseline'),('c_control','baseline','candidate')]
 require([(r.get('round'),r.get('variant')) for r in rows]==[(i,v) for i in range(len(rows)//3) for v in orders[i%3]],'rotation/order mismatch')
 warmups=d.get('warmups',[]);require(len(warmups)==3 and {r.get('variant') for r in warmups}==set(variants),'warmups missing')
 for r in rows+warmups:
  meta=variants.get(r.get('variant'),{})
  for owner in ('writer_progress','settled_status'):
   value=r.get(owner,{})
   require(value.get('crypto_source_digest')==meta.get('source_digest'),'writer/status digest mismatch')
   if owner=='writer_progress':require(value.get('crypto_lane')==meta.get('lane'),'writer lane mismatch')
   else:require(value.get('native_crypto_backend')==r.get('implementation'),'status backend mismatch')
  require(r.get('fresh_state') is True,'warmup/measured state reused')
 require(len({r.get('volume') for r in rows+warmups})==len(rows)+len(warmups),'warmup volume reuse')
 for variant,components in d.get('components',{}).items():
  require(len(components)==90,'component repetition count')
  require(all(r.get('iterations')==1024 for r in components),'component iteration floor')
 require(set(d.get('components',{}))==set(variants),'component variants missing')
 candidate_digest=variants.get('candidate',{}).get('source_digest')
 require(d.get('validation',{}).get('source_digest')==candidate_digest,'validation digest mismatch')
 baseline_selected=candidate_digest==variants.get('baseline',{}).get('source_digest')
 require(d.get('holdout',{}).get('candidate_digest')==candidate_digest and (baseline_selected or d.get('holdout',{}).get('qualifies') is True),'holdout missing or inconsistent')
 require(d.get('profile',{}).get('roster_locked') is True,'profile roster not sealed')

 seen=set()
 for r in rows:
  v=r.get('variant');m=variants.get(v,{})
  key=(r.get('round'),v);require(key not in seen,'duplicate round variant');seen.add(key)
  for field in ('source_digest','node_digest','image_id','lane'):require(r.get(field)==m.get(field),'run/package '+field+' mismatch')
  require(r.get('fresh_state') is True,'reused proof volume')
  proof=r.get('raw_proof',{})
  from crypto_lanes import HASH
  for field,value in {'validated_height':5000,'validated_hash':HASH,'chainstate_utxo_count':4574,'chainstate_backend':'rocksdb','rocksdb_wal_disabled':False,'prefetch_depth':4,'script_threads':4,'byte_source':'local_reference_p2p','utxo_accounting_policy':'core_spendable_v1'}.items():require(proof.get(field)==value,'proof '+field)
  require(r.get('script_jobs',0)>0 and r.get('script_worker_thread_cpu_ns',0)>0,'CPU coverage missing')
 require(len({r.get('volume') for r in rows})==len(rows),'volume reuse')
 checks=d.get('validation',{}).get('checks',{})
 for name in ('shared_vectors','isolated_build','external_consumer','malformed_subprocesses','dependency_audit','script_corpus','backend_selection','adapter_usage','fault_injection','trace_differential','x86_correctness'):
  require(checks.get(name,{}).get('result')=='passed','missing gate '+name)
 diff=checks.get('differential',{});require(diff.get('cases',0)>=100_000 and diff.get('result')=='passed' and not diff.get('failures'),'differential floor')
 require(diff.get('source_digest')==variants.get('candidate',{}).get('source_digest'),'differential digest mismatch')
 arith=d.get('arithmetic',{});require(arith.get('result')=='passed' and arith.get('field_comparisons',0)>=1_000_000 and arith.get('scalar_comparisons',0)>=1_000_000,'arithmetic floors')
 require(arith.get('source_digest')==variants.get('candidate',{}).get('source_digest'),'arithmetic digest mismatch')
 require(arith.get('inverse_comparisons_per_modulus',0)>=100_000 and (baseline_selected or arith.get('glv_splits',0)>=100_000) and arith.get('point_equivalences',0)>=10_000,'retained arithmetic floors')
 require(checks.get('x86_correctness',{}).get('source_digest')==candidate_digest,'x86 digest mismatch')
 require(d.get('historical_compatibility',{}).get('result')=='passed','historical compatibility')
 require(d.get('elapsed_gate')=='passed','elapsed gate')
 return errors
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('report',type=Path);a=p.parse_args();errors=validate(json.loads(a.report.read_text()));print('\n'.join(errors) if errors else 'valid residual comparison');raise SystemExit(bool(errors))
