#!/usr/bin/env python3
"""Post-submission build/link evidence. Static checks do not replace source review."""

import sys as _rb_sys
from pathlib import Path as _RBPath
_rb_sys.path.insert(0, str(_RBPath(__file__).resolve().parents[4] / 'Project/scripts'))
from state_root import operational_paths as _rb_paths, logical_path as _rb_logical, acquire_writer_lease as _rb_writer_lease
if __name__ == '__main__':
    _rb_writer_lease()
import argparse,json,shutil,subprocess,time,uuid
from pathlib import Path
from campaign_v2 import ROOT,save,digest
from broker import IMAGE

def audit(submission,language):
    base=(_rb_paths()['substrate'] / 'source-audits')/uuid.uuid4().hex;work=base/'workspace';shutil.copytree(submission,work)
    (work/'tmp').mkdir(exist_ok=True);(work/'cache').mkdir(exist_ok=True)
    if language=='rust':shutil.copytree((_rb_paths()['substrate'] / 'rust-infra/cargo'),work/'cache/cargo')
    cmd=['docker','run','--rm','--network','none','--cap-drop','ALL','--security-opt','no-new-privileges','--cpus','4','--memory','4g','--read-only','--tmpfs','/tmp:rw,size=512m','-e','CARGO_HOME=/workspace/cache/cargo','-e','GOCACHE=/workspace/cache/go','-e','ZIG_GLOBAL_CACHE_DIR=/workspace/cache/zig','-v',str(work)+':/workspace','-v',str((_rb_paths()['substrate'] / 'adapter-bundle'))+':/adapter:ro','-w','/workspace',IMAGE,'sh','-c','./build.sh && readelf -d service && nm -D --undefined-only service && ldd service']
    start=time.monotonic();p=subprocess.run(cmd,capture_output=True,text=True,timeout=600);(base/'build-link.log').write_text(p.stdout+p.stderr)
    text=p.stdout;forbidden=['rocksdb_put','rocksdb_delete','rocksdb_merge','rocksdb_write_writebatch_wi','rocksdb_ingest_external_file','rocksdb_transactiondb_write']
    symbols=[line.split()[-1].split('@')[0] for line in text.splitlines() if ' U ' in line]
    result={'schema':'rosettanode.substrate.submission_audit.v1','submission':str(submission),'language':language,'fresh_build_exit':p.returncode,'fresh_build_seconds':time.monotonic()-start,'input_binary_sha256':digest(submission/'service'),'rebuilt_binary_sha256':digest(work/'service') if (work/'service').exists() else None,'dynamic_rocksdb':bool('librocksdb.so.7.8' in text),'dynamic_common_adapter':bool('librosetta.so' in text),'c_write_symbol':'rocksdb_write' in symbols,'forbidden_write_symbols':[s for s in symbols if s in forbidden],'llvm_entrypoints':[s for s in symbols if s.startswith('rn_')],'source_review_required':True,'logs':str(base)}
    result['status']='passed' if p.returncode==0 and result['dynamic_rocksdb'] and result['dynamic_common_adapter'] and result['c_write_symbol'] and not result['forbidden_write_symbols'] else 'needs_review'
    save(base/'result.json',result);return result
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('submission',type=Path);p.add_argument('language',choices=['go','rust','zig']);a=p.parse_args();print(json.dumps(audit(a.submission,a.language),indent=2))
