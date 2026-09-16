#!/usr/bin/env python3
"""Repeat in a fresh container/filesystem; compare semantic results and extracted text."""
import hashlib,json,shutil,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def stable(result):
    return {k:result[k] for k in ['schema','status','identity','cases_per_build','matrix','mutation','asan','coverage','alive2','book']}
def main():
    image=json.loads((ROOT/'toolchain.json').read_text())['image_id']
    with tempfile.TemporaryDirectory(dir=ROOT/'.local',prefix='reproduction-') as temp:
        dst=Path(temp)/'package'
        shutil.copytree(ROOT,dst,ignore=shutil.ignore_patterns('.local','__pycache__'))
        subprocess.run(['docker','run','--rm','--network','none','--cpus','4','--memory','4g','-v',f'{dst}:/work',image,'python3','tools/gate.py'],check=True,stdout=subprocess.DEVNULL)
        first=json.loads((ROOT/'evidence/compactsize-gate.json').read_text())
        second=json.loads((dst/'evidence/compactsize-gate.json').read_text())
        assert stable(first)==stable(second),'Semantic result drift'
        hashes={}
        for name in ['compactsize','reconstruction']:
            a=(ROOT/f'.local/book/{name}.txt').read_bytes();b=(dst/f'.local/book/{name}.txt').read_bytes()
            assert a==b,'Document text drift'
            hashes[name]=hashlib.sha256(a).hexdigest()
        report={'schema':'rosettanode.reproduction.v1','status':'passed','environment':'fresh container and copied source tree using identical pinned image; same physical host/architecture','semantic_manifest_sha256':hashlib.sha256(json.dumps(stable(first),sort_keys=True).encode()).hexdigest(),'document_text_sha256':hashes,'excluded':['elapsed_seconds','commands timing','PDF binary metadata'],'cross_architecture':False}
        (ROOT/'evidence/reproduction.json').write_text(json.dumps(report,indent=2)+'\n')
        print(json.dumps(report))
if __name__=='__main__':main()
