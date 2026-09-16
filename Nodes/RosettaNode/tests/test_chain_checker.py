import copy,sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from chain_checker import check_block,compact,digest,merkle,serialize
from test_transactions import simple

def block(txs):
    root=merkle([digest(serialize(tx,False)) for tx in txs])
    return bytes(36)+root+bytes(12)+compact(len(txs))+b''.join(serialize(tx) for tx in txs)
def committed():
    spend=simple(['ab']);coinbase=simple(['00'*32]);coinbase['inputs'][0]['previous_txid_digest_order']='00'*32;coinbase['inputs'][0]['previous_index']='4294967295'
    expected=digest(merkle([bytes(32),digest(serialize(spend))])+bytes(32)).hex()
    coinbase['outputs']=[{'amount':'0','script':'6a24aa21a9ed'+'11'*32},{'amount':'0','script':'6a24aa21a9ed'+expected}]
    return [coinbase,spend]
class Checker(unittest.TestCase):
    def test_last_match(self):
        txs=committed();self.assertTrue(check_block(block(txs))['witness_commitment'])
        txs[0]['outputs'].reverse()
        with self.assertRaisesRegex(ValueError,'witness commitment'):check_block(block(txs))
    def test_reserved_value(self):
        txs=committed();txs[0]['inputs'][0]['witness']=['01'*32]
        with self.assertRaisesRegex(ValueError,'witness commitment'):check_block(block(txs))
    def test_reserved_shape(self):
        for wit in [['00'*31],['00'*32,''],[]]:
            txs=committed();txs[0]['inputs'][0]['witness']=wit
            with self.assertRaises(ValueError):check_block(block(txs))
    def test_order_and_bytes(self):
        txs=committed();raw=block(txs);bad=raw[:81]+serialize(txs[1])+serialize(txs[0])
        with self.assertRaisesRegex(ValueError,'Merkle'):check_block(bad)
        bad=bytearray(raw);bad[-1]^=1
        with self.assertRaisesRegex(ValueError,'Merkle'):check_block(bytes(bad))
    def test_coinbase_zero_leaf(self):
        txs=committed();wrong=digest(merkle([digest(serialize(tx)) for tx in txs])+bytes(32))
        txs[0]['outputs'][-1]['script']='6a24aa21a9ed'+wrong.hex()
        with self.assertRaisesRegex(ValueError,'witness commitment'):check_block(block(txs))
if __name__=='__main__':unittest.main()
