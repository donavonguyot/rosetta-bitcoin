"""Generate mathematical constants and sqrt schedules without implementation imports."""
import json,hashlib
from pathlib import Path
WORK=Path(__file__).resolve().parent
def save(path,obj): pass
P=2**256-2**32-977;N=int('fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141',16)
G=(int('79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798',16),int('483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8',16))
def plus(a,b):
 if a is None:return b
 if b is None:return a
 x,y=a;u,v=b
 if x==u and (y+v)%P==0:return None
 slope=((3*x*x)*pow(2*y,-1,P) if a==b else (v-y)*pow(u-x,-1,P))%P
 z=(slope*slope-x-u)%P
 return z,(slope*(x-z)-y)%P

def multiply(k,a=G):
 r=None
 for bit in bin(k)[2:]:
  r=plus(r,r)
  if bit=='1':r=plus(r,a)
 return r

def root(m):
 for a in range(2,1000):
  r=pow(a,(m-1)//3,m)
  if r!=1:return r
 raise ValueError('no root')

def nearest(a,b):
 if b<0:a,b=-a,-b
 return (1 if a>=0 else -1)*((2*abs(a)+b)//(2*b))

def derive():
 beta=root(P);lam=root(N)
 if multiply(lam)!=(beta*G[0]%P,G[1]):lam=lam*lam%N
 assert multiply(lam)==(beta*G[0]%P,G[1])
 a=(N,0);b=(-lam,1)
 dot=lambda x,y:sum(u*v for u,v in zip(x,y))
 while True:
  if dot(a,a)>dot(b,b):a,b=b,a
  q=nearest(dot(a,b),dot(a,a))
  if q==0:break
  b=tuple(v-q*u for u,v in zip(a,b))
 det=a[0]*b[1]-b[0]*a[1]
 if det<0:b=tuple(-v for v in b);det=-det
 assert det==N
 assert all((x+lam*y)%N==0 for x,y in (a,b))
 # Coordinate error is bounded by half the sum of absolute basis coordinates.
 bounds=[(abs(a[i])+abs(b[i])+1)//2 for i in (0,1)]
 assert max(bounds)<2**129
 C=2**256-N;bound=2**512-1;fold=[]
 for _ in range(3):bound=(2**256-1)+(bound>>256)*C;fold.append(bound)
 assert bound<2*N
 result=dict(beta=hex(beta),lam=hex(lam),basis=[a,b],determinant=str(det),coordinate_bounds=list(map(str,bounds)),scalar_fold_upper_bounds=list(map(str,fold)),proof='nearest coefficient errors <=1/2; coordinate residual bounded by (abs(basis0[i])+abs(basis1[i]))/2')
 save(WORK/'derivation.json',result)
 return beta,lam,a,b

def sqrt_source(kind):
 exponent=(P+1)//4
 if kind=='window':
  digits=[int(x,16) for x in hex(exponent)[2:]];symbol=0
  for d in digits:symbol=16*symbol+d
  assert symbol==exponent
  return '''fn sqrtPower(a:u256) u256 {
 var powers:[16]u256=undefined; powers[0]=1; powers[1]=a;
 for(2..16) |i| powers[i]=mul(powers[i-1],a);
 var r:u256=1;
 inline for ([_]u4{'''+','.join(map(str,digits))+'''}) |digit| {
  r=squares(r,4); if(digit!=0) r=mul(r,powers[digit]);
 }
 return r;
}
'''
 import itertools
 runs=[(bit,len(list(group))) for bit,group in itertools.groupby(bin(exponent)[2:])]
 lines=['fn sqrtPower(a:u256) u256 {',' const m1=a;'];known={1:1};mults=0
 def ones(k):
  nonlocal mults
  if k in known:return
  half=k//2;ones(half)
  if k%2==0:lines.append(f' const m{k}=mul(squares(m{half},{half}),m{half});');known[k]=known[half]*(2**half+1)
  else:
   ones(k-1);lines.append(f' const m{k}=mul(squares(m{k-1},1),a);');known[k]=known[k-1]*2+1
  mults+=1;assert known[k]==2**k-1
 for bit,k in runs:
  if bit=='1':ones(k)
 lines.append(' var r:u256=1;');symbol=0
 for idx,(bit,k) in enumerate(runs):
  if idx==0:lines.append(f' r=m{k};');symbol=known[k]
  else:
   lines.append(f' r=squares(r,{k});');symbol<<=k
   if bit=='1':lines.append(f' r=mul(r,m{k});');symbol+=known[k];mults+=1
 assert symbol==exponent
 lines.extend([' return r;','}']);save(WORK/'sqrt-chain-proof.json',dict(exponent=hex(exponent),runs=runs,multiplications=mults,symbolic_verified=True))
 return '\n'.join(lines)+'\n'
if __name__=='__main__':
 beta,lam,a,b=derive()
 text=(Path(__file__).resolve().parents[1]/'src/root.zig').read_text()
 import re
 for name,value in [('beta',beta),('lambda',lam)]:
  found=re.search(r'const '+name+r': u256 = (0x[0-9a-f]+);',text)
  assert found and int(found[1],16)==value,name
 for name,values in [('basis_a',a),('basis_b',b)]:
  found=re.search(r'const '+name+r': \[2\]i512 = \.\{ ([^}]+) \};',text)
  assert found and tuple(map(int,found[1].split(',')))==values,name
 print(json.dumps({'beta':hex(beta),'lambda':hex(lam),'basis':[a,b],'symbolic_sqrt_verified':bool(sqrt_source('chain')),'result':'passed'}))
