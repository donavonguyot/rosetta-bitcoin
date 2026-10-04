"""Build baseline/candidate/C controls from the same frozen node and pinned tools."""

import sys as _rb_sys
from pathlib import Path as _RBPath
_rb_sys.path.insert(0, str(_RBPath(__file__).resolve().parents[3] / 'Project/scripts'))
from state_root import operational_paths as _rb_paths
import argparse,shutil,fcntl
from common import *
def build(variant,probe=False,reject=''):
 base=json.loads((HERE/'baseline.json').read_text())
 assert source_digest(ROOT/'Nodes/Zig/src')==base['node_digest'],'node drift'
 frozen_node=WORK/'frozen/Nodes/Zig';assert source_digest(frozen_node)==base['node_tree_digest']
 label=variant+('-probe' if probe else '')+('-'+reject if reject else '')
 ctx=WORK/('context-'+label)
 if ctx.exists():shutil.rmtree(ctx)
 node=ctx/'Nodes/Zig';node.mkdir(parents=True)
 for name in ('src','tests','build.zig','build.zig.zon'):
  src=frozen_node/name
  if src.is_dir():shutil.copytree(src,node/name)
  else:shutil.copy(src,node/name)
 package=WORK/('candidate' if variant=='candidate' else 'baseline')
 lib=ctx/'Libraries/Zig/libsecp256k1-zig';shutil.copytree(package,lib,ignore=shutil.ignore_patterns('.zig-cache','zig-out','__pycache__','*.pyc'))
 bench=ctx/'bench';bench.mkdir();shutil.copy(HERE/'bench.zig',bench/'bench.zig')
 shutil.copy(ROOT/'Project/scripts/zig_crypto_campaign/c_control.zig',bench/'c_control.zig')
 shutil.copy((_rb_paths()['campaigns'] / 'crypto-lanes/reference.tar.gz'),ctx/'reference.tar.gz');shutil.copy(HERE/'Dockerfile',ctx/'Dockerfile')
 backend='c_binding' if variant=='c_control' else 'own_curve'
 digest=source_digest(lib) if backend=='own_curve' else json.loads((HERE/'toolchains.lock.json').read_text())['reference_archive_sha256']
 image='rosetta-zig-open-'+label+':'+digest[:12]
 cmd=['docker','build','--platform','linux/arm64','--build-arg','BACKEND='+backend,'--build-arg','SOURCE_DIGEST='+digest,'--build-arg','PROBE='+str(probe).lower(),'--build-arg','REJECT='+reject,'-t',image,str(ctx)]
 if variant=='c_control':
  selected=json.loads((WORK/'control-selection.json').read_text())['selected']
  cmd[-1:-1]=['--build-arg','C_WINDOW='+str(selected['window']),'--build-arg','C_TARGET='+selected['target'],'--build-arg','C_LTO='+('ON' if selected['lto'] else 'OFF')]
 (WORK/(label+'-build.log')).write_text(run(cmd))
 identity=run(['docker','image','inspect',image,'--format','{{.Id}}']).strip()
 meta=dict(variant=variant,image=image,image_id=identity,source_digest=digest,node_digest=base['node_digest'],node_tree_digest=base['node_tree_digest'],lane=backend,command=cmd,probe=probe,reject=reject)
 save(WORK/(label+'-image.json'),meta)
 if variant=='candidate' and not probe:
  cmd[cmd.index('-t')+1]=image+'-builder';cmd[2:2]=['--target','build'];(WORK/'candidate-builder.log').write_text(run(cmd))
 print('built',label,identity,flush=True);return meta
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('variant',choices=['baseline','candidate','c_control']);p.add_argument('--probe',action='store_true');p.add_argument('--reject',default='');a=p.parse_args()
 with ((_rb_paths()['campaigns'] / 'crypto-lanes/node-benchmark.lock')).open('a') as lock:
  fcntl.flock(lock,fcntl.LOCK_EX);build(a.variant,a.probe,a.reject)
