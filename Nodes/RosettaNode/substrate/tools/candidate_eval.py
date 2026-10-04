#!/usr/bin/env python3
"""Frozen candidate evaluator. Candidate runs as UID 65534; evaluator stays root."""

import sys as _rb_sys
from pathlib import Path as _RBPath
_rb_sys.path.insert(0, str(_RBPath(__file__).resolve().parents[4] / 'Project/scripts'))
from state_root import operational_paths as _rb_paths, logical_path as _rb_logical, acquire_writer_lease as _rb_writer_lease
if __name__ == '__main__':
    _rb_writer_lease()
import argparse,json,os,sys,time,traceback,hashlib,concurrent.futures
from pathlib import Path
from service_probe import ROOT,Host,ITEM,invariant
from mutation_matrix import cell
from recovery_probe import complete
from workload_probe import Client
from priority_probe import trial as priority_trial
sys.path.insert(0,str(ROOT/'evaluator'))
from corpus import cases,identity
from state import check
from limits_probe import trial as limits_trial
import error_probe,after_ack_probe,workload_probe,mixed_probe,edge_probe


def encoding(base):
    h=Host(base);client=Client(h);rows=[]
    try:
        items=[];expected=[];names=[]
        for row in cases():
            q=row['request'];ex=row['expected']
            if q['op'] not in ['decode_exact','decode_prefix'] or 'limits' in q:continue
            raw=bytes.fromhex(q['bytes'])[int(q.get('offset','0')):]
            items.append({'hex':raw.hex(),'mode':q['mode'],'operation':'exact' if q['op']=='decode_exact' else 'prefix'});names.append(row['id'])
            status={'ok':'0','malformed_encoding':'1','resource_limit':'2'}[ex['status']]
            result={'status':status,'consumed':'0','full_size':'0','stripped_size':'0','txid_digest_order':'00'*32,'wtxid_digest_order':'00'*32}
            if status=='0':
                ident=identity(ex['transaction']);result.update({k:ident[k] for k in ['full_size','stripped_size','txid_digest_order','wtxid_digest_order']});result['consumed']=ex['consumed']
            expected.append(result)
        for start in range(0,len(items),64):
            response=client.call({'op':'evaluate','items':items[start:start+64]});actual=response.get('results',[])
            for i,ex in enumerate(expected[start:start+64]):rows.append({'case':names[start+i],'passed':i<len(actual) and actual[i]==ex})
        client.close();state=h.stop();assert invariant(state) is None
        assert all(r['passed'] for r in rows),[r for r in rows if not r['passed']]
        return {'cases':len(rows),'checks':rows}
    finally:
        client.close()
        if h.process.poll() is None:h.process.kill();h.process.wait()

def cancel_lifetime(base):
    h=Host(base,boundary='adapter_enter',transition='*')
    try:
        assert h.request({'op':'submit','id':'job','items':[ITEM]})['status']=='accepted';h.barrier()
        with concurrent.futures.ThreadPoolExecutor() as pool:
            pending=pool.submit(h.request,{'op':'cancel','id':'job'})
            time.sleep(.05)
            completed_before_release=pending.done()
            h.release.touch()
            response=pending.result()
        assert response['status'] in ['ok','too_late']
        receipt=complete(h)
        if response['status']=='ok':assert receipt['state']=='cancelled'
        else:assert receipt['state']=='complete'
        rows=h.stop();assert check(rows,cancelled=['job'] if response['status']=='ok' else []) is None
        return {'cancel_preserved_worker_lifetime':True,'cancel_completed_while_held':completed_before_release,'disposition':response['status']}
    finally:
        if h.process.poll() is None:h.process.kill();h.process.wait()

def crash(base,boundary,kind):
    h=Host(base,boundary=boundary,transition=kind+'/00000000000000000001')
    try:
        with h.connect() as s:
            s.sendall(json.dumps({'request':'a','op':'submit','id':'job','items':[ITEM]}).encode()+b'\n');h.barrier()
        before=h.stop(kill=True);assert invariant(before) is None
        restored=Host(base,db=h.db)
        try:
            if 'id/job' in before:assert complete(restored)['state']=='complete'
            after=restored.stop();assert invariant(after) is None
            return {'boundary':boundary,'transition':kind,'recovered':True}
        finally:
            if restored.process.poll() is None:restored.process.kill();restored.process.wait()
    finally:
        if h.process.poll() is None:h.process.kill();h.process.wait()

def linkage(base,phase):
    h=Host(base,boundary='adapter_enter',transition='*')
    try:
        assert h.request({'op':'submit','id':'job','items':[ITEM]})['status']=='accepted';h.barrier()
        paths={e['path'] for e in h.events() if e['phase']=='rocksdb_loaded'}
        assert len(paths)==1,paths;path=Path(next(iter(paths)));expected=json.loads((ROOT/'evidence/storage-probe.json').read_text())['library']['sha256'];assert hashlib.sha256(path.read_bytes()).hexdigest()==expected
        events=h.events();writes=[e for e in events if e['phase']=='write_enter'];assert writes and all(e['sync']==1 and e['wal']==1 for e in writes)
        assert any(e['phase']=='wal_sync_exit' and e['transition'].startswith('p/') and e['sync']==1 and e['inode'] for e in events)
        abi='v1' if phase=='initial' else 'v2';assert any(e['phase']=='adapter_enter' and e['path']==abi for e in events)
        options={e['phase']:e['inode'] for e in events if e['phase'].startswith('option_') or e['phase']=='cache_capacity'}
        assert options=={'option_write_buffer':64<<20,'option_write_buffers':2,'option_background_jobs':2,'option_compression':0,'cache_capacity':128<<20},options
        h.release.touch();complete(h);h.stop();return {'library_real_path':str(path),'library_sha256':expected,'abi_observed':abi,'options':options}
    finally:
        if h.process.poll() is None:h.process.kill();h.process.wait()

def upgrade(base):
    old=Host(base,variant='/predecessor/service',boundary='adapter_enter',transition='*')
    try:
        assert old.request({'op':'submit','id':'job','items':[ITEM]})['status']=='accepted';old.barrier();assert old.request({'op':'cancel','id':'job'})['status']=='ok';before=old.stop(kill=True);assert check(before,cancelled=['job']) is None
        h=Host(base,db=old.db)
        try:
            assert complete(h)['state']=='cancelled';after=h.stop();assert check(after,cancelled=['job']) is None
            return {'pending_v1_recovered':True,'cancellation_preserved':True}
        finally:
            if h.process.poll() is None:h.process.kill();h.process.wait()
    finally:
        if old.process.poll() is None:old.process.kill();old.process.wait()

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--phase',choices=['initial','maintenance','optimization'],required=True);args=parser.parse_args()
    base=(_rb_paths()['substrate'])/('candidate-'+str(time.monotonic_ns()));base.mkdir();results=[]
    def test(name,fn):
        start=time.monotonic()
        try:detail=fn();passed=True;error=None
        except Exception as e:detail=None;passed=False;error=repr(e);(base/(name+'.traceback')).write_text(traceback.format_exc())
        results.append({'family':name,'passed':passed,'detail':detail,'error':error,'elapsed_seconds':time.monotonic()-start})
    for family in ['unknown','early_ack','admission_atomic','terminal_atomic','conflicting_id','late_cancel','arena_lifetime']:
        def run(family=family):
            r=cell(base,'dummy',family);assert r['observed']=='pass',r;return r
        test(family,run)
    test('invalid_requests',lambda:edge_probe.requests(base));test('completed_accounting',lambda:edge_probe.completed_accounting(base));test('incompatible_version',lambda:edge_probe.incompatible(base));test('encoding_mixed_batches',lambda:encoding(base));test('native_linkage_options_abi',lambda:linkage(base,args.phase));test('cancel_worker_lifetime',lambda:cancel_lifetime(base))
    for kind in ['p','r']:
        for boundary in ['write_enter','wal_sync_enter','native_success']:test('crash_'+kind+'_'+boundary,lambda kind=kind,boundary=boundary:crash(base,boundary,kind))
    test('job_saturation',lambda:limits_trial(base,False));test('payload_saturation',lambda:limits_trial(base,True))
    test('injected_failures',error_probe.main);test('after_ack_repeated_recovery',after_ack_probe.main);test('workloads_1_3',workload_probe.main)
    if args.phase!='initial':
        test('mixed_service_workload',mixed_probe.main)
        test('pending_v1_upgrade',lambda:upgrade(base))
        for mixed in [False,True]:
            def check_priority(mixed=mixed):
                r=priority_trial(base,'dummy_v2',mixed);assert r['passed'],r;return r
            test('priority_'+str(mixed),check_priority)
    result={'schema':'rosettanode.substrate.candidate_evaluation.v1','phase':args.phase,'status':'passed' if all(r['passed'] for r in results) else 'failed','results':results,'diagnostics':str(base),'candidate_started_after_gate_freeze':None}
    Path('/output/result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({'status':result['status'],'failed':[r['family'] for r in results if not r['passed']]}));return int(result['status']!='passed')
if __name__=='__main__':raise SystemExit(main())
