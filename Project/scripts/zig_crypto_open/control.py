"""Build and measure explicit upstream window/target/LTO configurations."""

import sys as _rb_sys
from pathlib import Path as _RBPath
_rb_sys.path.insert(0, str(_RBPath(__file__).resolve().parents[3] / 'Project/scripts'))
from state_root import operational_paths as _rb_paths
import argparse
import json
import math
import shutil
import statistics
from common import ROOT, WORK, BUILDER, docker, digest, save, exclusive

WINDOWS=(8,10,12,13,14,15,16)
ARCHIVE_SHA='385c115a21ee1ff31d0b0320acc2b278c92f7bde971f510566ad481a38835be0'


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--window',type=int,choices=WINDOWS);a=parser.parse_args()
    archive=(_rb_paths()['campaigns'] / 'crypto-lanes/reference.tar.gz')
    if digest(archive)!=ARCHIVE_SHA:raise ValueError('Wrong reference archive')
    shutil.copy(archive,WORK/'reference.tar.gz')
    shutil.copy(ROOT/'Project/scripts/zig_crypto_campaign/c_control.zig',WORK/'c_control.zig')
    shutil.copy(ROOT/'Project/scripts/zig_crypto_residual/bench.zig',WORK/'control-bench.zig')
    with exclusive():
        docker(['sh','-c','mkdir -p /work/reference-source && tar -xzf /work/reference.tar.gz -C /work/reference-source --strip-components=1'])
        for width in ((a.window,) if a.window else WINDOWS):
            if width>15:
                docker(['gcc','-O2','-DECMULT_WINDOW_SIZE='+str(width),'/work/reference-source/src/precompute_ecmult.c','-o','/work/reference-precompute'])
                generated=docker(['sh','-c','cd /work/reference-source && /work/reference-precompute'])
                (WORK/'reference-precompute.log').write_text(generated)
            for target in ('generic','native'):
                for lto in (False,True):
                    name=f'c-w{width}-{target}-lto{int(lto)}';path=WORK/(name+'.json')
                    if path.exists():
                        print('preserved',name,flush=True);continue
                    directory='/work/'+name
                    flags='-O3 -DNDEBUG'+(' -mcpu=native' if target=='native' else '')
                    args=['cmake','-S','/work/reference-source','-B',directory,'-DCMAKE_BUILD_TYPE=Release','-DBUILD_SHARED_LIBS=ON',
                          '-DSECP256K1_BUILD_TESTS=OFF','-DSECP256K1_BUILD_EXHAUSTIVE_TESTS=OFF','-DSECP256K1_BUILD_BENCHMARK=OFF',
                          '-DSECP256K1_ASM=OFF',f'-DSECP256K1_ECMULT_WINDOW_SIZE={width}',
                          '-DCMAKE_C_FLAGS_RELEASE='+flags,'-DCMAKE_INTERPROCEDURAL_OPTIMIZATION='+('ON' if lto else 'OFF')]
                    output=docker(args)+docker(['cmake','--build',directory,'-j4'])
                    (WORK/(name+'-build.log')).write_text(output)
                    docker(['zig','build-exe','-O','ReleaseSafe','--dep','secp256k1','-Mroot=/work/control-bench.zig',
                            '-O','ReleaseSafe','-I/work/reference-source/include','-L'+directory+'/lib','-rpath',directory+'/lib',
                            '-lc','-lsecp256k1','-Msecp256k1=/work/c_control.zig','-femit-bin=/work/'+name+'-bench'])
                    rows=[]
                    for batch in range(2):rows.extend(json.loads(s) for s in docker(['/work/'+name+'-bench','/work/tuning.json',str(batch)]).splitlines())
                    symbols=docker(['sh','-c',f'nm -S --size-sort {directory}/lib/libsecp256k1.so | tail -12'])
                    libs=list((WORK/name/'lib').glob('libsecp256k1.so.*'))
                    library=next(p for p in libs if not p.is_symlink())
                    info=dict(schema='rb.zig_open_c_configuration.v1',name=name,builder=BUILDER,window=width,target=target,lto=lto,assembly='OFF',linkage='shared',configure_command=args,
                              library_sha256=digest(library),library_bytes=library.stat().st_size,symbol_sizes=symbols,
                              input_sha256=digest(WORK/'tuning.json'),reference_generated_table_sha256=digest(WORK/'reference-source/src/precomputed_ecmult.c'),measurements=rows,
                              medians_ns={op:statistics.median(r['total_ns']/r['iterations'] for r in rows if r['operation']==op) for op in ('ecdsa/valid','schnorr/valid','parse/valid','tweak/valid')})
                    save(path,info);print(name,info['medians_ns'],flush=True)

if __name__=='__main__':main()
