#!/usr/bin/env python3
"""Preliminary socket and crash checks, not the complete launch gate."""
import hashlib,json,os,socket,subprocess,time,uuid
from pathlib import Path
from storage_probe import ROOT,run,inspect
ITEM={'hex':'01000000000000000000','mode':'witness','operation':'exact'}

def invariant(rows):
    import sys
    sys.path.insert(0,str(ROOT/'evaluator'))
    from state import check
    return check(rows)

class Host:
    def __init__(self,base,variant='dummy',boundary=None,transition=None,db=None,per_job=False,extra_env=None):
        self.root=base/(Path(variant).name+'-'+uuid.uuid4().hex[:8]);self.root.mkdir();self.db=db or self.root/'db';self.socket=self.root/'s';self.trace=self.root/'events';self.release=self.root/'release'
        self.stderr=(self.root/'stderr').open('w');self.stdout=(self.root/'stdout').open('w')
        env={**os.environ,'LD_PRELOAD':str(ROOT/'.local/interpose.so'),'RN_TRACE':str(self.trace),'RN_STATS':str(self.root/'rocksdb-stats.txt')}
        env.update(extra_env or {})
        if boundary:env.update(RN_BARRIER=boundary,RN_TRANSITION=transition,RN_RELEASE=str(self.release))
        if per_job:self.release.mkdir();env['RN_RELEASE_DIR']=str(self.release)
        program=str(ROOT/'.local'/variant)
        override=os.environ.get('RN_CANDIDATE')
        if override and variant in ['dummy','dummy_v2']:program=override
        untrusted=program.startswith(('/candidate/','/predecessor/'))
        if untrusted:
            os.chmod(base,0o711);os.chown(self.root,65534,65534)
            if self.release.is_dir():os.chown(self.release,65534,65534)
        def demote():
            os.setgroups([]);os.setgid(65534);os.setuid(65534)
        self.process=subprocess.Popen([program,str(self.db),str(self.socket)],env=env,stdout=self.stdout,stderr=self.stderr,cwd=self.root,preexec_fn=demote if untrusted else None)
        end=time.monotonic()+10
        while not self.socket.exists():
            if self.process.poll() is not None:raise RuntimeError('host failed: '+(self.root/'stderr').read_text())
            if time.monotonic()>end:raise TimeoutError('socket')
            time.sleep(.005)
    def connect(self):
        s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);s.settimeout(3);s.connect(str(self.socket));return s
    def request(self,q):
        with self.connect() as s:
            s.sendall(json.dumps({'request':'probe',**q}).encode()+b'\n');return json.loads(s.makefile('rb').readline())
    def events(self):
        if not self.trace.exists():return []
        # Writer may be in the middle of an append; parse completed lines only.
        return [json.loads(x) for x in self.trace.read_text().splitlines() if x.endswith('}')]
    def barrier(self):
        end=time.monotonic()+5
        while time.monotonic()<end:
            if any(e['phase']=='barrier_held' for e in self.events()):return
            if self.process.poll() is not None:raise RuntimeError('host exited before barrier')
            time.sleep(.005)
        raise TimeoutError('barrier not observed')
    def stop(self,kill=False,inspect_state=True):
        if kill:self.process.kill()
        else:self.request({'op':'shutdown'})
        self.process.wait(timeout=20);self.stderr.close();self.stdout.close()
        if not kill:assert self.process.returncode==0,('unclean shutdown',self.process.returncode)
        return inspect(self.db) if inspect_state else None

def main():
    base=ROOT/'.local'/('service-probe-'+time.strftime('%Y%m%dT%H%M%S'));base.mkdir()
    for name,macro in [('dummy',None),('dummy_early','EARLY_ACK'),('dummy_torn','TORN_ADMIT'),('dummy_terminal','TORN_TERMINAL'),('dummy_conflict','ID_CONFLICT'),('dummy_cancel','LATE_CANCEL'),('dummy_v2','ABI_V2'),('dummy_starve','STARVE_NORMAL')]:
        run(['gcc','-g','-Wno-deprecated-declarations',*(['-D'+macro] if macro else []),*(['-DABI_V2'] if name=='dummy_starve' else []),'native/dummy.c','-L.local','-l:adapter.so','-Wl,-rpath,/work/.local','-lrocksdb','-ljson-c','-lcrypto','-lpthread','-o',str(ROOT/'.local'/name)],cwd=ROOT)
    results=[]
    for variant in ['dummy','dummy_early','dummy_torn','dummy_terminal']:
        terminal=variant=='dummy_terminal';h=Host(base,variant,'native_success',('r/' if terminal else 'p/')+'00000000000000000001')
        try:
            with h.connect() as s:
                s.sendall(json.dumps({'request':'a','op':'submit','id':'job','items':[ITEM]}).encode()+b'\n');h.barrier();s.settimeout(.15)
                try:ack=json.loads(s.makefile('rb').readline())
                except TimeoutError:ack=None
            rows=h.stop(kill=True);problem=invariant(rows)
            if variant=='dummy':passed=ack is None and problem is None
            elif variant=='dummy_early':passed=ack is not None and ack['status']=='accepted'
            else:passed=problem is not None
            results.append({'variant':variant,'test':'held_native_return_then_kill','passed':passed,'ack':ack,'recovered_rows':rows,'invariant_failure':problem,'events':h.events()})
        finally:
            if h.process.poll() is None:h.process.kill();h.process.wait()
    for variant in ['dummy','dummy_conflict','dummy_cancel','dummy_v2']:
        h=Host(base,variant)
        try:
            assert h.request({'op':'status','id':'absent'})['status']=='not_found'
            assert h.request({'op':'cancel','id':'absent'})['status']=='not_found'
            assert h.request({'op':'submit','id':'job','items':[ITEM]})['status']=='accepted'
            end=time.monotonic()+5
            while h.request({'op':'status','id':'job'})['job']['state']!='complete':
                if time.monotonic()>end:raise TimeoutError('terminal')
            retry=h.request({'op':'submit','id':'job','items':[ITEM]})
            conflict=h.request({'op':'submit','id':'job','items':[{**ITEM,'hex':'02000000000000000000'}]})
            cancel=h.request({'op':'cancel','id':'job'})
            rows=h.stop();problem=invariant(rows)
            passed=retry['status']=='existing' and conflict['status']==('existing' if variant=='dummy_conflict' else 'conflict') and cancel['status']==('ok' if variant=='dummy_cancel' else 'too_late') and problem is None
            results.append({'variant':variant,'test':'retry_conflict_terminal_cancel_unknown','passed':passed,'retry':retry,'conflict':conflict,'cancel':cancel,'invariant_failure':problem})
        finally:
            if h.process.poll() is None:h.process.kill();h.process.wait()
    result={'schema':'rosettanode.substrate.service_probe.v1','status':'passed' if all(r['passed'] for r in results) else 'failed','scope':'preliminary; terminal cancellation test is post-completion, not concurrent boundary qualification','results':results,'candidate_launch_allowed':False}
    (base/'result.json').write_text(json.dumps(result,indent=2)+'\n');(ROOT/'evidence/service-probe.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({'status':result['status'],'tests':len(results)}));return int(result['status']!='passed')
if __name__=='__main__':raise SystemExit(main())
