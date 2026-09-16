"""Paired campaign-local selection; no historical validators are changed."""
import math,random,statistics
from common import *
SCORED=('ecdsa/valid','schnorr/valid','parse/valid')
VALID=(*SCORED,'tweak/valid')
def samples(report,op,batch):
 return [r['total_ns']/r['iterations'] for r in sorted(report['measurements'],key=lambda r:r['repetition']) if r['operation']==op and r['batch']==batch]
def median(report,op,batch):return statistics.median(samples(report,op,batch))
def score(base,candidate,batch):return math.prod(median(base,op,batch)/median(candidate,op,batch) for op in SCORED)**(1/3)
def interval(values):
 ordered=sorted(values);return [ordered[int(.025*len(ordered))],ordered[int(.975*len(ordered))]]
def component_interval(base,candidate):
 rng=random.Random(0x524553494455414c);values=[]
 for _ in range(10_000):
  ratios=[]
  for batch in (0,1):
   indexes=[rng.randrange(5) for _ in range(5)]
   for op in SCORED:
    a=samples(base,op,batch);b=samples(candidate,op,batch)
    ratios.append(statistics.median(a[i] for i in indexes)/statistics.median(b[i] for i in indexes))
  values.append(math.prod(ratios)**(1/6))
 return interval(values)
def assess(base,candidate):
 scores=[score(base,candidate,b) for b in (0,1)]
 ci=component_interval(base,candidate)
 regressions={op:[median(candidate,op,b)/median(base,op,b)-1 for b in (0,1)] for op in VALID}
 passed=min(scores)>=1.05 and ci[0]>1 and not any(min(v)>.05 for v in regressions.values())
 return dict(qualifies=passed,scores=scores,score=math.prod(scores)**.5,paired_bootstrap_95=ci,regressions=regressions)
def node_interval(runs):
 by_round={}
 for row in runs:by_round.setdefault(row['round'],{})[row['variant']]=row['node_elapsed_ms']
 ratios=[r['candidate']/r['baseline']-1 for r in by_round.values()]
 rng=random.Random(0x354b524553494455)
 return interval([statistics.mean(rng.choices(ratios,k=len(ratios))) for _ in range(10_000)])
if __name__=='__main__':
 base=json.loads((WORK/'baseline-tuning-bench.json').read_text());results={}
 for path in WORK.glob('*-tuning-bench.json'):
  report=json.loads(path.read_text());results[report['name']]=assess(base,report)
 save(WORK/'selection-scores.json',results)
 for name,r in sorted(results.items(),key=lambda r:r[1]['score'],reverse=True):print(name,round(r['score'],3),r['qualifies'])
