import sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from corpus import cases,matches
from evaluate_attempt import profile_oracle
class Evaluator(unittest.TestCase):
    def test_independent_profile_oracle(self):
        for row in cases():
            if row['request']['op'].startswith('decode'):
                with self.subTest(case=row['id']):self.assertTrue(matches(profile_oracle(row['request']),row['expected']))
    def test_error_does_not_expose_partial_object(self):
        self.assertFalse(matches({'status':'malformed_encoding','transaction':{}},{'status':'malformed_encoding'}))
    def test_constantly_malformed_cannot_pass(self):
        results=[matches({'status':'malformed_encoding'},row['expected']) for row in cases()]
        self.assertFalse(all(results));self.assertTrue(any(results))
if __name__=='__main__':unittest.main()
