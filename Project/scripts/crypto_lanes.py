"""Independent crypto-lane validation and Project projection, never node truth."""
import hashlib, json, re, sqlite3
from pathlib import Path
LANES=('own_curve','ecosystem_curve','c_binding')
SCHEMA='rb.crypto_lane_result.v1'
HASH='000000000e3cb5b92e9765ed9c80c6b06f3d0a186478b330dd5e6b274acf03e2'
DDL='''CREATE TABLE IF NOT EXISTS crypto_lane_results (
 path TEXT PRIMARY KEY, port TEXT NOT NULL, lane TEXT NOT NULL,
 implementation TEXT NOT NULL, milestone TEXT NOT NULL, source_digest TEXT NOT NULL,
 captured_at TEXT NOT NULL, result TEXT NOT NULL, payload TEXT NOT NULL)'''
def source_digest(path):
 h=hashlib.sha256()
 for p in sorted(Path(path).rglob('*')):
  if not p.is_file() or any(x in ('.zig-cache','zig-out','.git','__pycache__','worktrees') for x in p.parts):continue
  h.update(p.relative_to(path).as_posix().encode()+b'\0'+p.read_bytes()+b'\0')
 return h.hexdigest()
def validate(d):
 errors=[]
 def require(ok,message):
  if not ok:errors.append(message)
 require(d.get('schema')==SCHEMA,'schema');require(d.get('lane') in LANES,'lane')
 for key in ('port','implementation','captured_at','toolchain','build_settings','dependencies'):
  require(bool(d.get(key)),key)
 require(bool(re.fullmatch('[0-9a-f]{64}',d.get('source_digest',''))),'source_digest')
 require(d.get('binary_gate_status')=='not_attempted','binary_gate_status')
 require(d.get('milestone') in ('component','5k'),'milestone')
 if d.get('implementation') in ('libsecp256k1-go','libsecp256k1-zig'):require(d.get('lane')=='own_curve','package lane mismatch')
 require(d.get('result') in ('passed','failed'),'result')
 if d.get('lane')=='own_curve':
  require(d.get('dependencies',{}).get('curve_provider')=='package','own_curve requires package-owned curve')
  require(d.get('dependencies',{}).get('production')==[],'own_curve production dependencies')
  require(d.get('dependencies',{}).get('ffi') is False,'own_curve FFI')
  require(d.get('implementation')=='libsecp256k1-'+d.get('port',''),'implementation identity')
 if d.get('result')=='passed':
  checks=d.get('checks',{})
  for key in ('shared_vectors','differential','isolated_build','external_consumer','dependency_audit'):
   require(checks.get(key,{}).get('result')=='passed',key)
  require(checks.get('shared_vectors',{}).get('cases')==52,'all 52 shared vectors')
  require(checks.get('differential',{}).get('reference_commit')=='0cdc758a56360bf58a851fe91085a327ec97685a','pinned reference')
  require(not checks.get('differential',{}).get('failures'),'differential mismatches')
  require(checks.get('differential',{}).get('cases',0)>=480,'differential cases')
  if d.get('milestone')=='component':
   counts={}
   for row in d.get('benchmarks',[]):
    op=re.sub(r'-[0-9]+$','',row.get('operation','').replace('BenchmarkOperations/',''))
    counts[op]=counts.get(op,0)+1
   require(all(counts.get(op)==5 for op in ('ecdsa/valid','ecdsa/invalid','schnorr/valid','schnorr/invalid','parse/valid','parse/invalid','tweak/valid','tweak/invalid')),'five repetitions of all component operations')
  else:
   for key in ('script_corpus','adapter_usage','fault_injection','trace_differential','backend_selection','node_regression'):
    require(checks.get(key,{}).get('result')=='passed',key)
   require(checks.get('script_corpus',{}).get('passed')==45,'45/45 corpus')
   for op in ('ecdsa','schnorr','tweak'):
    require(checks.get('adapter_usage',{}).get('calls',{}).get(op,0)>0,'adapter '+op)
    require(checks.get('trace_differential',{}).get('operations',{}).get(op,0)>0,'trace '+op)
   require(not checks.get('trace_differential',{}).get('failures'),'trace mismatches')
   require(checks.get('trace_differential',{}).get('reference_commit')=='0cdc758a56360bf58a851fe91085a327ec97685a','trace reference')
   runs=d.get('runs',[]);require(len(runs)==3,'three node repetitions')
   for r in runs:
    for k,v in {'validated_height':5000,'header_height':5000,'validated_hash':HASH,'chainstate_utxo_count':4574,'chainstate_backend':'rocksdb','rocksdb_wal_disabled':False,'fresh_state':True,'prefetch_depth':4,'script_runner_mode':'parallel','runtime_surface':'docker','byte_source':'local_reference_p2p'}.items():require(r.get(k)==v,'run '+k)
    require(r.get('implementation')==d.get('implementation'),'run implementation mismatch')
    require(r.get('lane')==d.get('lane'),'run lane mismatch')
    require(r.get('source_digest')==d.get('source_digest'),'run source mismatch')
    require(bool(r.get('image_id')),'image identity')
    require(all(k in r.get('timing_buckets_ms',{}) for k in ('p2p_fetch','block_parse_validate','utxo_load','script_verify','utxo_apply','commit','block_connect_store_commit')),'timing buckets')
 return errors
def import_result(connection,root,path,payload):
 from provenance import validate as validate_build_provenance
 pins=validate_build_provenance(payload)
 errors=validate(payload)
 if errors:raise ValueError(f'{path}: '+', '.join(errors))
 payload={**payload,**pins}
 connection.execute(DDL)
 connection.execute('INSERT OR REPLACE INTO crypto_lane_results VALUES(?,?,?,?,?,?,?,?,?)',(str(path.relative_to(root)),payload['port'],payload['lane'],payload['implementation'],payload['milestone'],payload['source_digest'],payload['captured_at'],payload['result'],json.dumps(payload,sort_keys=True)))
def report(connection):
 print('## Crypto lanes\n')
 print('| lane | port | implementation | milestone | result | captured |\n| --- | --- | --- | --- | --- | --- |')
 exists=connection.execute("SELECT 1 FROM sqlite_master WHERE name='crypto_lane_results'").fetchone()
 for lane in LANES:
  curated=connection.execute("SELECT 1 FROM sqlite_master WHERE name='evidence_index_entries'").fetchone()
  where=" WHERE path IN (SELECT path FROM evidence_index_entries WHERE status='current' AND claim LIKE 'crypto_lane:%')" if curated else ""
  rows=[] if not exists else connection.execute('SELECT port,implementation,milestone,result,captured_at FROM (SELECT *,row_number() OVER(PARTITION BY port,lane,implementation,milestone ORDER BY captured_at DESC,path DESC) AS rank FROM crypto_lane_results'+where+') WHERE lane=? AND rank=1 ORDER BY port,milestone',(lane,)).fetchall()
  if not rows:print(f'| {lane} | — | — | — | no new lane evidence | — |')
  for row in rows:print('| '+lane+' | '+' | '.join(str(x) for x in row)+' |')
