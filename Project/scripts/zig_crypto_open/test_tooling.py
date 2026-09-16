import unittest
from assembly import audit

class AssemblyTests(unittest.TestCase):
    def function(self, body):
        return '.type root.chain__anon_1,@function\nroot.chain__anon_1:\n'+body+'\n.size root.chain__anon_1, .-root.chain__anon_1\n'
    def test_accepts_inline_and_cold_panic(self):
        self.assertTrue(audit(self.function('mul x0,x1,x2\nbl debug.panic'))['passed'])
    def test_rejects_direct_tail_and_alias(self):
        for branch in ('bl','b'):
            self.assertFalse(audit(self.function(branch+' field52.square'))['passed'])
        self.assertFalse(audit(self.function('bl \"field52.Kernel(true).Field(1).square\"'))['passed'])
        self.assertFalse(audit('.set alias, field52.product\n'+self.function('bl alias'))['passed'])
    def test_rejects_unknown_or_missing_hot_code(self):
        with self.assertRaises(ValueError):audit('')
        self.assertFalse(audit(self.function('blr x8'))['passed'])


class BatchProtocolTests(unittest.TestCase):
    def test_ids_and_truncation(self):
        from differential import responses
        self.assertEqual(['valid'],responses('{"id":1,"result":"valid"}\n',[1]))
        for text in ('{"id":1,"result":"valid"}', '{"id":2,"result":"valid"}\n', '{"id":1,"result":"valid"}\n{"id":1,"result":"valid"}\n', ''):
            with self.assertRaises(ValueError):responses(text,[1])
    def test_invalid_tweak_response(self):
        from differential import responses
        with self.assertRaises(ValueError):responses('{"id":1,"result":"00:2"}\n',[1])

class SelectionTests(unittest.TestCase):
    def report(self,scale=1):
        return {'input_sha256':'same','measurements':[dict(operation=op,batch=b,repetition=r,iterations=1024,total_ns=int(1024000*scale)) for op in ('ecdsa/valid','schnorr/valid','parse/valid','tweak/valid') for b in range(2) for r in range(5)]}
    def test_identical_does_not_qualify(self):
        from selection import assess
        self.assertFalse(assess(self.report(),self.report())['qualifies'])
    def test_improvement_and_pairing(self):
        from selection import assess
        self.assertTrue(assess(self.report(),self.report(.9))['qualifies'])
        report=self.report();report['input_sha256']='other'
        with self.assertRaises(ValueError):assess(self.report(),report)

if __name__=='__main__':unittest.main()
