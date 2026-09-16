"""Assemble comparison and uncurated candidate evidence from writer-owned output."""
import copy,datetime,hashlib,json,platform,statistics,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3];WORK=ROOT/'Project/.campaigns/zig-opt';HERE=Path(__file__).parent
sys.path.insert(0,str(ROOT/'Project/scripts'));import crypto_lanes
from comparison import SCHEMA,validate,summary

def load(name):return json.loads((WORK/name).read_text())
def main():
 d=load('measurements.json');d.update(schema=SCHEMA,comparison_label='campaign_comparable',binary_gate_status='not_attempted',captured_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),validation=load('validation.json'),baseline=load('baseline.json'),stages=[])
 d['toolchain']={'zig':'0.16.0','optimization':'ReleaseSafe','architecture':platform.machine(),'docker_base':'debian:bookworm-slim@sha256:0104b334637a5f19aa9c983a91b54c89887c0984081f2068983107a6f6c21eeb','rocksdb':'7.8.3-2','reference_commit':'0cdc758a56360bf58a851fe91085a327ec97685a','c_build':'CMake Release; static; compiler identity and packages recorded per variant'}
 d['toolchain_lock']=json.loads((HERE/'toolchains.lock.json').read_text())
 for variant,m in d['variants'].items():
  packages=dict(line.split('\t',1) for line in m['build_packages'].splitlines())
  for package,version in d['toolchain_lock']['build_packages'].items():assert packages.get(package)==version,(package,packages.get(package),version)
  m['c_compiler']=subprocess.check_output(['docker','run','--rm','--network','none',m['image_id'],'cat','/usr/local/bin/c-compiler.txt'],text=True)
  m['runtime_architecture']=subprocess.check_output(['docker','image','inspect',m['image_id'],'--format','{{.Architecture}}'],text=True).strip()
 for before,after,target,counter in [('original','stage1','schnorr/valid','field_mul'),('stage1','stage2','ecdsa/valid','scalar_fermat'),('stage2','stage3','ecdsa/valid','binary_inverse'),('stage3','stage4','ecdsa/valid','field_mul')]:
  entry={'stage':after,'previous':before,'target':target,'counts_before':load(before+'-counts.json'),'counts_after':load(after+'-counts.json'),'batches':[],'source':load(after+'-source.json')}
  wins=[]
  for b in range(2):
   values={}
   for name in (before,after):
    rows=[json.loads(x) for x in (WORK/f'{name}-bench-{b}.jsonl').read_text().splitlines() if x.startswith('{')]
    samples=[r['total_ns']/r['iterations'] for r in rows if r['operation']==target];assert len(samples)==5
    values[name]={'median_ns':statistics.median(samples),'min_ns':min(samples),'max_ns':max(samples),'samples_ns':samples}
   wins.append(values[after]['median_ns']<values[before]['median_ns']);entry['batches'].append(values)
  entry['retained']=all(wins) and entry['counts_after'][counter]<entry['counts_before'][counter];assert entry['retained'],entry;d['stages'].append(entry)
 original=[r['wall_seconds'] for r in d['runs'] if r['variant']=='original'];optimized=[r['wall_seconds'] for r in d['runs'] if r['variant']=='optimized']
 assert statistics.median(optimized)<=max(original),'Regression requires repeating the complete rotation'
 d['retention']={'end_to_end_regression':False,'original_slowest_seconds':max(original),'optimized_median_seconds':statistics.median(optimized),'hypothesis':'2.5–4x ECDSA microbenchmark improvement, not a gate'}
 for section,name,extra in [('baseline-5k','canonical-baseline-before.txt',[]),('leaderboard','canonical-leaderboard-before.txt',['--gate','baseline_5k'])]:
  output=subprocess.check_output([sys.executable,ROOT/'Project/scripts/report.py','--db',ROOT/'Project/project.db','--section',section,*extra],text=True)
  assert output==(WORK/name).read_text(),section
 d['canonical_unchanged']=True
 d['curated_index_sha256']=hashlib.sha256((ROOT/'Nodes/Shared/conformance/current_evidence.json').read_bytes()).hexdigest()
 assert d['curated_index_sha256']==(WORK/'curated-before.sha256').read_text().strip()
 d['notes']=['Worker timings include interpreter, hashing and scheduling, not just signature verification.','Legacy worker_cpu_ms remains elapsed time; new worker_thread_cpu_ns uses a thread CPU clock.','No canonical evidence selected or replaced. C is a separately built control; no C implementation code or tables copied into own_curve.']
 errors=validate(d);assert not errors,errors
 stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
 comparison=ROOT/'Nodes/Shared/conformance/crypto_comparisons'/f'zig_optimization_{stamp}.json';comparison.write_text(json.dumps(d,indent=2)+'\n')
 meta=d['variants']['optimized'];base={'schema':crypto_lanes.SCHEMA,'port':'zig','lane':'own_curve','implementation':'libsecp256k1-zig','source_digest':meta['source_digest'],'captured_at':d['captured_at'],'binary_gate_status':'not_attempted','result':'passed','toolchain':d['toolchain'],'build_settings':{'optimization':'ReleaseSafe','candidate_only':True,'comparison_report':str(comparison.relative_to(ROOT))},'dependencies':{'production':[],'ffi':False,'curve_provider':'package','arithmetic':'package u257/u512; variable-time binary inverse; separate-table width-5 Straus','hashing':'Zig std.crypto.hash.sha2.Sha256'},'checks':d['validation']['checks'],'node_source_digest':meta['node_digest']}
 component=copy.deepcopy(base);component['milestone']='component';component['benchmarks']=[]
 for row in d['components']['optimized']:
  if row['operation']=='ecdsa/scalar_early_invalid':continue
  row=copy.deepcopy(row);row['operation']=row['operation'].replace('late_invalid','invalid').replace('early_invalid','invalid');component['benchmarks'].append(row)
 node=copy.deepcopy(base);node['milestone']='5k';node['runs']=[]
 for row in d['runs']:
  if row['variant']!='optimized':continue
  run={**row['raw_proof'],**row};run['timing_buckets_ms']=row['raw_proof']['timing_summary']['stage_totals_ms'];run['header_height']=row['writer_progress']['header_height'];run['runtime_surface']=row['raw_proof']['runtime_surface'];node['runs'].append(run)
 for payload in (component,node):
  errors=crypto_lanes.validate(payload);assert not errors,errors
  path=ROOT/'Nodes/Shared/conformance/results'/f"zig_own_curve_optimized_{payload['milestone']}_{stamp}.json";path.write_text(json.dumps(payload,indent=2)+'\n');print(path)
 print(comparison);summary(d)
if __name__=='__main__':main()
