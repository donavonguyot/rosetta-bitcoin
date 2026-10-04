#!/usr/bin/env python3
"""Exercise full-size dummy-host traffic and independently inspect all receipts."""

import sys as _rb_sys
from pathlib import Path as _RBPath
_rb_sys.path.insert(0, str(_RBPath(__file__).resolve().parents[4] / 'Project/scripts'))
from state_root import operational_paths as _rb_paths, logical_path as _rb_logical, acquire_writer_lease as _rb_writer_lease
if __name__ == '__main__':
    _rb_writer_lease()
import concurrent.futures,hashlib,json,statistics,sys,time
from pathlib import Path
from service_probe import ROOT,Host,invariant
sys.path.insert(0,str(ROOT/'evaluator'))
from corpus import structure,identity
from chain_checker import serialize

class Client:
    def __init__(self,h):self.socket=h.connect();self.socket.settimeout(60);self.stream=self.socket.makefile('rb');self.counter=0;self.events=[]
    def call(self,q):
        self.counter+=1;rid=str(self.counter);self.socket.sendall(json.dumps({'request':rid,**q}).encode()+b'\n')
        while True:
            line=self.stream.readline()
            if not line:raise RuntimeError('socket closed before response')
            r=json.loads(line)
            if 'event' in r:self.events.append(r);continue
            if r.get('request')!=rid:raise RuntimeError('correlation mismatch')
            return r
    def close(self):self.stream.close();self.socket.close()

def expected(tx):
    ex=identity(tx)
    return {'status':'0','consumed':str(len(serialize(tx))),'full_size':ex['full_size'],'stripped_size':ex['stripped_size'],'txid_digest_order':ex['txid_digest_order'],'wtxid_digest_order':ex['wtxid_digest_order']}
def main():
    base=(_rb_paths()['substrate'])/('workloads-'+time.strftime('%Y%m%dT%H%M%S'));base.mkdir();rows=[]
    tx=structure(['']);item={'hex':serialize(tx).hex(),'mode':'witness','operation':'exact'};ex=expected(tx)
    for batch in [1,8,64]:
        h=Host(base,'dummy')
        try:
            c=Client(h);times=[]
            for _ in range(100):
                start=time.monotonic_ns();r=c.call({'op':'evaluate','items':[item]*batch});times.append(time.monotonic_ns()-start);assert r=={'request':str(c.counter),'status':'ok','results':[ex]*batch}
            c.close();state=h.stop();assert invariant(state) is None and state.get('meta/sequence','0')=='0'
            rows.append({'workload':1,'batch':batch,'requests':100,'passed':True,'median_ns':statistics.median(times),'min_ns':min(times),'max_ns':max(times),'scope':'instrument smoke, not candidate benchmark'})
        finally:
            if h.process.poll() is None:h.process.kill();h.process.wait()
    h=Host(base,'dummy')
    def producer(index):
        c=Client(h);lat=[]
        try:
            for i in range(1250):
                start=time.monotonic_ns()
                while True:
                    r=c.call({'op':'submit','id':f'job_{index}_{i}','items':[item]*8})
                    if r['status']!='backpressure':break
                    if time.monotonic_ns()-start>60_000_000_000:raise TimeoutError('admission after backpressure')
                    time.sleep(.001)
                lat.append(time.monotonic_ns()-start)
                if r['status']!='accepted':raise RuntimeError(r)
            return lat
        finally:c.close()
    try:
        start=time.monotonic()
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:latencies=sum(list(pool.map(producer,range(8))),[])
        state=h.stop();elapsed=time.monotonic()-start
        assert invariant(state) is None and state['meta/checkpoint']=='10000'
        receipts=[json.loads(v) for k,v in state.items() if k.startswith('r/')]
        assert len(receipts)==10000 and all(r['state']=='complete' and r['results']==[ex]*8 for r in receipts)
        events=h.events();writes=[e for e in events if e['phase']=='write_enter'];syncs=[e for e in events if e['phase']=='wal_sync_exit' and e['sync']==1]
        assert all(e['sync']==1 and e['wal']==1 for e in writes)
        rows.append({'workload':3,'jobs':10000,'transactions_per_job':8,'clients':8,'passed':True,'elapsed_seconds':elapsed,'admission_median_ns':statistics.median(latencies),'admission_max_ns':max(latencies),'c_write_count':len(writes),'wal_sync_count':len(syncs),'receipt_checks':len(receipts),'scope':'single instrument qualification run, not language performance evidence'})
    finally:
        if h.process.poll() is None:h.process.kill();h.process.wait()
    result={'schema':'rosettanode.substrate.workload_probe.v1','status':'passed','results':rows,'candidate_launch_allowed':False,'missing':['workload 4 full trace','allocation/write errors','full measurement runner']}
    (base/'result.json').write_text(json.dumps(result,indent=2)+'\n');(ROOT/'evidence/workload-probe.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
if __name__=='__main__':main()
