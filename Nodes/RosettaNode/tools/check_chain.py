#!/usr/bin/env python3
import hashlib,json,time
from pathlib import Path
from chain_checker import check_block,serialize,digest
from protocol import Engine
ROOT=Path(__file__).resolve().parents[1]
def main():
    engines=[Engine('o0'),Engine('o2')];comparisons=0
    def compare(tx,raw):
        nonlocal comparisons
        # This valid-chain family includes policy-limited observations separately.
        for engine in engines:
            actual=engine.request({'op':'decode_exact','mode':'witness','bytes':raw.hex()})
            items=len(tx['inputs'])+len(tx['outputs'])+sum(len(v['witness']) for v in tx['inputs'])
            if items>4096:
                assert actual=={'status':'resource_limit'};continue
            assert actual=={'status':'ok','transaction':tx,'consumed':str(len(raw))},actual
            result=engine.request({'op':'identify','transaction':tx})
            full=serialize(tx,True);stripped=serialize(tx,False)
            expected={'status':'ok','full':full.hex(),'stripped':stripped.hex(),'full_size':str(len(full)),'stripped_size':str(len(stripped))}
            for name,data in [('txid',stripped),('wtxid',full)]:expected.update({name+'_digest_order':digest(data).hex(),name+'_display_order':digest(data)[::-1].hex()})
            assert result==expected
        comparisons+=1
    start=time.monotonic();groups={}
    for group in ['shared','reference']:
        paths=sorted((ROOT/f'.local/blocks/{group}').glob('*.hex'))
        if not paths:raise RuntimeError(f'Missing {group} inputs; run export/staging first')
        rows=[]
        for path in paths:
            data=bytes.fromhex(path.read_text().strip());result=check_block(data,compare)
            rows.append({'file':path.name,'sha256':hashlib.sha256(data).hexdigest(),**result})
        groups[group]={'blocks':len(rows),'transactions':sum(r['transactions'] for r in rows),'witness_blocks':sum(r['witness_commitment'] for r in rows),'manifest_sha256':hashlib.sha256(json.dumps(rows,sort_keys=True).encode()).hexdigest()}
        (ROOT/f'.local/blocks/{group}/checked.json').write_text(json.dumps(rows,indent=2)+'\n')
    report={'schema':'rosettanode.chain_composition.v1','status':'passed','groups':groups,'transaction_comparisons':comparisons,'builds':['o0','o2'],'elapsed_seconds':time.monotonic()-start,'claim':'Valid parse/hash composition only; excludes malformed/profile and consensus validity','python_port_comparison':{'path':'Nodes/Python/pybitnode/consensus/witness.py','observed':'first matching commitment with break; checker requires last matching output; no port modification'}}
    (ROOT/'evidence/chain-composition.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
if __name__=='__main__':main()
