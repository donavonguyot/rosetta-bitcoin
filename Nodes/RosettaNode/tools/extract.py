#!/usr/bin/env python3
"""Literal extraction: code blocks are copied, never interpreted as prose."""
import argparse, hashlib, json, re
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def extract(check=False, module="compactsize"):
    source=ROOT/f'spec/{module}.md'
    matches=re.findall(r'^```llvm module=([a-z0-9_]+)\n(.*?)^```$',source.read_text(),re.M|re.S)
    if len(matches)!=1 or matches[0][0]!=module:raise ValueError('Expected exactly one named IR module')
    ir=matches[0][1]
    if re.search(r'\b(undef|poison|inbounds|nsw|nuw)\b',ir):raise ValueError('Prohibited IR assumption')
    if re.search(r'^@.*\bglobal\b',ir,re.M):raise ValueError('Mutable global')
    out=ROOT/f'generated/{module}.ll'
    if check:
        if not out.exists() or out.read_text()!=ir:raise ValueError('Generated IR drift')
    else:out.write_text(ir)
    return {'source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'ir_sha256':hashlib.sha256(ir.encode()).hexdigest(),'authored_ir_lines':len(ir.splitlines()),'mechanically_generated_ir_lines':0}
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--check',action='store_true');p.add_argument('--module',default='compactsize');a=p.parse_args();print(json.dumps(extract(a.check,a.module)))
