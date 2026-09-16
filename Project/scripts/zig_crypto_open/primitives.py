"""A0 dependency-chain/throughput measurements; no production package edits."""
import argparse
import json
import shutil
import statistics
from common import HERE, WORK, BUILDER, docker, save, exclusive, digest


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--field-source',type=__import__('pathlib').Path,default=HERE/'field52.zig');parser.add_argument('--output',default='primitives.json');args=parser.parse_args()
    shutil.copy(HERE/'primitive.zig',WORK/'primitive.zig');shutil.copy(args.field_source,WORK/'field52.zig')
    report={'schema':'rb.zig_open_primitives.v1','builder':BUILDER,'source_sha256':digest(args.field_source),
            'caveats':['add/sub include limb masking to bound each next input; not raw lazy operation latency',
                       'loop control is reported separately and may optimize algebraically; never subtracted',
                       'latency is measured with one dependent stream; throughput uses four independent streams'], 'variants':{}}
    with exclusive():
        docker(['zig','test','/work/field52.zig','-O','ReleaseSafe'])
        for name,checked,wide in [('wide',True,True),('checked',True,False),('unchecked',False,False)]:
            (WORK/'options.zig').write_text(f'pub const checked = {str(checked).lower()};\npub const wide = {str(wide).lower()};\n')
            docker(['zig','build-exe','-O','ReleaseSafe','--dep','options','-Mroot=/work/primitive.zig',
                    '-Moptions=/work/options.zig','-femit-bin=/work/primitive-'+name,'-femit-asm=/work/primitive-'+name+'.s'])
            rows=[]
            for batch in range(2):
                rows.extend(json.loads(line) for line in docker(['/work/primitive-'+name,str(batch)]).splitlines())
            report['variants'][name]={'measurements':rows,'assembly_sha256':digest(WORK/('primitive-'+name+'.s')),
              'medians_ns':{str(batch):{op:statistics.median(r['total_ns']/r['iterations'] for r in rows if r['streams']==1 and r['batch']==batch and r['operation']==op) for op in ('multiply','square','add_bounded','subtract_bounded')} for batch in range(2)}}
            save(WORK/args.output,report)
            print(name,report['variants'][name]['medians_ns'],flush=True)
    save(WORK/args.output,report)

if __name__=='__main__':main()
