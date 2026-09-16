#!/usr/bin/env python3
import ctypes,json,os,subprocess,time
from service_probe import ROOT,Host,ITEM,invariant
from priority_probe import item,token
from workload_probe import Client

def requests(base):
    h=Host(base);c=Client(h)
    try:
        cases=[[],[ITEM]*65,[{**ITEM,'mode':'auto'}],[{**ITEM,'operation':'other'}],[{**ITEM,'hex':'0'}],[{**ITEM,'hex':'xx'}]]
        for i,items in enumerate(cases):assert c.call({'op':'submit','id':'bad'+str(i),'items':items})['status']=='invalid_request'
        assert c.call({'op':'submit','id':'bad/id','items':[ITEM]})['status']=='invalid_request'
        c.close();rows=h.stop();assert invariant(rows) is None and not any(k.startswith('id/') for k in rows)
        return {'invalid_cases':len(cases)+1,'no_state_created':True}
    finally:
        c.close()
        if h.process.poll() is None:h.process.kill();h.process.wait()

def completed_accounting(base):
    h=Host(base,boundary='adapter_enter',transition='*',per_job=True);c=Client(h)
    try:
        for n in range(2,1025):(h.release/token(n).replace('/','_')).touch()
        for n in range(1,1025):assert c.call({'op':'submit','id':'j'+str(n),'items':[item(n)]})['status']=='accepted'
        end=time.monotonic()+20
        while sum(e['phase']=='adapter_exit' for e in h.events())<1023:
            if time.monotonic()>end:raise TimeoutError('unblocked workers did not finish')
            time.sleep(.01)
        assert c.call({'op':'submit','id':'over','items':[ITEM]})['status']=='backpressure'
        c.close();rows=h.stop(kill=True);assert invariant(rows) is None and rows['meta/jobs']=='1024' and rows.get('meta/checkpoint','0')=='0'
        return {'completed_uncommitted':1023,'outstanding':1024,'head_of_line_accounting':True}
    finally:
        c.close()
        if h.process.poll() is None:h.process.kill();h.process.wait()

def incompatible(base):
    h=Host(base);h.stop();lib=ctypes.CDLL('librocksdb.so')
    signatures={'rocksdb_options_create':([],ctypes.c_void_p),'rocksdb_open':([ctypes.c_void_p,ctypes.c_char_p,ctypes.POINTER(ctypes.c_char_p)],ctypes.c_void_p),'rocksdb_writeoptions_create':([],ctypes.c_void_p),'rocksdb_writeoptions_set_sync':([ctypes.c_void_p,ctypes.c_ubyte],None),'rocksdb_put':([ctypes.c_void_p,ctypes.c_void_p,ctypes.c_char_p,ctypes.c_size_t,ctypes.c_char_p,ctypes.c_size_t,ctypes.POINTER(ctypes.c_char_p)],None),'rocksdb_close':([ctypes.c_void_p],None)}
    for name,(args,restype) in signatures.items():fn=getattr(lib,name);fn.argtypes=args;fn.restype=restype
    error=ctypes.c_char_p();options=lib.rocksdb_options_create();db=lib.rocksdb_open(options,str(h.db).encode(),ctypes.byref(error));assert db and not error.value
    wo=lib.rocksdb_writeoptions_create();lib.rocksdb_writeoptions_set_sync(wo,1);lib.rocksdb_put(db,wo,b'meta/version',12,b'99',2,ctypes.byref(error));assert not error.value;lib.rocksdb_close(db)
    program=os.environ.get('RN_CANDIDATE',str(ROOT/'.local/dummy'))
    def demote():os.setgroups([]);os.setgid(65534);os.setuid(65534)
    p=subprocess.run([program,str(h.db),str(h.root/'new-socket')],capture_output=True,timeout=5,cwd=h.root,preexec_fn=demote if 'RN_CANDIDATE' in os.environ else None)
    assert p.returncode!=0 and p.stderr,('incompatible version accepted',p.returncode)
    return {'version':'99','rejected':True,'diagnostic':p.stderr.decode(errors='replace')[:1000]}
