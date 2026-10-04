#!/usr/bin/env python3

import sys as _rb_sys
from pathlib import Path as _RBPath
_rb_sys.path.insert(0, str(_RBPath(__file__).resolve().parents[4] / 'Project/scripts'))
from state_root import operational_paths as _rb_paths, logical_path as _rb_logical, acquire_writer_lease as _rb_writer_lease
if __name__ == '__main__':
    _rb_writer_lease()
import concurrent.futures,json,socket,time
from service_probe import ROOT,Host,ITEM,invariant
from recovery_probe import complete
from storage_probe import inspect

VARIANTS=['dummy','dummy_early','dummy_torn','dummy_terminal','dummy_conflict','dummy_cancel','dummy_arena']
FAMILIES=['unknown','early_ack','admission_atomic','terminal_atomic','conflicting_id','late_cancel','arena_lifetime']
TARGET={'dummy_early':'early_ack','dummy_torn':'admission_atomic','dummy_terminal':'terminal_atomic','dummy_conflict':'conflicting_id','dummy_cancel':'late_cancel','dummy_arena':'arena_lifetime'}

def cell(base,variant,family):
    boundary=None;transition=None
    if family in ['early_ack','admission_atomic']:boundary='native_success';transition='p/00000000000000000001'
    if family in ['terminal_atomic','late_cancel']:boundary='native_success';transition='r/00000000000000000001'
    env={}
    if variant in ['dummy_arena','dummy_asan']:env={'LD_PRELOAD':'/usr/lib/aarch64-linux-gnu/libasan.so.8:'+str((_rb_paths()['substrate'] / 'interpose.so')),'ASAN_OPTIONS':'detect_leaks=1:abort_on_error=1'}
    h=Host(base,variant,boundary,transition,extra_env=env);observed='pass';detail=None
    try:
        if family=='unknown':
            assert h.request({'op':'status','id':'x'})['status']=='not_found';assert h.request({'op':'cancel','id':'x'})['status']=='not_found';state=h.stop();assert invariant(state) is None and 'id/x' not in state
        elif family in ['early_ack','admission_atomic','terminal_atomic']:
            with h.connect() as s:
                s.sendall(json.dumps({'op':'submit','request':'r','id':'job','items':[ITEM]}).encode()+b'\n');h.barrier();s.settimeout(.1)
                try:ack=json.loads(s.makefile('rb').readline())
                except TimeoutError:ack=None
            state=h.stop(kill=True)
            if family=='early_ack':observed='failure' if ack is not None else 'pass';detail={'ack_while_admission_return_held':ack}
            else:detail=invariant(state);observed='failure' if detail else 'pass'
        elif family=='late_cancel':
            h.request({'op':'submit','id':'job','items':[ITEM]});h.barrier()
            with concurrent.futures.ThreadPoolExecutor() as pool:
                f=pool.submit(h.request,{'op':'cancel','id':'job'});time.sleep(.03);h.release.touch();r=f.result()
            observed='failure' if r['status']!='too_late' else 'pass';detail=r;h.stop()
        elif family=='conflicting_id':
            h.request({'op':'submit','id':'job','items':[ITEM]});complete(h)
            r=h.request({'op':'submit','id':'job','items':[{**ITEM,'hex':'02000000000000000000'}]});observed='failure' if r['status']!='conflict' else 'pass';detail=r;h.stop()
        elif family=='arena_lifetime':
            h.request({'op':'submit','id':'job','items':[ITEM]})
            if variant=='dummy_arena':
                h.process.wait(timeout=5);diagnostic=(h.root/'stderr').read_text();observed='failure' if h.process.returncode!=0 and 'heap-use-after-free' in diagnostic and 'rn_verify_v1' in diagnostic else 'infrastructure_failure';detail='ASan heap-use-after-free in worker verification' if observed=='failure' else diagnostic[-2000:]
            else:complete(h);h.stop()
    except Exception as error:
        diagnostic=(h.root/'stderr').read_text()
        if variant=='dummy_arena' and 'heap-use-after-free' in diagnostic:observed='blocked_by_lifetime_fault';detail='Worker arena fault prevents this kernel-dependent family; not counted as its intended kill.'
        else:observed='infrastructure_failure';detail=str(error)
    finally:
        if h.process.poll() is None:h.process.kill();h.process.wait()
    expected='failure' if TARGET.get(variant)==family else 'pass'
    allowed=observed==expected or variant=='dummy_arena' and observed=='blocked_by_lifetime_fault' and family in ['terminal_atomic','conflicting_id','late_cancel']
    return {'variant':variant,'family':family,'observed':observed,'expected':expected,'qualified':allowed,'detail':detail,'diagnostics':_rb_logical(h.root)}

def main():
    base=(_rb_paths()['substrate'])/('matrix-'+time.strftime('%Y%m%dT%H%M%S'));base.mkdir();matrix=[]
    for variant in VARIANTS:
        for family in FAMILIES:matrix.append(cell(base,variant,family))
    matrix.append(cell(base,'dummy_asan','arena_lifetime'))
    intended=all(any(c['variant']==v and c['family']==f and c['observed']=='failure' for c in matrix) for v,f in TARGET.items())
    result={'schema':'rosettanode.substrate.mutation_matrix.v1','status':'passed' if intended and all(c['qualified'] for c in matrix) else 'failed','matrix':matrix,'intended_kills':intended,'starvation_matrix':'priority-probe.json','candidate_launch_allowed':False}
    (base/'result.json').write_text(json.dumps(result,indent=2)+'\n');(ROOT/'evidence/mutation-matrix.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({'status':result['status'],'cells':len(matrix),'unexpected':[c for c in matrix if not c['qualified']]}));return int(result['status']!='passed')
if __name__=='__main__':raise SystemExit(main())
