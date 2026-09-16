#!/usr/bin/env python3
"""One measured repetition inside the evaluator image, fresh /state volume."""
import argparse,concurrent.futures,hashlib,json,statistics,sys,time
from pathlib import Path
from service_probe import ROOT,Host,invariant
from storage_probe import inspect
from workload_probe import Client,expected
sys.path.insert(0,str(ROOT/'evaluator'))
from corpus import structure
from chain_checker import serialize
from state import check
from proxy import Proxy

def quantile(values,q):
    a=sorted(values);return a[min(len(a)-1,int((len(a)-1)*q))]
def main():
    p=argparse.ArgumentParser();p.add_argument('--workload',choices=['1-1','1-8','1-64','3','4'],required=True);p.add_argument('--lane',choices=['baseline','optimization'],required=True);a=p.parse_args()
    base=Path('/state/run');base.mkdir();h=Host(base,extra_env={'LD_PRELOAD':''} if a.workload.startswith('1-') else None);proxy=None
    txs=[structure([]),structure(['']),structure(['0011'])];txs[0]['outputs'][0]['amount']='7';txs[2]['outputs'][0]['amount']='19'
    items=[{'hex':serialize(tx).hex(),'mode':'witness','operation':'exact'} for tx in txs];ex=[expected(tx) for tx in txs];latencies=[];cancelled=[];acks={};lost=0
    try:
        if a.workload.startswith('1-'):
            batch=int(a.workload.split('-')[1]);c=Client(h);start=time.monotonic_ns()
            for i in range(10000):
                before=time.monotonic_ns();r=c.call({'op':'evaluate','items':[items[0]]*batch});latencies.append(time.monotonic_ns()-before);assert r['status']=='ok' and r['results']==[ex[0]]*batch
            elapsed=(time.monotonic_ns()-start)/1e9;c.close();rows=h.stop();assert invariant(rows) is None;units=10000*batch
        else:
            original=h.socket
            if a.workload=='4':
                drops=[f'job_{client}_{i}' for client in range(8) for i in range(1250) if i%11==0];proxy=Proxy(h.root/'proxy',original,drops);h.socket=h.root/'proxy'
            def producer(client):
                c=Client(h);local=[];acknowledged={};cancels=[];lost_count=0;backpressure=0
                try:
                    for i in range(1250):
                        id=f'job_{client}_{i}';kind=i%3 if a.workload=='4' else 0;batch=[items[kind]]*(8 if a.workload=='3' else 1);before=time.monotonic_ns()
                        while True:
                            r=c.call({'op':'submit','id':id,'items':batch,'priority':'high' if a.workload=='4' and i%4 else 'normal'})
                            if r.get('transport_outcome')=='response_lost':lost_count+=1;continue
                            if r['status']=='backpressure':
                                backpressure+=1
                                if time.monotonic_ns()-before>120_000_000_000:raise TimeoutError('backpressure did not resolve')
                                time.sleep(.001);continue
                            assert r['status'] in ['accepted','existing'],r;break
                        local.append(time.monotonic_ns()-before);acknowledged[id]={'items':batch,'results':[ex[kind]]*len(batch)}
                        if a.workload=='4' and i%7==0:
                            r=c.call({'op':'cancel','id':id});assert r['status'] in ['ok','too_late']
                            if r['status']=='ok':cancels.append(id)
                    return local,acknowledged,cancels,lost_count,backpressure
                finally:c.close()
            start=time.monotonic_ns()
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:parts=list(pool.map(producer,range(8)))
            if proxy:proxy.close();h.socket=original
            time.sleep(.02);h.stop(inspect_state=False);elapsed=(time.monotonic_ns()-start)/1e9;rows=inspect(h.db)
            latencies=[v for part in parts for v in part[0]];acks={k:v for part in parts for k,v in part[1].items()};cancelled=[v for part in parts for v in part[2]];lost=sum(part[3] for part in parts)
            problem=check(rows,acks,cancelled);assert problem is None,problem;assert rows['meta/checkpoint']=='10000';units=10000
        events=h.events();writes=[e for e in events if e['phase']=='write_enter'];members={}
        for e in events:
            if e['phase']=='write_member':members.setdefault(e['call'],set()).add(e['transition'])
        histogram={}
        for w in writes:
            assert w['sync']==1 and w['wal']==1
            group=members.get(w['call'],set());n=sum(k.startswith(('p/','r/')) for k in group)
            assert n<= (32 if a.lane=='optimization' else 1),('group limit',n)
            if n:histogram[str(n)]=histogram.get(str(n),0)+1
        syncs=[e for e in events if e['phase']=='wal_sync_exit' and e['sync']==1]
        stats=h.root/'rocksdb-stats.txt';log=h.db/'LOG';activity=[line for line in log.read_text(errors='replace').splitlines() if any(word in line.lower() for word in ['compaction','flush','stall'])] if log.exists() else []
        result={'schema':'rosettanode.substrate.repetition.v1','status':'passed','workload':a.workload,'lane':a.lane,'elapsed_seconds':elapsed,'units':units,'units_per_second':units/elapsed,'latency_kind':'request round trip' if a.workload.startswith('1-') else 'admission round trip including retry/backpressure','latency_ns':{'median':statistics.median(latencies),'p95':quantile(latencies,.95),'p99':quantile(latencies,.99),'max':max(latencies)},'lost_acknowledgements':lost,'accepted_cancellations':len(cancelled),'c_write_count':len(writes),'wal_sync_count':len(syncs),'batch_size_histogram':histogram,'datadir_bytes':sum(p.stat().st_size for p in h.db.rglob('*') if p.is_file()),'rocksdb_stats':stats.read_text() if stats.exists() else None,'compaction_flush_stall_log_lines':activity,'instrumentation':'none in timed workload 1; C API/WAL observation in workloads 3/4','timer_boundary':'first request to last response for W1; first producer dispatch through durable draining process exit for W3/4; startup/volume/inspection excluded','intentional_group_wait_verification':'source audit plus declared timer; observed wall time cannot isolate deliberate wait from OS scheduling'}
        Path('/output/result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({'status':'passed','elapsed_seconds':elapsed}))
    finally:
        if proxy:proxy.close()
        if h.process.poll() is None:h.process.kill();h.process.wait()
if __name__=='__main__':main()
