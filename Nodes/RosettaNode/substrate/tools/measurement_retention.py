#!/usr/bin/env python3
"""Retain successful measured state as a verified archive; failed volumes stay live."""
import gzip,hashlib,json,subprocess,tarfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def retain(result,out,image):
    if result['status']!='passed':return {'failed_volume_preserved':True}
    volume=result['volume'];name=result['container'];assert volume.startswith('rn-substrate-measure-') and name.startswith('rn-substrate-measure-')
    info=json.loads(subprocess.check_output(['docker','volume','inspect',volume],text=True))[0];assert info.get('Labels',{}).get('rosettanode.substrate')=='measurement'
    archive=out/'verified-state.tar.gz';p=subprocess.Popen(['docker','run','--rm','--network','none','--read-only','--cap-drop','ALL','--cap-add','DAC_OVERRIDE','-v',volume+':/state:ro',image,'tar','-C','/state','-cf','-','.'],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    with gzip.open(archive,'wb',compresslevel=1) as target:
        for block in iter(lambda:p.stdout.read(4<<20),b''):target.write(block)
    error=p.stderr.read();assert p.wait()==0,error
    with tarfile.open(archive,'r:gz') as tar:
        for member in tar:
            if member.isfile():
                f=tar.extractfile(member)
                for block in iter(lambda:f.read(4<<20),b''):pass
    result={'archive':str(archive),'sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),'verified_tar':True,'volume_removed_after_inspection_and_artifact':True}
    (out/'state-retention.json').write_text(json.dumps(result,indent=2)+'\n')
    subprocess.run(['docker','rm',name],check=True,capture_output=True);subprocess.run(['docker','volume','rm',volume],check=True,capture_output=True);return result
