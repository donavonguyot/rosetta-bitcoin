"""Campaign boundaries and protocol errors, using synthetic data only."""
import unittest,json
from differential import responses
from selection import component_interval,assess,node_interval
class ProtocolTests(unittest.TestCase):
 def test_ids_and_truncation(self):
  valid='{"id":7,"result":"valid"}\n{"id":8,"result":"consensus_invalid"}\n'
  self.assertEqual(responses(valid,[7,8]),['valid','consensus_invalid'])
  for text in (valid[:-1],valid.replace('"id":8','"id":7'),valid.splitlines()[0]+'\n',valid.replace('"id":8','"id":9')):
   with self.assertRaises(ValueError):responses(text,[7,8])
 def test_bad_tweak(self):
  with self.assertRaises(ValueError):responses('{"id":0,"result":"ff:2"}\n',[0])
 def report(self,scale):
  return {'measurements':[dict(operation=op,batch=b,repetition=r,iterations=1024,total_ns=int(scale*(100+r)*1024)) for op in ('ecdsa/valid','schnorr/valid','parse/valid','tweak/valid') for b in (0,1) for r in range(5)]}
 def test_selection(self):
  baseline=self.report(1);self.assertFalse(assess(baseline,baseline)['qualifies']);self.assertTrue(assess(baseline,self.report(.8))['qualifies'])
 def test_node_pairing(self):
  rows=[dict(round=i,variant=v,node_elapsed_ms=(100+i)*scale) for i in range(9) for v,scale in [('baseline',1),('candidate',1.04),('c_control',.5)]]
  lo,hi=node_interval(rows);self.assertGreater(lo,.03);self.assertGreater(hi,.03)
if __name__=='__main__':unittest.main()
