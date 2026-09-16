"""Reconstruct the frozen baseline and measured arithmetic snapshots from Git."""
import hashlib,io,json,subprocess,tarfile,sys,shutil
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).parent;WORK=ROOT/'Project/.campaigns/zig-opt'
sys.path.insert(0,str(ROOT/'Project/scripts'));from crypto_lanes import source_digest
WORK.mkdir(parents=True,exist_ok=True)
if '--reference' in sys.argv:
 import run_crypto_lane
 run_crypto_lane.WORK.mkdir(parents=True,exist_ok=True)
 run_crypto_lane.reference()
base=json.loads((HERE/'baseline.json').read_text());assert subprocess.check_output(['git','rev-parse',base['tag']+'^{commit}'],cwd=ROOT,text=True).strip()==base['commit']
(WORK/'baseline.json').write_text(json.dumps(base,indent=2)+'\n')
archive=subprocess.check_output(['git','archive',base['commit'],'Libraries/Zig/libsecp256k1-zig'],cwd=ROOT)
with tarfile.open(fileobj=io.BytesIO(archive)) as source,tarfile.open(WORK/'original-package.tar.gz','w:gz') as dest:
 for entry in source:
  if not entry.isfile():continue
  stream=source.extractfile(entry);entry.name=str(Path(entry.name).relative_to('Libraries/Zig/libsecp256k1-zig'));dest.addfile(entry,stream)
# Never overwrite existing measurement snapshots or their logs.
for name in ('original','stage1','stage2','stage3','stage4'):
 dest=WORK/name
 if dest.exists():continue
 dest.mkdir()
 with tarfile.open(WORK/'original-package.tar.gz') as tar:tar.extractall(dest,filter='data')
 if name!='original':
  for i in range(1,int(name[-1])+1):subprocess.run(['patch','-p1','-i',str(HERE/'stages'/f'stage{i}.patch')],cwd=dest,check=True)
 digest=source_digest(dest)
 (WORK/f'{name}-reconstructed-source.json').write_text(json.dumps({'source_digest':digest,'arithmetic_patch_level':name}))
 shutil.copy(HERE/'bench.zig',dest/'src/bench.zig')
for section,name,extra in [('baseline-5k','canonical-baseline-before.txt',[]),('leaderboard','canonical-leaderboard-before.txt',['--gate','baseline_5k'])]:
 p=WORK/name
 if not p.exists():p.write_text(subprocess.check_output([sys.executable,ROOT/'Project/scripts/report.py','--db',ROOT/'Project/project.db','--section',section,*extra],text=True))
p=WORK/'curated-before.sha256'
if not p.exists():p.write_text(hashlib.sha256((ROOT/'Nodes/Shared/conformance/current_evidence.json').read_bytes()).hexdigest()+'\n')
print('baseline reconstructed; existing snapshots preserved')
