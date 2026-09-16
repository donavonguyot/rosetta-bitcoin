#!/usr/bin/env python3
import hashlib,json,shutil,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def stable(value):
    if isinstance(value,dict):return {k:stable(v) for k,v in value.items() if k not in ['elapsed_seconds','commands']}
    if isinstance(value,list):return [stable(v) for v in value]
    return value

def main():
    image=json.loads((ROOT/'toolchain.json').read_text())['image_id']
    with tempfile.TemporaryDirectory(dir=ROOT/'.local',prefix='tx-reproduction-') as temp:
        dst=Path(temp)/'package';shutil.copytree(ROOT,dst,ignore=shutil.ignore_patterns('.local','__pycache__'))
        shutil.copytree(ROOT/'.local/blocks',dst/'.local/blocks')
        commands=[['python3','tools/build.py'],['python3','-m','unittest','discover','-s','tests'],['python3','tools/adversarial.py'],['python3','tools/variants.py'],['python3','tools/check_chain.py'],['python3','tools/transaction_book.py']]
        log=[]
        for command in commands:
            p=subprocess.run(['docker','run','--rm','--network','none','--cpus','4','--memory','4g','-v',f'{dst}:/work',image,*command],text=True,capture_output=True,timeout=180)
            log.append({'command':command,'returncode':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
            if p.returncode:raise RuntimeError(log[-1])
        results={}
        for name in ['adversarial','execution-variants','chain-composition','packet']:
            first=stable(json.loads((ROOT/f'evidence/{name}.json').read_text()));second=stable(json.loads((dst/f'evidence/{name}.json').read_text()))
            assert first==second,f'Semantic drift {name}'
            results[name]=hashlib.sha256(json.dumps(first,sort_keys=True).encode()).hexdigest()
        text_hashes={}
        for name in ['rosettanode','reconstruction']:
            blobs=[]
            for directory in [ROOT,dst]:
                subprocess.run(['docker','run','--rm','--network','none','-v',f'{directory}:/work',image,'pdftotext','-layout',f'.local/transaction-book/{name}.pdf',f'.local/transaction-book/{name}.txt'],check=True)
                blobs.append((directory/f'.local/transaction-book/{name}.txt').read_bytes())
            assert blobs[0]==blobs[1],f'Document drift {name}'
            text_hashes[name]=hashlib.sha256(blobs[0]).hexdigest()
        (ROOT/'.local/tx/reproduction-log.json').write_text(json.dumps(log,indent=2)+'\n')
        report={'schema':'rosettanode.transaction_reproduction.v1','status':'passed','environment':'fresh containers, fresh copied source/build tree; same pinned image and physical host','test_manifest_hashes':results,'document_text_hashes':text_hashes,'excluded':['elapsed_seconds','command timing','PDF metadata'],'cross_architecture':False}
        (ROOT/'evidence/transaction-reproduction.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
if __name__=='__main__':main()
