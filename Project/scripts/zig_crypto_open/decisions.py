"""Measured incremental decisions; overlapping opportunities are never summed."""
import json,statistics
from common import WORK,save
from selection import assess,samples


def read(name):return json.loads((WORK/name).read_text())

def medians(report):
    return {op:statistics.median(r['total_ns']/r['iterations'] for r in report['measurements'] if r['operation']==op) for op in ('ecdsa/valid','schnorr/valid','parse/valid','tweak/valid')}

def main():
    selected=read('selection-confirmation.json')['selected'];base=read('baseline-tuning-bench.json')
    rows={}
    for label,name in [('baseline','baseline'),('common_z','shared-z'),('divsteps','divsteps'),('selected',selected)]:
        rows[label]=medians(read(name+'-tuning-bench.json'))
    ablations={mode:assess(read(selected+'-without-'+mode+'-tuning-bench.json'),read(selected+'-tuning-bench.json')) for mode in ('generator','variable','both','common-z')}
    counts=read('candidate-counts.json')['operations']
    retained=read('holdout-decision.json')['selected']=='candidate'
    if retained:
        for op,p,n in [('0',0,1),('2',1,0),('6',1,0)]:assert counts[op]['inverse_p']==p and counts[op]['inverse_n']==n
    decision=dict(status='complete',field={'retained':'widened','reason':'5x52 fails A0 in checked and unchecked forms after two correction passes'},common_z={'retained':retained,'retention_scope':'part of the complete configuration qualified against the frozen baseline on confirmation and holdout; isolated three-operation ablation CI overlaps no improvement, so no independently significant score gain is claimed','inversion_targets':'ECDSA p=0 n=1; Schnorr p=1 n=0; tweak p=1 n=0','ablation':ablations['common-z']},inversion={'retained':'binary GCD','rejected':'batched divstep','reason':'slower verification and tweak in measured batches'},doubling={'retained':'existing 2M+5S','reason':'already implements the requested count; no separate gain claimed'},tables={'selected':selected if retained else 'baseline','experiment_selected':selected,'sweep':read('sweep-roster.json'),'confirmation':read('selection-confirmation.json'),'comb':'4/6/8-tooth alternatives measured; not selected','generator_glv_ablation':ablations['generator'],'variable_glv_ablation':ablations['variable'],'both_glv_ablation':ablations['both'],'width15_budget':'C and Zig width15 configurations are recorded separately; equal bytes/windows do not equate decomposition algorithms'},extra_rounds={'attempted':False,'reason':'post-field/common-Z checkpoint exceeds 1.30x C for both verification workloads in both batches'},holdout=read('holdout-decision.json'),budget={'unit':'nanoseconds per operation','medians':rows,'interpretation':'incremental stage/ablation measurements; field, normalization, parsing and checks overlap and are not summed'},scoped_safety={'shipping':False,'reason':'unchecked A0 kernels did not qualify'},assembly={'shipping':False,'reason':'no speculative machine-kernel rounds after failed checkpoint'})
    save(WORK/'decisions.json',decision)

if __name__=='__main__':main()
