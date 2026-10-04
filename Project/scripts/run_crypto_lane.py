#!/usr/bin/env python3
"""Reproduce bounded own_curve package and node evidence; Project owns artifacts."""
import fcntl, functools
import argparse, datetime, hashlib, json, os, platform, re, shutil, subprocess, sys, tarfile, tempfile, time, urllib.request
from pathlib import Path
from crypto_lanes import source_digest,validate,SCHEMA,HASH
ROOT=Path(__file__).resolve().parents[2]
WORK=ROOT/'Project/.campaigns/crypto-lanes'
REFERENCE='0cdc758a56360bf58a851fe91085a327ec97685a'
ARCHIVE='385c115a21ee1ff31d0b0320acc2b278c92f7bde971f510566ad481a38835be0'
def run(cmd,log=None,cwd=ROOT,env=None):
 print('+ '+' '.join(map(str,cmd)),flush=True)
 p=subprocess.run(list(map(str,cmd)),cwd=cwd,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 if log:Path(log).write_text(p.stdout)
 if p.returncode:raise RuntimeError(f'command exited {p.returncode}: {cmd}\n{p.stdout[-3500:]}')
 return p.stdout

def reference():
 archive=WORK/'reference.tar.gz'
 if not archive.exists():urllib.request.urlretrieve(f'https://codeload.github.com/bitcoin-core/secp256k1/tar.gz/{REFERENCE}',archive)
 assert hashlib.sha256(archive.read_bytes()).hexdigest()==ARCHIVE
 src=WORK/f'secp256k1-{REFERENCE}'
 if not src.exists():
  with tarfile.open(archive) as f:f.extractall(WORK,filter='data')
 build=WORK/'reference-build'
 run(['cmake','-S',src,'-B',build,'-DBUILD_SHARED_LIBS=ON','-DSECP256K1_BUILD_TESTS=OFF','-DSECP256K1_BUILD_EXHAUSTIVE_TESTS=OFF','-DSECP256K1_BUILD_BENCHMARK=OFF'],WORK/'reference-config.log')
 run(['cmake','--build',build,'-j','4'],WORK/'reference-build.log')
 return next(p for p in (build/'lib').iterdir() if p.name in ('libsecp256k1.dylib','libsecp256k1.so'))

def image_build(port,digest,probe=False,reject=''):
 from provenance import begin_build, finish_build
 started=begin_build()
 lang=port.title();image=f'rosetta-{port}-own-curve'+('-probe' if probe else '')+('-reject-'+reject if reject else '')+':local'
 args=['docker','build','-f',f'Nodes/{lang}/docker/Dockerfile','--build-arg','CRYPTO_BACKEND=own_curve','--build-arg','CRYPTO_SOURCE_DIGEST='+digest,'--build-arg','CRYPTO_PROBE='+str(probe).lower()]
 if port=='zig':args+=['--build-arg','CRYPTO_REJECT='+reject]
 run(args+['-t',image,'.'],WORK/f'{port}-build-{probe}-{reject}.log')
 if not probe:
  run(args+['--target','build','-t',image+'-builder','.'],WORK/f'{port}-builder.log')
 receipt=finish_build(started,image)
 return 'sha256:'+receipt['binary_sha256']

def base(port,lib,digest,toolchain):
 return {'schema':SCHEMA,'port':port,'lane':'own_curve','implementation':'libsecp256k1-'+port,'source_digest':digest,'captured_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'binary_gate_status':'not_attempted','result':'passed','toolchain':toolchain,'build_settings':{'optimization':'Go default' if port=='go' else 'ReleaseSafe','candidate_only':True,'host':platform.platform(),'cpu':platform.machine()},'dependencies':{'production':[],'ffi':False,'curve_provider':'package','arithmetic':'Go math/big' if port=='go' else 'package u257/u512','hashing':'Go crypto/sha256' if port=='go' else 'Zig std.crypto.hash.sha2.Sha256'},'checks':{}}

def components(port,lib,image,ref,digest):
 from provenance import begin_build, finish_build, from_receipt
 component_start=begin_build()
 builder=f'rosetta-{port}-own-curve:local-builder';lang=port.title();env=dict(os.environ,CGO_ENABLED='0',GOWORK='off')
 toolchain=run(['docker','run','--rm','--network','none',builder,port,'version']).strip()
 d=base(port,lib,digest,{'node':toolchain,'component':run([port,'version']).strip()});checks=d['checks']
 sources={'native.json':ROOT/'Nodes/Shared/conformance/fixtures/native_crypto_v1_vectors.json','bip340.csv':ROOT/'Nodes/Shared/testing/fixtures/bip340/test-vectors.csv'}
 fixtures=lib/('testdata' if port=='go' else 'src/testdata');hashes={}
 for name,source in sources.items():
  assert (fixtures/name).read_bytes()==source.read_bytes();hashes[name]=hashlib.sha256(source.read_bytes()).hexdigest()
 if port=='go':
  run(['go','test','./...'],WORK/'go-unit.log',lib,env)
  consumer=WORK/'go-consumer';run(['go','build','-o',consumer,'.'],cwd=lib/'examples/consumer',env=env)
  bench=run(['go','test','-run','^$','-bench','.','-benchtime=64x','-count=5','-benchmem'],WORK/'go-bench.txt',lib,env)
  benchmarks=[]
  for line in bench.splitlines():
   if line.startswith('BenchmarkOperations/'):
    fields=line.split();benchmarks.append({'operation':fields[0],'iterations':int(fields[1]),'ns_per_op':float(fields[2]),'bytes_per_op':int(fields[4]),'allocations_per_op':int(fields[6])})
  deps=run(['go','list','-deps','-f','{{if not .Standard}}{{.ImportPath}}{{end}}','.'],cwd=lib,env=env)
  assert deps.strip()=='github.com/donavonguyot/rosetta-bitcoin/Libraries/Go/libsecp256k1-go'
  isolated='CGO_ENABLED=0 GOWORK=off GOPROXY=off go test ./... && cd examples/consumer && CGO_ENABLED=0 GOWORK=off GOPROXY=off go build -o /tmp/consumer .'
 else:
  run(['zig','build','test','-Doptimize=ReleaseSafe'],WORK/'zig-unit.log',lib)
  run(['zig','build','-Doptimize=ReleaseSafe'],cwd=lib/'examples/consumer');consumer=lib/'examples/consumer/zig-out/bin/consumer'
  bench=run(['zig','build','bench','-Doptimize=ReleaseSafe'],WORK/'zig-bench.jsonl',lib);benchmarks=[json.loads(x) for x in bench.splitlines() if x.startswith('{')]
  production=(lib/'src/root.zig').read_text();assert 'std.crypto.ecc' not in production and 'std.crypto.sign' not in production and '@cImport' not in production
  isolated='zig build test -Doptimize=ReleaseSafe && cd examples/consumer && zig build -Doptimize=ReleaseSafe'
 assert len(benchmarks)==40
 checks['shared_vectors']={'result':'passed','cases':52,'hashes':hashes}
 with tempfile.TemporaryDirectory(prefix='rosetta-isolation-') as temp:
  dest=Path(temp)/'package';shutil.copytree(lib,dest,ignore=shutil.ignore_patterns('.zig-cache','zig-out','.git'))
  run(['docker','run','--rm','--network','none','-v',f'{dest}:/package','-w','/package',builder,'sh','-c',isolated],WORK/f'{port}-isolation.log')
 checks['isolated_build']={'result':'passed','network':'none','contents':'package only','command':isolated}
 outfile=WORK/f'{port}-differential.json'
 run([sys.executable,ROOT/'Nodes/Shared/conformance/tools/crypto_lanes/differential.py','--reference',ref,'--candidate',consumer,'--output',outfile],WORK/f'{port}-differential.log')
 checks['differential']=json.loads(outfile.read_text());assert checks['differential']['result']=='passed'
 checks['external_consumer']={'result':'passed','operations':['ecdsa','schnorr','tweak'],'separate_project':True}
 binary='gobitnode-local-reference-proof' if port=='go' else 'zigbitnode'
 linkage=run(['docker','run','--rm','--network','none',image,'sh','-c',f'ldd /usr/local/bin/{binary}; test ! -e /usr/lib/aarch64-linux-gnu/libsecp256k1.so.1; test ! -e /usr/lib/x86_64-linux-gnu/libsecp256k1.so.1'])
 assert 'libsecp256k1' not in linkage
 checks['dependency_audit']={'result':'passed','builder_image_id':run(['docker','image','inspect',builder,'--format','{{.Id}}']).strip(),'dynamic_libraries':linkage.splitlines(),'no_crypto_ffi':True,'no_imported_curve':True}
 from provenance import begin_build, finish_build, from_receipt
 d['component_artifact_sha256']=hashlib.sha256(consumer.read_bytes()).hexdigest()
 d['provenance']=from_receipt(finish_build(component_start,consumer,'file'))
 d['runtime_image_id']=image
 d['milestone']='component';d['benchmarks']=benchmarks
 return d

def corpus(port,image,suffix='',reject=''):
 outfile=WORK/f'{port}-corpus{suffix}.json';trace=WORK/f'{port}-corpus{suffix}.log'
 cmd=['docker','run','--rm','--network','none','--user','0','-e',f'{port.upper()}BITNODE_RUNTIME_SURFACE=docker','-v',f'{ROOT}/Nodes/Shared:/shared:ro','-v',f'{WORK}:/results']
 if reject:cmd+=['-e','RB_CRYPTO_REJECT='+reject]
 cmd+=[image]
 cmd+=['gobitnode-script-corpus','--manifest','/shared/conformance/fixtures/scripts/manifest.json','--result-path','/results/'+outfile.name] if port=='go' else ['zigbitnode','script-corpus','--manifest','/shared/conformance/fixtures/scripts/manifest.json','--output','/results/'+outfile.name]
 if reject:
  p=subprocess.run(cmd,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT);trace.write_text(p.stdout)
  if not outfile.exists():raise RuntimeError(p.stdout[-2000:])
 else:run(cmd,trace)
 d=json.loads(outfile.read_text());assert (d['failed']>0 if reject else d['passed']==45 and d['failed']==0)
 return d,trace

def serialized_replay(fn):
 @functools.wraps(fn)
 def wrapped(*args,**kwargs):
  with (WORK/'node-benchmark.lock').open('w') as lock:
   fcntl.flock(lock,fcntl.LOCK_EX)
   return fn(*args,**kwargs)
 return wrapped

@serialized_replay
def replay(port,image,label,trace=False,reject=''):
 volume=f'rosetta-{port}-own-curve-{label}-{time.time_ns()}';run(['docker','volume','create',volume]);out=WORK/f'{port}-{label}.log'
 env=['-e',f'{port.upper()}BITNODE_RUNTIME_SURFACE=docker','-e','GOBITNODE_PAR_SCRIPT_VERIFY=1','-e','GOBITNODE_PAR_SCRIPT_THREADS=4','-e','GOBITNODE_BLOCK_PREFETCH_DEPTH=4','-e','ZIGBITNODE_SCRIPT_THREADS=4','-e','PREFETCH_DEPTH=4']
 if reject:env+=['-e','RB_CRYPTO_REJECT='+reject]
 cmd=['docker','run','--rm','--user','0','--network','rosetta-reference-node_default','-v',f'{volume}:/data','-v',f'{WORK}:/results',*env,image]
 cmd+=['gobitnode-local-reference-proof','--datadir','/data','--target','5000','--peer','bitcoin-core-testnet4:48333','--byte-source','p2p','--result-path','/results/'+port+'-'+label+'.json'] if port=='go' else ['zigbitnode','local-reference-proof','--datadir','/data','--target','5000','--peer','bitcoin-core-testnet4:48333','--output','/results/'+port+'-'+label+'.json']
 started=time.monotonic();p=subprocess.run(cmd,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT);elapsed=time.monotonic()-started;out.write_text(p.stdout)
 statuscmd=['gobitnode-status','--datadir','/data'] if port=='go' else ['zigbitnode','status','--datadir','/data']
 status_text=run(['docker','run','--rm','--user','0','--network','none','-v',f'{volume}:/data',image,*statuscmd],WORK/f'{port}-{label}-status.json')
 status=json.loads(status_text)
 if reject:
  assert p.returncode != 0
  assert status['validated_height']<5000
  assert 'rb.crypto_call ecdsa ' in p.stdout
  return {'result':'passed','validated_height':status['validated_height'],'volume':volume,'returncode':p.returncode,'settled_status':status,'primitive':'ecdsa'},out
 if p.returncode:raise RuntimeError(f'proof failed; preserved {volume}: {p.stdout[-2500:]}')
 debug=json.loads((WORK/f'{port}-{label}.json').read_text())
 for k,v in {'prefetch_depth':4,'script_runner_mode':'parallel','rocksdb_wal_disabled':False,'fresh_state':True,'chainstate_backend':'rocksdb','runtime_surface':'docker','byte_source':'local_reference_p2p'}.items():
  assert debug.get(k)==v,(k,debug.get(k),v)
 progress=[json.loads(line.split('rb.port_progress ',1)[1]) for line in p.stdout.splitlines() if line.startswith('rb.port_progress ')]
 assert progress;final=progress[-1];assert final['validated_height']==5000 and final['validated_hash']==HASH and final['chainstate_utxo_count']==4574
 identity=final.get('crypto') or {'implementation':final.get('native_crypto_backend'),'lane':final.get('crypto_lane'),'source_digest':final.get('crypto_source_digest')}
 assert identity['implementation']=='libsecp256k1-'+port and identity['lane']=='own_curve' and len(identity['source_digest'])==64
 result={'command':cmd,'implementation':identity['implementation'],'lane':identity['lane'],'source_digest':identity['source_digest'],'image_id':run(['docker','image','inspect',image,'--format','{{.Id}}']).strip(),'validated_height':final['validated_height'],'header_height':final['header_height'],'validated_hash':final['validated_hash'],'chainstate_utxo_count':final['chainstate_utxo_count'],'chainstate_backend':'rocksdb','rocksdb_wal_disabled':False,'fresh_state':True,'prefetch_depth':4,'script_runner_mode':'parallel','runtime_surface':'docker','byte_source':'local_reference_p2p','timing_buckets_ms':final['timing_buckets_ms'],'wall_seconds':elapsed,'progress_count':len(progress),'volume':volume,'settled_status':status}
 assert status['validated_height']==5000
 assert (status.get('crypto',{}).get('implementation') or status.get('crypto_backend'))==identity['implementation']
 assert (status.get('crypto',{}).get('source_digest') or status.get('crypto_source_digest'))==identity['source_digest']
 result['script_threads']=debug['script_threads']
 result['utxo_accounting_policy']=debug.get('utxo_accounting_policy')
 assert result['utxo_accounting_policy']=='core_spendable_v1'
 run(['docker','volume','rm',volume])
 return result,out

def save(d):
 d['git_revision']=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
 node=ROOT/'Nodes'/d['port'].title()
 h=hashlib.sha256()
 for folder in ('src','internal','cmd'):
  if (node/folder).exists():h.update(source_digest(node/folder).encode())
 d['node_source_digest']=h.hexdigest()
 image=d['runtime_image_id']
 d['node_dependencies']=run(['docker','run','--rm','--network','none',image,'dpkg-query','-W','librocksdb7.8']).strip()
 if d['port']=='go':d['node_module_manifest']=(ROOT/'Nodes/Go/go.mod').read_text()
 errors=validate(d)
 if errors:raise RuntimeError(errors)
 stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
 p=ROOT/'Nodes/Shared/conformance/results'/f"{d['port']}_own_curve_{d['milestone']}_{stamp}.json";p.write_text(json.dumps(d,indent=2)+'\n');print('EVIDENCE '+str(p),flush=True)
 return p

def main():
 p=argparse.ArgumentParser();p.add_argument('--run-ref');p.add_argument('--port',choices=['go','zig'],required=True);p.add_argument('--all',action='store_true');p.add_argument('--component-only',action='store_true');p.add_argument('--node-only',action='store_true');a=p.parse_args();WORK.mkdir(parents=True,exist_ok=True)
 lib=ROOT/'Libraries'/a.port.title()/('libsecp256k1-'+a.port);digest=source_digest(lib);ref=reference();image=image_build(a.port,digest)
 if a.node_only:
  matches=sorted((ROOT/'Nodes/Shared/conformance/results').glob(f'{a.port}_own_curve_component_*.json'))
  d=json.loads(matches[-1].read_text());assert d['source_digest']==digest
  d['captured_at']=datetime.datetime.now(datetime.timezone.utc).isoformat()
 else:
  d=components(a.port,lib,image,ref,digest)
  if a.run_ref is not None:d['provenance']['run_ref']=a.run_ref
  save(d)
 if a.component_only:return
 from provenance import for_image
 d['provenance']=for_image(image,a.run_ref)
 d['runtime_image_id']=image
 corpus_doc,_=corpus(a.port,image);d['checks']['script_corpus']={'result':'passed','passed':corpus_doc['passed'],'failed':corpus_doc['failed']}
 wrong=['docker','run','--rm','--network','none','-e',a.port.upper()+'BITNODE_CRYPTO_BACKEND=libsecp256k1',image]
 wrong+=['gobitnode-local-reference-proof'] if a.port=='go' else ['zigbitnode','local-reference-proof']
 rejected=subprocess.run(wrong,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 assert rejected.returncode!=0
 d['checks']['backend_selection']={'result':'passed','unavailable_backend_rejected':True,'output':rejected.stdout.strip()}
 unknown=list(wrong);unknown[unknown.index(a.port.upper()+'BITNODE_CRYPTO_BACKEND=libsecp256k1')]=a.port.upper()+'BITNODE_CRYPTO_BACKEND=unknown'
 rejected=subprocess.run(unknown,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 assert rejected.returncode!=0
 d['checks']['backend_selection'].update(unknown_backend_rejected=True,unknown_output=rejected.stdout.strip())
 probe=image_build(a.port,digest,True);_,trace=corpus(a.port,probe,'-probe')
 calls={op:sum(line.startswith('rb.crypto_call '+op+' ') for line in trace.read_text().splitlines()) for op in ('ecdsa','schnorr','tweak')};assert all(calls.values());d['checks']['adapter_usage']={'result':'passed','calls':calls}
 for op in ('ecdsa','schnorr','tweak'):
  rejectimage=probe if a.port=='go' else image_build(a.port,digest,True,op)
  corpus(a.port,rejectimage,'-reject-'+op,op)
  if op=='ecdsa':failure,_=replay(a.port,rejectimage,'fault',reject=op);d['checks']['fault_injection']=failure
 _,trace=replay(a.port,probe,'trace',trace=True)
 # Include corpus calls so Schnorr and tweaks are tested even if absent below 5k.
 combined=WORK/f'{a.port}-all-trace.log';combined.write_text((WORK/f'{a.port}-corpus-probe.log').read_text()+'\n'+trace.read_text())
 diff=WORK/f'{a.port}-trace-differential.json';run([sys.executable,ROOT/'Nodes/Shared/conformance/tools/crypto_lanes/differential.py','--reference',ref,'--trace',combined,'--output',diff])
 d['checks']['trace_differential']=json.loads(diff.read_text());d['milestone']='5k';d.pop('benchmarks',None);d['runs']=[]
 for repeat in range(3):result,_=replay(a.port,image,'run-'+str(repeat));d['runs'].append(result)
 if a.port=='go':
  commands=[['go','test','./...'],['go','test','-tags','owncurve','./...'],['go','test','-race','-tags','owncurve','./internal/crypto']]
 else:commands=[['zig','build','test','-Doptimize=ReleaseSafe'],['zig','build','test','-Dcrypto-backend=own_curve','-Doptimize=ReleaseSafe']]
 for index,command in enumerate(commands):run(command,WORK/f'{a.port}-regression-{index}.log',ROOT/'Nodes'/a.port.title())
 d['checks']['node_regression']={'result':'passed','commands':commands}
 save(d)
if __name__=='__main__':main()
