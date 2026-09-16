#!/usr/bin/env python3
"""Read-only Reference RPC export; all state belongs to RosettaNode."""
import base64,hashlib,json,urllib.request
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def rpc_batch(calls):
    body=json.dumps([{'jsonrpc':'1.0','id':i,'method':method,'params':params} for i,(method,params) in enumerate(calls)]).encode()
    request=urllib.request.Request('http://127.0.0.1:48332/',body,{'Content-Type':'application/json','Authorization':'Basic '+base64.b64encode(b'rosetta:rosetta-dev-only').decode()})
    with urllib.request.urlopen(request,timeout=60) as response:results=json.load(response)
    by_id={r['id']:r for r in results}
    if any(r['error'] for r in results):raise RuntimeError([r['error'] for r in results if r['error']])
    return [by_id[i]['result'] for i in range(len(calls))]
def main():
    out=ROOT/'.local/blocks/reference';out.mkdir(parents=True,exist_ok=True)
    network,chain=rpc_batch([('getnetworkinfo',[]),('getblockchaininfo',[])])
    if chain['chain']!='testnet4' or chain['blocks']<5000:raise RuntimeError('Reference testnet4 5000 unavailable')
    rows=[]
    for start in range(0,5001,100):
        heights=list(range(start,min(start+100,5001)))
        hashes=rpc_batch([('getblockhash',[h]) for h in heights])
        raw=rpc_batch([('getblock',[h,0]) for h in hashes])
        for height,blockhash,hexdata in zip(heights,hashes,raw):
            data=bytes.fromhex(hexdata);path=out/f'block_{height}.hex';path.write_text(hexdata+'\n')
            rows.append({'height':height,'hash':blockhash,'sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data)})
    manifest={'schema':'rosettanode.reference_export.v1','source_version':network['version'],'source_subversion':network['subversion'],'chain':chain['chain'],'range':[0,5000],'blocks':rows,'read_only_rpc_methods':['getnetworkinfo','getblockchaininfo','getblockhash','getblock']}
    (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(json.dumps({'blocks':len(rows),'bytes':sum(r['bytes'] for r in rows),'last_hash':rows[-1]['hash']}))
if __name__=='__main__':main()
