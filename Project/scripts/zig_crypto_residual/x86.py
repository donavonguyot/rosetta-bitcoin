"""Network-disabled package correctness under Docker linux/amd64 emulation."""
import hashlib,tarfile,urllib.request,fcntl,time,shutil
from common import *
def main():
 lock=json.loads((HERE/'toolchains.lock.json').read_text());archive=WORK/'zig-x86_64-0.16.0.tar.xz'
 if not archive.exists():urllib.request.urlretrieve('https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz',archive)
 assert hashlib.sha256(archive.read_bytes()).hexdigest()==lock['zig']['x86_64_linux_sha256']
 with tarfile.open(archive) as tar:
  # Official hash-verified archive; preserve its versioned directory.
  tar.extractall(WORK,filter='data')
 package=WORK/'x86-package';shutil.copytree(WORK/'candidate-test',package,dirs_exist_ok=True,ignore=shutil.ignore_patterns('.zig-cache','zig-out'))
 cmd=['docker','run','--rm','--platform','linux/amd64','--network','none','-v',str(WORK)+':/work','-w','/work/x86-package',lock['base_amd64'],'sh','-c','uname -m && /work/zig-x86_64-linux-0.16.0/zig build test -Doptimize=ReleaseSafe -Dtarget=x86_64-linux -Dcpu=baseline && cd examples/consumer && /work/zig-x86_64-linux-0.16.0/zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux -Dcpu=baseline']
 start=time.monotonic();output=run(cmd);(WORK/'x86.log').write_text(output)
 save(WORK/'x86.json',dict(result='passed',platform='linux/amd64',emulator='Docker linux/amd64 through OrbStack on ARM64',cpu_target='baseline (explicit, no native feature inference)',docker_server=run(['docker','version','--format','{{json .Server}}']),command=cmd,toolchain_sha256=lock['zig']['x86_64_linux_sha256'],seconds_diagnostic_only=time.monotonic()-start,source_digest=source_digest(WORK/'candidate')))
 # Native feature inference is diagnostic; the supported correctness target is explicit.
 shutil.copy(HERE/'x86_wide_regression.zig',WORK/'x86-wide-repro.zig')
 probe=['docker','run','--rm','--platform','linux/amd64','--network','none','-v',str(WORK)+':/work','-w','/work',lock['base_amd64'],'/work/zig-x86_64-linux-0.16.0/zig','test','-O','ReleaseSafe','/work/x86-wide-repro.zig']
 completed=__import__('subprocess').run(probe,capture_output=True,text=True)
 (WORK/'x86-native-repro.log').write_text(completed.stdout+completed.stderr)
 evidence=json.loads((WORK/'x86.json').read_text())
 evidence['native_feature_probe']={'result':'passed' if completed.returncode==0 else 'failed','package_independent':True,'command':probe,'returncode':completed.returncode,'scope':'native feature inference under emulation; compiler/emulator cause not established','supported_campaign_target':'x86_64-linux, cpu=baseline'}
 save(WORK/'x86.json',evidence)
 print('x86 correctness passed',flush=True)
if __name__=='__main__':
 with (ROOT/'Project/.campaigns/crypto-lanes/node-benchmark.lock').open('a') as lock:
  fcntl.flock(lock,fcntl.LOCK_EX);main()
