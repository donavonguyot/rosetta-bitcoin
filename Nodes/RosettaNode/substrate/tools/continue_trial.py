#!/usr/bin/env python3
"""Bounded continuation, respecting existing live controllers and owned storage."""

import sys as _rb_sys
from pathlib import Path as _RBPath
_rb_sys.path.insert(0, str(_RBPath(__file__).resolve().parents[4] / 'Project/scripts'))
from state_root import operational_paths as _rb_paths, logical_path as _rb_logical, acquire_writer_lease as _rb_writer_lease
if __name__ == '__main__':
    _rb_writer_lease()
import json,subprocess,time
from pathlib import Path
from campaign_v3 import ROOT,frozen,save
from build import RUNTIME
LINEAGES=['zig-1','go-1','rust-1','zig-2','go-2','rust-2']
def controllers():
    lines=subprocess.check_output(['ps','-axo','pid,command'],text=True).splitlines()
    return [line for line in lines if 'Nodes/RosettaNode/substrate/tools/campaign' in line and any(line.rstrip().endswith(' '+r) for r in ['initial','maintenance','optimization'])]
def record(lineage,round):
    p=ROOT/f'evidence/lineage-v2-{lineage}-{round}.json';return json.loads(p.read_text()) if p.exists() else None

def main():
    frozen();children=[];event_path=ROOT/'evidence/continuation-events.json';events=json.loads(event_path.read_text()) if event_path.exists() else [];last_archive=0
    while True:
        for p,stream in list(children):
            if p.poll() is not None:stream.close();children.remove((p,stream))
        active=controllers()
        if time.monotonic()-last_archive>120:
            with ((_rb_paths()['substrate'] / 'continuation-retention.log')).open('a') as log:subprocess.run(['python3',str(ROOT/'tools/archive_stopped_containers.py')],stdout=log,stderr=log,check=True)
            last_archive=time.monotonic()
        pending=[];unresolved=[]
        for round in ['initial','maintenance','optimization']:
            for lineage in LINEAGES:
                r=record(lineage,round)
                if r:
                    if r['status'] not in ['qualified','hard_gate_failed','reading_failed']:unresolved.append((lineage,round,r['status']))
                    continue
                previous={'maintenance':'initial','optimization':'maintenance'}.get(round)
                prior=record(lineage,previous) if previous else None
                if previous and (not prior or prior['status']!='qualified'):continue
                pending.append((lineage,round))
        if not active and not pending:
            save(ROOT/'evidence/continuation-complete.json',{'events':events,'unresolved':unresolved,'coding_concurrency_cap':2,'next':'audit final sources/diagnostics, reproduce final semantics, then serial measurements'});return
        if len(active)<2 and pending:
            stats=subprocess.check_output(['docker','run','--rm','--network','none',RUNTIME,'df','-Pk','/'],text=True);available=int(stats.splitlines()[-1].split()[3])*1024
            if available<8<<30:raise RuntimeError('Owned cleanup insufficient: Docker storage below 8 GiB; pause launches')
            lineage,round=pending[0];path=(_rb_paths()['substrate'] / 'campaign-controller-v3')/f'{lineage}-{round}.log';path.parent.mkdir(exist_ok=True);stream=path.open('x')
            p=subprocess.Popen(['python3',str(ROOT/'tools/campaign_v3.py'),lineage,round],stdout=stream,stderr=stream);children.append((p,stream));event={'lineage':lineage,'round':round,'controller_pid':p.pid,'available_docker_bytes_before':available,'started_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())};events.append(event);save(ROOT/'evidence/continuation-events.json',events);print(json.dumps(event),flush=True)
            time.sleep(3)
        else:time.sleep(2)
if __name__=='__main__':main()
