"""Profile a disposable frozen-source copy. No instrumentation enters packages."""
import json,re,shutil
from common import *
categories=['field_mul','field_reduce','field_add_sub','double','plus','mixed','table','recode','joint','inverse','sqrt','scalar_reduce','sha256','der','byte_io','parse','ecdsa','schnorr','tweak','glv_split']
functions={'mul':0,'reduceField':1,'add':2,'sub':2,'double':3,'plus':4,'mixed':5,'oddTable':6,'recode':7,'joint':8,'inverse':9,'pow':10,'profileScalar':11,'profileSha':12,'parseDer':13,'read':14,'write':14,'parsePublicKey':15,'parseXOnly':15,'verifyEcdsa':16,'verifySchnorr':17,'addXOnlyTweak':18,'splitScalar':19,'oddTableWidth':6,'recodeSigned':7,'sqrtPower':10,'reduceScalar':11,'scalar256':11}
import fcntl
_lock=(ROOT/'Project/.campaigns/crypto-lanes/node-benchmark.lock').open('a')
fcntl.flock(_lock,fcntl.LOCK_EX)
dest=WORK/'profile';shutil.copytree(FROZEN,dest,dirs_exist_ok=True)
s=(dest/'src/root.zig').read_text()
s=s.replace('@intCast((@as(u512, read(digest)) * w) % n)','profileScalar(@as(u512, read(digest)) * w)').replace('@intCast((@as(u512, sig.r.value) * w) % n)','profileScalar(@as(u512, sig.r.value) * w)')
start=s.index('    const Sha = std.crypto.hash.sha2.Sha256;',s.index('pub fn verifySchnorr'))
end=s.index('    const q = schnorrPoint',start)
sha=s[start:end].replace('    const e = scalar256(read(&digest));','    return scalar256(read(&digest));')
s=s[:start]+'    const e = profileSha(key, message, signature);\n'+s[end:]
s+='\nfn profileScalar(x:u512) u256 { return @intCast(x % n); }\nfn profileSha(key:[]const u8,message:[]const u8,signature:[]const u8) u256 {\n'+sha+'}\n'
# Two passes: coarse timing avoids timing every field operation; counters include all.
for mode in ('timing','counts','fine'):
 text=s
 for name,index in functions.items():
  timed=(mode=='timing' and index>=6) or mode=='fine'
  body=f'\n const prof_token: ?Token = if (@inComptime()) null else profEnter({index}); defer if (prof_token) |token| profLeave(token);' if timed else f'\n if (!@inComptime()) prof_count[{index}] += 1;'
  text=re.sub(r'(fn '+name+r'\([^\n]+\{)',lambda m:m[0]+body,text)
 text+='''
const TS=extern struct { sec:i64, ns:i64 };
extern "c" fn clock_gettime(c_int,*TS) c_int;
fn profNow() u64 { var ts:TS=undefined; std.debug.assert(clock_gettime(1,&ts)==0); return @intCast(ts.sec*1_000_000_000+ts.ns); }
var prof_count: [20]u64=@splat(0);
var prof_inclusive: [20]u64=@splat(0);
var prof_exclusive: [20]u64=@splat(0);
var prof_child: [64]u64=@splat(0);
var prof_depth:usize=0;
const Token=struct { start:u64,id:usize,depth:usize };
fn profEnter(id:usize) Token { const d=prof_depth; prof_child[d]=0; prof_depth+=1; prof_count[id]+=1; return .{.start=profNow(),.id=id,.depth=d}; }
fn profLeave(t:Token) void { const elapsed=profNow()-t.start; prof_inclusive[t.id]+=elapsed; prof_exclusive[t.id]+=elapsed-prof_child[t.depth]; prof_depth-=1; if(prof_depth>0) prof_child[prof_depth-1]+=elapsed; }
pub fn profileReset() void { prof_count=@splat(0);prof_inclusive=@splat(0);prof_exclusive=@splat(0); }
pub fn profileDump(op:usize) void { for(0..20) |i| std.debug.print("PROFILE {d} {d} {d} {d} {d}\\n",.{op,i,prof_count[i],prof_inclusive[i],prof_exclusive[i]}); }
'''
 (dest/'src/root.zig').write_text(text)
 bench=(HERE/'bench.zig').read_text()
 bench=bench.replace('for(0..5) |rep|','for(0..1) |rep|').replace('for(0..1024)','for(0..256)')
 bench=bench.replace('const start=std.Io.Clock.awake','secp.profileReset();\n const start=std.Io.Clock.awake')
 bench=bench.replace('const elapsed=std.Io.Clock.awake','secp.profileDump(op);\n const elapsed=std.Io.Clock.awake')
 (dest/'src/bench.zig').write_text(bench)
 out=docker(['zig','build-exe','-O','ReleaseSafe','-lc','--dep','secp256k1','-Mroot=/work/profile/src/bench.zig','-O','ReleaseSafe','-Msecp256k1=/work/profile/src/root.zig','-femit-bin=/work/profile-'+mode,'-femit-asm=/work/profile-'+mode+'.s'])
 out=docker(['/work/profile-'+mode,'/work/tuning.json','0']);(WORK/('profile-'+mode+'.log')).write_text(out)
# Timing tree exclusive shares reconcile to the sum of top-level calls.
rows=[]
for line in (WORK/'profile-timing.log').read_text().splitlines():
 if line.startswith('PROFILE '):
  op,idx,count,inc,exc=map(int,line.split()[1:]);rows.append(dict(operation=op,primitive=categories[idx],calls=count,inclusive_ns=inc,exclusive_ns=exc))
for op in (0,1,2):
 subset=[r for r in rows if r['operation']==op];total=sum(r['exclusive_ns'] for r in subset)
 for r in subset:r.update(exclusive_share=r['exclusive_ns']/total,inclusive_share=r['inclusive_ns']/total)
inversion=max(r.get('exclusive_share',0) for r in rows if r['primitive']=='inverse')
ledger={'schema':'rb.zig_open_profile.v1','package_digest':source_digest(FROZEN),'method':'coarse nested monotonic-clock instrumentation, field operations counted separately; shares include instrumentation overhead and are not benchmark results','rows':rows,'inversion_trigger_share':inversion,'roster':{'field':'A0 complete, latency gate failed','shared_z':'mandatory','divsteps':'mandatory','tables':'mandatory','scalar_montgomery':'conditional on exclusive reduction share >1%'},'deferrals':{'sha256':'standard-library provider unchanged','der':'encoding API unchanged','byte_io':'encoding API unchanged'},'reconciliation':'exclusive child time is subtracted once; field costs are included in exclusive group/sqrt time, not added again'}
ledger['fine_profile_log']='profile-fine.log'
ledger['assembly']={'artifact':'profile-counts.s','inline_schoolbook':'inspect emitted artifact','instructions':['mul','umulh'],'general_division_present':'inspect emitted artifact','runtime_safety':'enabled; checks not removed'}
ledger['fine_rows']=[]
for line in (WORK/'profile-fine.log').read_text().splitlines():
 if line.startswith('PROFILE '):
  op,idx,count,inc,exc=map(int,line.split()[1:]);ledger['fine_rows'].append(dict(operation=op,primitive=categories[idx],calls=count,inclusive_ns=inc,exclusive_ns=exc))
for op in range(9):
 subset=[r for r in ledger['fine_rows'] if r['operation']==op];total=sum(r['exclusive_ns'] for r in subset)
 for r in subset:r.update(exclusive_share=r['exclusive_ns']/total,inclusive_share=r['inclusive_ns']/total)
ledger['roster_locked']=False
ledger['fine_reconciliation']='Fine per-call clock instrumentation has observer cost; coarse timing controls the inverse trigger. Exclusive values partition roots; inclusive ancestors are not summed.'
ledger['assembly']['sha256']=__import__('hashlib').sha256((WORK/'profile-counts.s').read_bytes()).hexdigest()
save(WORK/'profile-ledger.json',ledger)
print('inversion share',inversion,'roster',ledger['roster'])
