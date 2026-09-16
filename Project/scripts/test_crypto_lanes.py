"""Regression tests for experimental evidence separation and rejection."""
import copy, sqlite3, tempfile, unittest
from pathlib import Path
import crypto_lanes as lane
class EvidenceTests(unittest.TestCase):
 def fixture(self):
  return {'schema':lane.SCHEMA,'port':'go','lane':'own_curve','implementation':'libsecp256k1-go','milestone':'component','source_digest':'a'*64,'captured_at':'2026-09-16T00:00:00Z','result':'passed','binary_gate_status':'not_attempted','toolchain':'Go pinned','build_settings':{'candidate_only':True},'dependencies':{'curve_provider':'package','production':[],'ffi':False},'checks':{'shared_vectors':{'result':'passed','cases':52},'differential':{'result':'passed','reference_commit':'0cdc758a56360bf58a851fe91085a327ec97685a','cases':480,'failures':[]},'isolated_build':{'result':'passed'},'external_consumer':{'result':'passed'},'dependency_audit':{'result':'passed'}},'benchmarks':[{'operation':op} for op in ('ecdsa/valid','ecdsa/invalid','schnorr/valid','schnorr/invalid','parse/valid','parse/invalid','tweak/valid','tweak/invalid') for _ in range(5)]}
 def test_accepted_component_is_separate(self):
  d=self.fixture();self.assertEqual(lane.validate(d),[])
  db=sqlite3.connect(':memory:');lane.import_result(db,Path('/repo'),Path('/repo/proof.json'),d)
  self.assertEqual(db.execute('select lane from crypto_lane_results').fetchone()[0],'own_curve')
  self.assertIsNone(db.execute("select 1 from sqlite_master where name='benchmark_results'").fetchone());db.close()
 def test_rejects_dependency_and_identity_lies(self):
  for key,value in [('curve_provider','ecosystem'),('production',['some-curve']),('ffi',True)]:
   d=self.fixture();d['dependencies'][key]=value;self.assertTrue(lane.validate(d))
  for key,value in [('implementation','zig-secp256k1'),('source_digest','unrecorded'),('lane','ecosystem_curve'),('binary_gate_status','passed')]:
   d=self.fixture();d[key]=value;self.assertTrue(lane.validate(d))
 def test_rejects_incomplete_and_false_node_claim(self):
  d=self.fixture();d['milestone']='5k';self.assertTrue(lane.validate(d))
  d=self.fixture();d['checks']['shared_vectors']['cases']=51;self.assertTrue(lane.validate(d))
  d=self.fixture();d['checks']['differential']['failures']=['mismatch'];self.assertTrue(lane.validate(d))
 def test_canonical_validator_rejects_experimental_crypto(self):
  import importlib.util
  from pathlib import Path
  path=Path(__file__).resolve().parents[2]/'Nodes/Shared/conformance/tools/validate_benchmark_artifact.py'
  spec=importlib.util.spec_from_file_location('benchmark_validator',path);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
  for backend in ('libsecp256k1-go','libsecp256k1-zig','zig-secp256k1'):
   errors,_=module.validate_payload({'native_crypto_backend':backend},gate_id='baseline_5k')
   self.assertTrue(any('experimental crypto lane' in error for error in errors))
 def test_independent_selection_keys(self):
  db=sqlite3.connect(':memory:')
  for i,category in enumerate(lane.LANES):
   d=self.fixture();d['lane']=category
   if category!='own_curve':d['implementation']='other-'+category;d['dependencies']['curve_provider']='ecosystem' if category=='ecosystem_curve' else 'C'
   lane.import_result(db,Path('/repo'),Path(f'/repo/{i}.json'),d)
  self.assertEqual(db.execute('select count(distinct lane) from crypto_lane_results').fetchone()[0],3);db.close()
 def test_updated_evidence_keeps_artifact_identity(self):
  import json
  import import_all
  with tempfile.TemporaryDirectory() as directory:
   root=Path(directory);index=root/'index.json';proof=root/'proof.json'
   db=sqlite3.connect(':memory:')
   import_all.init_db(db,Path(__file__).resolve().parents[1]/'schema.sql')
   for version in (1,2):
    index.write_text(json.dumps({'schema':'rb.current_evidence.v1','entries':[],'version':version}))
    import_all.import_current_evidence_index(db,root,index,False)
    payload=self.fixture();payload['revision']=version;proof.write_text(json.dumps(payload))
    import_all.import_json_artifact(db,root,proof,payload)
    identities=db.execute('select path,artifact_id from artifacts order by path').fetchall()
    if version==1:first=identities
    else:self.assertEqual(first,identities)
   self.assertEqual(db.execute('select count(*) from crypto_lane_results').fetchone()[0],1)
   db.close()
if __name__=='__main__':unittest.main()
