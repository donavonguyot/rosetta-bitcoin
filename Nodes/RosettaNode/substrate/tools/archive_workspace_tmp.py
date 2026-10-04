#!/usr/bin/env python3
"""Lossless archival of a completed phase's temporary tree; never volumes."""

import sys as _rb_sys
from pathlib import Path as _RBPath
_rb_sys.path.insert(0, str(_RBPath(__file__).resolve().parents[4] / 'Project/scripts'))
from state_root import operational_paths as _rb_paths, logical_path as _rb_logical, acquire_writer_lease as _rb_writer_lease
if __name__ == '__main__':
    _rb_writer_lease()
import argparse,hashlib,json,os,shutil,stat,subprocess,tarfile,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda:stream.read(4<<20),b''):h.update(chunk)
    return h.hexdigest()
def main():
    p=argparse.ArgumentParser();p.add_argument('workspace',type=Path);a=p.parse_args();work=a.workspace.resolve();tree=work/'tmp'
    assert work.is_relative_to((_rb_paths()['substrate'])) and work.name=='workspace' and tree.is_dir() and not tree.is_symlink()
    commands=subprocess.check_output(['ps','-axo','command'],text=True)
    assert not any(str(work) in line and ('codex exec' in line or 'tools/broker' in line) for line in commands.splitlines()),'active agent or broker'
    ids=subprocess.check_output(['docker','ps','-q'],text=True).split()
    if ids:
        for container in json.loads(subprocess.check_output(['docker','inspect',*ids],text=True)):
            assert not any(m.get('Source','')==str(work) for m in container.get('Mounts',[])),'active mounted workspace'
    destination=(_rb_paths()['substrate'] / 'retained-archives');destination.mkdir(exist_ok=True);name='-'.join(work.relative_to((_rb_paths()['substrate'])).parts[:-1]);archive=destination/(name+'-tmp.tar.gz');assert not archive.exists()
    manifest={};size=0
    for path in sorted(tree.rglob('*')):
        metadata=path.lstat();relative=str(path.relative_to(work))
        if stat.S_ISREG(metadata.st_mode):manifest[relative]={'sha256':sha(path),'bytes':metadata.st_size};size+=metadata.st_size
        elif stat.S_ISLNK(metadata.st_mode):manifest[relative]={'symlink':os.readlink(path)}
        elif stat.S_ISSOCK(metadata.st_mode):manifest[relative]={'closed_socket_endpoint':True,'mode':metadata.st_mode}
        elif not stat.S_ISDIR(metadata.st_mode):raise ValueError('Nonregular temporary artifact: '+str(path))
    with tarfile.open(archive,'w:gz',compresslevel=1,dereference=False) as tar:tar.add(tree,arcname='tmp')
    with tarfile.open(archive,'r:gz') as tar:
        for member in tar:
            if member.isfile():
                stream=tar.extractfile(member);h=hashlib.sha256()
                for chunk in iter(lambda:stream.read(4<<20),b''):h.update(chunk)
                assert manifest[member.name]['sha256']==h.hexdigest()
            elif member.issym():assert manifest[member.name]['symlink']==member.linkname
    record={'schema':'rosettanode.substrate.retained_archive.v1','original':str(tree),'archive':str(archive),'archive_sha256':sha(archive),'uncompressed_file_bytes':size,'archive_bytes':archive.stat().st_size,'verified_full_file_hashes':True,'files':manifest}
    (archive.with_suffix('.manifest.json')).write_text(json.dumps(record,indent=2)+'\n')
    shutil.rmtree(tree);tree.mkdir();(tree/'ARCHIVED.json').write_text(json.dumps({k:v for k,v in record.items() if k!='files'},indent=2)+'\n')
    print(json.dumps({k:v for k,v in record.items() if k!='files'}))
if __name__=='__main__':main()
