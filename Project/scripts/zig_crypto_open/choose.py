"""Rank a completed sweep and confirm a bounded shortlist on disjoint inputs."""
import math,json,subprocess,sys
from common import HERE,WORK,ROOT,save
from selection import assess


def rank(names,phase):
    baseline=json.loads((WORK/f'baseline-{phase}-bench.json').read_text());rows=[]
    for name in names:
        if name=='baseline':continue
        report=json.loads((WORK/f'{name}-{phase}-bench.json').read_text())
        result=assess(baseline,report);result.update(name=name,score=math.prod(result['scores'])**.5)
        table=WORK/(name+'-tables.json')
        result['table_bytes']=json.loads(table.read_text())['packed_bytes'] if table.exists() else 12288
        if name.startswith('comb'):result['table_bytes']+=12288
        rows.append(result)
    return sorted(rows,key=lambda r:r['score'],reverse=True)


def winner(rows):
    qualified=[r for r in rows if r['qualifies']]
    if not qualified:return 'baseline'
    best=max(r['score'] for r in qualified)
    tied=[r for r in qualified if best/r['score']<=1.01]
    return min(tied,key=lambda r:(r['table_bytes'],r['name']))['name']


def main():
    roster=json.loads((WORK/'sweep-roster.json').read_text());assert roster['status']=='measured'
    rows=rank(roster['names'],'tuning');save(WORK/'selection-tuning.json',rows)
    first=winner(rows)
    names=list(dict.fromkeys([first]+[r['name'] for r in rows if r['qualifies']][:2]))
    names=[n for n in names if n!='baseline']
    subprocess.run([sys.executable,str(HERE/'bench.py'),'baseline',*names,'--phase','confirmation'],cwd=ROOT,check=True)
    confirmed=rank(names,'confirmation');chosen=winner(confirmed)
    save(WORK/'selection-confirmation.json',dict(selected=chosen,shortlist=names,results=confirmed,rule='qualify both batches and paired CI; within 1% prefer smaller tables'))
    print(chosen,flush=True)

if __name__=='__main__':main()
