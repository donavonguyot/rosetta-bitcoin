"""Campaign-local paired selection without changing historical acceptance floors."""
import math
import random
import statistics

SCORED=('ecdsa/valid','schnorr/valid','parse/valid')
VALID=(*SCORED,'tweak/valid')


def samples(report, operation, batch):
    rows=sorted((r for r in report['measurements'] if r['operation']==operation and r['batch']==batch),key=lambda r:r['repetition'])
    if [r['repetition'] for r in rows]!=list(range(5)):
        raise ValueError('Missing or duplicate repetitions')
    if any(r['iterations']!=1024 or r['total_ns']<=0 for r in rows):
        raise ValueError('Invalid measurement')
    return [r['total_ns']/r['iterations'] for r in rows]


def assess(baseline,candidate):
    if baseline['input_sha256']!=candidate['input_sha256']:
        raise ValueError('Unpaired workload identities')
    cache={(side,b,op):samples(report,op,b) for side,report in enumerate((baseline,candidate)) for b in range(2) for op in VALID}
    median=lambda side,b,op:statistics.median(cache[side,b,op])
    scores=[math.prod(median(0,b,op)/median(1,b,op) for op in SCORED)**(1/3) for b in range(2)]
    rng=random.Random(0x4f50454e);boot=[]
    for _ in range(10_000):
        ratios=[]
        for b in range(2):
            indexes=[rng.randrange(5) for _ in range(5)]
            ratios.extend(statistics.median(cache[0,b,op][i] for i in indexes)/statistics.median(cache[1,b,op][i] for i in indexes) for op in SCORED)
        boot.append(math.prod(ratios)**(1/6))
    boot.sort();ci=[boot[250],boot[9750]]
    regressions={op:[median(1,b,op)/median(0,b,op)-1 for b in range(2)] for op in VALID}
    return dict(qualifies=min(scores)>1 and ci[0]>1 and not any(min(r)>.05 for r in regressions.values()),scores=scores,paired_bootstrap_95=ci,regressions=regressions)


def node_interval(runs):
    rounds={}
    for row in runs:
        entries=rounds.setdefault(row['round'],{})
        if row['variant'] in entries:raise ValueError('Duplicate round')
        entries[row['variant']]=row['node_elapsed_ms']
    if any(set(r)!={'baseline','candidate','c_control'} for r in rounds.values()):raise ValueError('Incomplete round')
    ratios=[r['candidate']/r['baseline']-1 for r in rounds.values()]
    rng=random.Random(0x4f50454e354b)
    values=sorted(statistics.mean(rng.choices(ratios,k=len(ratios))) for _ in range(10_000))
    return [values[250],values[9750]]
