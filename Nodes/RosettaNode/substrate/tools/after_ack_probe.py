#!/usr/bin/env python3

import sys as _rb_sys
from pathlib import Path as _RBPath
_rb_sys.path.insert(0, str(_RBPath(__file__).resolve().parents[4] / 'Project/scripts'))
from state_root import operational_paths as _rb_paths, logical_path as _rb_logical, acquire_writer_lease as _rb_writer_lease
if __name__ == '__main__':
    _rb_writer_lease()
import json,time
from service_probe import ROOT,Host,ITEM,invariant
from workload_probe import Client
from storage_probe import inspect

def main():
    base=(_rb_paths()['substrate'])/('after-ack-'+time.strftime('%Y%m%dT%H%M%S'));base.mkdir();db=None;results=[]
    for cycle in range(3):
        h=Host(base,db=db);db=h.db
        try:
            c=Client(h);identifier='job'+str(cycle);ack=c.call({'op':'submit','id':identifier,'items':[ITEM]});assert ack['status']=='accepted'
            deadline=time.monotonic()+5
            while not any(e.get('id')==identifier for e in c.events):
                r=json.loads(c.stream.readline());assert r.get('event')=='terminal';c.events.append(r)
                if time.monotonic()>deadline:raise TimeoutError('terminal notification')
            c.close();rows=h.stop(kill=True);assert invariant(rows) is None;assert rows['meta/checkpoint']==str(cycle+1)
            results.append({'cycle':cycle,'passed':True,'checkpoint':rows['meta/checkpoint'],'kill_after_observed_terminal_notification':True})
        finally:
            if h.process.poll() is None:h.process.kill();h.process.wait()
    result={'schema':'rosettanode.substrate.after_ack_probe.v1','status':'passed','results':results,'candidate_launch_allowed':False}
    (base/'result.json').write_text(json.dumps(result,indent=2)+'\n');(ROOT/'evidence/after-ack-probe.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
if __name__=='__main__':main()
