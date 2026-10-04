"""Freeze only Zig source in an isolated Git index; leave HEAD/index untouched."""

import sys as _rb_sys
from pathlib import Path as _RBPath
_rb_sys.path.insert(0, str(_RBPath(__file__).resolve().parents[3] / 'Project/scripts'))
from state_root import operational_paths as _rb_paths
import hashlib, json, os, subprocess, sys, tempfile, io, tarfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
HERE=Path(__file__).parent
WORK=(_rb_paths()['campaigns'] / 'zig-residual')
sys.path.insert(0,str(ROOT/'Project/scripts'))
from crypto_lanes import source_digest

def run(*args, **kw): return subprocess.check_output(args,cwd=ROOT,**kw)

def main():
    WORK.mkdir(parents=True,exist_ok=True)
    if (HERE/'baseline.json').exists(): raise SystemExit('Baseline already frozen; refusing replacement')
    paths=['Libraries/Zig/libsecp256k1-zig','Nodes/Zig']
    with tempfile.TemporaryDirectory() as tmp:
        env=dict(os.environ,GIT_INDEX_FILE=tmp+'/index')
        run('git','read-tree','HEAD',env=env)
        run('git','add','--',*paths,env=env)
        tree=run('git','write-tree',env=env).decode().strip()
        commit=run('git','commit-tree',tree,'-p','HEAD',input=b'Freeze optimized Zig source for independent residual campaign\n').decode().strip()
    tag='codex/zig-residual-baseline-'+commit[:12]
    run('git','tag','-a',tag,commit,'-m','Scoped optimized Zig baseline; unrelated working tree and index preserved')
    archive=run('git','archive',commit,*paths)
    (WORK/'baseline-source.tar').write_bytes(archive)
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar: tar.extractall(WORK/'frozen',filter='data')
    lib=ROOT/paths[0]
    data={'schema':'rb.zig_residual_freeze.v1','commit':commit,'tag':tag,'package_digest':source_digest(lib),'node_digest':source_digest(ROOT/'Nodes/Zig/src'),'node_tree_digest':source_digest(WORK/'frozen/Nodes/Zig'),'archive_sha256':hashlib.sha256(archive).hexdigest(),'paths':paths,'excluded_working_changes':['Go','Shared','Docs','tmp'],'timing_coverage':'scheduler worker loop; excludes verifier initialization/destruction; legacy per-job elapsed preserved','binary_gate_status':'not_attempted'}
    (HERE/'baseline.json').write_text(json.dumps(data,indent=2)+'\n')
    for section,name,extra in [('baseline-5k','baseline',[]),('leaderboard','leaderboard',['--gate','baseline_5k'])]:
        (WORK/(name+'-before.txt')).write_bytes(run(sys.executable,'Project/scripts/report.py','--db','Project/project.db','--section',section,*extra))
    (WORK/'curated-before.sha256').write_text(hashlib.sha256((ROOT/'Nodes/Shared/conformance/current_evidence.json').read_bytes()).hexdigest())
    print(json.dumps(data,indent=2))
if __name__=='__main__': main()
