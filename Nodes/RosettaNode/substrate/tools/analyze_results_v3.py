#!/usr/bin/env python3
"""Read retained v2 outcomes; never merge superseded v1 evaluator scores."""
import difflib,json,statistics
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]

def footprint(before,after):
    kinds={k:{'added':0,'removed':0,'files_changed':0} for k in ['production','test','generated','documentation']}
    def texts(root):
        out={}
        if not root:return out
        for p in root.rglob('*'):
            if not p.is_file() or p.is_symlink() or p.suffix not in ['.go','.rs','.zig','.c','.h','.py','.sh','.md','.toml','.json']:continue
            try:out[str(p.relative_to(root))]=[line.rstrip() for line in p.read_text().splitlines() if line.strip()]
            except UnicodeDecodeError:continue
        return out
    a,b=texts(before),texts(after)
    for name in sorted(a.keys()|b.keys()):
        if a.get(name)==b.get(name):continue
        kind='documentation' if name.endswith('.md') else 'generated' if 'generated' in name else 'test' if 'test' in name.lower() else 'production'
        kinds[kind]['files_changed']+=1
        for line in difflib.unified_diff(a.get(name,[]),b.get(name,[]),n=0):
            if line.startswith('+') and not line.startswith('+++'):kinds[kind]['added']+=1
            if line.startswith('-') and not line.startswith('---'):kinds[kind]['removed']+=1
    return kinds

def main():
    rows=[];missing=[]
    for language in ['zig','go','rust']:
        for number in [1,2]:
            lineage=f'{language}-{number}';predecessor=None
            for round in ['initial','maintenance','optimization']:
                path=ROOT/f'evidence/lineage-v2-{lineage}-{round}.json'
                if not path.exists():missing.append({'lineage':lineage,'round':round});continue
                r=json.loads(path.read_text());initial_path=r.get('corrected_evaluation') or next((a['evaluation'] for a in r.get('attempts',[]) if a['kind']=='initial_submission'),None)
                ev=json.loads(Path(initial_path).read_text()) if initial_path and Path(initial_path).exists() else None
                repair_excluded=bool(r.get('repair_attribution'));impl=r.get('implementation') or {};reading=r.get('reading') or {};repair=r.get('repair') or {}
                usage=[]
                for phase in ['reading','implementation','repair']:
                    phase_record=r.get(phase) or {}
                    for item in phase_record.get('usage',[]):usage.append({'phase':phase,'excluded_from_language_cost':phase=='repair' and repair_excluded,**item})
                submission=Path(r['qualified_submission']) if r.get('qualified_submission') else None
                row={'lineage':lineage,'language':language,'round':round,'controller_version':r.get('controller_version',1),'status':r['status'],'gate_before_repair':ev['status'] if ev else None,'failed_semantic_families':[{k:x.get(k) for k in ['family','error','detail']} for x in (ev or {}).get('results',[]) if not x['passed']],'reading_seconds':reading.get('elapsed_seconds'),'implementation_seconds':impl.get('elapsed_seconds'),'repair_seconds':None if repair_excluded else repair.get('elapsed_seconds'),'invalidated_evaluator_repair_seconds':repair.get('elapsed_seconds') if repair_excluded else None,'usage':usage,'monetary_cost':None,'source_record':str(path),'normalized_diff':footprint(predecessor,submission) if predecessor and submission else None}
                rows.append(row)
                if submission:predecessor=submission
    aggregates=[]
    for language in ['zig','go','rust']:
        for round in ['initial','maintenance','optimization']:
            cohort=[r for r in rows if r['language']==language and r['round']==round];times=[r['implementation_seconds'] for r in cohort if r['implementation_seconds'] is not None]
            aggregates.append({'language':language,'round':round,'attempts':len(cohort),'qualified':sum(r['status']=='qualified' for r in cohort),'initial_gate_passes':sum(r['gate_before_repair']=='passed' for r in cohort),'controller_versions':sorted({r['controller_version'] for r in cohort}),'initial_time_ranking_allowed':round!='initial','median_implementation_seconds':statistics.median(times) if times else None,'min_implementation_seconds':min(times) if times else None,'max_implementation_seconds':max(times) if times else None})
    output={'schema':'rosettanode.substrate.analysis.v2','classification':'comparison','binary_gate_status':'not_attempted','rows':rows,'aggregates':aggregates,'unattempted_or_pending':missing,'interpretation':'Small lineages; no significance claim or universal language ranking. Missing rounds require dependency/stop attribution before a complete report.','diagnostic_warning':'A Zig failure is not evidence that Zig is a bad language.','evaluator_version':'v2 only','cost_limitations':['Monetary cost unavailable','Model-active time unavailable; phase wall time includes tools and waits','Initial construction times under older controllers include duplicate request overhead; no initial timing ranking','Cached input tokens are included in provider usage fields; not converted into invented prices']}
    (ROOT/'evidence/analysis-v2.json').write_text(json.dumps(output,indent=2)+'\n');print(json.dumps(aggregates,indent=2))
if __name__=='__main__':main()
