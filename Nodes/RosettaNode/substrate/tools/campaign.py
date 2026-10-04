#!/usr/bin/env python3
"""Parent controller: frozen instruments, isolated fresh sessions, retained attempts."""

import sys as _rb_sys
from pathlib import Path as _RBPath
_rb_sys.path.insert(0, str(_RBPath(__file__).resolve().parents[4] / 'Project/scripts'))
from state_root import operational_paths as _rb_paths, logical_path as _rb_logical, acquire_writer_lease as _rb_writer_lease
if __name__ == '__main__':
    _rb_writer_lease()
import argparse,hashlib,json,os,re,shutil,signal,subprocess,time,uuid
from pathlib import Path
from isolation_probe import CODEX,config,toml,sandbox
from build import ROOT,parent_check
MODEL='gpt-6-astra'
BASE=(_rb_paths()['substrate'] / 'campaign')
EXCLUDE={'cache','target','.zig-cache','zig-out','tmp','home','queue','.git','__pycache__'}
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def save(p,data):p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(data,indent=2)+'\n')
def frozen():
    f=json.loads((ROOT/'evidence/campaign-freeze.json').read_text())
    for name,h in f['files'].items():assert digest(ROOT/name)==h,('frozen file changed',name)
    for name,h in f['evidence'].items():assert digest(ROOT/f'evidence/{name}.json')==h,('frozen evidence changed',name)
    for name,h in f['native_objects'].items():assert digest(ROOT/name)==h,('frozen native object changed',name)
    assert parent_check();return f

def snapshot(work,dest):
    dest.mkdir(parents=True);manifest={}
    for p in sorted(work.rglob('*')):
        rel=p.relative_to(work)
        if any(x in EXCLUDE or x.startswith('substrate-public-') for x in rel.parts):continue
        if p.is_symlink():raise ValueError('symlink submission: '+str(rel))
        if p.is_file():
            if p.stat().st_size>128<<20:raise ValueError('oversized submission file '+str(rel))
            q=dest/rel;q.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,q);manifest[str(rel)]=digest(q)
    save(dest.parent/(dest.name+'-manifest.json'),manifest);return manifest

def audit(work):
    checks=[]
    for target in [ROOT/'native/dummy.c',ROOT/'tools/candidate_eval.py',ROOT.parent/'spec/transactions.md',ROOT.parents[1]/'Zig/src/root.zig',Path.home()/'.codex/config.toml']:
        p=sandbox(work,['/bin/cat',str(target)]);checks.append({'probe':str(target),'passed':p.returncode!=0 and 'Operation not permitted' in p.stderr})
    for url in ['https://1.1.1.1','http://127.0.0.1:48332']:
        p=sandbox(work,['/usr/bin/curl','--max-time','2','-sS',url]);checks.append({'probe':url,'passed':p.returncode!=0})
    assert all(x['passed'] for x in checks),checks
    return checks

def phase(work,logs,name,prompt,seconds,thread=None,reading=False):
    values=config(work)
    if reading:values['permissions.substrate.filesystem']={':minimal':'read',str(work):'read',str(work/'tmp'):'write',str(work/'queue'):'write'}
    stop=logs/(name+'.broker-stop');blog=(logs/(name+'.broker.log')).open('w')
    broker=subprocess.Popen(['python3',str(ROOT/'tools/broker.py'),str(work),str((_rb_paths()['substrate'] / 'adapter-bundle')),str(stop),*(['--reading'] if reading else [])],stdout=blog,stderr=blog)
    flags=[x for k,v in values.items() for x in ['-c',k+'='+toml(v)]]
    common=['--ignore-user-config','--ignore-rules','--skip-git-repo-check','--json','-m',MODEL,*flags]
    cmd=[CODEX,'exec',*common,'-C',str(work),prompt] if thread is None else [CODEX,'exec','resume',*common,thread,prompt]
    start=time.monotonic();timeout=False
    try:
        with (logs/(name+'.jsonl')).open('w') as out,(logs/(name+'.stderr')).open('w') as err:
            p=subprocess.Popen(cmd,cwd=work,stdin=subprocess.DEVNULL,stdout=out,stderr=err,start_new_session=True)
            try:code=p.wait(timeout=seconds)
            except subprocess.TimeoutExpired:
                timeout=True;os.killpg(p.pid,signal.SIGINT)
                try:code=p.wait(timeout=10)
                except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);code=p.wait()
    finally:
        stop.touch()
        try:broker.wait(timeout=30)
        except subprocess.TimeoutExpired:broker.terminate();broker.wait(timeout=10)
        blog.close()
    events=[]
    for line in (logs/(name+'.jsonl')).read_text().splitlines():
        try:events.append(json.loads(line))
        except ValueError:pass
    threads=[e['thread_id'] for e in events if e.get('type')=='thread.started']
    return {'phase':name,'returncode':code,'timed_out':timeout,'elapsed_seconds':time.monotonic()-start,'limit_seconds':seconds,'thread_id':threads[0] if threads else thread,'usage':[e['usage'] for e in events if e.get('type')=='turn.completed' and 'usage' in e],'temperature':None,'seed':None,'cost':None,'configuration':values,'transcript_sha256':digest(logs/(name+'.jsonl'))}

def prepare(lineage,language,round,predecessor=None):
    root=BASE/lineage/round
    if root.exists():raise RuntimeError('Attempt already exists; use retained status, never replace')
    work=root/'workspace';work.mkdir(parents=True);logs=root/'logs';logs.mkdir()
    if predecessor:
        for p in predecessor.iterdir():
            if p.is_dir():shutil.copytree(p,work/p.name)
            else:shutil.copy2(p,work/p.name)
    else:
        shutil.copytree(ROOT/'bundles'/language,work/'reuse')
        for name in ['README.md','BUILDING.md','public_check.py']:shutil.copyfile(ROOT/'bundles'/name,work/name)
        shutil.copytree(ROOT/'contracts',work/'contracts')
    for name in ['tmp','home','queue','cache']:(work/name).mkdir(exist_ok=True)
    if language=='rust':
        shutil.copytree((_rb_paths()['substrate'] / 'rust-infra/cargo'),work/'cache/cargo',dirs_exist_ok=True)
    shutil.copyfile(ROOT/'tools/candidate_run.py',work/'run.py')
    save(logs/'isolation.json',audit(work));return root,work,logs

def evaluate(submission,output,round,predecessor=None):
    f=frozen();output.mkdir(parents=True);name='rn-substrate-eval-'+uuid.uuid4().hex[:12]
    cmd=['docker','run','--name',name,'--network','none','--security-opt','no-new-privileges','--cpus','4','--memory','4g','--label','rosettanode.substrate=evaluation','-e','RN_CANDIDATE=/candidate/service','-v',str((_rb_paths()['substrate'] / 'adapter-bundle'))+':/adapter:ro','-v',str(submission)+':/candidate:ro','-v',str(output)+':/output']
    if predecessor:cmd+=['-v',str(predecessor)+':/predecessor:ro']
    cmd += [f['evaluator_image'],'python3','tools/candidate_eval.py','--phase',round]
    started=time.monotonic()
    with (output/'log.txt').open('w') as log:
        p=subprocess.Popen(cmd,stdout=log,stderr=log)
        try:code=p.wait(timeout=900)
        except subprocess.TimeoutExpired:subprocess.run(['docker','kill',name],capture_output=True);p.wait();code=124
    # Preserve runtime diagnostics even when the evaluator never produced a result.
    subprocess.run(['docker','cp',name+':/evaluator/.local',str(output/'runtime')],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    if (output/'result.json').exists():result=json.loads((output/'result.json').read_text())
    else:result={'status':'failed','results':[],'infrastructure_error':'evaluator did not produce result'}
    result.update(container=name,exit_code=code,elapsed_seconds=time.monotonic()-started,candidate_started_after_gate_freeze=True)
    if code:result['status']='failed'
    save(output/'result.json',result);return result

def run(lineage,language,round):
    assert re.fullmatch(r'(go|rust|zig)-[12]',lineage) and lineage.startswith(language+'-')
    f=frozen();predecessor=None
    if round!='initial':
        previous='initial' if round=='maintenance' else 'maintenance';old=json.loads((ROOT/f'evidence/lineage-{lineage}-{previous}.json').read_text())
        assert old['status']=='qualified','dependent round prohibited after unresolved gate failure'
        predecessor=Path(old['qualified_submission'])
    root,work,logs=prepare(lineage,language,round,predecessor)
    report={'schema':'rosettanode.substrate.lineage_round.v1','lineage':lineage,'language':language,'round':round,'model':MODEL,'reasoning_effort':'high','freeze_sha256':digest(ROOT/'evidence/campaign-freeze.json'),'status':'reading','attempts':[]}
    path=ROOT/f'evidence/lineage-{lineage}-{round}.json';save(path,report)
    intro=f'You are an independent {language} substrate trial participant. This is a fresh {round} round. Read contracts/, README.md, BUILDING.md, reuse/, and any predecessor HANDOFF.md. The common native adapter is read-only at /adapter inside the Linux broker. Use python3 run.py to read pinned offline standard-library documentation. You have up to 10 minutes for reading; finish early if ready. Do not implement yet. Do not inspect other workspaces, evaluator, repository, network, or Bitcoin libraries. Record questions as ambiguities rather than asking the user. Return concise private notes for the next phase.'
    reading=phase(work,logs,'reading',intro,600,reading=True);report['reading']=reading;save(path,report)
    if reading['returncode'] or not reading['thread_id']:
        report['status']='reading_failed';save(path,report);return report
    objective={'initial':'Implement ABI v1 with normal-priority service and baseline one-job WriteBatches. Do not implement ABI v2 yet.','maintenance':'Upgrade the predecessor to ABI v2 and deterministic priority scheduling, preserving v1 datadirs and all durability behavior.','optimization':'Optimize the qualified v2 predecessor with at most three recorded hypotheses including bounded group commit as one. No rewrite or kernel replacement. Record baseline, experiments, failed ideas and final choices in EXPERIMENTS.md.'}[round]
    limit=5400 if round=='initial' else 3600
    prompt=f'Implementation phase starts now. {objective} Follow every supplied contract. Build/test through python3 run.py only. Deliver build.sh, Linux service executable, source, tests, HANDOFF.md and EXPERIMENTS.md. Use only the supplied infrastructure and offline docs. No external sources, other agents, Bitcoin libraries or evaluator access. You have at most {limit//60} minutes; finish early when ready. Your initial submission freezes on return, before evaluator feedback.'
    implementation=phase(work,logs,'implementation',prompt,limit,reading['thread_id']);report['implementation']=implementation
    submission=root/'submission';report['source_sha256']=snapshot(work,submission);report['status']='submitted';save(path,report)
    initial_v1=predecessor
    if round=='optimization':initial_v1=Path(json.loads((ROOT/f'evidence/lineage-{lineage}-initial.json').read_text())['qualified_submission'])
    result=evaluate(submission,root/'evaluation',round,initial_v1);report['attempts'].append({'kind':'initial_submission','evaluation':str(root/'evaluation/result.json'),'status':result['status']});save(path,report)
    if result['status']!='passed' and round!='optimization':
        failures=[{'family':r['family'],'error':r['error'],'detail':r['detail']} for r in result.get('results',[]) if not r['passed']]
        save(work/'feedback.json',{'failed_families':failures,'infrastructure_error':result.get('infrastructure_error'),'note':'Bounded evaluator observations; no evaluator source or other candidate code.'})
        repair=phase(work,logs,'repair','Separate 15-minute repair reserve. Read feedback.json and correct the identified contract failures. All restrictions and durability guarantees remain. Retain source and failure notes. Finish early when ready.',900,implementation['thread_id']);report['repair']=repair
        submission=root/'repair-submission';report['repair_source_sha256']=snapshot(work,submission);save(path,report)
        result=evaluate(submission,root/'repair-evaluation',round,initial_v1);report['attempts'].append({'kind':'repair','evaluation':str(root/'repair-evaluation/result.json'),'status':result['status']})
    report['status']='qualified' if result['status']=='passed' else 'hard_gate_failed'
    report['qualified_submission']=str(submission) if result['status']=='passed' else None
    save(path,report);print(json.dumps({'lineage':lineage,'round':round,'status':report['status']}));return report

def main():
    p=argparse.ArgumentParser();p.add_argument('lineage',choices=[f'{l}-{n}' for l in ['go','rust','zig'] for n in [1,2]]);p.add_argument('round',choices=['initial','maintenance','optimization']);a=p.parse_args();run(a.lineage,a.lineage.split('-')[0],a.round)
if __name__=='__main__':main()
