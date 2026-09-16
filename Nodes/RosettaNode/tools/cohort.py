#!/usr/bin/env python3
"""Fresh Codex reading/implementation sessions with audited filesystem profiles.

No evaluator is mounted in a candidate's readable roots. Model traffic belongs
to the Codex controller; all candidate tool networking is disabled.
"""
import argparse,hashlib,json,os,re,signal,shutil,subprocess,time,uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
CODEX='/Applications/ChatGPT.app/Contents/Resources/codex'
GO='/opt/homebrew/Cellar/go/1.27.1/libexec'
MODEL='gpt-6-astra'
BASE=ROOT/'.local/cohort'

def h(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def configuration(work,reading=False):
    permissions={':minimal':'read',str(work):'read' if reading else 'write',GO:'read',str(work/'tmp'):'write',str(work/'cache'):'write'}
    values={'default_permissions':'rosetta','permissions.rosetta.filesystem':permissions,'permissions.rosetta.network.enabled':False,'project_doc_max_bytes':0,'agents.enabled':False,'web_search':'disabled','features.apps':False,'features.plugins':False,'features.memories':False,'features.browser_use':False,'features.browser_use_external':False,'features.computer_use':False,'features.image_generation':False,'features.hooks':False,'features.workspace_dependencies':False,'approval_policy':'never','allow_login_shell':False,'model_reasoning_effort':'high','shell_environment_policy.inherit':'none','shell_environment_policy.set':{'PATH':GO+'/bin:/usr/bin:/bin','TMPDIR':str(work/'tmp'),'GOCACHE':str(work/'cache'),'GOENV':'off','GOTOOLCHAIN':'local','GOPROXY':'off','GOSUMDB':'off','CGO_ENABLED':'0','GO111MODULE':'off'}}
    return values

def toml(value):
    if isinstance(value,dict):return '{'+','.join(json.dumps(k)+'='+toml(v) for k,v in value.items())+'}'
    return json.dumps(value)
def args_for(values):
    return [part for k,v in values.items() for part in ['-c',k+'='+toml(v)]]
def sandbox(work,cmd,timeout=30,reading=False,input=None):
    values=configuration(work,reading)
    return subprocess.run([CODEX,'sandbox','-P','rosetta','-C',str(work),*args_for(values),*cmd],input=input,text=True,capture_output=True,timeout=timeout,env={**os.environ,**values['shell_environment_policy.set']})

def audit(work):
    denied=[ROOT/'spec/transactions.md',ROOT/'tools/corpus.py',ROOT.parent/'Zig/README.md',ROOT.parents[1]/'README.md',Path.home()/'.codex/config.toml']
    checks=[]
    for path in denied:
        result=sandbox(work,['/bin/cat',str(path)])
        checks.append({'probe':'read '+str(path),'exit':result.returncode,'denied':result.returncode!=0 and 'Operation not permitted' in result.stderr})
    for target in ['http://127.0.0.1:48332','https://1.1.1.1','https://example.com']:
        result=sandbox(work,['/usr/bin/curl','--max-time','2','-sS',target])
        checks.append({'probe':'network '+target,'exit':result.returncode,'denied':result.returncode!=0})
    assert all(c['denied'] for c in checks),checks
    return checks

def phase(work,logs,phase_name,prompt,seconds,thread=None):
    values=configuration(work,phase_name=='reading')
    common=['--ignore-user-config','--ignore-rules','--skip-git-repo-check','--json','-m',MODEL,*args_for(values)]
    cmd=[CODEX,'exec',*common,'-C',str(work),prompt] if thread is None else [CODEX,'exec','resume',*common,thread,prompt]
    started=time.monotonic();timed_out=False
    with (logs/(phase_name+'.jsonl')).open('w') as stdout,(logs/(phase_name+'.stderr')).open('w') as stderr:
        process=subprocess.Popen(cmd,cwd=work,stdin=subprocess.DEVNULL,stdout=stdout,stderr=stderr,start_new_session=True)
        try:code=process.wait(timeout=seconds)
        except subprocess.TimeoutExpired:
            timed_out=True;os.killpg(process.pid,signal.SIGINT)
            try:code=process.wait(timeout=10)
            except subprocess.TimeoutExpired:os.killpg(process.pid,signal.SIGKILL);code=process.wait()
    events=[]
    for line in (logs/(phase_name+'.jsonl')).read_text().splitlines():
        try:events.append(json.loads(line))
        except ValueError:pass
    ids=[e['thread_id'] for e in events if e.get('type')=='thread.started']
    usage=[e['usage'] for e in events if e.get('type')=='turn.completed' and 'usage' in e]
    return {'phase':phase_name,'elapsed_seconds':time.monotonic()-started,'limit_seconds':seconds,'timed_out':timed_out,'returncode':code,'thread_id':ids[0] if ids else thread,'usage':usage,'temperature':None,'seed':None,'cost':None,'configuration':values,'events_sha256':h(logs/(phase_name+'.jsonl'))}

def freeze():
    for name in ['compactsize-gate','adversarial','execution-variants','chain-composition','transaction-reproduction']:
        assert json.loads((ROOT/f'evidence/{name}.json').read_text())['status']=='passed',name
    packet=ROOT/'.local/transaction-book/reconstruction.md'
    frozen={'schema':'rosettanode.cohort_freeze.v1','packet_sha256':h(packet),'shared_sha256':h(ROOT/'spec/interface.md'),'evaluator_sources':{str(p.relative_to(ROOT)):h(p) for p in [ROOT/'tools/corpus.py',ROOT/'tools/chain_checker.py',ROOT/'tools/cohort.py',ROOT/'tools/evaluate_attempt.py']},'model':MODEL,'reasoning_effort':'high','language':'go','temperature':None,'seed':None,'reading_seconds':900,'implementation_seconds':3600,'repair_seconds':1800,'attempts_per_arm':3,'primary_result':'initial only; equal weighting of semantic families within each group','interpretation_rule':'observed improvement only if document median family score exceeds control in profile and no lower structured median; no observed improvement at ceiling or equal/lower medians; mixed directions/infrastructure defects inconclusive','cross_language_rule':'Only after completed Go analysis; never pool packet/evaluator versions.'}
    path=ROOT/'evidence/cohort-freeze.json'
    if path.exists():assert json.loads(path.read_text())==frozen,'Frozen materials changed; create a new version rather than overwrite'
    else:path.write_text(json.dumps(frozen,indent=2)+'\n')
    return frozen

def prepare(attempt,arm):
    if not re.fullmatch(r'[A-Za-z0-9_-]+',attempt):raise ValueError('Invalid attempt ID')
    frozen=json.loads((ROOT/'evidence/cohort-freeze.json').read_text())
    assert frozen['packet_sha256']==h(ROOT/'.local/transaction-book/reconstruction.md')
    assert frozen['shared_sha256']==h(ROOT/'spec/interface.md')
    for path,expected in frozen['evaluator_sources'].items():assert h(ROOT/path)==expected,'Frozen evaluator changed'
    root=BASE/attempt
    if root.exists():raise RuntimeError('Attempt already exists; failures are not silently replaced')
    work=root/'workspace';logs=root/'logs';work.mkdir(parents=True);logs.mkdir()
    for folder in ['tmp','cache']:(work/folder).mkdir()
    shutil.copyfile(ROOT/'spec/interface.md',work/'interface.md')
    if arm=='document':shutil.copyfile(ROOT/'.local/transaction-book/reconstruction.md',work/'packet.md')
    # Preinstall/warm only standard library compilation, outside measured phases.
    (work/'warm.go').write_text('package main\nimport("crypto/sha256";"encoding/json";"fmt")\nfunc main(){fmt.Println(sha256.Sum256(nil));_,_=json.Marshal(1)}\n')
    p=sandbox(work,[GO+'/bin/go','build','-o','warm','warm.go'],timeout=120)
    if p.returncode:raise RuntimeError(p.stderr)
    (work/'warm.go').unlink();(work/'warm').unlink()
    checks=audit(work)
    (logs/'isolation.json').write_text(json.dumps(checks,indent=2)+'\n')
    return work,logs,frozen

def initial(attempt,arm):
    work,logs,frozen=prepare(attempt,arm)
    material='interface.md and packet.md' if arm=='document' else 'interface.md'
    reading=phase(work,logs,'reading',f'Reading phase of an independent implementation experiment. Read {material} in this workspace. You have up to 15 minutes to understand the supplied materials. Do not write implementation code or search for other specifications. Return concise private implementation notes and ambiguities; the next phase will resume this same session. Use no external sources, libraries, agents, or network tools. The workspace is read-only during this phase. You may finish reading early.',900)
    report={'schema':'rosettanode.attempt.v1','attempt':attempt,'arm':arm,'language':'go','model':MODEL,'packet_sha256':frozen['packet_sha256'],'reading':reading,'initial':None,'repair':None,'status':'reading_failed'}
    report_path=ROOT/f'evidence/attempt-{attempt}.json'
    report_path.write_text(json.dumps(report,indent=2)+'\n')
    if reading['returncode'] or reading['timed_out'] or not reading['thread_id']:return report
    implementation=phase(work,logs,'implementation','Implementation phase begins now. Implement all four JSON-lines operations from the supplied materials in Go, standard library only. Write main.go and any additional Go sources directly in this workspace. No external sources, Bitcoin libraries, reference code or execution, evaluator access, other agents, or network tools. You have up to 60 minutes, may finish early, and should run your own tests. Do not ask questions; record ambiguities in your final response. Initial submission is frozen when you finish. Do not wait for evaluator feedback.',3600,reading['thread_id'])
    frozen_dir=BASE/attempt/'initial';frozen_dir.mkdir()
    for p in work.glob('*.go'):
        if p.is_symlink():raise RuntimeError('Symlink submission forbidden')
        shutil.copyfile(p,frozen_dir/p.name)
    report.update(initial=implementation,status='submitted' if implementation['returncode']==0 and not implementation['timed_out'] else 'implementation_failed',source_sha256={p.name:h(p) for p in frozen_dir.glob('*.go')})
    report_path.write_text(json.dumps(report,indent=2)+'\n')
    return report

def repair(attempt):
    path=ROOT/f'evidence/attempt-{attempt}.json';report=json.loads(path.read_text())
    if report.get('repair') is not None:raise RuntimeError('Repair already attempted')
    work=BASE/attempt/'workspace';logs=BASE/attempt/'logs'
    evaluation=json.loads((ROOT/f'evidence/evaluation-{attempt}-initial.json').read_text())
    if not report.get('initial') or not report['initial'].get('thread_id'):raise RuntimeError('No initial session to repair')
    feedback={'counterexamples':evaluation['feedback'],'build':evaluation['build'] if evaluation['build']['status']!='ok' else {'status':'ok'}}
    (work/'feedback.json').write_text(json.dumps(feedback,indent=2)+'\n')
    result=phase(work,logs,'repair','Separate repair phase, not part of the initial transfer measurement. Read feedback.json for bounded minimized counterexamples (structured examples are the smallest failing corpus cases). You have up to 30 minutes to repair your implementation using only your existing materials and this feedback. The same standard-library and isolation restrictions apply. Do not ask questions. Finish early when ready.',1800,report['initial']['thread_id'])
    destination=BASE/attempt/'repair';destination.mkdir()
    for source in work.glob('*.go'):
        if source.is_symlink():raise RuntimeError('Symlink forbidden')
        shutil.copyfile(source,destination/source.name)
    report['repair']=result;report['repair_source_sha256']={p.name:h(p) for p in destination.glob('*.go')}
    path.write_text(json.dumps(report,indent=2)+'\n');return report

def main():
    p=argparse.ArgumentParser();sub=p.add_subparsers(dest='command',required=True);sub.add_parser('freeze');run=sub.add_parser('initial');run.add_argument('attempt');run.add_argument('arm',choices=['document','control']);fix=sub.add_parser('repair');fix.add_argument('attempt');a=p.parse_args()
    if a.command=='freeze':print(json.dumps(freeze()))
    elif a.command=='repair':print(json.dumps(repair(a.attempt)))
    else:print(json.dumps(initial(a.attempt,a.arm)))
if __name__=='__main__':main()
