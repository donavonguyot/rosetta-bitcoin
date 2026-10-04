#!/usr/bin/env python3
"""Archive trial-owned stopped container diagnostics before removing layers."""

import sys as _rb_sys
from pathlib import Path as _RBPath
_rb_sys.path.insert(0, str(_RBPath(__file__).resolve().parents[4] / 'Project/scripts'))
from state_root import operational_paths as _rb_paths, logical_path as _rb_logical, acquire_writer_lease as _rb_writer_lease
if __name__ == '__main__':
    _rb_writer_lease()
import gzip,hashlib,json,subprocess,tarfile,time,datetime
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def main():
    destination=(_rb_paths()['substrate'] / 'retained-docker');destination.mkdir(exist_ok=True);results=[]
    ids=subprocess.check_output(['docker','ps','-aq','--filter','name=rn-substrate-'],text=True).split()
    if not ids:return
    for info in json.loads(subprocess.check_output(['docker','inspect',*ids],text=True)):
        name=info['Name'].lstrip('/')
        if not name.startswith('rn-substrate-') or info['State']['Running']:continue
        finished=info['State'].get('FinishedAt','')
        if finished and not finished.startswith('0001'):
            stamp=datetime.datetime.fromisoformat(finished[:19]+'+00:00').timestamp()
            if time.time()-stamp<60:continue
        folder=destination/name
        if folder.exists():continue
        folder.mkdir();(folder/'inspect.json').write_text(json.dumps(info,indent=2)+'\n')
        logs=subprocess.run(['docker','logs',name],capture_output=True);(folder/'stdout.log').write_bytes(logs.stdout);(folder/'stderr.log').write_bytes(logs.stderr)
        archive=folder/'evaluator-state.tar.gz';p=subprocess.Popen(['docker','cp',name+':/evaluator/.local','-'],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        with gzip.open(archive,'wb',compresslevel=1) as out:
            for chunk in iter(lambda:p.stdout.read(4<<20),b''):out.write(chunk)
        error=p.stderr.read();code=p.wait()
        if code:
            (folder/'copy-error.txt').write_bytes(error);results.append({'container':name,'removed':False,'reason':'state export failed'});continue
        with tarfile.open(archive,'r:gz') as tar:
            for member in tar:
                if member.isfile():
                    stream=tar.extractfile(member)
                    for chunk in iter(lambda:stream.read(4<<20),b''):pass
        sha=hashlib.sha256(archive.read_bytes()).hexdigest()
        # Never delete attached named volumes, including failed-run volumes.
        subprocess.run(['docker','rm',name],check=True,capture_output=True)
        row={'container':name,'removed':True,'state_archive':str(archive),'sha256':sha,'named_volumes_removed':False,'original_exit_code':info['State']['ExitCode']};results.append(row);print(json.dumps(row),flush=True)
    path=ROOT/'evidence/container-retention.json';old=json.loads(path.read_text()) if path.exists() else [];path.write_text(json.dumps(old+results,indent=2)+'\n')
if __name__=='__main__':main()
