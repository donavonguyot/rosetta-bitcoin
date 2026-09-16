#!/usr/bin/env python3
"""Completed requests must not execute again when a broker restarts."""
import json,subprocess,time,uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def main():
    work=ROOT/'.local'/('broker-regression-'+uuid.uuid4().hex[:8]);work.mkdir();q=work/'queue';q.mkdir();token='1'*32
    request={'command':'echo replayed >> /workspace/REPLAYED','seconds':10}
    (q/(token+'.request')).write_text(json.dumps(request));(q/(token+'.response')).write_text(json.dumps({'exit':0,'stdout':'original','stderr':''}))
    stop=work/'stop';log=(work/'log').open('w');p=subprocess.Popen(['python3',str(ROOT/'tools/broker_v3.py'),str(work),str(ROOT/'.local/adapter-bundle'),str(stop)],stdout=log,stderr=log)
    try:
        time.sleep(.3);assert p.poll() is None
        token2='2'*32;(q/(token2+'.request')).write_text(json.dumps({'command':'echo fresh > /workspace/FRESH','seconds':10}))
        end=time.monotonic()+20
        while not (q/(token2+'.response')).exists():
            assert time.monotonic()<end and p.poll() is None;time.sleep(.05)
        assert json.loads((q/(token2+'.response')).read_text())['exit']==0
        assert (work/'FRESH').read_text()=='fresh\n' and not (work/'REPLAYED').exists()
        assert json.loads((q/(token+'.response')).read_text())['stdout']=='original'
    finally:stop.touch();p.wait(timeout=10);log.close()
    result={'schema':'rosettanode.substrate.broker_regression.v1','status':'passed','completed_request_not_replayed':True,'new_request_executed_once':True,'work':str(work)}
    (ROOT/'evidence/broker-regression-v3.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
if __name__=='__main__':main()
