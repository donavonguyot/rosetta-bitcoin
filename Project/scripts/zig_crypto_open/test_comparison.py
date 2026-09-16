"""New report boundary and unchanged historical-evidence acceptance."""
import copy,json,unittest
from common import ROOT
from comparison import validate,SCHEMA

class ComparisonTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path=sorted((ROOT/'Nodes/Shared/conformance/crypto_comparisons').glob('zig_residual_*.json'))[-1]
        cls.report=json.loads(path.read_text())
        cls.report.update(schema=SCHEMA,node_claim='regression_gate_only',control_selection={'sweep_configurations':28},a0={'selected_field':'frozen_widened'},decisions={'status':'complete'})
    def test_historical_shape_not_admitted_implicitly(self):
        d=copy.deepcopy(self.report);d['schema']='rb.zig_crypto_residual_comparison.v1'
        self.assertIn('wrong schema',validate(d))
    def test_new_consistent_digest(self):
        d=copy.deepcopy(self.report);digest='abc123'*10+'abcd'
        d['variants']['candidate']['source_digest']=digest
        for row in d['runs']+d['warmups']:
            if row['variant']=='candidate':
                row['source_digest']=digest
                row['writer_progress']['crypto_source_digest']=digest
                row['settled_status']['crypto_source_digest']=digest
        d['validation']['source_digest']=digest
        d['validation']['checks']['differential']['source_digest']=digest
        d['validation']['checks']['x86_correctness']['source_digest']=digest
        d['arithmetic']['source_digest']=digest;d['holdout']['candidate_digest']=digest
        self.assertEqual([],validate(d))
    def test_mismatched_run_and_lane(self):
        d=copy.deepcopy(self.report);d['runs'][0]['source_digest']='0'*64
        self.assertIn('run/package source_digest mismatch',validate(d))
        d=copy.deepcopy(self.report);d['variants']['candidate']['lane']='c_binding'
        self.assertIn('wrong lane candidate',validate(d))
    def test_controls_cannot_be_curated(self):
        d=copy.deepcopy(self.report);d['curated_current']=True
        self.assertIn('must remain uncurated',validate(d))

if __name__=='__main__':unittest.main()
