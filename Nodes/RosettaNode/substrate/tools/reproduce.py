#!/usr/bin/env python3
"""Fresh build and fresh evaluator run for a retained qualified submission."""
import argparse,json,uuid
from pathlib import Path
from campaign_v3 import ROOT,evaluate,save,digest,frozen
from submission_audit import audit

def main():
    p=argparse.ArgumentParser();p.add_argument('lineage');p.add_argument('round',choices=['initial','maintenance','optimization']);a=p.parse_args();frozen()
    record=json.loads((ROOT/f'evidence/lineage-v2-{a.lineage}-{a.round}.json').read_text());assert record['status']=='qualified'
    submission=Path(record['qualified_submission']);build=audit(submission,record['language']);assert build['status']=='passed',build
    work=Path(build['logs'])/'workspace';predecessor=None
    if a.round!='initial':predecessor=Path(json.loads((ROOT/f'evidence/lineage-v2-{a.lineage}-initial.json').read_text())['qualified_submission'])
    out=ROOT/'.local/reproductions'/f'{a.lineage}-{a.round}-{uuid.uuid4().hex[:8]}'
    result=evaluate(work,out,a.round,predecessor)
    # Compare semantic family manifests only; race-permitted outcomes and timings differ.
    prior_path=record.get('corrected_evaluation') if not record.get('repair') or record.get('repair_attribution') else None
    if prior_path is None:prior_path=record['attempts'][-1]['evaluation']
    prior=json.loads(Path(prior_path).read_text());manifest=lambda r:[(x['family'],x['passed']) for x in r.get('results',[])]
    report={'schema':'rosettanode.substrate.reproduction.v1','lineage':a.lineage,'round':a.round,'status':'passed' if result['status']=='passed' and manifest(result)==manifest(prior) else 'failed','build':build,'binary_identical':build['input_binary_sha256']==build['rebuilt_binary_sha256'],'semantic_manifest':manifest(result),'original_semantic_manifest':manifest(prior),'result':str(out/'result.json'),'excluded':['timings','PIDs','temporary paths','permitted cancellation race disposition'],'fresh_environment':True}
    save(ROOT/f'evidence/reproduction-{a.lineage}-{a.round}.json',report);print(json.dumps({'lineage':a.lineage,'round':a.round,'status':report['status']}))
if __name__=='__main__':main()
