#!/usr/bin/env python3
"""Run as root inside the evaluation image; probe the candidate UID boundary."""
import json,os,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def demote():os.setgroups([]);os.setgid(65534);os.setuid(65534)
def main():
    checks=[]
    for path in [ROOT/'evaluator/state.py',ROOT/'tools/candidate_eval.py',ROOT/'.local/dummy',ROOT/'native/dummy.c']:
        assert path.is_file(),path
        p=subprocess.run(['cat',str(path)],capture_output=True,preexec_fn=demote);checks.append({'path':str(path),'denied':p.returncode!=0})
    p=subprocess.run(['sh','-c','test -r /adapter/librosetta.so && test -r /candidate/service && test ! -e /var/run/docker.sock'],preexec_fn=demote)
    result={'schema':'rosettanode.substrate.evaluation_isolation.v1','status':'passed' if all(c['denied'] for c in checks) and p.returncode==0 else 'failed','checks':checks,'same_uid_tampering_note':'LD_PRELOAD is observational instrumentation, not a security boundary against deliberately malicious native code; source and linkage audit remain required.'}
    Path('/output/isolation.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result));return int(result['status']!='passed')
if __name__=='__main__':raise SystemExit(main())
