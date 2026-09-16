#!/usr/bin/env python3
import concurrent.futures,json,sys,time
from service_probe import ROOT,Host,invariant
from workload_probe import Client,expected
sys.path.insert(0,str(ROOT/'evaluator'))
from proxy import Proxy
from state import check
from corpus import structure
from chain_checker import serialize

def main():
    base=ROOT/'.local'/('mixed-'+time.strftime('%Y%m%dT%H%M%S'));base.mkdir();h=Host(base,'dummy_v2');original=h.socket
    ids=[f'job_{p}_{i}' for p in range(8) for i in range(1250) if i%11==0]
    proxy=Proxy(h.root/'proxy',original,ids);h.socket=h.root/'proxy'
    txs=[structure([]),structure(['']),structure(['0011'])]
    # Negative amounts are explicitly a separate fixture family.
    txs[0]['outputs'][0]['amount']='7';txs[2]['outputs'][0]['amount']='19'
    items=[{'hex':serialize(tx).hex(),'mode':'witness','operation':'exact'} for tx in txs];expect=[expected(tx) for tx in txs]
    def producer(p):
        c=Client(h);acks={};cancelled=[];counts={'ok':0,'too_late':0,'response_lost':0};latencies=[]
        try:
            for i in range(1250):
                id=f'job_{p}_{i}';k=i%3;q={'op':'submit','id':id,'items':[items[k]],'priority':'high' if i%4 else 'normal'};start=time.monotonic_ns()
                while True:
                    r=c.call(q)
                    if r.get('transport_outcome')=='response_lost':counts['response_lost']+=1;continue
                    if r['status']=='backpressure':
                        if time.monotonic_ns()-start>60_000_000_000:raise TimeoutError('backpressure')
                        time.sleep(.001);continue
                    assert r['status'] in ['accepted','existing'],r;break
                latencies.append(time.monotonic_ns()-start);acks[id]={'items':q['items'],'results':[expect[k]]}
                if i%7==0:
                    r=c.call({'op':'cancel','id':id});assert r['status'] in ['ok','too_late'];counts[r['status']]+=1
                    if r['status']=='ok':cancelled.append(id)
            return acks,cancelled,counts,latencies
        finally:c.close()
    try:
        start=time.monotonic()
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:parts=list(pool.map(producer,range(8)))
        # Close the proxy before the final control connection so it cannot exceed
        # the eight-client cap while drained connections are retiring.
        proxy.close();h.socket=original;time.sleep(.02);rows=h.stop();elapsed=time.monotonic()-start
        acks={k:v for part in parts for k,v in part[0].items()};cancelled=[k for part in parts for k in part[1]]
        problem=check(rows,acks,cancelled);assert problem is None,problem;assert rows['meta/checkpoint']=='10000';assert len(proxy.events)==len(ids)
        result={'schema':'rosettanode.substrate.mixed_probe.v1','status':'passed','jobs':10000,'clients':8,'elapsed_seconds':elapsed,'lost_acknowledgements':len(proxy.events),'accepted_cancellations':len(cancelled),'late_cancellations':sum(p[2]['too_late'] for p in parts),'negative_amount_family':'one of three fixture families, reported separately','independent_receipts_checked':10000,'stats_path':str((h.root/'rocksdb-stats.txt').relative_to(ROOT)),'candidate_launch_allowed':False}
        (base/'result.json').write_text(json.dumps(result,indent=2)+'\n');(ROOT/'evidence/mixed-probe.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
    finally:
        proxy.close()
        if h.process.poll() is None:h.process.kill();h.process.wait()
if __name__=='__main__':main()
