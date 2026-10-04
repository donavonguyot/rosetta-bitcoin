"""Batched candidate/reference comparison; references never enter candidate binaries."""

import sys as _rb_sys
from pathlib import Path as _RBPath
_rb_sys.path.insert(0, str(_RBPath(__file__).resolve().parents[3] / 'Project/scripts'))
from state_root import operational_paths as _rb_paths
import argparse, hashlib, itertools, sys, json
from common import *
sys.path.insert(0,str(ROOT/'Nodes/Shared/conformance/tools/crypto_lanes'))
# Avoid self-import under the shared module's identical filename.
import importlib.util
spec=importlib.util.spec_from_file_location('reference_tool',ROOT/'Nodes/Shared/conformance/tools/crypto_lanes/differential.py')
refmod=importlib.util.module_from_spec(spec);spec.loader.exec_module(refmod)

def responses(text,ids):
    if not text.endswith('\n'): raise ValueError('truncated response')
    rows=[json.loads(line) for line in text.splitlines()]
    if [r['id'] for r in rows] != ids: raise ValueError('missing, duplicate, out-of-order or unexpected response')
    for r in rows:
        value=r['result']
        if value not in ('valid','consensus_invalid','malformed_input'):
            x,parity=value.split(':')
            if len(x)!=64 or parity not in ('0','1'):raise ValueError('bad tweak response')
            bytes.fromhex(x)
    return [r['result'] for r in rows]

def main():
    p=argparse.ArgumentParser();p.add_argument('--package',type=Path,default=LIB);p.add_argument('--count',type=int,default=100_005);p.add_argument('--label',default='candidate');a=p.parse_args()
    refpath=(_rb_paths()['campaigns'] / 'crypto-lanes/reference-build/lib/libsecp256k1.dylib')
    assert hashlib.sha256(((_rb_paths()['campaigns'] / 'crypto-lanes/reference.tar.gz')).read_bytes()).hexdigest()==refmod.ARCHIVE_SHA256
    ref=refmod.Reference(refpath)
    exe=WORK/('batch-'+a.label)
    package=WORK/'differential-package'
    import shutil
    if package.exists():shutil.rmtree(package)
    shutil.copytree(a.package,package,ignore=shutil.ignore_patterns('.zig-cache','zig-out'))
    docker(['zig','build-exe','-O','ReleaseSafe','--dep','secp256k1','-Mroot=/tooling/batch.zig','-O','ReleaseSafe','-Msecp256k1=/work/differential-package/src/root.zig','-femit-bin=/work/'+exe.name])
    docker(['sh','-c','cd /work/differential-package/examples/consumer && zig build -Doptimize=ReleaseSafe'])
    single=a.package/'examples/consumer/zig-out/bin/consumer'
    cases=itertools.islice(ref.cases((a.count+14)//15),a.count);count=0;failures=[];hashed=hashlib.sha256();ops={}
    while batch:=list(itertools.islice(cases,1024)):
        inputs=[dict(id=count+i,op=op,key=k.hex(),message=m.hex(),signature=s.hex()) for i,(op,k,m,s) in enumerate(batch)]
        data=''.join(json.dumps(row,separators=(',',':'))+'\n' for row in inputs);hashed.update(data.encode())
        path=WORK/'chunk.jsonl';path.write_text(data)
        results=responses(docker(['/work/'+exe.name,'/work/'+path.name]),[r['id'] for r in inputs])
        for i,((op,key,msg,sig),result) in enumerate(zip(batch,results)):
            expected=ref.run(op,key,msg,sig);got=result if ':' in result else result=='valid'
            if got!=expected:failures.append(dict(id=count+i,got=result,expected=expected))
            if count+i<60: assert result==docker(['/work/differential-package/examples/consumer/zig-out/bin/consumer',op,key.hex(),msg.hex(),sig.hex()]).strip()
            ops[op]=ops.get(op,0)+1
        count+=len(batch)
    evidence={'candidate_architecture':'aarch64-linux','result':'passed' if count==a.count and not failures else 'failed','cases':count,'failures':failures,'operations':ops,'input_sha256':hashed.hexdigest(),'source_digest':source_digest(a.package),'reference_commit':refmod.COMMIT,'reference_binary_sha256':hashlib.sha256(refpath.read_bytes()).hexdigest(),'batch_size':1024,'single_consumer_equivalence_cases':min(60,count),'error_mapping':'reference acceptance compared; shared fixtures preserve structured categories; high-S normalized by reference'}
    save(WORK/(a.label+'-differential.json'),evidence);print(json.dumps(evidence));assert not failures
if __name__=='__main__':
 with exclusive():main()
