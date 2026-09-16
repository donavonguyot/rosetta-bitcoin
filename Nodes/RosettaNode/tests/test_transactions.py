import copy,hashlib,json,sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from protocol import Engine
from chain_checker import serialize,digest,compact

def simple(witness=None):
    return {'version_bits':'4294967295','inputs':[{'previous_txid_digest_order':'12'*32,'previous_index':'7','script':'ab','sequence':'4294967294','witness':[] if witness is None else witness}],'outputs':[{'amount':'-1','script':'51'}],'locktime':'3'}
class Transactions(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.engines=[Engine('o0'),Engine('o2')]
    def response(self,req):
        a,b=[e.request(req) for e in self.engines];self.assertEqual(a,b);return a
    def decode(self,b,mode='witness',exact=True,**kw):return self.response(dict(op='decode_exact' if exact else 'decode_prefix',bytes=b.hex(),mode=mode,**kw))
    def test_structured_and_digests(self):
        for witness in [[],[''],['ab','']]:
            tx=simple(witness)
            for include in [False,True]:
                expected=serialize(tx,include)
                self.assertEqual(self.response(dict(op='serialize',transaction=tx,include_witness=include)),dict(status='ok',bytes=expected.hex()))
            result=self.response(dict(op='identify',transaction=tx))
            for key,include in [('txid',False),('wtxid',True)]:
                expected=digest(serialize(tx,include));self.assertEqual(result[key+'_digest_order'],expected.hex());self.assertEqual(result[key+'_display_order'],expected[::-1].hex())
            self.assertEqual(result['full_size'],str(len(serialize(tx,True))))
            self.assertEqual(result['stripped_size'],str(len(serialize(tx,False))))
            self.assertEqual(self.decode(serialize(tx))['transaction'],tx)
    def test_mutate_decoded(self):
        original=simple(['']);decoded=self.decode(serialize(original))['transaction']
        for field in ['amount','script','version','witness']:
            tx=copy.deepcopy(decoded)
            if field=='amount':tx['outputs'][0]['amount']='8'
            elif field=='script':tx['inputs'][0]['script']='fefe'
            elif field=='version':tx['version_bits']='2'
            else:tx['inputs'][0]['witness']=['ee']
            actual=self.response(dict(op='serialize',transaction=tx,include_witness=True))
            self.assertEqual(actual['bytes'],serialize(tx).hex());self.assertNotEqual(actual['bytes'],serialize(original).hex())
    def test_zero_flags_and_consumption(self):
        raw=bytes.fromhex('01000000000012345678')
        r=self.decode(raw);self.assertEqual(r['consumed'],'10');self.assertEqual(r['transaction']['locktime'],str(0x78563412))
        self.assertEqual(self.decode(raw+b'\xaa')['status'],'malformed_encoding')
        self.assertEqual(self.decode(raw+b'\xaa',exact=False)['consumed'],'10')
        self.assertEqual(self.decode(b'xyz'+raw+b'\xaa',exact=False,offset='3')['consumed'],'10')
        empty={'version_bits':'1','inputs':[],'outputs':[{'amount':'-3','script':''}],'locktime':'2'}
        self.assertEqual(self.decode(serialize(empty),'legacy')['transaction'],empty)
    def test_witness_flags(self):
        tx=simple(['']);raw=serialize(tx)
        self.assertEqual(self.decode(raw)['status'],'ok')
        # Replace the sole one-item empty stack with zero items.
        self.assertEqual(self.decode(raw[:-6]+b'\0'+raw[-4:])['status'],'malformed_encoding')
        self.assertEqual(self.decode(raw[:5]+b'\x03'+raw[6:])['status'],'malformed_encoding')
        plain=serialize(simple());unknown=plain[:4]+b'\0\2'+plain[4:]
        self.assertEqual(self.decode(unknown)['status'],'malformed_encoding')
        self.assertNotEqual(self.decode(raw,'legacy')['status'],'ok')
    def test_all_truncations(self):
        for tx in [simple(),simple(['','abcd'])]:
            raw=serialize(tx)
            for n in range(len(raw)):
                with self.subTest(length=n):self.assertEqual(self.decode(raw[:n])['status'],'malformed_encoding')
    def test_resource_order(self):
        tx=simple(['']);raw=serialize(tx)
        self.assertEqual(self.decode(raw,limits={'max_items':'2'})['status'],'resource_limit')
        self.assertEqual(self.decode(raw[:-1],limits={'max_items':'0'})['status'],'malformed_encoding')
        self.assertEqual(self.decode(raw+b'\0',limits={'max_items':'0'})['status'],'malformed_encoding')
        self.assertEqual(self.decode(bytes.fromhex('01000000ffffffffffffffffff'))['status'],'malformed_encoding')
        tx={'version_bits':'1','inputs':[],'outputs':[{'amount':'0','script':''}]*4097,'locktime':'0'}
        self.assertEqual(self.decode(serialize(tx),'legacy')['status'],'resource_limit')
    def test_admission_and_offset(self):
        self.assertEqual(self.decode(b'x',exact=False,offset='2')['status'],'invalid_request')
        raw=bytes.fromhex('01000000000000000000')
        prefix=b'x'*(4*1024*1024+1)
        self.assertEqual(self.decode(prefix+raw,exact=False,offset=str(len(prefix)))['status'],'ok')
        self.assertEqual(self.decode(prefix)['status'],'admission_limit')
    def test_allocation_failure(self):
        from unittest.mock import patch
        with patch('protocol.C.create_string_buffer',side_effect=MemoryError):
            self.assertEqual(self.engines[0].request({'op':'decode_exact','bytes':serialize(simple()).hex(),'mode':'witness'}),{'status':'execution_failure'})
    def test_history_independence(self):
        tx=simple();raw=serialize(tx)
        a=self.decode(raw,'legacy')['transaction'];b=self.decode(raw,'witness')['transaction']
        self.assertEqual(a,b)
        self.assertEqual(self.response(dict(op='identify',transaction=a)),self.response(dict(op='identify',transaction=b)))
if __name__=='__main__':unittest.main()
