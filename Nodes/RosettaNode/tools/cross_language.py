#!/usr/bin/env python3
"""Conditional Rust/Zig continuation. Go must be analyzed before any attempt starts."""
import argparse,hashlib,json,os,re,shlex,shutil,subprocess,sys
from pathlib import Path
import cohort
from cohort import ROOT,BASE,h
BASE_CONFIG=cohort.configuration
LANGUAGES={
 'rust':{'version':'1.98.1','root':'/opt/homebrew/Cellar/rust/1.98.1','compiler':'/opt/homebrew/Cellar/rust/1.98.1/bin/rustc','entry':'main.rs','extension':'rs','extra':['/opt/homebrew/opt/llvm@22','/opt/homebrew/opt/zstd','/Library/Developer/CommandLineTools']},
 'zig':{'version':'0.16.0','root':'/opt/homebrew/Cellar/zig/0.16.0_1','compiler':'/opt/homebrew/Cellar/zig/0.16.0_1/bin/zig','entry':'main.zig','extension':'zig','extra':['/opt/homebrew/opt/llvm@21','/opt/homebrew/opt/lld@21','/opt/homebrew/opt/zstd','/Library/Developer/CommandLineTools']}}

def drivers():
    directory=ROOT/'.local/toolchain-wrappers';directory.mkdir(parents=True,exist_ok=True)
    for language,info in LANGUAGES.items():
        libraries=':'.join(str((Path(path).resolve()/'lib')) for path in info['extra'] if path.startswith('/opt/homebrew/'))
        path=directory/('rustc' if language=='rust' else 'zig')
        content='#!/bin/sh\nexec /usr/bin/env '+shlex.quote('DYLD_LIBRARY_PATH='+libraries)+' '+shlex.quote(info['compiler'])+' "$@"\n'
        if not path.exists() or path.read_text()!=content:path.write_text(content)
        path.chmod(0o755)
    return directory

def activate(language):
    info=LANGUAGES[language];driver_dir=drivers()
    def config(work,reading=False):
        value=BASE_CONFIG(work,reading);permissions=value['permissions.rosetta.filesystem'];permissions.pop(cohort.GO,None);permissions[str(driver_dir)]='read'
        for path in [info['root'],*info['extra']]:
            permissions[path]='read';permissions[str(Path(path).resolve())]='read'
        env=value['shell_environment_policy.set'];env['PATH']=str(driver_dir)+':'+str(Path(info['compiler']).parent)+':/usr/bin:/bin';env['ZIG_GLOBAL_CACHE_DIR']=str(work/'cache');env['ZIG_LOCAL_CACHE_DIR']=str(work/'cache/local');env['SDKROOT']='/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk';env['DEVELOPER_DIR']='/Library/Developer/CommandLineTools'
        return value
    cohort.configuration=config
    return info

def build_command(language,entry,output):
    info=LANGUAGES[language]
    return ([str(ROOT/'.local/toolchain-wrappers'/('rustc' if language=='rust' else 'zig')),'--edition=2024','-C','opt-level=2','-C','linker=/Library/Developer/CommandLineTools/usr/bin/clang',entry,'-o',output] if language=='rust' else [str(ROOT/'.local/toolchain-wrappers'/('rustc' if language=='rust' else 'zig')),'build-exe',entry,'-O','ReleaseSafe','-femit-bin='+output])

def freeze():
    driver_dir=drivers()
    analysis=json.loads((ROOT/'evidence/go-initial-result.json').read_text())
    if analysis['missing']:raise RuntimeError('Go cohort incomplete')
    if analysis['cross_language']=='stop_this_packet_version':raise RuntimeError('Go arms reached ceiling; stop this packet version')
    manifest={'schema':'rosettanode.cross_language_freeze.v1','go_freeze_sha256':h(ROOT/'evidence/cohort-freeze.json'),'go_analysis_sha256':h(ROOT/'evidence/go-initial-result.json'),'packet_sha256':h(ROOT/'.local/transaction-book/reconstruction.md'),'interface_sha256':h(ROOT/'spec/interface.md'),'languages':LANGUAGES,'compiler_sha256':{language:h(Path(info['compiler'])) for language,info in LANGUAGES.items()},'sources':{str(p.relative_to(ROOT)):h(p) for p in [ROOT/'tools/cross_language.py',ROOT/'tools/evaluate_cross.py']},'dependency_rule':'Target standard library only; no Bitcoin libraries, reference/evaluator access or network tools','same_semantic_corpus':True,'pool_with_go':False,'driver_sha256':{p.name:h(p) for p in sorted(driver_dir.iterdir()) if p.name in ['rustc','zig']},'model':cohort.MODEL,'reasoning_effort':'high'}
    path=ROOT/'evidence/cross-language-freeze.json'
    if path.exists():assert json.loads(path.read_text())==manifest,'Cross-language freeze drift'
    else:path.write_text(json.dumps(manifest,indent=2)+'\n')
    return manifest

def initial(attempt,language,arm):
    if not re.fullmatch(r'[A-Za-z0-9_-]+',attempt):raise ValueError('Bad attempt ID')
    frozen=freeze();info=activate(language);root=BASE/attempt
    if root.exists():raise RuntimeError('Attempt exists; do not replace')
    work=root/'workspace';logs=root/'logs';work.mkdir(parents=True);logs.mkdir()
    for directory in ['cache','tmp']:(work/directory).mkdir()
    shutil.copyfile(ROOT/'spec/interface.md',work/'interface.md')
    if arm=='document':shutil.copyfile(ROOT/'.local/transaction-book/reconstruction.md',work/'packet.md')
    overlay=f'''This continuation uses {language} {info['version']}. Replace Go-specific language, package and source-file instructions in the shared interface and packet with {language}. Use only the target standard library; no external modules or Bitcoin libraries. Write {info['entry']} and any helper source files in this directory. The JSON-lines operations, field names, encoding conventions and supplied behavioral information are unchanged. Compile with: {' '.join(build_command(language,info['entry'],'candidate'))}. The installed target standard library/toolchain sources are available under {info['root']}. This overlay is identical for document and control arms.\n'''
    (work/'language.md').write_text(overlay)
    warm='fn main() {}\n' if language=='rust' else 'pub fn main() void {}\n'
    warmfile='warm.'+info['extension'];(work/warmfile).write_text(warm)
    result=cohort.sandbox(work,build_command(language,warmfile,'warm'),timeout=120)
    (logs/'preflight.txt').write_text(result.stdout+result.stderr)
    if result.returncode:raise RuntimeError('Toolchain preflight failed: '+result.stderr)
    (work/warmfile).unlink();(work/'warm').unlink()
    checks=cohort.audit(work);(logs/'isolation.json').write_text(json.dumps(checks,indent=2)+'\n')
    material='language.md, interface.md and packet.md' if arm=='document' else 'language.md and interface.md'
    reading=cohort.phase(work,logs,'reading',f'Reading phase of an independent implementation experiment. Read {material}. You have up to 15 minutes to understand the supplied materials. Do not write implementation code or search for other specifications. Return concise private implementation notes and ambiguities; the next phase resumes this session. No external sources, Bitcoin libraries, other agents, or network tools. The workspace is read-only. You may finish reading early.',900)
    record={'schema':'rosettanode.attempt.v1','attempt':attempt,'arm':arm,'language':language,'model':cohort.MODEL,'packet_sha256':frozen['packet_sha256'],'overlay_sha256':h(work/'language.md'),'reading':reading,'initial':None,'repair':None,'status':'reading_failed'}
    path=ROOT/f'evidence/attempt-{attempt}.json';path.write_text(json.dumps(record,indent=2)+'\n')
    if reading['returncode'] or reading['timed_out']:return record
    implementation=cohort.phase(work,logs,'implementation',f'Implementation phase begins. Implement all four JSON-lines operations from the supplied materials in {language}, standard library only, following language.md. Write {info["entry"]} and helper source files directly in this workspace. No external sources, Bitcoin libraries, reference code or execution, evaluator access, other agents, or network tools. You have up to 60 minutes and may finish early. Run your own tests. Do not ask questions; record ambiguities in the final response. Initial submission freezes when you finish.',3600,reading['thread_id'])
    dest=root/'initial';dest.mkdir()
    for source in work.glob('*.'+info['extension']):
        if source.is_symlink():raise RuntimeError('Symlink source forbidden')
        shutil.copyfile(source,dest/source.name)
    record.update(initial=implementation,status='submitted' if implementation['returncode']==0 and not implementation['timed_out'] else 'implementation_failed',source_sha256={p.name:h(p) for p in dest.iterdir() if p.is_file()})
    path.write_text(json.dumps(record,indent=2)+'\n');return record

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('attempt');p.add_argument('language',choices=LANGUAGES);p.add_argument('arm',choices=['document','control']);a=p.parse_args();print(json.dumps(initial(a.attempt,a.language,a.arm)))
