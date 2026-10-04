"""Build immutable comparison variants from one node snapshot and pinned inputs."""

import sys as _rb_sys
from pathlib import Path as _RBPath
_rb_sys.path.insert(0, str(_RBPath(__file__).resolve().parents[3] / 'Project/scripts'))
from state_root import operational_paths as _rb_paths
import argparse,json,shutil,subprocess,sys,tarfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3];WORK=(_rb_paths()['campaigns'] / 'zig-opt');HERE=Path(__file__).parent
sys.path.insert(0,str(ROOT/'Project/scripts'));from crypto_lanes import source_digest
p=argparse.ArgumentParser();p.add_argument('variant',choices=['original','optimized','c_control']);p.add_argument('--probe',action='store_true');p.add_argument('--reject',default='');a=p.parse_args()
base=json.loads((WORK/'baseline.json').read_text());assert source_digest(ROOT/'Nodes/Zig/src')==base['node_digest']
label=a.variant+('-probe' if a.probe else '')+('-'+a.reject if a.reject else '');ctx=WORK/('context-'+label)
if ctx.exists():shutil.rmtree(ctx)
node=ctx/'Nodes/Zig';node.mkdir(parents=True)
for item in ('src','tests','build.zig','build.zig.zon'):
 src=ROOT/'Nodes/Zig'/item
 if src.is_dir():shutil.copytree(src,node/item)
 else:shutil.copy(src,node/item)
lib=ctx/'Libraries/Zig/libsecp256k1-zig';lib.mkdir(parents=True)
if a.variant=='original':
 with tarfile.open(WORK/'original-package.tar.gz') as tar:tar.extractall(lib,filter='data')
else:
 shutil.copytree(ROOT/'Libraries/Zig/libsecp256k1-zig',lib,dirs_exist_ok=True,ignore=shutil.ignore_patterns('.zig-cache','zig-out'))
bench=ctx/'bench';bench.mkdir()
for name in ('bench.zig','c_control.zig'):shutil.copy(HERE/name,bench/name)
shutil.copytree(lib/'src/testdata',bench/'testdata')
shutil.copy((_rb_paths()['campaigns'] / 'crypto-lanes/reference.tar.gz'),ctx/'reference.tar.gz')
shutil.copy(HERE/'Dockerfile',ctx/'Dockerfile')
digest=source_digest(lib) if a.variant!='c_control' else '385c115a21ee1ff31d0b0320acc2b278c92f7bde971f510566ad481a38835be0'
backend='c_binding' if a.variant=='c_control' else 'own_curve';image='rosetta-zig-opt-'+label+':'+digest[:12]
cmd=['docker','build','--build-arg','BACKEND='+backend,'--build-arg','SOURCE_DIGEST='+digest,'--build-arg','PROBE='+str(a.probe).lower(),'--build-arg','REJECT='+a.reject,'-t',image,str(ctx)]
with (WORK/f'{label}-build.log').open('w') as log:subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT,check=True)
identity=subprocess.check_output(['docker','image','inspect',image,'--format','{{.Id}}'],text=True).strip()
metadata={'variant':a.variant,'image':image,'image_id':identity,'source_digest':digest,'node_digest':base['node_digest'],'lane':backend,'command':cmd,'probe':a.probe,'reject':a.reject}
(WORK/f'{label}-image.json').write_text(json.dumps(metadata,indent=2)+'\n');print(json.dumps(metadata),flush=True)
# Retain the exact builder for network-disabled package isolation checks.
if a.variant=='optimized' and not a.probe:
 cmd[-3:-3]=['--target','build'];cmd[cmd.index('-t')+1]=image+'-builder'
 with (WORK/f'{label}-builder.log').open('w') as log:subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT,check=True)
