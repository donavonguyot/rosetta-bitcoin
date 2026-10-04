#!/usr/bin/env python3

import sys as _rb_sys
from pathlib import Path as _RBPath
_rb_sys.path.insert(0, str(_RBPath(__file__).resolve().parents[4] / 'Project/scripts'))
from state_root import operational_paths as _rb_paths, logical_path as _rb_logical, acquire_writer_lease as _rb_writer_lease
if __name__ == '__main__':
    _rb_writer_lease()
import ctypes as C,hashlib,json,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'evaluator'))
from corpus import cases,identity
class Item(C.Structure):_fields_=[('data',C.c_void_p),('size',C.c_uint64),('witness',C.c_uint32),('exact',C.c_uint32)]
class Offset(C.Structure):_fields_=[('offset',C.c_uint64),('size',C.c_uint64),('witness',C.c_uint32),('exact',C.c_uint32)]
class Result(C.Structure):_fields_=[('status',C.c_uint64),('consumed',C.c_uint64),('full_size',C.c_uint64),('stripped_size',C.c_uint64),('txid',C.c_ubyte*32),('wtxid',C.c_ubyte*32)]
def main():
    lib=C.CDLL(str((_rb_paths()['substrate'] / 'adapter.so')));lib.rn_arena_create.argtypes=[C.c_void_p,C.c_uint64];lib.rn_arena_create.restype=C.c_void_p;lib.rn_arena_data.argtypes=[C.c_void_p];lib.rn_arena_data.restype=C.c_void_p;lib.rn_arena_destroy.argtypes=[C.c_void_p]
    lib.rn_verify_v1.argtypes=[C.c_void_p,C.POINTER(Item),C.c_uint64,C.POINTER(Result)];lib.rn_verify_v2.argtypes=[C.c_void_p,C.POINTER(Offset),C.c_uint64,C.POINTER(Result),C.POINTER(C.c_uint64)]
    checks=[]
    for row in cases():
        q=row['request'];expected=row['expected'];op=q['op']
        if op not in ['decode_exact','decode_prefix'] or 'limits' in q:continue
        data=bytes.fromhex(q['bytes'])[int(q.get('offset','0')):]
        for batch in [1,8,64]:
            raw=C.create_string_buffer(data*batch);a=lib.rn_arena_create(raw,len(data)*batch);assert a
            start=lib.rn_arena_data(a);items=(Item*batch)(*[Item(start+i*len(data),len(data),q['mode']=='witness',op=='decode_exact') for i in range(batch)]);offsets=(Offset*batch)(*[Offset(i*len(data),len(data),q['mode']=='witness',op=='decode_exact') for i in range(batch)])
            v1=(Result*batch)();v2=(Result*batch)();mask=C.c_uint64();assert lib.rn_verify_v1(a,items,batch,v1)==0;assert lib.rn_verify_v2(a,offsets,batch,v2,C.byref(mask))==0
            assert bytes(v1)==bytes(v2)
            status={'ok':0,'malformed_encoding':1,'resource_limit':2}[expected['status']]
            passed=all(r.status==status for r in v1) and mask.value==((1<<batch)-1 if status==0 else 0)
            if status==0:
                ex=identity(expected['transaction']);r=v1[0]
                passed &= r.consumed==int(expected['consumed']) and r.full_size==int(ex['full_size']) and r.stripped_size==int(ex['stripped_size']) and bytes(r.txid).hex()==ex['txid_digest_order'] and bytes(r.wtxid).hex()==ex['wtxid_digest_order']
            checks.append({'id':row['id'],'batch':batch,'passed':bool(passed),'family':row['semantic_family']});lib.rn_arena_destroy(a)
    good=subprocess.run([str((_rb_paths()['substrate'] / 'adapter-asan')),'01000000000000000000'],capture_output=True,text=True)
    bad=subprocess.run([str((_rb_paths()['substrate'] / 'adapter-asan-mutant')),'01000000000000000000'],capture_output=True,text=True)
    ((_rb_paths()['substrate'] / 'asan-control.log')).write_text(good.stdout+good.stderr);((_rb_paths()['substrate'] / 'asan-mutant.log')).write_text(bad.stdout+bad.stderr)
    asan=good.returncode==0 and 'AddressSanitizer' not in good.stderr and bad.returncode!=0 and 'heap-use-after-free' in bad.stderr and 'rn_verify_v1' in bad.stderr
    result={'schema':'rosettanode.substrate.adapter_probe.v1','status':'passed' if all(c['passed'] for c in checks) and asan else 'failed','checks':checks,'asan_lifetime_fault_detected':asan,'scope':'v1/v2 raw encoding adapter, not complete service lifetime gate','candidate_launch_allowed':False}
    (ROOT/'evidence/adapter-probe.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({'status':result['status'],'checks':len(checks),'failures':[c for c in checks if not c['passed']]}));return int(result['status']!='passed')
if __name__=='__main__':raise SystemExit(main())
