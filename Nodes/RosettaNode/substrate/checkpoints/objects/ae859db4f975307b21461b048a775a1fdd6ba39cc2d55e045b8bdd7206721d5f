#!/usr/bin/env python3
"""Public smoke checks; hidden crash/concurrency qualification is separate."""
import json,os,socket,subprocess,sys,tempfile,time
from pathlib import Path
binary=str(Path(sys.argv[1]).resolve());root=Path(tempfile.mkdtemp(prefix='substrate-public-',dir='.'));sock=root/'service.sock';data=root/'db'
p=subprocess.Popen([binary,str(data),str(sock)])
item={'hex':'01000000000000000000','mode':'witness','operation':'exact'}
def call(q):
    with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as s:
        s.settimeout(5);s.connect(str(sock));s.sendall(json.dumps({'request':'public',**q}).encode()+b'\n')
        with s.makefile('rb') as f:
            while True:
                r=json.loads(f.readline())
                if 'event' not in r:assert r['request']=='public';return r
try:
    end=time.monotonic()+10
    while not sock.exists():
        if p.poll() is not None:raise RuntimeError('service failed to start')
        if time.monotonic()>end:raise TimeoutError('socket startup')
        time.sleep(.01)
    assert call({'op':'status','id':'missing'})['status']=='not_found'
    assert call({'op':'cancel','id':'missing'})['status']=='not_found'
    r=call({'op':'evaluate','items':[item]});assert r['status']=='ok' and r['results'][0]['status']=='0' and r['results'][0]['consumed']=='10'
    assert call({'op':'submit','id':'job','items':[item]})['status']=='accepted'
    assert call({'op':'submit','id':'job','items':[item]})['status']=='existing'
    assert call({'op':'submit','id':'job','items':[{**item,'hex':'02000000000000000000'}]})['status']=='conflict'
    end=time.monotonic()+10
    while call({'op':'status','id':'job'})['job']['state'] not in ['complete','cancelled']:
        if time.monotonic()>end:raise TimeoutError('terminal receipt')
        time.sleep(.01)
    assert call({'op':'shutdown'})['status']=='draining';assert p.wait(timeout=10)==0
    print('public smoke passed; this is not durability qualification')
finally:
    if p.poll() is None:p.kill();p.wait()
