"""One final holdout; failure selects the frozen baseline without retuning."""
import json,subprocess,sys,shutil
from common import HERE,WORK,ROOT,FROZEN,source_digest,save,exclusive,docker,digest
from selection import assess


def main():
    if (WORK/'holdout-decision.json').exists():raise ValueError('Holdout already consumed')
    subprocess.run([sys.executable,str(HERE/'bench.py'),'baseline','candidate','--phase','holdout'],cwd=ROOT,check=True)
    baseline=json.loads((WORK/'baseline-holdout-bench.json').read_text());candidate=json.loads((WORK/'candidate-holdout-bench.json').read_text())
    decision=assess(baseline,candidate);decision['tested_candidate_digest']=source_digest(WORK/'candidate')
    selected=json.loads((WORK/'control-selection.json').read_text())['selected']
    rows=[]
    with exclusive():
        for batch in range(2):rows.extend(json.loads(line) for line in docker(['/work/'+selected['name']+'-bench','/work/holdout.json',str(batch)]).splitlines())
    save(WORK/'c_control-holdout-bench.json',dict(name='c_control',configuration=selected,input_sha256=digest(WORK/'holdout.json'),measurements=rows))
    if not decision['qualifies']:
        shutil.move(WORK/'candidate',WORK/'holdout-rejected-candidate')
        shutil.copytree(FROZEN,WORK/'candidate',ignore=shutil.ignore_patterns('.zig-cache','zig-out'))
        decision['selected']='baseline'
    else:decision['selected']='candidate'
    decision['candidate_digest']=source_digest(WORK/'candidate')
    save(WORK/'holdout-decision.json',decision);print(json.dumps(decision))

if __name__=='__main__':main()
