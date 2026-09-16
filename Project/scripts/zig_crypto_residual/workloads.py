"""Reference-generated tuning/holdout data, exclusively outside timed work."""
import itertools,hashlib,inspect,textwrap
from differential import refmod
from common import *
def main():
 ref=refmod.Reference(ROOT/'Project/.campaigns/crypto-lanes/reference-build/lib/libsecp256k1.dylib')
 cases=list(ref.cases(256));groups={}
 source=textwrap.dedent(inspect.getsource(refmod.Reference.cases)).replace('rosetta-secp-test-', 'rosetta-residual-holdout-')
 scope=dict(refmod.__dict__);exec(source,scope)
 holdout=list(scope['cases'](ref,256))
 bad_s='3026020101022100fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141'
 for phase,offset in [('tuning',0),('holdout',0)]:
  if phase=='holdout':cases=holdout
  groups={name:[] for name in ['ecdsa/valid','schnorr/valid','parse/valid','tweak/valid','ecdsa/late_invalid','schnorr/late_invalid','parse/early_invalid','tweak/early_invalid','ecdsa/scalar_early_invalid']}
  for i in range(offset,offset+256):
   e=cases[i*15];s=cases[i*15+6];t=cases[i*15+12]
   for name,row,expected in [('ecdsa/valid',e,True),('schnorr/valid',s,True),('parse/valid',e,True),('tweak/valid',t,True),('ecdsa/late_invalid',cases[i*15+1],False),('schnorr/late_invalid',cases[i*15+7],False),('parse/early_invalid',('parse',b'\0',b'',b''),False),('tweak/early_invalid',('tweak',t[1],b'',b''),False),('ecdsa/scalar_early_invalid',('ecdsa',e[1],e[2],bytes.fromhex(bad_s)),False)]:
    op,key,msg,sig=row
    groups[name].append(dict(key=key.hex(),message=msg.hex(),signature=sig.hex(),expected=expected))
  data=json.dumps(groups,separators=(',',':'));(WORK/(phase+'.json')).write_text(data)
  save(WORK/(phase+'-identity.json'),dict(sha256=hashlib.sha256(data.encode()).hexdigest(),cases_per_group=256,reference_commit=refmod.COMMIT,secret_seed_namespace='rosetta-secp-test' if phase=='tuning' else 'rosetta-residual-holdout',index_start=offset))
if __name__=='__main__':main()
