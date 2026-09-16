#!/usr/bin/env python3
"""Postprocess frozen native events; no measured workload or candidate changes."""
import hashlib,json,statistics,tarfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def summarize(values):
    values=sorted(values)
    return {'count':len(values),'median_ns':statistics.median(values),'p95_ns':values[int((len(values)-1)*.95)],'p99_ns':values[int((len(values)-1)*.99)],'max_ns':values[-1]}
def derive(archive):
    members={};success={}
    with tarfile.open(archive,'r:gz') as tar:
        files=[m for m in tar if m.isfile() and m.name.endswith('/events')];assert len(files)==1,files
        for line in tar.extractfile(files[0]):
            e=json.loads(line)
            if e['phase']=='write_member':members.setdefault(e['call'],set()).add(e['transition'])
            elif e['phase']=='native_success':success[e['call']]=e['ns']
    admitted={};terminal={}
    for call,keys in members.items():
        if call not in success:continue
        for key in keys:
            if key.startswith('p/'):admitted[int(key[2:])]=success[call]
            elif key.startswith('r/'):terminal[int(key[2:])]=success[call]
    assert len(admitted)==len(terminal)==10000 and admitted.keys()==terminal.keys()
    values=[terminal[seq]-admitted[seq] for seq in admitted];assert min(values)>=0
    return summarize(values)
def main():
    rows=[]
    for p in sorted((ROOT/'evidence').glob('repetition-*.json')):
        r=json.loads(p.read_text())
        if r['status']!='passed' or r.get('workload') not in ['3','4']:continue
        retention=r.get('retention',{});archive=retention.get('archive')
        if not archive:continue
        rows.append({'repetition_evidence':p.name,'lineage':r['lineage'],'lane':r['lane'],'workload':r['workload'],'warmup':r['warmup'],'repetition':r['repetition'],'durable_admission_to_terminal':derive(Path(archive))})
    result={'schema':'rosettanode.substrate.lifecycle_latencies.v1','definition':'Native admission WriteBatch success to native terminal WriteBatch success, matched by durable sequence. Complements socket admission round-trip tails; excludes time before durable admission. Process-crash durability only.','records':rows,'analysis_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
    (ROOT/'evidence/lifecycle-latencies.json').write_text(json.dumps(result,indent=2)+'\n')
if __name__=='__main__':main()
