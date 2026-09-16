#!/usr/bin/env python3
"""Run retained rounds; never restart or replace an existing attempt."""
import concurrent.futures,json,subprocess
from campaign import ROOT,frozen,save

def run_one(lineage,round):
    path=ROOT/f'evidence/lineage-{lineage}-{round}.json'
    if path.exists():return json.loads(path.read_text())['status']
    previous={'maintenance':'initial','optimization':'maintenance'}.get(round)
    if previous:
        p=ROOT/f'evidence/lineage-{lineage}-{previous}.json'
        if not p.exists() or json.loads(p.read_text())['status']!='qualified':return 'dependent_round_not_attempted'
    log=ROOT/'.local/campaign-controller'/f'{lineage}-{round}.log';log.parent.mkdir(exist_ok=True)
    with log.open('x') as stream:
        p=subprocess.run(['python3',str(ROOT/'tools/campaign.py'),lineage,round],stdout=stream,stderr=stream)
    return json.loads(path.read_text())['status'] if path.exists() else 'controller_failure'

def main():
    f=frozen();results=[]
    # Independent coding sessions may overlap; all measurements remain serial.
    for round in ['initial','maintenance','optimization']:
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            pending={pool.submit(run_one,lineage,round):lineage for lineage in f['lineages']}
            for future in concurrent.futures.as_completed(pending):
                try:status=future.result()
                except Exception as e:status='controller_failure: '+repr(e)
                row={'lineage':pending[future],'round':round,'status':status};results.append(row);print(json.dumps(row),flush=True);save(ROOT/'evidence/rounds.json',results)
    # Performance requires source review and no overlapping node benchmarks.
    save(ROOT/'evidence/rounds-complete.json',{'rounds':results,'next':'source/dependency audit and declared diagnostics, then tools/measure.py --campaign','measurements_started':False})
if __name__=='__main__':main()
