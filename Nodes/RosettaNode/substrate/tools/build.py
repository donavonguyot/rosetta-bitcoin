#!/usr/bin/env python3
"""Build substrate objects without executing any frozen parent generators."""

import sys as _rb_sys
from pathlib import Path as _RBPath
_rb_sys.path.insert(0, str(_RBPath(__file__).resolve().parents[4] / 'Project/scripts'))
from state_root import operational_paths as _rb_paths, logical_path as _rb_logical, acquire_writer_lease as _rb_writer_lease
if __name__ == '__main__':
    _rb_writer_lease()
import hashlib,json,re,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
LLVM='sha256:c18bebd5286d9b1e523c12e170c0123f6f4fd93139ecebc16ed156c4f0e1d9f1'
RUNTIME='sha256:f83bba745d70d68b66f374b5a195100a3a4cdb9439eb2cf3085020ab582e9a0a'
def docker(image,args):
    subprocess.run(['docker','run','--rm','--network','none','--cpus','4','--memory','4g','--label','rosettanode.substrate=preparation','-v',str(ROOT)+':/work','-w','/work',image,*args],check=True)
def main():
    ((_rb_paths()['substrate'])).mkdir(exist_ok=True)
    lock=json.loads((ROOT.parent/'toolchain.json').read_text())
    module=f'target triple = "{lock["target_triple"]}"\ntarget datalayout = "{lock["data_layout"]}"\n'
    module+='\n'.join((ROOT/f'vendor/{n}.ll').read_text() for n in ['support','compactsize','transactions'])
    assert module==(ROOT/'vendor/kernel.ll').read_text()
    docker(LLVM,['opt','-passes=verify,lint','-disable-output','vendor/kernel.ll'])
    docker(LLVM,['clang','-O2','-fPIC','-c','vendor/kernel.ll','-o','.local/kernel.o'])
    ((_rb_paths()['substrate'] / 'kernel-asan.ll')).write_text(re.sub(r'(define[^\n]+) \{',r'\1 sanitize_address {',module))
    docker(LLVM,['clang','-O1','-fPIC','-fsanitize=address','-c','.local/kernel-asan.ll','-o','.local/kernel-asan.o'])
    docker(RUNTIME,['gcc','-Wall','-Wextra','-Werror','-shared','-fPIC','native/interpose.c','-ldl','-lpthread','-lcrypto','-o','.local/interpose.so'])
    docker(RUNTIME,['gcc','-shared','-fPIC','native/adapter.c','vendor/sha256.c','.local/kernel.o','-lcrypto','-o','.local/adapter.so'])
    docker(RUNTIME,['gcc','native/inspect.c','-lrocksdb','-o','.local/inspect'])
    docker(RUNTIME,['gcc','native/adapter_probe.c','-L.local','-l:adapter.so','-Wl,-rpath,/work/.local','-o','.local/adapter_probe'])
    for name,flags in [('adapter-asan',[]),('adapter-asan-mutant',['-DUSE_AFTER_FREE'])]:
        docker(RUNTIME,['gcc','-g','-fsanitize=address',*flags,'native/adapter.c','native/adapter_probe.c','vendor/sha256.c','.local/kernel-asan.o','-lcrypto','-o','.local/'+name])
    docker(RUNTIME,['gcc','-g','-shared','-fPIC','-fsanitize=address','native/adapter.c','vendor/sha256.c','.local/kernel-asan.o','-lcrypto','-o','.local/adapter-asan.so'])
    for name,flags in [('dummy_asan',[]),('dummy_arena',['-DARENA_EARLY_FREE'])]:
        docker(RUNTIME,['gcc','-g','-fsanitize=address','-Wno-deprecated-declarations',*flags,'native/dummy.c','-L.local','-l:adapter-asan.so','-Wl,-rpath,/work/.local','-lrocksdb','-ljson-c','-lcrypto','-lpthread','-o','.local/'+name])
    manifest={'schema':'rosettanode.substrate.build.v1','llvm_image':LLVM,'runtime_image':RUNTIME,'target':lock['target_triple'],'layout':lock['data_layout'],'objects':{_rb_logical(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in ((_rb_paths()['substrate'] / 'kernel.o'),(_rb_paths()['substrate'] / 'adapter.so'),(_rb_paths()['substrate'] / 'interpose.so'))},'parent_unchanged':parent_check()}
    (ROOT/'evidence/build.json').write_text(json.dumps(manifest,indent=2)+'\n')
def parent_check():
    baseline=json.loads((ROOT/'evidence/parent-baseline.json').read_text())
    actual={str(p.relative_to(ROOT.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(ROOT.parent.rglob('*')) if p.is_file() and not any(x in p.relative_to(ROOT.parent).parts for x in ['substrate','.local','__pycache__'])}
    if actual!=baseline:raise RuntimeError('Frozen parent source/evidence changed')
    return True
if __name__=='__main__':main()
