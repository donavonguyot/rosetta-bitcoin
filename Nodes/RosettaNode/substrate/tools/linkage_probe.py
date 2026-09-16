#!/usr/bin/env python3
import hashlib,json,os,subprocess,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def main():
    base=ROOT/'.local'/('linkage-'+time.strftime('%Y%m%dT%H%M%S'));base.mkdir()
    p=subprocess.run([str(ROOT/'.local/probe'),str(base/'db'),'admit'],env={**os.environ,'LD_PRELOAD':str(ROOT/'.local/interpose.so'),'LD_DEBUG':'bindings','RN_TRACE':str(base/'events')},capture_output=True,text=True)
    (base/'loader.log').write_text(p.stderr);bindings=[s.strip() for s in p.stderr.splitlines() if any(x in s for x in ['symbol `rocksdb_write\'','symbol `fdatasync\'','symbol `fsync\''])]
    events=[json.loads(x) for x in (base/'events').read_text().splitlines()];lib=Path('/usr/lib/aarch64-linux-gnu/librocksdb.so').resolve()
    passing=p.returncode==0 and any('interpose.so' in s and 'rocksdb_write' in s for s in bindings) and any('librocksdb.so' in s and 'rocksdb_write' in s for s in bindings) and any(e['phase']=='wal_sync_exit' and e['transition']=='p/1' and e['inode'] and e['sync']==1 for e in events)
    result={'schema':'rosettanode.substrate.linkage_probe.v1','status':'passed' if passing else 'failed','library_real_path':str(lib),'library_sha256':hashlib.sha256(lib.read_bytes()).hexdigest(),'bindings':bindings,'loader_log_sha256':hashlib.sha256(p.stderr.encode()).hexdigest(),'events':events,'candidate_launch_allowed':False}
    (base/'result.json').write_text(json.dumps(result,indent=2)+'\n');(ROOT/'evidence/linkage-probe.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({'status':result['status'],'bindings':len(bindings)}));return not passing
if __name__=='__main__':raise SystemExit(main())
