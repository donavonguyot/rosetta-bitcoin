#!/usr/bin/env python3

import sys as _rb_sys
from pathlib import Path as _RBPath
_rb_sys.path.insert(0, str(_RBPath(__file__).resolve().parents[4] / 'Project/scripts'))
from state_root import operational_paths as _rb_paths, logical_path as _rb_logical, acquire_writer_lease as _rb_writer_lease
if __name__ == '__main__':
    _rb_writer_lease()
import json,subprocess,time,os
from service_probe import ROOT,Host,ITEM,invariant
from workload_probe import Client

def trial(base,byte_limit):
    h=Host(base,'dummy','adapter_enter','*')
    try:
        c=Client(h);items=[{**ITEM,'hex':'00'*(256*1024)}]*64 if byte_limit else [ITEM];count=4 if byte_limit else 1024
        for n in range(count):assert c.call({'op':'submit','id':'j'+str(n),'items':items})['status']=='accepted'
        over=c.call({'op':'submit','id':'over','items':[ITEM]});assert over['status']=='backpressure'
        unknown=c.call({'op':'cancel','id':'unknown'});assert unknown['status']=='not_found'
        program=os.environ.get('RN_CANDIDATE',str((_rb_paths()['substrate'] / 'dummy')))
        def demote():os.setgroups([]);os.setgid(65534);os.setuid(65534)
        second=subprocess.run([program,str(h.db),str(h.root/'other')],capture_output=True,text=True,timeout=5,cwd=h.root,preexec_fn=demote if 'RN_CANDIDATE' in os.environ else None)
        assert second.returncode!=0 and 'lock' in second.stderr.lower()
        c.close();before=h.stop(kill=True);assert invariant(before) is None and before['meta/jobs']==str(count) and 'id/over' not in before and 'id/unknown' not in before
        return {'test':'payload_saturation' if byte_limit else 'job_saturation','admitted':count,'bytes':before['meta/bytes'],'competing_writer_rejected':True,'passed':True}
    finally:
        if h.process.poll() is None:h.process.kill();h.process.wait()
def main():
    base=(_rb_paths()['substrate'])/('limits-'+time.strftime('%Y%m%dT%H%M%S'));base.mkdir();rows=[trial(base,False),trial(base,True)]
    result={'schema':'rosettanode.substrate.limits_probe.v1','status':'passed','results':rows,'candidate_launch_allowed':False}
    (base/'result.json').write_text(json.dumps(result,indent=2)+'\n');(ROOT/'evidence/limits-probe.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
if __name__=='__main__':main()
