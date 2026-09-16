#!/usr/bin/env python3
"""Evaluate frozen source in the same denied-read/network sandbox, without a model."""
import argparse,collections,json,shutil,time
from pathlib import Path
from cohort import ROOT,BASE,GO,sandbox,h,audit
from corpus import cases,matches,identity
from chain_checker import Reader,transaction,check_block,serialize

def build(work):
    files=sorted(p.name for p in work.glob('*.go') if not p.name.endswith('_test.go'))
    if not files:return {'status':'build_failure','detail':'no Go source'}
    deps=sandbox(work,[GO+'/bin/go','list','-deps','-f','{{if not .Standard}}{{.ImportPath}}{{end}}',*files],timeout=120)
    nonstd=[x.strip() for x in deps.stdout.splitlines() if x.strip() and x.strip()!='command-line-arguments']
    if deps.returncode or nonstd:return {'status':'dependency_failure','detail':deps.stderr,'nonstandard':nonstd}
    result=sandbox(work,[GO+'/bin/go','build','-o','candidate',*files],timeout=120)
    if result.returncode:return {'status':'build_failure','detail':result.stderr}
    return {'status':'ok','binary_sha256':h(work/'candidate')}

def execute(work,requests,timeout=60):
    result=sandbox(work,[str(work/'candidate')],input=''.join(json.dumps(r,separators=(',',':'))+'\n' for r in requests),timeout=timeout)
    lines=result.stdout.splitlines();outputs=[]
    for i in range(len(requests)):
        try:out=json.loads(lines[i])
        except (IndexError,ValueError):out={'infrastructure':'missing_or_invalid_response'}
        outputs.append(out)
    return outputs,{'returncode':result.returncode,'stderr':result.stderr,'extra_response_lines':max(0,len(lines)-len(requests))}

def profile_oracle(req):
    """Independent decoder oracle for bounded counterexample reduction only."""
    data=bytes.fromhex(req['bytes']);offset=int(req.get('offset','0'))
    if offset>len(data):return {'status':'invalid_request'}
    if len(data)>8*1024*1024:return {'status':'transport_limit'}
    data=data[offset:]
    if len(data)>4*1024*1024:return {'status':'admission_limit'}
    r=Reader(data)
    try:tx=transaction(r,req['mode']=='witness')
    except ValueError:return {'status':'malformed_encoding'}
    if req['op']=='decode_exact' and r.pos!=len(data):return {'status':'malformed_encoding'}
    items=len(tx['inputs'])+len(tx['outputs'])+sum(len(v['witness']) for v in tx['inputs'])
    if items>int(req.get('limits',{}).get('max_items','4096')):return {'status':'resource_limit'}
    return {'status':'ok','transaction':tx,'consumed':str(r.pos)}

def minimize(work,row,max_trials=24):
    # Preserve expected outcome category; bound evaluator effort explicitly.
    req=dict(row['request']);expected=row['expected'];trials=0
    if req['op'].startswith('decode'):
        raw=bytes.fromhex(req['bytes']);chunk=max(1,len(raw)//2)
        while chunk and trials<max_trials:
            reduced=False
            for start in range(0,len(raw),chunk):
                if trials>=max_trials:break
                trial=dict(req,bytes=(raw[:start]+raw[start+chunk:]).hex())
                oracle=profile_oracle(trial)
                if oracle['status']!=expected['status']:continue
                actual,_=execute(work,[trial],timeout=10);trials+=1
                if not matches(actual[0],oracle):req=trial;raw=bytes.fromhex(req['bytes']);expected=oracle;reduced=True;break
            if not reduced:chunk//=2
    return {'request':req,'expected':expected,'reduction_trials':trials,'method':'bounded deletion reduction preserving expected outcome category' if req['op'].startswith('decode') else 'smallest failing structured case in frozen corpus; no structural reducer','globally_minimal':False}

def evaluate(attempt,phase='initial'):
    attempt_root=BASE/attempt;source=attempt_root/phase;work=attempt_root/(phase+'-evaluation');work.mkdir()
    for folder in ['tmp','cache']:(work/folder).mkdir()
    for p in source.glob('*.go'):
        if p.is_symlink():raise RuntimeError('symlink forbidden')
        shutil.copyfile(p,work/p.name)
    checks=audit(work);built=build(work)
    report={'schema':'rosettanode.evaluation.v1','attempt':attempt,'phase':phase,'build':built,'isolation':checks,'matrix':{},'semantic_families':{},'groups':{},'feedback':[]}
    rows=cases();start=time.monotonic()
    if built['status']=='ok':
        outputs,execution=execute(work,[r['request'] for r in rows]);report['execution']=execution
        for row,actual in zip(rows,outputs):report['matrix'][row['id']]={'pass':matches(actual,row['expected']),'group':row['family'],'family':row['semantic_family'],'actual':actual}
        failing=collections.defaultdict(list)
        for row in rows:
            if not report['matrix'][row['id']]['pass']:failing[row['semantic_family']].append(row)
        for family,failed in failing.items():
            smallest=min(failed,key=lambda r:len(json.dumps(r['request'])));report['feedback'].append({'family':family,**minimize(work,smallest)})
        chain_pass=chain_total=0;chain_failures=[]
        # Family score stays one family regardless of chain transaction count.
        for group in ['shared','reference']:
            requests=[];expected=[]
            def append(tx,raw):
                items=len(tx['inputs'])+len(tx['outputs'])+sum(len(v['witness']) for v in tx['inputs'])
                requests.append({'op':'decode_exact','mode':'witness','bytes':raw.hex()})
                expected.append({'status':'resource_limit'} if items>4096 else {'status':'ok','transaction':tx,'consumed':str(len(raw))})
                if items<=4096:
                    requests.append({'op':'identify','transaction':tx});expected.append(identity(tx))
            for path in sorted((ROOT/f'.local/blocks/{group}').glob('*.hex')):check_block(bytes.fromhex(path.read_text().strip()),append)
            for start_batch in range(0,len(requests),250):
                actuals,_=execute(work,requests[start_batch:start_batch+250],timeout=30)
                for index,(actual,exp) in enumerate(zip(actuals,expected[start_batch:start_batch+250])):
                    passed=matches(actual,exp);chain_total+=1;chain_pass+=int(passed)
                    if not passed and len(chain_failures)<3:chain_failures.append({'group':group,'index':start_batch+index,'expected_status':exp['status'],'actual_status':actual.get('status') if isinstance(actual,dict) else None})
        report['chain']={'passed':chain_pass,'total':chain_total,'examples':chain_failures,'claim':'valid-chain parse/hash composition only'}
    else:
        for row in rows:report['matrix'][row['id']]={'pass':False,'group':row['family'],'family':row['semantic_family']}
        report['chain']={'passed':0,'total':0,'not_run':'candidate build failed'}
    families=collections.defaultdict(list);groups=collections.defaultdict(list)
    for row in report['matrix'].values():families[(row['group'],row['family'])].append(row['pass'])
    for (group,family),outcomes in families.items():
        score=sum(outcomes)/len(outcomes);report['semantic_families'][family]={'group':group,'passed':sum(outcomes),'total':len(outcomes),'score':score};groups[group].append(score)
    report['groups']={g:sum(v)/len(v) for g,v in groups.items()}
    report['groups']['valid_chain']=report['chain']['passed']/report['chain']['total'] if report['chain']['total'] else 0
    report['elapsed_seconds']=time.monotonic()-start
    report['source_sha256']={p.name:h(p) for p in source.glob('*.go')}
    # Keep verbose outputs local. Compact evidence retains full pass/fail matrix.
    (attempt_root/(phase+'-evaluation.json')).write_text(json.dumps(report,indent=2)+'\n')
    compact=json.loads(json.dumps(report))
    for row in compact['matrix'].values():row.pop('actual',None)
    (ROOT/f'evidence/evaluation-{attempt}-{phase}.json').write_text(json.dumps(compact,indent=2)+'\n')
    return compact
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('attempt');p.add_argument('--phase',default='initial',choices=['initial','repair']);a=p.parse_args();v=evaluate(a.attempt,a.phase);print(json.dumps({'attempt':a.attempt,'phase':a.phase,'build':v['build'],'groups':v['groups']}))
