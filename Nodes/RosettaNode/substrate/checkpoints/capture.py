"""Capture source and local diagnostics without modifying frozen experiments."""
import hashlib,json,os,shutil,tarfile,time
from pathlib import Path
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[3]
LAB=ROOT/'Nodes/RosettaNode'
LOCAL=LAB/'substrate/.local/checkpoint-20260916'
SKIP={'cache','target','.zig-cache','zig-out','node_modules','.git','__pycache__','home'}
EXT={'.py','.go','.rs','.zig','.c','.h','.ll','.md','.txt','.sh','.toml','.mod','.sum','.lock','.zon','.json','.patch','.diff'}
def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1<<20),b''):h.update(b)
 return h.hexdigest()
def save(p,x):p.write_text(json.dumps(x,indent=2)+'\n')
def main():
 LOCAL.mkdir(parents=True,exist_ok=False);(HERE/'objects').mkdir(exist_ok=True)
 inventories=[];cache=[];source=[];diagnostics=[]
 for base in [LAB/'.local',LAB/'substrate/.local']:
  for d,dirs,files in os.walk(base,followlinks=False):
   dirs[:]=[n for n in dirs if not (Path(d)/n).is_symlink() and Path(d)/n!=LOCAL]
   for n in list(dirs):
    p=Path(d)/n
    # Only agent/build workspace caches; preserve standalone pinned dependency stores.
    if (n in SKIP or n.startswith('go-build')) and ('workspace' in p.parts or 'source-audits' in p.parts):
     if n not in {'home','.git'}:cache.append(p)
     dirs.remove(n)
   for n in files:
    p=Path(d)/n
    if not p.is_file() or p.is_symlink():continue
    rel=str(p.relative_to(ROOT));size=p.stat().st_size
    inventories.append({'path':rel,'bytes':size})
    attempt=any(x in p.parts for x in ['cohort','campaign','campaign-v2'])
    if attempt and (p.suffix != '.json' or p.name in {'package.json','tsconfig.json'} or 'contracts' in p.parts) and p.suffix in EXT and size<4<<20 and not any(x in p.parts for x in ['evaluation','repair-evaluation','initial-evaluation','runtime','queue','reading-queue','implementation-queue','repair-queue','logs']):
     data=p.read_bytes()
     if b'\0' not in data:
      h=hashlib.sha256(data).hexdigest();obj=HERE/'objects'/h
      if not obj.exists():obj.write_bytes(data)
      assert sha(obj)==h
      source.append({'original':rel,'sha256':h,'bytes':size,'executable':bool(p.stat().st_mode&0o111)})
    if size<64<<20 and (p.suffix in {'.jsonl','.log','.stderr','.json','.md','.txt'} or n in {'stderr','stdout','events'}):diagnostics.append(p)
 # Logs stay local; archive verified byte-for-byte before any cleanup.
 archive=LOCAL/'diagnostics.tar.gz';expected={}
 with tarfile.open(archive,'w:gz',compresslevel=6) as t:
  for p in diagnostics:
   rel=str(p.relative_to(ROOT));expected[rel]=sha(p);t.add(p,arcname=rel,recursive=False)
 with tarfile.open(archive,'r:gz') as t:
  actual={m.name:hashlib.sha256(t.extractfile(m).read()).hexdigest() for m in t if m.isfile()}
 assert actual==expected
 cache_records=[]
 for p in cache:
  paths=[q for q in p.rglob('*') if q.is_file() and not q.is_symlink()]
  cache_records.append({'path':str(p.relative_to(ROOT)),'files':len(paths),'bytes':sum(q.stat().st_size for q in paths),'classification':'reproducible workspace compiler/build cache'})
 save(HERE/'source-index.json',{'schema':'rosettanode.source_checkpoint.v1','files':source,'unique_objects':len({x['sha256'] for x in source}),'interrupted_workspaces_are_not_submissions':True})
 save(LOCAL/'file-inventory.json',inventories)
 save(LOCAL/'diagnostics-files.json',expected)
 save(HERE/'local-retention.json',{'archive':str(archive.relative_to(ROOT)),'archive_sha256':sha(archive),'files':len(expected),'verified':True,'inventory':str((LOCAL/'file-inventory.json').relative_to(ROOT)),'cache_removal':cache_records,'runtime_datadirs_deleted':False,'docker_state_changed':False})
 print(json.dumps({'source_files':len(source),'unique_objects':len({x['sha256'] for x in source}),'diagnostics':len(expected),'cache_bytes':sum(x['bytes'] for x in cache_records)}),flush=True)
 # Nothing is removed until both curated source and diagnostics have verified.
 for p in cache:shutil.rmtree(p)
 print('cache cleanup complete',flush=True)
if __name__=='__main__':main()
