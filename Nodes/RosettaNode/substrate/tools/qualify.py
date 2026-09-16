#!/usr/bin/env python3
"""Run instrument qualification serially; this does not launch candidates."""
import hashlib,json,subprocess,time,uuid
from pathlib import Path
from build import ROOT,RUNTIME,parent_check
PROBES=['storage_probe','service_probe','adapter_probe','linkage_probe','recovery_probe','priority_probe','mutation_matrix','limits_probe','error_probe','after_ack_probe','workload_probe','mixed_probe']
FILES={name:name.replace('_','-')+'.json' for name in PROBES}

def main():
    folder=ROOT/'.local'/('qualification-'+uuid.uuid4().hex[:10]);folder.mkdir();started=time.monotonic();runs=[]
    p=subprocess.run(['python3',str(ROOT/'tools/build.py')],capture_output=True,text=True);(folder/'build.log').write_text(p.stdout+p.stderr)
    if p.returncode:raise RuntimeError('build failed; see '+str(folder))
    for probe in PROBES:
        start=time.monotonic()
        with (folder/(probe+'.log')).open('w') as out:
            p=subprocess.run(['docker','run','--rm','--network','none','--cpus','4','--memory','4g','--label','rosettanode.substrate=qualification','-e','PYTHONDONTWRITEBYTECODE=1','-v',str(ROOT)+':/work',RUNTIME,'python3','tools/'+probe+'.py'],stdout=out,stderr=out,timeout=900)
        result=ROOT/'evidence'/FILES[probe]
        passed=p.returncode==0 and result.exists() and json.loads(result.read_text())['status']=='passed'
        runs.append({'probe':probe,'passed':passed,'elapsed_seconds':time.monotonic()-start,'returncode':p.returncode,'result_sha256':hashlib.sha256(result.read_bytes()).hexdigest() if result.exists() else None})
        if result.exists():(folder/result.name).write_bytes(result.read_bytes())
        print(json.dumps(runs[-1]),flush=True)
        if not passed:break
    record={'schema':'rosettanode.substrate.qualification.v1','status':'passed' if len(runs)==len(PROBES) and all(r['passed'] for r in runs) else 'failed','runs':runs,'elapsed_seconds':time.monotonic()-started,'parent_unchanged':parent_check(),'candidate_launch_allowed':False,'remaining_launch_requirements':['frozen public/withheld traces','candidate evaluator isolation','complete cohort/measurement tooling','clean-environment semantic reproduction','freeze hashes']}
    (folder/'result.json').write_text(json.dumps(record,indent=2)+'\n');(ROOT/'evidence/qualification.json').write_text(json.dumps(record,indent=2)+'\n')
    return int(record['status']!='passed')
if __name__=='__main__':raise SystemExit(main())
