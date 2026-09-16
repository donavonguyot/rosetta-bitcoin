#!/usr/bin/env python3
"""Reuse the frozen semantic evaluator with mechanical source-suffix adaptation."""
import argparse,importlib.util,json,sys,types
from pathlib import Path
from cohort import ROOT,h
from cross_language import activate,build_command,LANGUAGES

def evaluate(attempt):
    record=json.loads((ROOT/f'evidence/attempt-{attempt}.json').read_text());language=record['language'];info=activate(language)
    frozen=json.loads((ROOT/'evidence/cohort-freeze.json').read_text())
    original=ROOT/'tools/evaluate_attempt.py';assert h(original)==frozen['evaluator_sources']['tools/evaluate_attempt.py']
    # Only source discovery changes. Requests, independent expectations,
    # reduction, chain checks and scoring execute the frozen evaluator text.
    text=original.read_text().replace("glob('*.go')",f"glob('*.{info['extension']}')")
    module=types.ModuleType('cross_evaluator');module.__file__=str(original)
    exec(compile(text,str(original),'exec'),module.__dict__)
    def build(work):
        import cohort
        result=cohort.sandbox(work,build_command(language,info['entry'],'candidate'),timeout=120)
        if result.returncode:return {'status':'build_failure','detail':result.stderr}
        return {'status':'ok','binary_sha256':h(work/'candidate'),'language':language,'dependencies':'standard library only; compiler invocation has no external package inputs'}
    module.build=build
    result=module.evaluate(attempt)
    return {'attempt':attempt,'language':language,'groups':result['groups'],'build':result['build']}
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('attempt');a=p.parse_args();print(json.dumps(evaluate(a.attempt)))
