#!/usr/bin/env python3

import sys as _rb_sys
from pathlib import Path as _RBPath
_rb_sys.path.insert(0, str(_RBPath(__file__).resolve().parents[4] / 'Project/scripts'))
from state_root import operational_paths as _rb_paths, logical_path as _rb_logical, acquire_writer_lease as _rb_writer_lease
if __name__ == '__main__':
    _rb_writer_lease()
import hashlib,json,os,shutil,subprocess,time,uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
CODEX='/Applications/ChatGPT.app/Contents/Resources/codex'
def toml(v):
    if isinstance(v,dict):return '{'+','.join(json.dumps(k)+'='+toml(x) for k,x in v.items())+'}'
    return json.dumps(v)
def config(work):
    return {'default_permissions':'substrate','permissions.substrate.filesystem':{':minimal':'read',str(work):'write'},'permissions.substrate.network.enabled':False,'project_doc_max_bytes':0,'agents.enabled':False,'web_search':'disabled','features.apps':False,'features.plugins':False,'features.memories':False,'features.browser_use':False,'features.browser_use_external':False,'features.computer_use':False,'features.image_generation':False,'features.hooks':False,'features.workspace_dependencies':False,'approval_policy':'never','allow_login_shell':False,'model_reasoning_effort':'high','shell_environment_policy.inherit':'none','shell_environment_policy.set':{'PATH':'/usr/bin:/bin','TMPDIR':str(work/'tmp')}}
def sandbox(work,args):
    c=config(work);flags=[x for k,v in c.items() for x in ['-c',k+'='+toml(v)]]
    return subprocess.run([CODEX,'sandbox','-P','substrate','-C',str(work),*flags,*args],capture_output=True,text=True,timeout=150,env={**os.environ,**c['shell_environment_policy.set']})
def main():
    work=(_rb_paths()['substrate'])/('isolation-'+uuid.uuid4().hex[:8]);work.mkdir();(work/'tmp').mkdir();(work/'home').mkdir();shutil.copyfile(ROOT/'tools/candidate_run.py',work/'run.py')
    stop=(_rb_paths()['substrate'])/('broker-stop-'+uuid.uuid4().hex);log=(work/'broker.log').open('w')
    broker=subprocess.Popen(['/usr/bin/python3',str(ROOT/'tools/broker.py'),str(work),str((_rb_paths()['substrate'] / 'adapter-bundle')),str(stop)],stdout=log,stderr=log)
    results=[]
    try:
        for target in [ROOT/'tools/service_probe.py',ROOT.parent/'spec/transactions.md',ROOT.parents[1]/'Zig/src/root.zig',Path.home()/'.codex/config.toml']:
            p=sandbox(work,['/bin/cat',str(target)]);results.append({'probe':'deny_read '+str(target),'passed':p.returncode!=0 and 'Operation not permitted' in p.stderr,'exit':p.returncode})
        for url in ['https://1.1.1.1','https://example.com','http://127.0.0.1:48332']:
            p=sandbox(work,['/usr/bin/curl','--max-time','2','-sS',url]);results.append({'probe':'deny_network '+url,'passed':p.returncode!=0,'exit':p.returncode})
        command='go version; rustc --version; zig version; test ! -e /var/run/docker.sock && test ! -e /work/native && test ! -e /Users && test ! -e /adapter/dummy.c && test -r /adapter/adapter.h'
        p=sandbox(work,['/usr/bin/python3',str(work/'run.py'),command]);results.append({'probe':'offline_linux_broker','passed':p.returncode==0 and 'go1.27.1 linux/arm64' in p.stdout and 'rustc 1.98.1' in p.stdout and '0.16.0' in p.stdout,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
    finally:stop.touch();broker.wait(timeout=10);log.close()
    result={'schema':'rosettanode.substrate.isolation_probe.v1','status':'passed' if all(r['passed'] for r in results) else 'failed','checks':results,'configuration':config(work),'candidate_launch_allowed':False,'limits':['repeat before each attempt','no candidate launched; full cohort runner pending']}
    (work/'result.json').write_text(json.dumps(result,indent=2)+'\n');(ROOT/'evidence/isolation-probe.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
if __name__=='__main__':main()
