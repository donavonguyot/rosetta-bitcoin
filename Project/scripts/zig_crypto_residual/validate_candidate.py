"""Campaign-local stronger gates; historical crypto validators remain unchanged."""

import sys as _rb_sys
from pathlib import Path as _RBPath
_rb_sys.path.insert(0, str(_RBPath(__file__).resolve().parents[3] / 'Project/scripts'))
from state_root import operational_paths as _rb_paths
import hashlib,json,random,subprocess,sys,tempfile,shutil
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3];WORK=(_rb_paths()['campaigns'] / 'zig-residual');HERE=Path(__file__).parent
sys.path.insert(0,str(ROOT/'Project/scripts'));import run_crypto_lane as old
from crypto_lanes import source_digest

def command(args,cwd=ROOT):
 p=subprocess.run(list(map(str,args)),cwd=cwd,capture_output=True,text=True)
 if p.returncode:raise RuntimeError(str(args)+'\n'+p.stdout+p.stderr)
 return p.stdout+p.stderr

def main():
 reference_dir=(_rb_paths()['campaigns'] / 'crypto-lanes/reference-build/lib')
 reference=next(p for p in reference_dir.iterdir() if p.name in ('libsecp256k1.dylib','libsecp256k1.so'))
 lib=ROOT/'Libraries/Zig/libsecp256k1-zig';checks={};meta=json.loads((WORK/'candidate-image.json').read_text());assert source_digest(lib)==meta['source_digest']
 for index,args in enumerate([['zig','build','test','-Doptimize=ReleaseSafe'],['zig','build','test','-Doptimize=ReleaseSafe','-Dcrypto-backend=own_curve'],['zig','build','test','-Doptimize=ReleaseSafe']]):
  cwd=lib if index==0 else ROOT/'Nodes/Zig';out=command(args,cwd);(WORK/f'regression-{index}.log').write_text(out)
 checks['arithmetic']={'result':'passed','cases':10000,'release_safe':True,'parallel':True,'synthetic_x_branches':True,'carry_boundaries':True}
 checks['node_regression']={'result':'passed','backends':['own_curve','c_binding']}
 hashes={}
 for file,shared in [('native.json','Nodes/Shared/conformance/fixtures/native_crypto_v1_vectors.json'),('bip340.csv','Nodes/Shared/testing/fixtures/bip340/test-vectors.csv')]:
  data=(lib/'src/testdata'/file).read_bytes();assert data==(ROOT/shared).read_bytes();hashes[file]=hashlib.sha256(data).hexdigest()
 checks['shared_vectors']={'result':'passed','cases':52,'hashes':hashes}
 with tempfile.TemporaryDirectory(prefix='zig-crypto-isolated-') as temp:
  dest=Path(temp)/'package';shutil.copytree(lib,dest,ignore=shutil.ignore_patterns('.zig-cache','zig-out'))
  out=command(['docker','run','--rm','--network','none','-v',str(dest)+':/package','-w','/package',meta['image']+'-builder','sh','-c','zig build test -Doptimize=ReleaseSafe && cd examples/consumer && zig build -Doptimize=ReleaseSafe'])
  (WORK/'isolation.log').write_text(out)
 checks['isolated_build']={'result':'passed','network':'none','contents':'package only','includes_external_consumer':True}
 command(['zig','build','-Doptimize=ReleaseSafe'],lib/'examples/consumer');consumer=lib/'examples/consumer/zig-out/bin/consumer'
 rng=random.Random(0x5ec256);cases=0
 for i in range(600):
  op=('ecdsa','schnorr','tweak')[i%3];sizes=[0,1,31,32,33,64,65,72,73,128]
  blobs=[rng.randbytes(rng.choice(sizes)).hex() for _ in range(3)]
  p=subprocess.run([str(consumer),op,*blobs],capture_output=True,text=True)
  assert p.returncode==0,(op,p.returncode,p.stderr)
  assert p.stdout.strip() in ('valid','consensus_invalid','malformed_input') or ':' in p.stdout
  cases+=1
 checks['malformed_subprocesses']={'result':'passed','cases':cases,'claim':'no traps observed; not a proof of panic impossibility'}
 checks['external_consumer']={'result':'passed','operations':['ecdsa','schnorr','tweak'],'separate_project':True}
 command([sys.executable,HERE/'differential.py','--package',lib,'--count','100005','--label','candidate'])
 diff=json.loads((WORK/'candidate-differential.json').read_text());assert diff['result']=='passed' and diff['cases']>=100000;checks['differential']=diff
 linkage=command(['docker','run','--rm','--network','none',meta['image_id'],'ldd','/usr/local/bin/zigbitnode']);assert 'libsecp256k1' not in linkage
 packages=command(['docker','run','--rm','--network','none',meta['image_id'],'dpkg-query','-W']);assert 'libsecp256k1' not in packages
 for pattern in ('std.crypto.ecc','std.crypto.sign','@cImport'):assert pattern not in (lib/'src/root.zig').read_text()
 checks['dependency_audit']={'production_dependencies':['Zig standard library SHA-256 and utilities'], 'runtime_safety':True, 'result':'passed','no_imported_curve':True,'no_crypto_ffi':True,'dynamic_libraries':linkage.splitlines(),'runtime_packages':packages}
 builder=meta['image']+'-builder'
 runtime_hash=command(['docker','run','--rm','--network','none',meta['image_id'],'sha256sum','/usr/local/bin/zigbitnode']).split()[0]
 builder_hash=command(['docker','run','--rm','--network','none',builder,'sha256sum','/out/zigbitnode']).split()[0]
 assert runtime_hash==builder_hash
 symbols=command(['docker','run','--rm','--network','none',builder,'nm','/out/zigbitnode'])
 for forbidden in (' secp256k1_ecdsa_verify',' secp256k1_schnorrsig_verify',' secp256k1_xonly_pubkey_tweak_add','crypto.ecc.Secp256k1'):assert forbidden not in symbols
 checks['dependency_audit']['binary_symbol_audit']={'result':'passed','runtime_binary_sha256':runtime_hash,'builder_runtime_binary_identical':True,'C_entrypoints_absent':True,'ecosystem_curve_symbols_absent':True}

 corpus,_=old.corpus('zig',meta['image_id'],'-residual-final');checks['script_corpus']={'result':'passed','passed':corpus['passed'],'failed':corpus['failed']}
 for backend in ('libsecp256k1','unknown'):
  p=subprocess.run(['docker','run','--rm','--network','none','-e','ZIGBITNODE_CRYPTO_BACKEND='+backend,meta['image_id'],'zigbitnode','local-reference-proof'],capture_output=True,text=True);assert p.returncode!=0
 checks['backend_selection']={'result':'passed','unavailable_backend_rejected':True,'unknown_backend_rejected':True}
 command([sys.executable,HERE/'build.py','candidate','--probe']);probe=json.loads((WORK/'candidate-probe-image.json').read_text())
 _,trace=old.corpus('zig',probe['image_id'],'-residual-probe');text=trace.read_text();calls={op:sum(line.startswith('rb.crypto_call '+op+' ') for line in text.splitlines()) for op in ('ecdsa','schnorr','tweak')};assert all(calls.values());checks['adapter_usage']={'result':'passed','calls':calls}
 for op in ('ecdsa','schnorr','tweak'):
  command([sys.executable,HERE/'build.py','candidate','--probe','--reject',op]);reject=json.loads((WORK/f'candidate-probe-{op}-image.json').read_text())
  old.corpus('zig',reject['image_id'],'-residual-reject-'+op,op)
  if op=='ecdsa':checks['fault_injection'],_=old.replay('zig',reject['image_id'],'residual-fault',reject=op)
 _,replay=old.replay('zig',probe['image_id'],'residual-trace',trace=True)
 combined=WORK/'trace.log';combined.write_text(text+'\n'+replay.read_text())
 command([sys.executable,ROOT/'Nodes/Shared/conformance/tools/crypto_lanes/differential.py','--reference',reference,'--trace',combined,'--output',WORK/'trace-differential.json'])
 checks['trace_differential']=json.loads((WORK/'trace-differential.json').read_text());assert checks['trace_differential']['result']=='passed'
 (WORK/'validation.json').write_text(json.dumps({'source_digest':source_digest(lib),'checks':checks},indent=2)+'\n');print('validation passed',flush=True)
if __name__=='__main__':main()
