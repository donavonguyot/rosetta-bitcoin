"""Measure isolated package variants with the unchanged public-API workload driver."""
import argparse
import json
import shutil
import statistics
import sys
from common import ROOT, WORK, FROZEN, BUILDER, docker, digest, save, exclusive
sys.path.insert(0,str(ROOT/'Project/scripts'))
from crypto_lanes import source_digest


def main():
    p=argparse.ArgumentParser();p.add_argument('names',nargs='+');p.add_argument('--phase',choices=('tuning','confirmation','holdout'),default='tuning');a=p.parse_args()
    shutil.copy(ROOT/'Project/scripts/zig_crypto_residual/bench.zig',WORK/'bench.zig')
    with exclusive():
        for name in a.names:
            package=FROZEN if name=='baseline' else WORK/name
            relative=package.relative_to(WORK)
            docker(['zig','build-exe','-O','ReleaseSafe','--dep','secp256k1','-Mroot=/work/bench.zig','-O','ReleaseSafe',
                    '-Msecp256k1=/work/'+str(relative)+'/src/root.zig','-femit-bin=/work/bench-'+name,'-femit-asm=/work/bench-'+name+'.s'])
        reports={name:dict(name=name,builder=BUILDER,source_digest=source_digest(FROZEN if name=='baseline' else WORK/name),
                          input_sha256=digest(WORK/(a.phase+'.json')),measurements=[]) for name in a.names}
        for batch in range(2):
            for name in (a.names if batch==0 else reversed(a.names)):
                rows=[json.loads(s) for s in docker(['/work/bench-'+name,'/work/'+a.phase+'.json',str(batch)]).splitlines()]
                reports[name]['measurements'].extend(rows)
                save(WORK/(name+'-'+a.phase+'-bench.json'),reports[name])
        for name,r in reports.items():
            print(name,{op:statistics.median(row['total_ns']/row['iterations'] for row in r['measurements'] if row['operation']==op) for op in ('ecdsa/valid','schnorr/valid','parse/valid','tweak/valid')},flush=True)

if __name__=='__main__':main()
