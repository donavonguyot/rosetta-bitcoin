#!/usr/bin/env python3
"""Descriptive, initial-only comparison; no significance or language-ranking claim."""
import json,statistics
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def main():
    ids=['D1','D2','D3','C1','C2','C3'];arms={'document':[],'control':[]};missing=[];phases={};usage=[]
    for name in ids:
        path=ROOT/f'evidence/evaluation-{name}-initial.json';attempt=ROOT/f'evidence/attempt-{name}.json'
        if not path.exists() or not attempt.exists():missing.append(name);continue
        a=json.loads(attempt.read_text());e=json.loads(path.read_text());arms[a['arm']].append({'attempt':name,'groups':e['groups'],'build':e['build']['status']})
        phases[name]={p:a[p] and {'elapsed_seconds':a[p]['elapsed_seconds'],'timed_out':a[p]['timed_out'],'usage':a[p]['usage']} for p in ['reading','initial','repair']}
        for p in ['reading','initial','repair']:
            if a[p]:usage.extend(a[p]['usage'])
    medians={arm:{group:statistics.median(row['groups'][group] for row in rows) for group in ['encoding','profile','structured','valid_chain']} for arm,rows in arms.items() if rows}
    outcome='inconclusive';reason='Initial cohort incomplete';continuation='blocked_pending_go_cohort'
    if not missing:
        doc=medians['document'];control=medians['control']
        ceiling=all(all(value==1 for value in row['groups'].values()) for rows in arms.values() for row in rows)
        if ceiling:outcome='no observed improvement';reason='Both arms reached the evaluated ceiling';continuation='stop_this_packet_version'
        elif doc['profile']>control['profile'] and doc['structured']>=control['structured']:
            outcome='observed improvement';reason='Document median improves profile families without a lower structured-serialization median';continuation='one_frozen_pair_each_rust_zig'
        elif doc['profile']<=control['profile'] and doc['structured']<=control['structured']:
            outcome='no observed improvement';reason='No positive document median difference in profile/structured groups';continuation='instrument_review_before_cross_language'
        else:reason='Mixed profile/structured direction';continuation='instrument_review_before_cross_language'
    total={key:sum(u.get(key,0) for u in usage) for key in sorted({k for u in usage for k in u})}
    repairs={}
    for name in ids:
        path=ROOT/f'evidence/evaluation-{name}-repair.json'
        if path.exists():repairs[name]=json.loads(path.read_text())['groups']
    report={'schema':'rosettanode.transfer_report.v1','outcome':outcome,'reason':reason,'initial_only':True,'attempts':arms,'group_medians':medians,'repairs_separate':repairs,'phase_accounting':phases,'usage_totals':total,'missing':missing,'cross_language':continuation,'iteration_latency':None,'iteration_latency_note':'CLI phase logs do not provide per-iteration timestamps; phase elapsed and reported usage retained, no inferred latency.','monetary_cost':None,'cautions':['Three attempts per arm are descriptive, not a causal/significance study.','Familiar Bitcoin encoding is sensitive to prior knowledge.','Repairs are excluded from initial transfer scores.','C2/C3 structured cases share negative amounts: their zero score is driven by a correlated signedness defect, not evidence that they lack serializers.','All six Go attempts passed the valid-chain family; real chain data did not expose these profile/negative-amount failures.','No authored-IR superiority or consensus/node-readiness claim.']}
    (ROOT/'evidence/transfer-report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({'outcome':outcome,'medians':medians,'missing':missing,'continuation':continuation}))
if __name__=='__main__':main()
