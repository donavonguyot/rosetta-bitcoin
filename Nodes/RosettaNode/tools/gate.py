#!/usr/bin/env python3
"""Run the CompactSize prerequisite in a pinned disposable toolchain container."""
import hashlib,json,os,re,subprocess,time
from pathlib import Path
from extract import extract,ROOT
from book import build as book
OUT=ROOT/'.local/gate'
COMMANDS=[]
def run(args,expected=0,timeout=60,env=None):
    start=time.monotonic()
    r=subprocess.run(args,cwd=ROOT,text=True,capture_output=True,timeout=timeout,env=env)
    COMMANDS.append({'argv':list(map(str,args)),'returncode':r.returncode,'elapsed_seconds':time.monotonic()-start})
    (OUT/f'command-{len(COMMANDS):04d}.log').write_text(r.stdout+'\n'+r.stderr)
    if expected is not None and r.returncode!=expected:raise RuntimeError(f'{args}: {r.returncode}\n{r.stdout}\n{r.stderr}')
    return r

def cases():
    fixtures=json.loads((ROOT/'fixtures/compactsize.json').read_text());rows=[]
    for value,h in fixtures['valid']:
        used=len(h)//2
        rows.append((f'decode-{value}',['decode',h],{'status':0,'value':value,'consumed':str(used)}))
        rows.append((f'prefix-{value}',['decode',h+'aabb'],{'status':0,'value':value,'consumed':str(used)}))
        rows.append((f'encode-{value}',['encode',value],{'status':0,'bytes':h,'consumed':str(used)}))
        rows.append((f'capacity-{value}',['encode',value,str(used-1)],{'status':1,'bytes':'a5'*9,'consumed':'987654321'}))
        for n in range(used):rows.append((f'truncated-{value}-{n}',['decode',h[:n*2]],{'status':1,'value':'123456789','consumed':'987654321'}))
    for i,h in enumerate(fixtures['noncanonical']):rows.append((f'noncanonical-{i}',['decode',h],{'status':2,'value':'123456789','consumed':'987654321'}))
    return rows

def evaluate(prefix):
    results={};hits=set()
    for name,args,expected in cases():
        r=run([*prefix,*args]);actual=json.loads(r.stdout)
        results[name]=actual==expected
        hits.update(int(x) for x in re.findall(r'hit:(\d+)',r.stderr))
    return results,hits

def native(ir,name,opt='-O0',sanitize=False,host='host/compactsize.c'):
    run(['opt','-passes=verify','-disable-output',str(ir)])
    args=['clang',opt,host,str(ir),'-o',str(OUT/name)]
    if sanitize:args+=['-fsanitize=address','-fno-omit-frame-pointer','-g']
    run(args);return [str(OUT/name)]

def main():
    OUT.mkdir(parents=True,exist_ok=True);start=time.monotonic();identity=extract(check=True)
    ir=ROOT/'generated/compactsize.ll'
    run(['opt','-passes=verify,lint','-disable-output',str(ir)])
    run(['llvm-as',str(ir),'-o',str(OUT/'core.bc')])
    run(['clang','-O0','-emit-llvm','-c','host/compactsize.c','-o',str(OUT/'host.bc')])
    run(['llvm-link',str(OUT/'core.bc'),str(OUT/'host.bc'),'-o',str(OUT/'jit.bc')])
    builds={'jit':['lli',str(OUT/'jit.bc')],'native_o0':native(ir,'o0'),'native_o2':native(ir,'o2','-O2')}
    # Function attributes make the sanitizer pass apply to authored IR too.
    checked=re.sub(r'(define[^\n]+) \{',r'\1 sanitize_address {',ir.read_text())
    checked_path=OUT/'checked.ll';checked_path.write_text(checked)
    builds['asan']=native(checked_path,'asan',sanitize=True)
    matrix={}
    for name,prefix in builds.items():
        matrix[name],_=evaluate(prefix)
        if not all(matrix[name].values()):raise RuntimeError(f'Unmodified control failed: {name}')
    before='%canonical = icmp uge i64 %decoded, %minimum'
    if ir.read_text().count(before)!=1:raise RuntimeError('Mutation anchor not unique')
    mutant=OUT/'noncanonical.ll';mutant.write_text(ir.read_text().replace(before,'%canonical = icmp uge i64 %decoded, 0'))
    mutation,_=evaluate(native(mutant,'mutant'))
    intended=[k for k in mutation if k.startswith('noncanonical-')]
    controls=[k for k in mutation if not k.startswith('noncanonical-')]
    assert all(not mutation[k] for k in intended) and all(mutation[k] for k in controls)
    # Deliberately remove the read bound: same production decoder, heap boundary.
    bad=OUT/'bad-bound.ll';bad.write_text(checked.replace('%fits = icmp ule i64 %n, %remaining','%fits = icmp ule i64 0, %remaining'))
    badcmd=native(bad,'asan-bad',sanitize=True)
    fault=run([*badcmd,'decode','ff'],expected=None)
    assert fault.returncode!=0 and 'AddressSanitizer: heap-buffer-overflow' in fault.stderr
    # Per-block reachability is inserted only in a disposable copy.
    mappings={};symbol=None
    def instrument(match):
        label,phis=match.group(1),match.group(2)
        idx=len(mappings);mappings[idx]=label.strip()[:-1]
        return label+'\n'+phis+f'  call void @rn_hit(i32 {idx})\n'
    body=re.sub(r'(^[ \t]*[a-zA-Z][a-zA-Z0-9_]*:)[ \t]*\n((?:[ \t]+%[^\n]+ = phi [^\n]+\n)*)',instrument,ir.read_text(),flags=re.M)
    # Labels repeat across functions; attach each block to its enclosing symbol.
    symbol=None
    for line in body.splitlines():
        m=re.match(r'define.*@([^ (]+)',line)
        if m:symbol=m[1]
        m=re.search(r'call void @rn_hit\(i32 (\d+)\)',line)
        if m:
            idx=int(m[1]);mappings[idx]=symbol+':'+mappings[idx]
    instrumented=OUT/'coverage.ll';instrumented.write_text('declare void @rn_hit(i32)\n'+body)
    coverage_host=OUT/'coverage.c';coverage_host.write_text((ROOT/'host/compactsize.c').read_text()+'\nvoid rn_hit(int i){fprintf(stderr,"hit:%d\\n",i);}\n')
    cover,hits=evaluate(native(instrumented,'coverage',host=str(coverage_host)))
    assert all(cover.values())
    assert {mappings[i].split(':')[0] for i in hits}=={'read_le','cs_decode','cs_encode'}
    alive=run(['sh','-c','command -v alive-tv'],expected=None)
    if alive.returncode:
        alive_result={'outcome':'unsupported','reason':'alive-tv is not installed in the pinned toolchain; no translation proof claimed','helper':'read_le','command_returncode':alive.returncode}
    else:
        run(['llvm-extract','--func=read_le',str(OUT/'core.bc'),'-o',str(OUT/'helper.bc')])
        run(['opt','-passes=instcombine',str(OUT/'helper.bc'),'-o',str(OUT/'helper-opt.bc')])
        try:
            r=run([alive.stdout.strip(),str(OUT/'helper.bc'),str(OUT/'helper-opt.bc')],expected=None,timeout=30)
            outcome='verified' if 'Transformation seems to be correct!' in r.stdout and r.returncode==0 else 'unsupported'
            if 'Transformation doesn\'t verify!' in r.stdout:outcome='counterexample'
            alive_result={'outcome':outcome,'stdout':r.stdout,'stderr':r.stderr}
        except subprocess.TimeoutExpired:alive_result={'outcome':'timeout','seconds':30}
    doc=book()
    for name in ['compactsize','reconstruction']:
        run(['pdftotext','-layout',str(ROOT/f'.local/book/{name}.pdf'),str(ROOT/f'.local/book/{name}.txt')])
    result={'schema':'rosettanode.compactsize_gate.v1','status':'passed','identity':identity,'cases_per_build':len(cases()),'matrix':matrix,'mutation':{'applied':True,'case_results':mutation,'intended_kills':intended,'unaffected_controls':controls},'asan':{'clean_control':True,'injected_fault':'heap-buffer-overflow','detected':True},'coverage':{'blocks':mappings,'hit':sorted(hits),'unhit':[v for k,v in mappings.items() if k not in hits]},'alive2':alive_result,'book':doc,'elapsed_seconds':time.monotonic()-start,'commands':COMMANDS,'scope':'CompactSize only; visual document review recorded separately','cost':None}
    (ROOT/'evidence/compactsize-gate.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:result[k] for k in ['status','cases_per_build','elapsed_seconds','alive2','coverage']}))
if __name__=='__main__':main()
