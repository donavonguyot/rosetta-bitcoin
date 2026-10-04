#!/usr/bin/env python3

import sys as _rb_sys
from pathlib import Path as _RBPath
_rb_sys.path.insert(0, str(_RBPath(__file__).resolve().parents[4] / 'Project/scripts'))
from state_root import operational_paths as _rb_paths, logical_path as _rb_logical, acquire_writer_lease as _rb_writer_lease
if __name__ == '__main__':
    _rb_writer_lease()
import hashlib,json,os,subprocess,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def main():
    base=(_rb_paths()['substrate'])/('linkage-'+time.strftime('%Y%m%dT%H%M%S'));base.mkdir()
    p=subprocess.run([str((_rb_paths()['substrate'] / 'probe')),str(base/'db'),'admit'],env={**os.environ,'LD_PRELOAD':str((_rb_paths()['substrate'] / 'interpose.so')),'LD_DEBUG':'bindings','RN_TRACE':str(base/'events')},capture_output=True,text=True)
    (base/'loader.log').write_text(p.stderr);bindings=[s.strip() for s in p.stderr.splitlines() if any(x in s for x in ['symbol `rocksdb_write\'','symbol `fdatasync\'','symbol `fsync\''])]
    events=[json.loads(x) for x in (base/'events').read_text().splitlines()];lib=Path('/usr/lib/aarch64-linux-gnu/librocksdb.so').resolve()
    passing=p.returncode==0 and any('interpose.so' in s and 'rocksdb_write' in s for s in bindings) and any('librocksdb.so' in s and 'rocksdb_write' in s for s in bindings) and any(e['phase']=='wal_sync_exit' and e['transition']=='p/1' and e['inode'] and e['sync']==1 for e in events)
    result={'schema':'rosettanode.substrate.linkage_probe.v1','status':'passed' if passing else 'failed','library_real_path':str(lib),'library_sha256':hashlib.sha256(lib.read_bytes()).hexdigest(),'bindings':bindings,'loader_log_sha256':hashlib.sha256(p.stderr.encode()).hexdigest(),'events':events,'candidate_launch_allowed':False}
    (base/'result.json').write_text(json.dumps(result,indent=2)+'\n');(ROOT/'evidence/linkage-probe.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({'status':result['status'],'bindings':len(bindings)}));return not passing
if __name__=='__main__':raise SystemExit(main())
