#!/usr/bin/env python3

import sys as _rb_sys
from pathlib import Path as _RBPath
_rb_sys.path.insert(0, str(_RBPath(__file__).resolve().parents[4] / 'Project/scripts'))
from state_root import operational_paths as _rb_paths, logical_path as _rb_logical, acquire_writer_lease as _rb_writer_lease
if __name__ == '__main__':
    _rb_writer_lease()
import json,time
from service_probe import ROOT,Host,ITEM,invariant
from recovery_probe import complete

def main():
    base=(_rb_paths()['substrate'])/('errors-'+time.strftime('%Y%m%dT%H%M%S'));base.mkdir();results=[]
    for fault in ['admission','terminal','allocation']:
        env={'RN_FAIL_ARENA':'1'} if fault=='allocation' else {'RN_FAIL_TRANSITION':('p/' if fault=='admission' else 'r/')+'00000000000000000001'}
        h=Host(base,extra_env=env)
        try:
            with h.connect() as connection:
                connection.sendall(json.dumps({'request':'fault','op':'submit','id':'job','items':[ITEM]}).encode()+b'\n')
                try:line=connection.makefile('rb').readline()
                except ConnectionResetError:
                    if fault!='admission':raise
                    line=b''
                ack=json.loads(line) if line else None
                if fault!='admission':assert ack is not None, 'acknowledged-job fault must follow admission acknowledgement'
            h.process.wait(timeout=10)
            from storage_probe import inspect
            before=inspect(h.db);assert h.process.returncode!=0 and invariant(before) is None
            if fault=='admission':assert ack is None or ack.get('status')=='execution_failure'
            else:assert ack['status']=='accepted'
            restored=Host(base,db=h.db)
            try:
                if fault!='admission':assert complete(restored)['state']=='complete'
                else:assert restored.request({'op':'status','id':'job'})['status']=='not_found'
                after=restored.stop();assert invariant(after) is None
                results.append({'fault':fault,'passed':True,'ack':ack,'before':before,'after':after})
            finally:
                if restored.process.poll() is None:restored.process.kill();restored.process.wait()
        finally:
            if h.process.poll() is None:h.process.kill();h.process.wait()
    result={'schema':'rosettanode.substrate.error_probe.v1','status':'passed','results':results,'candidate_launch_allowed':False}
    (base/'result.json').write_text(json.dumps(result,indent=2)+'\n');(ROOT/'evidence/error-probe.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({'status':'passed','faults':len(results)}))
if __name__=='__main__':main()
