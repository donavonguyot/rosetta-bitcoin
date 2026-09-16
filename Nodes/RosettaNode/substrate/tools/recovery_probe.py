#!/usr/bin/env python3
"""External barriers and independent post-crash inspection for the dummy service."""
import concurrent.futures,json,time
from service_probe import ROOT,Host,ITEM,invariant

def complete(host,id='job'):
    end=time.monotonic()+10
    while time.monotonic()<end:
        r=host.request({'op':'status','id':id})
        if r['status']=='ok' and r['job']['state'] in ['complete','cancelled']:return r['job']
        time.sleep(.005)
    raise TimeoutError('receipt')

def main():
    base=ROOT/'.local'/('recovery-probe-'+time.strftime('%Y%m%dT%H%M%S'));base.mkdir();results=[]
    for variant in ['dummy','dummy_cancel']:
        h=Host(base,variant,'native_success','r/00000000000000000001')
        try:
            assert h.request({'op':'submit','id':'job','items':[ITEM]})['status']=='accepted';h.barrier()
            with concurrent.futures.ThreadPoolExecutor() as executor:
                f=executor.submit(h.request,{'op':'cancel','id':'job'})
                time.sleep(.05);h.release.touch();cancel=f.result()
            rows=h.stop();expected='ok' if variant=='dummy_cancel' else 'too_late'
            results.append({'test':'cancel_started_after_terminal_entry','variant':variant,'observed':cancel['status'],'expected':expected,'intended_mutant_failure':variant=='dummy_cancel','passed':cancel['status']==expected and invariant(rows) is None})
        finally:
            if h.process.poll() is None:h.process.kill();h.process.wait()
    # All four workers stop inside the common adapter; cancellation must not free
    # worker-owned arenas and its durable intent must survive SIGKILL.
    h=Host(base,'dummy','adapter_enter','*')
    try:
        ack=h.request({'op':'submit','id':'job','items':[ITEM]});h.barrier()
        cancel=h.request({'op':'cancel','id':'job'});again=h.request({'op':'cancel','id':'job'})
        rows=h.stop(kill=True);assert cancel['status']==again['status']=='ok'
        assert rows.get('c/00000000000000000001')=='1' and invariant(rows) is None
        recovered=Host(base,'dummy_v2',db=h.db)
        try:
            receipt=complete(recovered);after=recovered.stop()
            results.append({'test':'v1_cancel_pending_to_v2_recovery','passed':ack['status']=='accepted' and receipt['state']=='cancelled' and invariant(after) is None,'before':rows,'after':after})
        finally:
            if recovered.process.poll() is None:recovered.process.kill();recovered.process.wait()
    finally:
        if h.process.poll() is None:h.process.kill();h.process.wait()
    for kind in ['p','r']:
        for boundary in ['write_enter','wal_sync_enter','native_success']:
            h=Host(base,'dummy',boundary,kind+'/00000000000000000001')
            try:
                with h.connect() as s:
                    s.sendall(json.dumps({'request':'a','op':'submit','id':'job','items':[ITEM]}).encode()+b'\n');h.barrier()
                before=h.stop(kill=True);assert invariant(before) is None
                recovered=Host(base,'dummy_v2',db=h.db)
                try:
                    if 'meta/sequence' in before:receipt=complete(recovered)
                    else:receipt=None
                    after=recovered.stop();passed=invariant(after) is None and (receipt is None or receipt['state']=='complete')
                    results.append({'test':'process_crash','transition':kind,'boundary':boundary,'passed':passed,'before':before,'after':after})
                finally:
                    if recovered.process.poll() is None:recovered.process.kill();recovered.process.wait()
            finally:
                if h.process.poll() is None:h.process.kill();h.process.wait()
    result={'schema':'rosettanode.substrate.recovery_probe.v1','status':'passed' if all(r['passed'] for r in results) else 'failed','results':results,'candidate_launch_allowed':False,'limits':['not a complete Gate B','priority starvation and notification loss not yet qualified']}
    (base/'result.json').write_text(json.dumps(result,indent=2)+'\n');(ROOT/'evidence/recovery-probe.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({'status':result['status'],'tests':len(results)}))
if __name__=='__main__':main()
