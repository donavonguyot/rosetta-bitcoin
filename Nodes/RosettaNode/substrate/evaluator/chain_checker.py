#!/usr/bin/env python3
"""Independent valid-chain parse/hash composition checker, not consensus validation.

Does not call IR or another port. Malformed/profile/structured-input tests remain
separate. Python hashlib is independent of the native reference SHA primitive.
"""
import hashlib,struct

def digest(b):return hashlib.sha256(hashlib.sha256(b).digest()).digest()
def compact(n):
    if n<253:return bytes([n])
    width=2 if n<=65535 else 4 if n<=4294967295 else 8
    return bytes([{2:253,4:254,8:255}[width]])+n.to_bytes(width,'little')
class Reader:
    def __init__(self,data):self.data=data;self.pos=0
    def take(self,n):
        if not 0<=n<=len(self.data)-self.pos:raise ValueError('truncated')
        out=self.data[self.pos:self.pos+n];self.pos+=n;return out
    def uint(self,n):return int.from_bytes(self.take(n),'little')
    def count(self,minimum=1):
        n=self.uint(1)
        if n>=253:
            width={253:2,254:4,255:8}[n];n=self.uint(width)
            if n<{2:253,4:65536,8:4294967296}[width]:raise ValueError('noncanonical')
        if n>(len(self.data)-self.pos)//minimum:raise ValueError('impossible count')
        return n
    def blob(self):return self.take(self.count())

def serialize(tx,witness=True):
    out=int(tx['version_bits']).to_bytes(4,'little');vin=tx['inputs'];vout=tx['outputs']
    extended=witness and any(v['witness'] for v in vin)
    if extended:out+=b'\0\1'
    out+=compact(len(vin))
    for v in vin:
        script=bytes.fromhex(v['script'])
        out+=bytes.fromhex(v['previous_txid_digest_order'])+int(v['previous_index']).to_bytes(4,'little')+compact(len(script))+script+int(v['sequence']).to_bytes(4,'little')
    out+=compact(len(vout))
    for v in vout:
        script=bytes.fromhex(v['script']);out+=int(v['amount']).to_bytes(8,'little',signed=True)+compact(len(script))+script
    if extended:
        for v in vin:
            out+=compact(len(v['witness']))
            for h in v['witness']:
                b=bytes.fromhex(h);out+=compact(len(b))+b
    return out+int(tx['locktime']).to_bytes(4,'little')

def transaction(r,allow_witness=True):
    tx={'version_bits':str(r.uint(4)),'inputs':[],'outputs':[],'locktime':'0'}
    n=r.count();flags=0
    if n==0 and allow_witness:
        flags=r.uint(1)
        if flags:n=r.count(41)
    if n>(len(r.data)-r.pos)//41:raise ValueError('impossible inputs')
    for _ in range(n):
        tx['inputs'].append({'previous_txid_digest_order':r.take(32).hex(),'previous_index':str(r.uint(4)),'script':r.blob().hex(),'sequence':str(r.uint(4)),'witness':[]})
    if n or flags or not allow_witness:
        for _ in range(r.count(9)):
            amount=int.from_bytes(r.take(8),'little',signed=True)
            tx['outputs'].append({'amount':str(amount),'script':r.blob().hex()})
    if flags&1:
        for v in tx['inputs']:v['witness']=[r.blob().hex() for _ in range(r.count())]
        if not any(v['witness'] for v in tx['inputs']):raise ValueError('superfluous witness')
    if flags&~1:raise ValueError('unknown flags')
    tx['locktime']=str(r.uint(4));return tx

def merkle(leaves):
    if not leaves:raise ValueError('empty tree')
    nodes=list(leaves)
    while len(nodes)>1:
        if len(nodes)%2:nodes.append(nodes[-1])
        nodes=[digest(nodes[i]+nodes[i+1]) for i in range(0,len(nodes),2)]
    return nodes[0]

def check_block(data,compare=None):
    r=Reader(data);header=r.take(80);count=r.count(10);txs=[];raws=[]
    for _ in range(count):
        start=r.pos;tx=transaction(r);raw=data[start:r.pos]
        if serialize(tx,True)!=raw:raise ValueError('noncanonical block transaction')
        txs.append(tx);raws.append(raw)
        if compare is not None:compare(tx,raw)
    if r.pos!=len(data):raise ValueError('trailing block bytes')
    root=merkle([digest(serialize(tx,False)) for tx in txs])
    if root!=header[36:68]:raise ValueError('transaction Merkle mismatch')
    cb=txs[0];commitment=None
    for output in cb['outputs']:
        script=bytes.fromhex(output['script'])
        if len(script)>=38 and script[:6]==bytes.fromhex('6a24aa21a9ed'):commitment=script[6:38]
    if commitment is not None:
        if len(cb['inputs'])!=1 or len(cb['inputs'][0]['witness'])!=1:raise ValueError('coinbase reserved stack shape')
        reserved=bytes.fromhex(cb['inputs'][0]['witness'][0])
        if len(reserved)!=32:raise ValueError('reserved length')
        wroot=merkle([bytes(32)]+[digest(raw) for raw in raws[1:]])
        if digest(wroot+reserved)!=commitment:raise ValueError('witness commitment mismatch')
    elif any(v['witness'] for tx in txs for v in tx['inputs']):raise ValueError('witness without commitment')
    return {'transactions':count,'witness_commitment':commitment is not None,'block_hash':digest(header)[::-1].hex()}
