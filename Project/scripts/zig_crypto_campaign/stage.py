"""Freeze and measure an arithmetic stage; never changes the production package."""
import json,shutil,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'Project/scripts'))
from crypto_lanes import source_digest
name=sys.argv[1];work=ROOT/'Project/.campaigns/zig-opt';lib=ROOT/'Libraries/Zig/libsecp256k1-zig';dest=work/name
if '--existing' not in sys.argv:
 assert not dest.exists(),dest
 shutil.copytree(lib,dest,ignore=shutil.ignore_patterns('.zig-cache','zig-out'))
 (work/f'{name}-source.json').write_text(json.dumps({'source_digest':source_digest(lib)}))
else:
 assert dest.exists(),dest
shutil.copyfile(Path(__file__).with_name('bench.zig'),dest/'src/bench.zig')
for batch in range(2):
 p=subprocess.run(['zig','build','bench','-Doptimize=ReleaseSafe'],cwd=dest,text=True,capture_output=True)
 if p.returncode:raise RuntimeError(p.stdout+p.stderr)
 (work/f'{name}-bench-{batch}.jsonl').write_text(p.stdout+p.stderr)
 print(name,batch,flush=True)
