"""Capture immutable image and toolchain provenance outside measured runs."""
import hashlib,shutil,platform
from common import *
if __name__=='__main__':
 result=dict(host=platform.platform(),machine=platform.machine(),host_zig_version=run(['zig','version']).strip(),host_zig_binary_sha256=hashlib.sha256(Path(shutil.which('zig')).read_bytes()).hexdigest(),docker_server=run(['docker','version','--format','{{json .Server}}']),docker_info=run(['docker','info','--format','{{.OperatingSystem}} {{.Architecture}} {{.NCPU}}']),profiling_builder_image_id=run(['docker','image','inspect',BUILDER,'--format','{{.Id}}']).strip(),variants={})
 for name in ('baseline','candidate','c_control'):
  meta=json.loads((WORK/(name+'-image.json')).read_text());image=meta['image_id']
  out={}
  for file in ('build-packages.txt','zig-version.txt','c-compiler.txt'):
   out[file]=run(['docker','run','--rm','--network','none',image,'cat','/usr/local/bin/'+file])
  out['linkage']=run(['docker','run','--rm','--network','none',image,'ldd','/usr/local/bin/zigbitnode'])
  if name!='c_control':assert 'secp256k1' not in out['linkage']
  else:
   out['reference_library_sha256']=run(['docker','run','--rm','--network','none',image,'cat','/usr/local/bin/c-library-sha256.txt'])
   cmd=meta['command'].copy();cmd[2:2]=['--target','build'];cmd[cmd.index('-t')+1]=meta['image']+'-builder'
   (WORK/'c-control-builder.log').write_text(run(cmd))
   out['cmake_cache']=run(['docker','run','--rm','--network','none',meta['image']+'-builder','cat','/tmp/reference-build/CMakeCache.txt'])
  result['variants'][name]=out
 save(WORK/'environment.json',result);print('provenance captured')
