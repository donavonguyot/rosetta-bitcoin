#!/usr/bin/env python3

import sys as _rb_sys
from pathlib import Path as _RBPath
_rb_sys.path.insert(0, str(_RBPath(__file__).resolve().parents[4] / 'Project/scripts'))
from state_root import operational_paths as _rb_paths, logical_path as _rb_logical, acquire_writer_lease as _rb_writer_lease
if __name__ == '__main__':
    _rb_writer_lease()
import hashlib,json,time
from service_probe import ROOT,Host,invariant

def item(n):return {'hex':n.to_bytes(4,'little').hex()+'000000000000','mode':'witness','operation':'exact'}
def token(n):return 'a/'+hashlib.sha256(bytes.fromhex(item(n)['hex'])).hexdigest()
def wait_entries(h,n):
    end=time.monotonic()+10
    while time.monotonic()<end:
        entries=[e['transition'] for e in h.events() if e['phase']=='adapter_enter']
        if len(entries)>=n:return entries
        time.sleep(.005)
    raise TimeoutError('adapter dispatch')
def release(h,n):(h.release/token(n).replace('/','_')).touch()
def trial(base,variant,mixed):
    h=Host(base,variant,'adapter_enter','*',per_job=True)
    try:
        for n in range(1,5):assert h.request({'op':'submit','id':'block'+str(n),'items':[item(n)]})['status']=='accepted'
        wait_entries(h,4)
        if mixed:
            assert h.request({'op':'submit','id':'solehigh','items':[item(9)],'priority':'high'})['status']=='accepted'
            release(h,4);wait_entries(h,5)
        high=list(range(10,16)) if mixed else []
        normal=list(range(20,22)) if mixed else list(range(20,28))
        for n in high+normal:assert h.request({'op':'submit','id':'q'+str(n),'items':[item(n)],'priority':'high' if n in high else 'normal'})['status']=='accepted'
        release(h,9 if mixed else 4);observed=[];mapping={token(n):n for n in high+normal}
        for i in range(len(mapping)):
            offset=5 if mixed else 4;entries=wait_entries(h,offset+1+i);current=mapping[entries[offset+i]];observed.append(current);release(h,current)
        for n in [1,2,3]:release(h,n)
        rows=h.stop();expected=[10,11,12,20,13,14,15,21] if mixed else normal
        failure=observed!=expected
        return {'variant':variant,'mixed':mixed,'observed':observed,'expected':expected,'intended_failure':variant=='dummy_starve' and mixed,'passed':failure==(variant=='dummy_starve' and mixed) and invariant(rows) is None,'barriers_external':True}
    finally:
        if h.process.poll() is None:h.process.kill();h.process.wait()
def main():
    base=(_rb_paths()['substrate'])/('priority-'+time.strftime('%Y%m%dT%H%M%S'));base.mkdir()
    rows=[trial(base,v,mixed) for v in ['dummy_v2','dummy_starve'] for mixed in [False,True]]
    result={'schema':'rosettanode.substrate.priority_probe.v1','status':'passed' if all(r['passed'] for r in rows) else 'failed','results':rows,'candidate_launch_allowed':False}
    (base/'result.json').write_text(json.dumps(result,indent=2)+'\n');(ROOT/'evidence/priority-probe.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
if __name__=='__main__':main()
