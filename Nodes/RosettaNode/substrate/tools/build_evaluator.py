#!/usr/bin/env python3

import sys as _rb_sys
from pathlib import Path as _RBPath
_rb_sys.path.insert(0, str(_RBPath(__file__).resolve().parents[4] / 'Project/scripts'))
from state_root import operational_paths as _rb_paths, logical_path as _rb_logical, acquire_writer_lease as _rb_writer_lease
if __name__ == '__main__':
    _rb_writer_lease()
import hashlib,json,shutil,subprocess,uuid
from pathlib import Path
from build import ROOT,RUNTIME

def main():
    context=(_rb_paths()['substrate'])/('eval-context-'+uuid.uuid4().hex[:8]);context.mkdir()
    for name in ['tools','evaluator','native','evidence']:
        shutil.copytree(ROOT/name,context/name,ignore=shutil.ignore_patterns('__pycache__'))
    binaries=context/'binaries';binaries.mkdir()
    for p in ((_rb_paths()['substrate'])).iterdir():
        if p.is_file() and (p.suffix=='.so' or p.name.startswith('dummy') or p.name in ['inspect','probe']):shutil.copyfile(p,binaries/p.name);(binaries/p.name).chmod(0o755)
    shutil.copyfile(ROOT/'Evaluator.Dockerfile',context/'Dockerfile')
    actual=subprocess.check_output(['docker','image','inspect','rosettanode-substrate:instrument','--format','{{.Id}}'],text=True).strip();assert actual==RUNTIME
    with (context/'build.log').open('w') as log:subprocess.run(['docker','build','--label','rosettanode.substrate=evaluator','-t','rosettanode-substrate:evaluator',str(context)],stdout=log,stderr=log,check=True)
    identity=subprocess.check_output(['docker','image','inspect','rosettanode-substrate:evaluator','--format','{{.Id}}'],text=True).strip()
    (ROOT/'evidence/evaluator-image.json').write_text(json.dumps({'schema':'rosettanode.substrate.evaluator_image.v1','image_id':identity,'base_image_id':RUNTIME,'source_sha256':{str(p.relative_to(context)):hashlib.sha256(p.read_bytes()).hexdigest() for p in context.rglob('*') if p.is_file() and p.name!='build.log'}},indent=2)+'\n')
    print(identity)
if __name__=='__main__':main()
