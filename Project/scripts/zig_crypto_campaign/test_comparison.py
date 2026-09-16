"""Regression tests against shipped, independently validated campaign evidence."""
import copy,json,sys,unittest
from pathlib import Path
from comparison import ROOT,validate
sys.path.insert(0,str(ROOT/'Project/scripts'));import crypto_lanes
class ComparisonTests(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  paths=sorted((ROOT/'Nodes/Shared/conformance/crypto_comparisons').glob('zig_optimization_*.json'))
  if not paths:raise RuntimeError('assemble the campaign evidence before running report tests')
  cls.evidence=json.loads(paths[-1].read_text())
 def test_accepts_report_and_new_consistent_digest(self):
  d=copy.deepcopy(self.evidence);self.assertEqual(validate(d),[])
  d['variants']['optimized']['source_digest']='a'*64;d['validation']['source_digest']='a'*64
  for run in d['runs']+d['warmups']:
   if run['variant']=='optimized':
    run['source_digest']='a'*64;run['writer_progress']['crypto_source_digest']='a'*64;run['settled_status']['crypto_source_digest']='a'*64
  self.assertEqual(validate(d),[])
 def test_rejects_identity_and_measurement_contamination(self):
  for change in ('digest','lane','probe','node','volume','order'):
   d=copy.deepcopy(self.evidence)
   if change=='digest':d['runs'][0]['source_digest']='b'*64
   elif change=='lane':d['variants']['optimized']['lane']='c_binding'
   elif change=='probe':d['variants']['optimized']['probe']=True
   elif change=='node':d['variants']['optimized']['node_digest']='b'*64
   elif change=='volume':d['runs'][0]['volume']=d['runs'][1]['volume']
   else:d['runs'][0],d['runs'][1]=d['runs'][1],d['runs'][0]
   self.assertTrue(validate(d),change)
 def test_campaign_floor_is_local(self):
  d=copy.deepcopy(self.evidence);d['validation']['checks']['differential']['cases']=480;self.assertTrue(validate(d))
  d=copy.deepcopy(self.evidence);d['components']['optimized'][0]['iterations']=64;self.assertTrue(validate(d))
  paths=list((ROOT/'Nodes/Shared/conformance/results').glob('*_own_curve_*.json'))
  self.assertTrue(paths)
  for path in paths:self.assertEqual(crypto_lanes.validate(json.loads(path.read_text())),[],str(path))
 def test_current_evidence_unchanged(self):
  import hashlib
  current=ROOT/'Nodes/Shared/conformance/current_evidence.json'
  self.assertEqual(hashlib.sha256(current.read_bytes()).hexdigest(),self.evidence['curated_index_sha256'])
  entries=json.loads(current.read_text())['entries']
  self.assertFalse(any('crypto_comparisons/' in e['path'] or 'own_curve_optimized_' in e['path'] for e in entries))
if __name__=='__main__':unittest.main()
