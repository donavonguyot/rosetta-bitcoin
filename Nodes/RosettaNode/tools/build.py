#!/usr/bin/env python3
import json,subprocess
from pathlib import Path
from extract import ROOT,extract
from generate_support import generated

def build():
    gate=json.loads((ROOT/'evidence/compactsize-gate.json').read_text())
    assert gate['status']=='passed'
    assert gate['identity']==extract(True,'compactsize'),'CompactSize gate is stale'
    assert json.loads((ROOT/'evidence/session.json').read_text())['gate_budget_satisfied'],'CompactSize budget gate failed'
    for module in ['compactsize','transactions']:extract(True,module)
    assert (ROOT/'generated/support.ll').read_text()==generated()
    lock=json.loads((ROOT/'toolchain.json').read_text())
    out=ROOT/'.local/tx';out.mkdir(parents=True,exist_ok=True)
    module='target triple = "'+lock['target_triple']+'"\ntarget datalayout = "'+lock['data_layout']+'"\n'
    for name in ['support','compactsize','transactions']:module+=(ROOT/f'generated/{name}.ll').read_text()+'\n'
    (out/'module.ll').write_text(module)
    subprocess.run(['opt','-passes=verify,lint','-disable-output',str(out/'module.ll')],check=True)
    for name,opt in [('o0','-O0'),('o2','-O2')]:
        subprocess.run(['clang',opt,'-shared','-fPIC',str(out/'module.ll'),'host/sha256.c','-lcrypto','-o',str(out/f'{name}.so')],cwd=ROOT,check=True)
    print('Built checked transaction modules')
if __name__=='__main__':build()
