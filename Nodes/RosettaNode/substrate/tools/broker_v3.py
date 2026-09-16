#!/usr/bin/env python3
"""Parent-side offline build broker; candidates never receive the Docker socket.

A candidate submits shell text via a bounded JSON file. It runs only inside a
resource-limited container mounting that candidate workspace and the adapter.
This module must stay outside every candidate filesystem permission profile.
"""
import argparse,json,os,signal,stat,subprocess,time,uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
IMAGE='sha256:cc9b0ebe055af2cf067e3ca206f6d236682c87c48debb5f205d0657dbcc0476e'

def read_at(fd,name):
    f=os.open(name,os.O_RDONLY|os.O_NOFOLLOW,dir_fd=fd)
    try:
        if not stat.S_ISREG(os.fstat(f).st_mode) or os.fstat(f).st_size>65536:raise ValueError('invalid request file')
        return json.loads(os.read(f,65537))
    finally:os.close(f)
def write_at(fd,name,value):
    f=os.open(name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=fd)
    try:os.write(f,json.dumps(value).encode())
    finally:os.close(f)

def serve(work,control,stop,reading=False):
    work=work.resolve(strict=True);control=control.resolve(strict=True)
    if not work.is_relative_to(ROOT/'.local'):raise ValueError('not campaign-owned workspace')
    queue=work/'queue';queue.mkdir(exist_ok=True);fd=os.open(queue,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    seen={name for name in os.listdir(fd) if name.endswith('.request') and name[:-8]+'.response' in os.listdir(fd)}
    try:
        while not stop.exists():
            for name in os.listdir(fd):
                if not name.endswith('.request') or name in seen:continue
                token=name[:-8]
                if len(token)!=32 or any(c not in '0123456789abcdef' for c in token):continue
                seen.add(name)
                request=read_at(fd,name);command=request.get('command');seconds=request.get('seconds',120)
                if not isinstance(command,str) or not isinstance(seconds,int) or not 1<=seconds<=300:raise ValueError('invalid command')
                cname='rn-substrate-build-'+uuid.uuid4().hex[:16]
                cmd=['docker','run','--name',cname,'--rm','--network','none','--cap-drop','ALL','--security-opt','no-new-privileges','--pids-limit','256','--cpus','4','--memory','4g','--read-only','--tmpfs','/tmp:rw,size=512m','--label','rosettanode.substrate=broker','-e','HOME=/workspace/home','-e','GOCACHE=/workspace/cache/go','-e','ZIG_GLOBAL_CACHE_DIR=/workspace/cache/zig','-e','CARGO_HOME=/workspace/cache/cargo','-v',str(work)+(':/workspace:ro' if reading else ':/workspace'),'-v',str(control)+':/adapter:ro','-w','/workspace',IMAGE,'sh','-c',command]
                started=time.monotonic();timeout=False
                output=ROOT/'.local/broker-logs'/cname;output.mkdir(parents=True)
                with (output/(token+'.stdout')).open('w') as out,(output/(token+'.stderr')).open('w') as err:
                    p=subprocess.Popen(cmd,stdout=out,stderr=err,start_new_session=True)
                    while p.poll() is None:
                        excessive=any((output/(token+suffix)).stat().st_size>64*1024*1024 for suffix in ['.stdout','.stderr'])
                        if time.monotonic()-started>seconds or stop.exists() or excessive:
                            timeout=time.monotonic()-started>seconds
                            subprocess.run(['docker','kill',cname],capture_output=True);p.wait(timeout=20);break
                        time.sleep(.05)
                    code=124 if timeout else p.returncode

                stdout=(output/(token+'.stdout')).read_bytes()[:1024*1024].decode(errors='replace');stderr=(output/(token+'.stderr')).read_bytes()[:1024*1024].decode(errors='replace')
                (output/'record.json').write_text(json.dumps({'command':command,'reading':reading,'exit':code,'timeout':timeout,'elapsed_seconds':time.monotonic()-started,'container':cname},indent=2)+'\n')
                write_at(fd,token+'.replytmp',{'exit':code,'timeout':timeout,'elapsed_seconds':time.monotonic()-started,'stdout':stdout,'stderr':stderr})
                os.rename(token+'.replytmp',token+'.response',src_dir_fd=fd,dst_dir_fd=fd)
            time.sleep(.05)
    finally:os.close(fd)
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('workspace',type=Path);p.add_argument('adapter',type=Path);p.add_argument('stop',type=Path);p.add_argument('--reading',action='store_true');a=p.parse_args();serve(a.workspace,a.adapter,a.stop,a.reading)
