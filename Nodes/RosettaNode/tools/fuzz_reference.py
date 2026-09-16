#!/usr/bin/env python3
"""Deterministic bounded implementation checks; excluded from frozen cohort scoring."""
import copy,json,random,time
from protocol import Engine,ROOT
from corpus import identity,matches
from chain_checker import serialize
from evaluate_attempt import profile_oracle

def main():
    rng=random.Random(20260916);engines=[Engine('o0'),Engine('o2')];start=time.monotonic();checks=0
    for _ in range(500):
        tx={'version_bits':str(rng.randrange(1<<32)),'locktime':str(rng.randrange(1<<32)),'inputs':[],'outputs':[]}
        for _ in range(rng.randrange(1,4)):
            tx['inputs'].append({'previous_txid_digest_order':rng.randbytes(32).hex(),'previous_index':str(rng.randrange(1<<32)),'sequence':str(rng.randrange(1<<32)),'script':rng.randbytes(rng.randrange(20)).hex(),'witness':[rng.randbytes(rng.randrange(10)).hex() for _ in range(rng.randrange(4))]})
        for _ in range(rng.randrange(4)):tx['outputs'].append({'amount':str(rng.randrange(-(1<<63),1<<63)),'script':rng.randbytes(rng.randrange(20)).hex()})
        expected=identity(tx)
        for engine in engines:
            assert engine.request({'op':'identify','transaction':tx})==expected
            raw=serialize(tx);assert engine.request({'op':'decode_exact','mode':'witness','bytes':raw.hex()})=={'status':'ok','transaction':tx,'consumed':str(len(raw))};checks+=2
        for _ in range(3):
            changed=bytearray(raw);index=rng.randrange(len(changed));changed[index]^=rng.randrange(1,256)
            request={'op':'decode_exact','mode':'witness','bytes':changed.hex()}
            expected=profile_oracle(request)
            for engine in engines:assert matches(engine.request(request),expected);checks+=1
    report={'schema':'rosettanode.bounded_fuzz.v1','status':'passed','seed':20260916,'checks':checks,'structured_inputs':500,'byte_mutations':1500,'builds':['o0','o2'],'elapsed_seconds':time.monotonic()-start,'scope':'Reference implementation check only; excluded from frozen reconstruction scoring'}
    (ROOT/'evidence/bounded-fuzz.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
if __name__=='__main__':main()
