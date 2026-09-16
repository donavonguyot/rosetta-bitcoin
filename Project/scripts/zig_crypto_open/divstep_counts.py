"""Observed divstep iteration distribution in a disposable test-only copy."""
import shutil,re
from common import WORK,docker,save,exclusive


def main():
    dest=WORK/'divsteps-counts'
    shutil.copytree(WORK/'divsteps',dest,dirs_exist_ok=True,ignore=shutil.ignore_patterns('.zig-cache','zig-out'))
    s=(dest/'src/root.zig').read_text().replace('    const scale=if(modulus==p) inverse_field_scales[batches]', '    observed[if(modulus==p) 0 else 1][batches]+=1;\n    const scale=if(modulus==p) inverse_field_scales[batches]')
    s+='''
var observed:[2][26]u64=.{@splat(0),@splat(0)};
test "open divstep observed iterations" {
 observed=.{@splat(0),@splat(0)};
 var rng=std.Random.DefaultPrng.init(0x495445524154494f);
 for([_]u256{p,n}) |modulus| {
  for(0..100_000) |_| {_=try inverse(rng.random().int(u256)%(modulus-1)+1,modulus);}
  for([_]u256{1,3,5,7,modulus-1,modulus-2}) |input| {_=try inverse(input,modulus);}
  for(1..256) |bit| {const power=@as(u256,1)<<@as(u8,@intCast(bit));for([_]u256{power-1,power,power+1}) |input| {if(input<modulus) {_=try inverse(input,modulus);}}}
 }
 for(observed,0..) |hist,mod| for(hist,0..) |count,batches| {if(count!=0) std.debug.print("DIVCOUNT {d} {d} {d}\\n",.{mod,batches*30,count});};
}
'''
    (dest/'src/root.zig').write_text(s)
    with exclusive():out=docker(['zig','test','-O','ReleaseSafe','/work/divsteps-counts/src/root.zig','--test-filter','open divstep observed'])
    hist={}
    for mod,steps,count in re.findall(r'DIVCOUNT (\d+) (\d+) (\d+)',out):hist.setdefault('p' if mod=='0' else 'n',{})[steps]=int(count)
    assert len(hist)==2
    save(WORK/'divstep-iterations.json',dict(histograms=hist,proven_steps=741,batch_cap=750,scope='100000 random plus named adversarial families per modulus; observed maximum need not attain conservative bound'))

if __name__=='__main__':main()
