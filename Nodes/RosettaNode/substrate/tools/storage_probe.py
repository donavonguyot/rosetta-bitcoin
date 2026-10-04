#!/usr/bin/env python3
"""Run inside the pinned instrument image. This is a prerequisite, not Gate A."""

import sys as _rb_sys
from pathlib import Path as _RBPath
_rb_sys.path.insert(0, str(_RBPath(__file__).resolve().parents[4] / 'Project/scripts'))
from state_root import operational_paths as _rb_paths, logical_path as _rb_logical, acquire_writer_lease as _rb_writer_lease
if __name__ == '__main__':
    _rb_writer_lease()
import hashlib,json,os,selectors,signal,subprocess,time,uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]

def run(args,**kw):return subprocess.run(args,check=True,text=True,capture_output=True,**kw)
def inspect(path):
    result=run([str((_rb_paths()['substrate'] / 'inspect')),str(path)])
    return {bytes.fromhex(k).decode():bytes.fromhex(v).decode() for k,v in (line.split('\t') for line in result.stdout.splitlines())}
def invariant(rows):
    if 'p/1' in rows and rows.get('m/sequence')!='1':return 'pending_without_sequence'
    if 'r/1' in rows and 'p/1' in rows:return 'receipt_with_pending'
    if 'r/1' in rows and (rows.get('m/checkpoint')!='1' or rows.get('m/outstanding')!='0'):return 'receipt_without_checkpoint_or_accounting'
    if 'p/1' in rows and rows.get('m/outstanding')!='1':return 'pending_without_accounting'
    return None

def trial(base,variant,operation,boundary,kill=False):
    root=base/f'{variant}-{operation}-{boundary}-{uuid.uuid4().hex[:6]}';root.mkdir()
    db=root/'db';trace=root/'events.jsonl';release=root/'release'
    if operation=='terminal':run([str((_rb_paths()['substrate'] / 'probe')),str(db),'admit'])
    env={**os.environ,'LD_PRELOAD':str((_rb_paths()['substrate'] / 'interpose.so')),'RN_TRACE':str(trace),'RN_BARRIER':boundary,'RN_TRANSITION':('p/1' if operation=='admit' else 'r/1'),'RN_RELEASE':str(release)}
    with (root/'stderr').open('w') as stderr:
        p=subprocess.Popen([str((_rb_paths()['substrate']/variant)),str(db),operation],env=env,stdout=subprocess.PIPE,stderr=stderr,text=True)
        deadline=time.monotonic()+10
        try:
            while time.monotonic()<deadline:
                events=[json.loads(x) for x in trace.read_text().splitlines()] if trace.exists() else []
                if any(e['phase']=='barrier_held' and e['transition']==env['RN_TRANSITION'] for e in events):break
                if p.poll() is not None:raise RuntimeError('process exited without required interception')
                time.sleep(.005)
            else:raise RuntimeError('missing required interposition boundary '+boundary)
            sel=selectors.DefaultSelector();sel.register(p.stdout,selectors.EVENT_READ)
            early=bool(sel.select(.1));ack=p.stdout.readline().strip() if early else None
            if kill:p.kill()
            else:release.touch()
            tail=p.communicate(timeout=10)[0]
        finally:
            if p.poll() is None:p.kill();p.wait()
    rows=inspect(db)
    events=[json.loads(x) for x in trace.read_text().splitlines()]
    writes=[e for e in events if e['phase']=='write_enter']
    syncs=[e for e in events if e['phase']=='wal_sync_enter' and e['transition']==env['RN_TRANSITION']]
    return {'variant':variant,'operation':operation,'boundary':boundary,'killed':kill,'ack_while_return_withheld':bool(ack),'ack':ack or tail.strip(),'rows':rows,'invariant_failure':invariant(rows),'sync_options_valid':bool(writes) and all(e['sync']==1 and e['wal']==1 for e in writes),'correlated_wal_syncs':syncs,'returncode':p.returncode,'trace_sha256':hashlib.sha256(trace.read_bytes()).hexdigest(),'local_diagnostics':_rb_logical(root)}

def main():
    base=(_rb_paths()['substrate'])/('storage-probe-'+time.strftime('%Y%m%dT%H%M%S'));base.mkdir()
    for name,macro in [('probe',None),('early','EARLY_ACK'),('torn_admit','TORN_ADMIT'),('torn_terminal','TORN_TERMINAL')]:
        run(['gcc','-Wall','-Wextra','-Werror',*( ['-D'+macro] if macro else []),'native/probe.c','-lrocksdb','-o',str((_rb_paths()['substrate']/name))],cwd=ROOT)
    rows=[]
    for op in ['admit','terminal']:
        rows.append(trial(base,'probe',op,'native_success'))
        for boundary in ['write_enter','wal_sync_enter','native_success']:rows.append(trial(base,'probe',op,boundary,True))
    rows.append(trial(base,'early','admit','native_success'))
    rows.append(trial(base,'torn_admit','admit','native_success',True))
    rows.append(trial(base,'torn_terminal','terminal','native_success',True))
    # Unaffected controls use the other transition, or allow both split writes to finish.
    rows.append(trial(base,'torn_admit','admit','native_success'))
    rows.append(trial(base,'torn_terminal','terminal','native_success'))
    expected={'early':'early_durable_ack','torn_admit':'pending_without_sequence','torn_terminal':'receipt_with_pending'}
    for r in rows:
        r['observed_failure']='early_durable_ack' if r['ack_while_return_withheld'] else r['invariant_failure']
        target=expected.get(r['variant']) if r['variant']=='early' or r['killed'] else None
        r['expected_failure']=target;r['test_passed']=r['observed_failure']==target and r['sync_options_valid']
    # Post-ack kill: keep process alive externally is a separate future service gate.
    lib=Path('/usr/lib/aarch64-linux-gnu/librocksdb.so').resolve()
    result={'schema':'rosettanode.substrate.storage_probe.v1','status':'passed' if all(r['test_passed'] for r in rows) else 'failed','scope':'preliminary synchronous C write probe; not service Gate A/B','library':{'path':str(lib),'sha256':hashlib.sha256(lib.read_bytes()).hexdigest(),'elf_notes':run(['readelf','-n',str(lib)]).stdout,'packages':run(['dpkg-query','-W','librocksdb7.8','librocksdb-dev']).stdout,'package_sha256':Path('/packages/SHA256SUMS').read_text()},'trials':rows,'unproven':['socket protocol','cancel boundary','conflicting digest','arena lifetime','after-ack kill','complete mutation matrix','Gate B','candidate isolation'],'candidate_launch_allowed':False}
    (base/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    (ROOT/'evidence/storage-probe.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({'status':result['status'],'trials':len(rows),'failures':[r for r in rows if not r['test_passed']]}))
    return 0 if result['status']=='passed' else 1
if __name__=='__main__':raise SystemExit(main())
