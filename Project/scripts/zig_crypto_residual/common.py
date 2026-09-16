"""Shared paths and checked commands for the isolated residual campaign."""
import json, subprocess, sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]; HERE=Path(__file__).parent
WORK=ROOT/'Project/.campaigns/zig-residual'; LIB=ROOT/'Libraries/Zig/libsecp256k1-zig'
FROZEN=WORK/'frozen/Libraries/Zig/libsecp256k1-zig'
sys.path.insert(0,str(ROOT/'Project/scripts'))
from crypto_lanes import source_digest
BUILDER='rosetta-zig-opt-optimized:cb491eda661d-builder'
def run(args,cwd=ROOT):
    p=subprocess.run(list(map(str,args)),cwd=cwd,capture_output=True,text=True)
    if p.returncode: raise RuntimeError(str(args)+'\n'+p.stdout+p.stderr)
    return p.stdout+p.stderr

def docker(args):
    return run(['docker','run','--rm','--network','none','-v',str(WORK)+':/work','-w','/work',BUILDER,*args])
def save(path,obj): path.write_text(json.dumps(obj,indent=2)+'\n')
