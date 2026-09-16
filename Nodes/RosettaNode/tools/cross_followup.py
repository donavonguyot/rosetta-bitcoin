#!/usr/bin/env python3
"""Separate repair/reproduction operations; never modify a frozen initial source."""
import argparse,json,shutil,types
import cohort
from cohort import ROOT,BASE,h
from cross_language import activate,build_command,freeze

def evaluator(language):
    freeze();info=activate(language)
    original=ROOT/'tools/evaluate_attempt.py'
    frozen=json.loads((ROOT/'evidence/cohort-freeze.json').read_text())
    assert h(original)==frozen['evaluator_sources']['tools/evaluate_attempt.py']
    module=types.ModuleType('cross_followup_evaluator');module.__file__=str(original)
    text=original.read_text().replace("glob('*.go')",f"glob('*.{info['extension']}')")
    exec(compile(text,str(original),'exec'),module.__dict__)
    def build(work):
        result=cohort.sandbox(work,build_command(language,info['entry'],'candidate'),timeout=120)
        if result.returncode:return {'status':'build_failure','detail':result.stderr}
        return {'status':'ok','binary_sha256':h(work/'candidate'),'language':language,'dependencies':'standard library only; compiler invocation has no external package inputs'}
    module.build=build
    return module,info

def repair(attempt):
    freeze()
    path=ROOT/f'evidence/attempt-{attempt}.json';record=json.loads(path.read_text())
    if record['repair'] is not None:raise RuntimeError('Repair already attempted')
    info=activate(record['language']);work=BASE/attempt/'workspace';logs=BASE/attempt/'logs'
    evaluation=json.loads((ROOT/f'evidence/evaluation-{attempt}-initial.json').read_text())
    if not record['initial'] or not record['initial']['thread_id']:raise RuntimeError('No initial session to repair')
    feedback={'counterexamples':evaluation['feedback'],'build':evaluation['build'] if evaluation['build']['status']!='ok' else {'status':'ok'}}
    (work/'feedback.json').write_text(json.dumps(feedback,indent=2)+'\n')
    result=cohort.phase(work,logs,'repair','Separate repair phase, not part of the initial transfer measurement. Read feedback.json for bounded minimized counterexamples (structured examples are the smallest failing corpus cases). You have up to 30 minutes to repair your implementation using only your existing materials and this feedback. The same target-standard-library and isolation restrictions apply. Follow language.md. Do not ask questions. Finish early when ready.',1800,record['initial']['thread_id'])
    destination=BASE/attempt/'repair';destination.mkdir()
    for source in work.glob('*.'+info['extension']):
        if source.is_symlink():raise RuntimeError('Symlink forbidden')
        shutil.copyfile(source,destination/source.name)
    record['repair']=result;record['repair_source_sha256']={p.name:h(p) for p in destination.iterdir()}
    path.write_text(json.dumps(record,indent=2)+'\n')
    return {'attempt':attempt,'repair':result}

def reproduce(attempt,phase):
    record=json.loads((ROOT/f'evidence/attempt-{attempt}.json').read_text())
    module,info=evaluator(record['language']);other='reproduce-'+phase+'-'+attempt
    source=BASE/attempt/phase;dest=BASE/other/'initial';dest.mkdir(parents=True)
    for path in source.glob('*.'+info['extension']):shutil.copyfile(path,dest/path.name)
    module.evaluate(other)
    before=json.loads((BASE/attempt/(phase+'-evaluation.json')).read_text());after=json.loads((BASE/other/'initial-evaluation.json').read_text())
    fields=['matrix','semantic_families','groups','chain','source_sha256']
    left={key:before[key] for key in fields};right={key:after[key] for key in fields}
    assert left==right,'Semantic reproduction drift: '+attempt
    import hashlib
    result={'schema':'rosettanode.cross_reproduction.v1','attempt':attempt,'phase':phase,'status':'passed','semantic_manifest_sha256':hashlib.sha256(json.dumps(left,sort_keys=True).encode()).hexdigest(),'environment':'Fresh source/build/cache directories and sandboxed native processes, same pinned physical host; no model rerun'}
    (ROOT/f'evidence/reproduction-{attempt}-{phase}.json').write_text(json.dumps(result,indent=2)+'\n')
    return result

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('command',choices=['repair','evaluate-repair','reproduce']);p.add_argument('attempt');p.add_argument('--phase',choices=['initial','repair'],default='initial');a=p.parse_args()
    if a.command=='repair':result=repair(a.attempt)
    elif a.command=='reproduce':result=reproduce(a.attempt,a.phase)
    else:
        record=json.loads((ROOT/f'evidence/attempt-{a.attempt}.json').read_text());module,_=evaluator(record['language']);v=module.evaluate(a.attempt,'repair');result={'attempt':a.attempt,'phase':'repair','groups':v['groups'],'build':v['build']}
    print(json.dumps(result))
