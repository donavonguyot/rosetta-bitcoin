#!/usr/bin/env python3
"""Report actual acceptance without promoting a reference pass to a transfer claim."""
import hashlib,json,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def read(name):
    path=ROOT/f'evidence/{name}.json'
    return json.loads(path.read_text()) if path.exists() else {}
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None

def main():
    checks={}
    for name in ['compactsize-gate','reproduction','adversarial','execution-variants','chain-composition','transaction-reproduction','bounded-fuzz','cohort-reproduction-initial','cohort-reproduction-repair']:
        p=ROOT/f'evidence/{name}.json';checks[name]=p.exists() and json.loads(p.read_text()).get('status')=='passed'
    freeze=ROOT/'evidence/cohort-freeze.json';v={}
    if freeze.exists():
        v=json.loads(freeze.read_text());checks['packet_frozen']=hashlib.sha256((ROOT/'.local/transaction-book/reconstruction.md').read_bytes()).hexdigest()==v['packet_sha256']
        checks['evaluator_frozen']=all(hashlib.sha256((ROOT/p).read_bytes()).hexdigest()==expected for p,expected in v['evaluator_sources'].items())
    else:checks['packet_frozen']=checks['evaluator_frozen']=False
    ids=['D1','D2','D3','C1','C2','C3'];threads=[]
    report=ROOT/'evidence/transfer-report.json'
    checks['transfer_analysis']=report.exists() and not json.loads(report.read_text()).get('missing',['unknown'])
    if checks['transfer_analysis']:
        continuation=json.loads(report.read_text())['cross_language']
        cross=read('cross-language-report')
        checks['conditional_continuation']=continuation=='stop_this_packet_version' or cross.get('status')=='complete'
        if continuation=='one_frozen_pair_each_rust_zig':
            ids+=['RD1','RC1','ZD1','ZC1']
            frozen=read('cross-language-freeze')
            checks['cross_sources_frozen']=bool(frozen) and all(digest(ROOT/p)==expected for p,expected in frozen.get('sources',{}).items())
            checks['cross_provenance']=bool(frozen) and digest(ROOT/'evidence/go-initial-result.json')==frozen['go_analysis_sha256'] and digest(freeze)==frozen['go_freeze_sha256'] and frozen['packet_sha256']==v.get('packet_sha256')
            checks['cross_compilers']=bool(frozen) and all(digest(Path(frozen['languages'][language]['compiler']))==expected for language,expected in frozen.get('compiler_sha256',{}).items())
            checks['cross_drivers']=bool(frozen) and all(digest(ROOT/'.local/toolchain-wrappers'/name)==expected for name,expected in frozen.get('driver_sha256',{}).items())
    else:checks['conditional_continuation']=False
    for name in ids:
        a=read('attempt-'+name);e=read('evaluation-'+name+'-initial');base=ROOT/'.local/cohort'/name
        checks['initial_'+name]=bool(a.get('initial')) and bool(e)
        if not checks['initial_'+name]:continue
        threads.append(a['reading']['thread_id'])
        checks['source_'+name]=bool(a.get('source_sha256')) and a['source_sha256']==e['source_sha256'] and all((base/'initial'/p).exists() and digest(base/'initial'/p)==expected for p,expected in a['source_sha256'].items())
        checks['isolation_'+name]=bool(e['isolation']) and all(c['denied'] for c in e['isolation'])
        checks['materials_'+name]=bool(v) and digest(base/'workspace/interface.md')==v['shared_sha256'] and ((a['arm']=='document' and digest(base/'workspace/packet.md')==v['packet_sha256']) or (a['arm']=='control' and not (base/'workspace/packet.md').exists()))
        for phase,label in [('reading','reading'),('initial','implementation'),('repair','repair')]:
            record=a.get(phase)
            if not record:continue
            checks['log_'+name+'_'+phase]=digest(base/'logs'/(label+'.jsonl'))==record['events_sha256']
            checks['network_'+name+'_'+phase]=record['configuration']['permissions.rosetta.network.enabled'] is False
            if phase=='repair':
                repaired=read('evaluation-'+name+'-repair')
                checks['repair_'+name]=bool(repaired) and a['repair_source_sha256']==repaired.get('source_sha256') and all(digest(base/'repair'/p)==expected for p,expected in a['repair_source_sha256'].items())
        if a['language']!='go':
            checks['overlay_'+name]=digest(base/'workspace/language.md')==a['overlay_sha256']
            checks['reproduction_'+name]=read('reproduction-'+name+'-initial').get('status')=='passed'
            if a.get('repair'):checks['repair_reproduction_'+name]=read('reproduction-'+name+'-repair').get('status')=='passed'
    checks['fresh_reading_sessions']=len(threads)==len(ids) and len(set(threads))==len(threads) and None not in threads
    if 'RD1' in ids:
        checks['matched_language_overlays']=all(read('attempt-'+left).get('overlay_sha256') and read('attempt-'+left).get('overlay_sha256')==read('attempt-'+right).get('overlay_sha256') for left,right in [('RD1','RC1'),('ZD1','ZC1')])
    checks['gate_budget']=read('session').get('gate_budget_satisfied') is True
    review=read('transaction-visual-review')
    checks['document_visual_review']=review.get('result')=='passed' and all(digest(ROOT/'.local/transaction-book'/name)==row.get('sha256') for name,row in review.get('documents',{}).items())
    reproduction=read('transaction-reproduction')
    checks['document_text_reproduction']=bool(reproduction.get('document_text_hashes')) and all(digest(ROOT/'.local/transaction-book'/(name+'.txt'))==expected for name,expected in reproduction.get('document_text_hashes',{}).items())
    result={'schema':'rosettanode.acceptance.v1','accepted':all(checks.values()),'checks':checks,'binary_gate_status':'not_attempted','kind':'specification_transfer_experiment','scope':'No consensus validity, node readiness, or authored-IR superiority claim'}
    (ROOT/'evidence/acceptance.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
    return 0 if result['accepted'] else 1
if __name__=='__main__':sys.exit(main())
