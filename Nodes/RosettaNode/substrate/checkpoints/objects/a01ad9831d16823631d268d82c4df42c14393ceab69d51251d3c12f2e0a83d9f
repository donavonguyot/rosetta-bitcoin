#!/usr/bin/env python3
"""Candidate-side request client; no Docker access and no network required."""
import json,os,sys,time,uuid
from pathlib import Path
root=Path(__file__).resolve().parent;queue=root/'queue';queue.mkdir(exist_ok=True)
token=uuid.uuid4().hex;path=queue/(token+'.request')
with (queue/(token+'.tmp')).open('x') as f:json.dump({'command':sys.argv[1],'seconds':int(sys.argv[2]) if len(sys.argv)>2 else 120},f)
os.replace(queue/(token+'.tmp'),path)
end=time.monotonic()+330
while not (queue/(token+'.response')).exists():
    if time.monotonic()>end:raise SystemExit('build broker did not respond')
    time.sleep(.1)
r=json.loads((queue/(token+'.response')).read_text());print(r['stdout'],end='');print(r['stderr'],end='',file=sys.stderr);raise SystemExit(r['exit'])
