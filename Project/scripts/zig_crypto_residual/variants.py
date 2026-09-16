"""Construct isolated independently authored experiments from the frozen source."""
import argparse,re,shutil
from common import *
from derive import derive,sqrt_source

def replace_fn(s,name,body):
 start=s.index('fn '+name+'(');brace=s.index('{',start);depth=1;end=brace+1
 while depth:
  depth+=(s[end]=='{')-(s[end]=='}');end+=1
 return s[:start]+body+s[end:]

SCALAR='''
// c is 129 bits. Three folds leave <2n, not necessarily <2^256.
fn reduceScalar(w:u512) u256 {
 const mask:u512=std.math.maxInt(u256);
 const c:u512=(@as(u512,1)<<256)-n;
 var r=(w & mask)+(w>>256)*c;
 r=(r & mask)+(r>>256)*c;
 r=(r & mask)+(r>>256)*c;
 if(r>=n) r-=n;
 return @intCast(r);
}
fn scalar256(x:u256) u256 { return if(x>=n) x-n else x; }
'''
SQUARES='''
fn squares(a:u256,comptime count:usize) u256 {var r=a;for(0..count) |_| r=mul(r,r);return r;}
'''
TWEAK='''
fn generatorMultiply(k:u256) Point {
 const digits=recodeWidth(k,g_width);
 var result=Point.infinity();var i=digits.len;
 while(i!=0) {i-=1;result=result.double();if(digits.values[i]!=0) result=result.mixed(signedPoint(&generator_table,digits.values[i]));}
 return result;
}
'''
GENERATOR_GLV='fn generatorMultiply(k:u256) Point {\n const split=splitScalar(k);\n const a=recodeSigned(split[0],g_width);const b=recodeSigned(split[1],g_width);\n var result=Point.infinity();var length=@max(a.len,b.len);\n while(length!=0){length-=1;result=result.double();\n  if(a.values[length]!=0)result=result.mixed(signedPoint(&generator_table,a.values[length]));\n  if(b.values[length]!=0)result=result.mixed(signedPoint(&phi_generator_table,b.values[length]));\n }\n return result;\n}\n'
def make(name,scalar=False,sqrt=None,inverse=False,limb_inverse=False,limbs=False,glv=False,gw=5,pw=5,tweak=False):
 assert (WORK/'profile-ledger.json').exists(),'profile first'
 dest=WORK/name
 if dest.exists():shutil.rmtree(dest)
 shutil.copytree(FROZEN,dest,ignore=shutil.ignore_patterns('.zig-cache','zig-out'))
 s=(dest/'src/root.zig').read_text()
 if name=='baseline':
  save(WORK/(name+'-source.json'),dict(name=name,source_digest=source_digest(dest)))
  return dest
 if scalar:
  s+=SCALAR;s=s.replace('@intCast((@as(u512, read(digest)) * w) % n)','reduceScalar(@as(u512, read(digest)) * w)').replace('@intCast((@as(u512, sig.r.value) * w) % n)','reduceScalar(@as(u512, sig.r.value) * w)').replace('const e = read(&digest) % n;','const e = scalar256(read(&digest));')
 if sqrt:s+=SQUARES+sqrt_source(sqrt);s=s.replace('pow(rhs, (p + 1) / 4, p)','sqrtPower(rhs)')
 if inverse:s=s.replace('@intCast((@as(u257, x) + modulus) >> 1)','(x >> 1) + (modulus >> 1) + 1')
 if limb_inverse:
  s+='\nconst limb_inv=@import("inverse_limbs.zig");\n';s=replace_fn(s,'inverse','fn inverse(input:u256,modulus:u256) Error!u256 { return limb_inv.inverse(input,modulus); }')
  shutil.copy(HERE/'inverse_limbs.zig',dest/'src/inverse_limbs.zig')
 # Generalized separate-base widths keep the old recode as a test comparator.
 s+=f'\nconst g_width:usize={gw};\nconst p_width:usize={pw};\n'
 original=s[s.index('fn recode('):s.index('fn oddTable(')]
 generalized=original.replace('fn recode(scalar: u256)','fn recodeWidth(scalar: u256, comptime width:usize)').replace('remaining & 31','remaining & ((@as(u257,1)<<width)-1)').replace('residue > 16','residue > (1<<(width-1))').replace('residue - 32','residue - (1<<width)')
 s+=generalized
 s=s.replace('fn oddTable(point: Point) [8]Point {','fn oddTableWidth(point: Point, comptime width:usize) [1<<(width-2)]Point {\n const size=1<<(width-2);').replace('var table: [8]Point','var table: [size]Point').replace('for (1..8)','for (1..size)').replace('var prefix: [8]u256','var prefix: [size]u256').replace('var i: usize = 8;','var i: usize = size;').replace('@setEvalBranchQuota(1_000_000)','@setEvalBranchQuota(20_000_000)').replace('oddTable(g)','oddTableWidth(g,g_width)').replace('fn signedPoint(table: *const [8]Point, digit: i8)','fn signedPoint(table: anytype, digit: i8)')
 s=s.replace('const left = recode(a);','const left = recodeWidth(a,g_width);').replace('const right = recode(b);','const right = recodeWidth(b,p_width);').replace('[_]Point{Point.infinity()} ** 8 else oddTable(point)','[_]Point{Point.infinity()} ** (1<<(p_width-2)) else oddTableWidth(point,p_width)')
 if tweak:s+=TWEAK;s=s.replace('joint(t, pubkey.point, 1).affine()','generatorMultiply(t).mixed(pubkey.point).affine()')
 if limbs:
  shutil.copy(HERE/'field.zig',dest/'src/field.zig');s+='\nconst field=@import("field.zig");\n'
  s=replace_fn(s,'mul','fn mul(a:u256,b:u256) u256 { return field.multiply(a,b); }')
  s=replace_fn(s,'add','fn add(a:u256,b:u256) u256 { return field.add(a,b); }')
  s=replace_fn(s,'sub','fn sub(a:u256,b:u256) u256 { return field.subtract(a,b); }')
  s=re.sub(r'mul\((self\.[xyz]|[a-z0-9_]+), \1\)',r'field.square(\1)',s)
  s=s.replace('r=mul(r,r)','r=field.square(r)')
 if glv:
  beta,lam,a,b=derive()
  template=(HERE/'glv.zig.in').read_text()
  for key,value in {'BETA':hex(beta),'LAMBDA':hex(lam),'AX':str(a[0]),'AY':str(a[1]),'BX':str(b[0]),'BY':str(b[1])}.items():template=template.replace('@'+key+'@',value)
  s=replace_fn(s,'joint',template)
  if tweak:s=replace_fn(s,'generatorMultiply',GENERATOR_GLV)
 (dest/'src/root.zig').write_text(s)
 save(WORK/(name+'-source.json'),dict(name=name,source_digest=source_digest(dest),scalar=scalar,sqrt=sqrt,inverse=inverse,limb_inverse=limb_inverse,limbs=limbs,glv=glv,gw=gw,pw=pw,tweak=tweak))
 return dest
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('name')
 for flag in ['scalar','inverse','limb-inverse','limbs','glv','tweak']:p.add_argument('--'+flag,action='store_true')
 p.add_argument('--sqrt',choices=['chain','window']);p.add_argument('--gw',type=int,default=5);p.add_argument('--pw',type=int,default=5)
 a=vars(p.parse_args());make(**a)
