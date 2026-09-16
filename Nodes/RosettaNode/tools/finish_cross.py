#!/usr/bin/env python3
"""Finish the frozen conditional cohort, retaining initial and repair results."""
import concurrent.futures,json,subprocess,sys,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
IDS=['RD1','RC1','ZD1','ZC1']

def read(name):return json.loads((ROOT/f'evidence/{name}.json').read_text())
def run(script,*args):
    result=subprocess.run([sys.executable,str(ROOT/'tools'/script),*args],capture_output=True,text=True)
    log=ROOT/'.local'/('finish-cross-'+script.replace('.py','')+'-'+'-'.join(args)+'.log')
    log.write_text(result.stdout+result.stderr)
    if result.returncode:raise RuntimeError(f'{script} {args} failed; inspect {log}')
    print(script,*args,'complete',flush=True)

def main():
    last=None
    while True:
        ready=[name for name in IDS if (ROOT/f'evidence/attempt-{name}.json').exists() and read('attempt-'+name).get('initial')]
        if ready!=last:print('Frozen initials:',','.join(ready),flush=True);last=ready
        if len(ready)==len(IDS):break
        time.sleep(15)
    for name in IDS:
        if not (ROOT/f'evidence/evaluation-{name}-initial.json').exists():run('evaluate_cross.py',name)
    repairs=[name for name in IDS if any(score<1 for score in read('evaluation-'+name+'-initial')['groups'].values())]
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        jobs=[pool.submit(run,'cross_followup.py','repair',name) for name in repairs if read('attempt-'+name).get('repair') is None]
        for job in jobs:job.result()
    for name in repairs:
        if not (ROOT/f'evidence/evaluation-{name}-repair.json').exists():run('cross_followup.py','evaluate-repair',name)
    for name in IDS:
        for phase in ['initial']+(['repair'] if name in repairs else []):
            if not (ROOT/f'evidence/reproduction-{name}-{phase}.json').exists():run('cross_followup.py','reproduce',name,'--phase',phase)
    pairs={'rust':{},'zig':{}};phase_accounting={};repair_scores={};infrastructure=[]
    for name in IDS:
        a=read('attempt-'+name);e=read('evaluation-'+name+'-initial')
        pairs[a['language']][a['arm']]={'attempt':name,'groups':e['groups'],'build':e['build']['status']}
        phase_accounting[name]={phase:None if not a.get(phase) else {key:a[phase][key] for key in ['elapsed_seconds','limit_seconds','timed_out','returncode','usage','temperature','seed','cost']} for phase in ['reading','initial','repair']}
        if a['status']!='submitted' or e['build']['status']!='ok':infrastructure.append(name)
        if name in repairs:repair_scores[name]=read('evaluation-'+name+'-repair')['groups']
    result={'schema':'rosettanode.cross_language_report.v1','status':'complete','pairs':pairs,'initial_only':True,'repairs_separate':repair_scores,'phase_accounting':phase_accounting,'infrastructure_failures':infrastructure,'interpretation':'One document/control pair per language under the frozen packet and semantic evaluator. Results are exploratory and are not pooled with Go or used to rank languages. Initial scores remain separate from counterexample-assisted repairs.','monetary_cost':None,'iteration_latency':None}
    (ROOT/'evidence/cross-language-report.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result),flush=True)
if __name__=='__main__':main()
