#!/usr/bin/env python3
"""JSON/ABI marshaler. Byte parsing, emission and digest composition execute in IR."""
import ctypes as C,json,re,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
MAX_ADMITTED=4*1024*1024; MAX_BYTES=8*1024*1024; MAX_TEXT=20*1024*1024
U64=C.c_uint64; PTR=C.c_void_p
class Scan(C.Structure):
    _fields_=[('data',PTR),('length',U64),('pos',U64),('error',U64),('items',U64),('events',PTR),('used',U64)]
class Write(C.Structure):
    _fields_=[('out',PTR),('cap',U64),('pos',U64),('error',U64)]
class Outcome(Exception):
    def __init__(self,status):self.status=status

def integer(value,low=0,high=(1<<64)-1):
    if not isinstance(value,str) or not re.fullmatch(r'0|-?[1-9][0-9]*',value):raise Outcome('invalid_request')
    if len(value)>21:raise Outcome('invalid_request')
    n=int(value)
    if not low<=n<=high:raise Outcome('invalid_request')
    return n

def byte_string(value):
    if not isinstance(value,str) or len(value)%2 or re.search('[^0-9a-fA-F]',value):raise Outcome('invalid_request')
    if len(value)>MAX_BYTES*2:raise Outcome('transport_limit')
    return bytes.fromhex(value)

def limit(req):
    limits=req.get('limits',{})
    if not isinstance(limits,dict) or set(limits)-{'max_items'}:raise Outcome('invalid_request')
    return integer(limits.get('max_items','4096'),0,4096)

def boolean(value):
    if type(value) is not bool:raise Outcome('invalid_request')
    return value

class Engine:
    def __init__(self,library='o2'):
        self.lib=C.CDLL(str(ROOT/f'.local/tx/{library}.so'))
        self.lib.tx_scan.argtypes=[C.POINTER(Scan),C.c_bool,C.c_bool,U64];self.lib.tx_scan.restype=U64
        self.lib.tx_serialize.argtypes=[PTR,U64,PTR,C.c_bool,C.POINTER(Write)];self.lib.tx_serialize.restype=U64
        self.lib.tx_digest.argtypes=[PTR,U64,PTR];self.lib.tx_digest.restype=C.c_int
    def decode(self,req,budget):
        data=byte_string(req['bytes']);offset=integer(req.get('offset','0'),0,len(data)) if req['op']=='decode_prefix' else 0
        if req['mode'] not in ['legacy','witness']:raise Outcome('invalid_request')
        suffix=data[offset:]
        if len(suffix)>MAX_ADMITTED:raise Outcome('admission_limit')
        buf=C.create_string_buffer(suffix);s=Scan(C.addressof(buf),len(suffix),0,0,0,None,0)
        status=self.lib.tx_scan(C.byref(s),req['mode']=='witness',req['op']=='decode_exact',budget)
        if status:raise Outcome({1:'malformed_encoding',2:'resource_limit'}[status])
        used=s.used;consumed=s.pos
        events=(U64*(used*4))();s=Scan(C.addressof(buf),len(suffix),0,0,0,C.addressof(events),0)
        if self.lib.tx_scan(C.byref(s),req['mode']=='witness',req['op']=='decode_exact',budget)!=0 or s.used!=used or s.pos!=consumed:raise Outcome('execution_failure')
        tx={'version_bits':'0','inputs':[],'outputs':[],'locktime':'0'};wi=-1
        for j in range(used):
            kind,a,b,c=events[j*4:j*4+4]
            if kind==0:tx['version_bits']=str(a)
            elif kind==1:tx['inputs'].append({'previous_txid_digest_order':suffix[a:a+32].hex(),'previous_index':str(c),'sequence':str(b),'script':'','witness':[]})
            elif kind==2:tx['inputs'][-1]['script']=suffix[a:a+b].hex()
            elif kind==3:tx['outputs'].append({'amount':str(a if a<(1<<63) else a-(1<<64)),'script':suffix[b:b+c].hex()})
            elif kind==4:wi+=1
            elif kind==5:tx['inputs'][wi]['witness'].append(suffix[a:a+b].hex())
            elif kind==6:tx['locktime']=str(a)
        return {'status':'ok','transaction':tx,'consumed':str(consumed)}
    def marshal(self,tx,budget):
        if not isinstance(tx,dict) or set(tx)!={'version_bits','inputs','outputs','locktime'}:raise Outcome('invalid_request')
        vin=tx['inputs'];vout=tx['outputs']
        if not isinstance(vin,list) or not isinstance(vout,list):raise Outcome('invalid_request')
        events=[];pool=bytearray();items=len(vin)+len(vout)
        def event(*args):events.extend(args)
        def payload(value):
            b=byte_string(value);start=len(pool)
            if start+len(b)>MAX_BYTES:raise Outcome('transport_limit')
            pool.extend(b);return start,len(b)
        event(0,integer(tx['version_bits'],0,(1<<32)-1),0,0);event(7,len(vin),0,0)
        for v in vin:
            if not isinstance(v,dict) or set(v)!={'previous_txid_digest_order','previous_index','sequence','script','witness'}:raise Outcome('invalid_request')
            prev,n=payload(v['previous_txid_digest_order'])
            if n!=32:raise Outcome('invalid_request')
            seq=integer(v['sequence'],0,(1<<32)-1);idx=integer(v['previous_index'],0,(1<<32)-1)
            event(1,prev,seq,idx);script,n=payload(v['script']);event(2,script,n,seq)
        event(8,len(vout),0,0)
        for v in vout:
            if not isinstance(v,dict) or set(v)!={'amount','script'}:raise Outcome('invalid_request')
            amount=integer(v['amount'],-(1<<63),(1<<63)-1);script,n=payload(v['script']);event(3,amount% (1<<64),script,n)
        for v in vin:
            wit=v['witness']
            if not isinstance(wit,list):raise Outcome('invalid_request')
            items+=len(wit);event(4,len(wit),0,0)
            for item in wit:
                start,n=payload(item);event(5,start,n,0)
        event(6,integer(tx['locktime'],0,(1<<32)-1),0,0)
        if items>budget:raise Outcome('resource_limit')
        return (U64*len(events))(*events),C.create_string_buffer(bytes(pool))
    def serialize(self,events,pool,include):
        w=Write(None,MAX_ADMITTED,0,0)
        if self.lib.tx_serialize(events,len(events)//4,pool,include,C.byref(w)):raise Outcome('resource_limit')
        size=w.pos;buf=C.create_string_buffer(size);w=Write(C.addressof(buf),size,0,0)
        if self.lib.tx_serialize(events,len(events)//4,pool,include,C.byref(w)) or w.pos!=size:raise Outcome('execution_failure')
        return buf.raw[:size]
    def digest(self,data):
        buf=C.create_string_buffer(data);out=C.create_string_buffer(32)
        if self.lib.tx_digest(buf,len(data),out)!=1:raise Outcome('execution_failure')
        return out.raw
    def request(self,req):
        try:
            if not isinstance(req,dict):raise Outcome('invalid_request')
            budget=limit(req);op=req['op']
            if op in ['decode_prefix','decode_exact']:return self.decode(req,budget)
            if op not in ['serialize','identify']:raise Outcome('invalid_request')
            events,pool=self.marshal(req['transaction'],budget)
            if op=='serialize':return {'status':'ok','bytes':self.serialize(events,pool,boolean(req['include_witness'])).hex()}
            stripped=self.serialize(events,pool,False);full=self.serialize(events,pool,True)
            txid=self.digest(stripped);wtxid=self.digest(full)
            return {'status':'ok','stripped':stripped.hex(),'full':full.hex(),'stripped_size':str(len(stripped)),'full_size':str(len(full)),'txid_digest_order':txid.hex(),'txid_display_order':txid[::-1].hex(),'wtxid_digest_order':wtxid.hex(),'wtxid_display_order':wtxid[::-1].hex()}
        except Outcome as e:return {'status':e.status}
        except MemoryError:return {'status':'execution_failure'}
        except (KeyError,TypeError,ValueError,OverflowError):return {'status':'invalid_request'}

def main():
    engine=Engine(sys.argv[1] if len(sys.argv)>1 else 'o2')
    while True:
        line=sys.stdin.buffer.readline(MAX_TEXT+1)
        if not line:break
        if len(line)>MAX_TEXT:
            print(json.dumps({'status':'transport_limit'}),flush=True);break
        try:result=engine.request(json.loads(line))
        except (ValueError,UnicodeError):result={'status':'invalid_request'}
        print(json.dumps(result,separators=(',',':')),flush=True)
if __name__=='__main__':main()
