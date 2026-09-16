#!/usr/bin/env python3
"""Repeat frozen Go submissions in fresh denied-read/network workspaces, no model."""
import argparse,hashlib,json,shutil,time
from pathlib import Path
from cohort import ROOT,BASE
from evaluate_attempt import evaluate

def main():
    p=argparse.ArgumentParser();p.add_argument('--phase',choices=['initial','repair'],default='initial');a=p.parse_args()
    ids=['D1','C1','D2','C2','D3','C3'] if a.phase=='initial' else ['C1','C2','C3']
    result={'schema':'rosettanode.cohort_reproduction.v1','phase':a.phase,'status':'passed','environment':'Fresh source/build/cache directories and fresh sandboxed processes on the same pinned macOS/Go host; no model rerun','attempts':{}};start=time.monotonic()
    for name in ids:
        other='reproduce-'+a.phase+'-'+name;source=BASE/name/a.phase;dest=BASE/other/'initial'
        if dest.exists():raise RuntimeError('Reproduction exists; inspect instead of overwriting')
        dest.mkdir(parents=True)
        for path in source.glob('*.go'):shutil.copyfile(path,dest/path.name)
        evaluate(other)
        before=json.loads((BASE/name/(a.phase+'-evaluation.json')).read_text());after=json.loads((BASE/other/'initial-evaluation.json').read_text())
        fields=['matrix','semantic_families','groups','chain','source_sha256']
        left={key:before[key] for key in fields};right={key:after[key] for key in fields}
        assert left==right,f'Non-reproducible semantic manifest: {name}'
        result['attempts'][name]={'semantic_manifest_sha256':hashlib.sha256(json.dumps(left,sort_keys=True).encode()).hexdigest(),'status':'passed'}
        print(name,'reproduced',flush=True)
    result['elapsed_seconds']=time.monotonic()-start
    (ROOT/f'evidence/cohort-reproduction-{a.phase}.json').write_text(json.dumps(result,indent=2)+'\n')
if __name__=='__main__':main()
