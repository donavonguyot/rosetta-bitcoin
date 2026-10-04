#!/usr/bin/env python3
"""One-way campaign freeze; never overwrite after any candidate attempt."""

import sys as _rb_sys
from pathlib import Path as _RBPath
_rb_sys.path.insert(0, str(_RBPath(__file__).resolve().parents[4] / 'Project/scripts'))
from state_root import operational_paths as _rb_paths, logical_path as _rb_logical, acquire_writer_lease as _rb_writer_lease
if __name__ == '__main__':
    _rb_writer_lease()
import hashlib,json,time
from pathlib import Path
from build import ROOT,parent_check
from campaign import save,digest

def main():
    path=ROOT/'evidence/campaign-freeze.json'
    if path.exists():raise RuntimeError('Campaign already frozen; version corrections explicitly')
    assert not list((ROOT/'evidence').glob('lineage-*.json'))
    required=['qualification','adapter-probe','storage-probe','linkage-probe','mutation-matrix','priority-probe','bundle-probe','isolation-probe','gate-reproduction','measurement-control']
    for name in required:
        r=json.loads((ROOT/f'evidence/{name}.json').read_text());assert r['status']=='passed',name
    assert parent_check()
    files={str(p.relative_to(ROOT)):digest(p) for folder in ['tools','native','vendor','evaluator','bundles','contracts','traces'] for p in sorted((ROOT/folder).rglob('*')) if p.is_file() and '__pycache__' not in p.parts}
    evidence={name:digest(ROOT/f'evidence/{name}.json') for name in required}
    f={'schema':'rosettanode.substrate.campaign_freeze.v1','frozen_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'gate_a':'passed','gate_b':'passed','files':files,'evidence':evidence,'evaluator_image':json.loads((ROOT/'evidence/evaluator-image.json').read_text())['image_id'],'toolchain_image':json.loads((ROOT/'evidence/toolchains.json').read_text()).get('image_id'),'model':'gpt-6-astra','reasoning_effort':'high','temperature':None,'seed':None,'lineages':['zig-1','go-1','rust-1','zig-2','go-2','rust-2'],'round_limits_seconds':{'reading':600,'initial':5400,'maintenance':3600,'optimization':3600,'repair':900},'candidate_launch_allowed':True,'binary_gate_status':'not_attempted','classification':'comparison'}
    f['native_objects']={_rb_logical(p):digest(p) for d in ['adapter-bundle','adapter-asan-bundle'] for p in ((_rb_paths()['substrate'])/d).iterdir() if p.is_file()}
    save(path,f);print(json.dumps({'status':'frozen','sha256':digest(path)}))
if __name__=='__main__':main()
