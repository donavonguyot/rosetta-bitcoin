#!/usr/bin/env python3
"""Wait for all initial submissions, then evaluate the frozen cohort unchanged."""
import hashlib,json,subprocess,sys,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
IDS=['D1','C1','D2','C2','D3','C3']
def ready():
    for name in IDS:
        path=ROOT/f'evidence/attempt-{name}.json'
        if not path.exists():return False
        attempt=json.loads(path.read_text())
        if attempt.get('initial') is None:
            if attempt.get('reading',{}).get('returncode') not in [None,0]:raise RuntimeError(f'{name}: reading failed; retain failure, do not replace')
            return False
    return True

def main():
    deadline=time.monotonic()+7200
    while not ready():
        if time.monotonic()>deadline:raise TimeoutError('Cohort did not finish; no automatic replacements')
        time.sleep(5)
    frozen=json.loads((ROOT/'evidence/cohort-freeze.json').read_text())
    for path,expected in frozen['evaluator_sources'].items():assert hashlib.sha256((ROOT/path).read_bytes()).hexdigest()==expected,'Evaluator drift'
    for name in IDS:
        attempt=json.loads((ROOT/f'evidence/attempt-{name}.json').read_text());directory=ROOT/f'.local/cohort/{name}/initial'
        assert {p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in directory.glob('*.go')}==attempt['source_sha256'],'Submission drift'
        evidence=ROOT/f'evidence/evaluation-{name}-initial.json'
        if evidence.exists():raise RuntimeError('Existing evaluation: inspect instead of overwriting '+name)
        with (ROOT/f'.local/cohort/{name}/evaluation-driver.log').open('w') as log:
            process=subprocess.run([sys.executable,str(ROOT/'tools/evaluate_attempt.py'),name],stdout=log,stderr=subprocess.STDOUT,timeout=600)
        if process.returncode:raise RuntimeError(f'{name}: evaluator failure; preserve logs and version fixes explicitly')
        result=json.loads(evidence.read_text());print(json.dumps({'attempt':name,'groups':result['groups']}),flush=True)
    subprocess.run([sys.executable,str(ROOT/'tools/analyze_cohort.py')],check=True)
if __name__=='__main__':main()
