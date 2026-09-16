"""Audit designated AArch64 hot functions for accidental field-kernel calls."""
import re

FUNCTION = re.compile(r'^\s*\.type\s+([^,\s]+),\s*[@%]function\s*$', re.M)
BRANCH = re.compile(r'^\s*(bl|b)\s+("[^"\n]+"|[A-Za-z_.$][\w.$]*)\s*(?://.*)?$', re.M)
FIELD = re.compile(r'(?:field(?:52)?\.|(?:^|\.)root\.)(?:.*\.)?(?:mul|multiply|square|add|sub|subtract|weak|finish|product|reduceField)(?:$|__)')


def audit(text, hot_pattern=r'chain(?:$|__)'):
    aliases = {a.strip(chr(34)):b.strip(chr(34)) for a,b in re.findall(r'^\s*\.(?:set|equ)\s+("[^"\n]+"|[\w.$]+),\s*("[^"\n]+"|[\w.$]+)\s*$', text, re.M)}
    functions = []
    failures = []
    for match in FUNCTION.finditer(text):
        name = match.group(1)
        if not re.search(hot_pattern, name):
            continue
        end = re.search(r'^\s*\.size\s+' + re.escape(name) + r'\s*,', text[match.end():], re.M)
        if not end:
            raise ValueError('Missing function boundary: ' + name)
        body = text[match.end():match.end()+end.start()]
        functions.append(name)
        for branch, target in BRANCH.findall(body):
            target = target.strip(chr(34))
            seen = set()
            while target in aliases:
                if target in seen:
                    raise ValueError('Cyclic assembly alias')
                seen.add(target)
                target = aliases[target]
            if FIELD.search(target):
                failures.append({'function':name,'branch':branch,'target':target})
        if re.search(r'^\s*(?:blr|br)\s+x\d+',body,re.M):
            failures.append({'function':name,'target':'unresolved indirect branch'})
    if not functions:
        raise ValueError('No designated hot functions found')
    return {'hot_functions':functions,'unexpected_calls':failures,'passed':not failures}
