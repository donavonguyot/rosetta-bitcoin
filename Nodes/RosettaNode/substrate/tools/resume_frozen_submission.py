#!/usr/bin/env python3
"""Retain an old-controller initial submission; evaluate/repair with corrected tools."""
import argparse,json,os,signal,subprocess,time
from pathlib import Path
from campaign_v3 import ROOT,save,digest,evaluate,phase,snapshot,frozen

def main():
    p=argparse.ArgumentParser();p.add_argument('lineage');p.add_argument('record',type=Path);p.add_argument('controller',type=int);p.add_argument('roundroot',type=Path);a=p.parse_args();frozen()
    while True:
        original=json.loads(a.record.read_text())
        if original.get('implementation') and (a.roundroot/'submission').is_dir():break
        time.sleep(.1)
    # Only stop the known old controller after its source snapshot exists.
    ps=subprocess.run(['ps','-p',str(a.controller),'-o','command='],capture_output=True,text=True)
    if ps.returncode==0:
        assert 'tools/campaign' in ps.stdout and a.lineage+' initial' in ps.stdout
        os.kill(a.controller,signal.SIGSTOP);os.kill(a.controller,signal.SIGKILL)
    save(ROOT/f'evidence/controller-revisions/{a.lineage}-initial-pre-v3.json',original)
    out=a.roundroot/'v3-evaluation';result=evaluate(a.roundroot/'submission',out,'initial')
    report=dict(original);report.update(schema='rosettanode.substrate.lineage_round.v2',original_freeze_sha256=original['freeze_sha256'],freeze_sha256=digest(ROOT/'evidence/campaign-freeze-v3.json'),controller_version=1,continuation_controller_version=3,corrected_evaluation=str(out/'result.json'),initial_submission_gate_v2=result['status'])
    report['attempts']=[{'kind':'initial_submission','evaluation':str(out/'result.json'),'status':result['status']}];submission=a.roundroot/'submission'
    if result['status']!='passed':
        work=a.roundroot/'workspace';logs=a.roundroot/'logs'
        save(work/'feedback.json',{'failed_families':[{k:r.get(k) for k in ['family','error','detail']} for r in result.get('results',[]) if not r['passed']]})
        report['repair']=phase(work,logs,'corrected-repair','Separate 15-minute repair reserve. Read feedback.json. Correct those contract failures using only supplied materials, offline docs and the Linux broker. Preserve tests and a concise handoff. Do not weaken durability or access evaluator/other candidates. Finish early when ready.',900,original['implementation']['thread_id'])
        report['repair_controller_version']=3;submission=a.roundroot/'corrected-repair-submission';report['repair_source_sha256']=snapshot(work,submission)
        result=evaluate(submission,a.roundroot/'corrected-repair-evaluation','initial');report['attempts'].append({'kind':'repair','evaluation':str(a.roundroot/'corrected-repair-evaluation/result.json'),'status':result['status']})
    report['status']='qualified' if result['status']=='passed' else 'hard_gate_failed';report['qualified_submission']=str(submission) if result['status']=='passed' else None
    save(ROOT/f'evidence/lineage-v2-{a.lineage}-initial.json',report);print(json.dumps({'lineage':a.lineage,'status':report['status']}))
if __name__=='__main__':main()
