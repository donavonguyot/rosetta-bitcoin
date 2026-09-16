#!/usr/bin/env python3
"""Explicit evaluator correction; v1 sources, freeze and outcomes stay retained."""
import json,time
from campaign import ROOT,frozen as verify_v1,save,digest

def main():
    previous=verify_v1();path=ROOT/'evidence/campaign-freeze-v2.json';assert not path.exists()
    results={}
    for key in ['control','go-1','zig-1']:
        p=ROOT/'.local'/('correction-v2-final-'+key)/'result.json';r=json.loads(p.read_text());assert r['status']=='passed';results[key]={'sha256':digest(p),'semantic_families':[(v['family'],v['passed']) for v in r['results']]}
    eof=ROOT/'.local/correction-v2-eof-recheck/log.txt';assert '"status": "passed", "faults": 3' in eof.read_text()
    early=ROOT/'.local/correction-v2-early-mutant/log.txt';assert 'AssertionError' in early.read_text() and "ack.get('status')=='execution_failure'" in early.read_text()
    correction=json.loads((ROOT/'evidence/instrument-correction-v2.json').read_text());correction.update(status='qualified',original_submissions_reevaluated=results,correct_eof_control_sha256=digest(eof),early_ack_mutant_sha256=digest(early),candidate_contract_changed=False,comparison_rule='All reported semantic comparisons use v2 evaluation only. Original v1-contract submissions remain eligible because candidate contract did not change. Evaluator-induced repair work is excluded from candidate maintenance cost and predecessor selection.')
    save(ROOT/'evidence/instrument-correction-v2.json',correction)
    f=dict(previous);f.update(schema='rosettanode.substrate.campaign_freeze.v2',frozen_utc=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),supersedes_sha256=digest(ROOT/'evidence/campaign-freeze.json'),correction='instrument-correction-v2.json',evaluator_image=json.loads((ROOT/'evidence/evaluator-image.json').read_text())['image_id'])
    f['files']={str(p.relative_to(ROOT)):digest(p) for folder in ['tools','native','vendor','evaluator','bundles','contracts','traces'] for p in sorted((ROOT/folder).rglob('*')) if p.is_file() and '__pycache__' not in p.parts}
    f['evidence']={**previous['evidence'],'instrument-correction-v2':digest(ROOT/'evidence/instrument-correction-v2.json')}
    save(path,f);print(json.dumps({'status':'frozen_v2','sha256':digest(path)}))
if __name__=='__main__':main()
