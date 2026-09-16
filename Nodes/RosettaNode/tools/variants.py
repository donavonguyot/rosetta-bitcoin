#!/usr/bin/env python3
import ctypes as C,hashlib,json,re,subprocess,time
from pathlib import Path
from protocol import Engine,ROOT,Scan
from corpus import cases
from chain_checker import digest
OUT=ROOT/'.local/tx'
def run(cmd):return subprocess.run(cmd,cwd=ROOT,check=True,text=True,capture_output=True,timeout=30).stdout.strip()
def main():
    start=time.monotonic();module=OUT/'module.ll'
    run(['clang','-emit-llvm','-c','host/transaction.c','-o',str(OUT/'host.bc')]);run(['clang','-emit-llvm','-c','host/sha256.c','-o',str(OUT/'sha.bc')]);run(['llvm-as',str(module),'-o',str(OUT/'module.bc')]);run(['llvm-link',str(OUT/'module.bc'),str(OUT/'host.bc'),str(OUT/'sha.bc'),'-o',str(OUT/'jit.bc')])
    builds={'jit':['lli','-load=/usr/lib/aarch64-linux-gnu/libcrypto.so.3',str(OUT/'jit.bc')]}
    checked=OUT/'checked.ll';checked.write_text(re.sub(r'(define[^\n]+) \{',r'\1 sanitize_address {',module.read_text()))
    for name,opt in [('o0','-O0'),('o2','-O2'),('asan','-O1')]:
        cmd=['clang',opt,'host/transaction.c','host/sha256.c',str(checked if name=='asan' else module),'-lcrypto','-o',str(OUT/name)]
        if name=='asan':cmd+=['-fsanitize=address','-fno-omit-frame-pointer','-g']
        run(cmd);builds[name]=[str(OUT/name)]
    engine=Engine();commands=[]
    for row in cases():
        req=row['request']
        if req['op'].startswith('decode'):
            b=bytes.fromhex(req['bytes'])[int(req.get('offset','0')):];budget=int(req.get('limits',{}).get('max_items','4096'))
            commands.append((row['id'],['scan',b.hex(),str(int(req['mode']=='witness')),str(int(req['op']=='decode_exact')),str(budget)]))
        else:
            events,pool=engine.marshal(req['transaction'],4096)
            for include in ([req['include_witness']] if req['op']=='serialize' else [False,True]):commands.append((row['id']+'_'+str(include),['serialize',pool.raw.hex(),bytes(events).hex(),str(int(include))]))
    matrix={};outputs={}
    for name,prefix in builds.items():
        outputs[name]={k:run(prefix+args) for k,args in commands}
    for name in builds:
        matrix[name]={key:value==outputs['o0'][key] for key,value in outputs[name].items()};assert all(matrix[name].values())
    result={'schema':'rosettanode.execution_variants.v1','status':'passed','matrix':matrix,'cases':len(commands),'elapsed_seconds':time.monotonic()-start,'asan':'clean checked IR and C host','comparison':'complete emitted event tape / consumption / status and serialized bytes / digest across JIT, O0, O2 and ASan'}
    (ROOT/'evidence/execution-variants.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({k:result[k] for k in ['status','cases','elapsed_seconds']}))
if __name__=='__main__':main()
