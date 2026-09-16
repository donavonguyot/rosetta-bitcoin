"""Digest/lane isolation regressions against this campaign's completed report."""
import copy,unittest
from common import *
from comparison import validate
class EvidenceTests(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  files=sorted((ROOT/'Nodes/Shared/conformance/crypto_comparisons').glob('zig_residual_*.json'))
  if not files:raise RuntimeError('assemble a residual report first')
  cls.report=json.loads(files[-1].read_text())
 def test_accepts_fresh_consistent_digest(self):
  d=copy.deepcopy(self.report);self.assertEqual(validate(d),[])
  digest='a'*64;d['variants']['candidate']['source_digest']=digest;d['arithmetic']['source_digest']=digest;d['validation']['checks']['differential']['source_digest']=digest
  d['validation']['source_digest']=digest;d['holdout']['candidate_digest']=digest;d['validation']['checks']['x86_correctness']['source_digest']=digest
  for r in d['runs']+d['warmups']:
   if r['variant']=='candidate':
    r['source_digest']=digest
    for owner in ('writer_progress','settled_status'):r[owner]['crypto_source_digest']=digest
  self.assertEqual(validate(d),[])
 def test_rejects_contamination(self):
  for field in ('source_digest','node_digest','lane','image_id'):
   d=copy.deepcopy(self.report);d['runs'][0][field]='wrong';self.assertTrue(validate(d),field)
  d=copy.deepcopy(self.report);d['validation']['checks']['differential']['cases']=480;self.assertTrue(validate(d))
  d=copy.deepcopy(self.report);d['variants']['candidate']['probe']=True;self.assertTrue(validate(d))
 def test_separate_schema(self):
  import crypto_lanes
  self.assertTrue(crypto_lanes.validate(self.report))
if __name__=='__main__':unittest.main()
