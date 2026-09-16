#!/usr/bin/env python3
"""Test-only pinned libsecp256k1 oracle; candidate executables use public APIs.

The reference normalizes ECDSA high-S. Reference bool APIs cannot distinguish
malformed encodings from invalid equations; structured categories are tested by
the shared fixtures separately. No reference code is linked into candidates.
"""
import argparse, ctypes as c, hashlib, json, subprocess
from pathlib import Path
COMMIT='0cdc758a56360bf58a851fe91085a327ec97685a'
ARCHIVE_SHA256='385c115a21ee1ff31d0b0320acc2b278c92f7bde971f510566ad481a38835be0'
class Reference:
 def __init__(self,path):
  self.lib=c.CDLL(str(path));self.lib.secp256k1_context_create.argtypes=[c.c_uint];self.lib.secp256k1_context_create.restype=c.c_void_p
  self.ctx=self.lib.secp256k1_context_create(1)
  signatures={'ec_pubkey_parse':[c.c_void_p]*3+[c.c_size_t],'ecdsa_signature_parse_der':[c.c_void_p]*3+[c.c_size_t], 'ecdsa_signature_normalize':[c.c_void_p]*3,'ecdsa_verify':[c.c_void_p]*4,'xonly_pubkey_parse':[c.c_void_p]*3,'schnorrsig_verify':[c.c_void_p]*4+[c.c_size_t,c.c_void_p], 'xonly_pubkey_tweak_add':[c.c_void_p]*4,'xonly_pubkey_from_pubkey':[c.c_void_p]*4,'xonly_pubkey_serialize':[c.c_void_p]*3,'ec_pubkey_create':[c.c_void_p]*3,'ec_pubkey_serialize':[c.c_void_p]*3+[c.c_void_p,c.c_uint],'ecdsa_sign':[c.c_void_p]*6,'ecdsa_signature_serialize_der':[c.c_void_p]*4,'keypair_create':[c.c_void_p]*3,'schnorrsig_sign32':[c.c_void_p]*5}
  signatures['schnorrsig_verify']=[c.c_void_p,c.c_void_p,c.c_void_p,c.c_size_t,c.c_void_p]
  for name,args in signatures.items():getattr(self.lib,'secp256k1_'+name).argtypes=args
 def call(self,name,*args):return getattr(self.lib,'secp256k1_'+name)(self.ctx,*args)
 def run(self,op,key,msg,sig):
  pk=c.create_string_buffer(64)
  if op=='ecdsa':
   if len(msg)!=32 or not self.call('ec_pubkey_parse',pk,key,len(key)):return False
   signature=c.create_string_buffer(64)
   if not self.call('ecdsa_signature_parse_der',signature,sig,len(sig)):return False
   self.call('ecdsa_signature_normalize',signature,signature)
   return bool(self.call('ecdsa_verify',signature,msg,pk))
  if len(key)!=32 or not self.call('xonly_pubkey_parse',pk,key):return False
  if op=='schnorr':
   return len(sig)==64 and bool(self.call('schnorrsig_verify',sig,msg,len(msg),pk))
  if len(msg)!=32:return False
  out=c.create_string_buffer(64)
  if not self.call('xonly_pubkey_tweak_add',out,pk,msg):return False
  parity=c.c_int();self.call('xonly_pubkey_from_pubkey',pk,c.byref(parity),out);raw=c.create_string_buffer(32);self.call('xonly_pubkey_serialize',raw,pk)
  return raw.raw.hex()+':'+str(parity.value)
 def cases(self,count):
  n=int('fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141',16)
  for i in range(count):
   secret=(int.from_bytes(hashlib.sha256(f'rosetta-secp-test-{i}'.encode()).digest(),'big')%(n-1)+1).to_bytes(32,'big');msg=hashlib.sha256(b'message'+secret).digest()
   pk=c.create_string_buffer(64);assert self.call('ec_pubkey_create',pk,secret)
   key=c.create_string_buffer(33);size=c.c_size_t(33);assert self.call('ec_pubkey_serialize',key,c.byref(size),pk,258)
   signature=c.create_string_buffer(64);assert self.call('ecdsa_sign',signature,msg,secret,None,None)
   der=c.create_string_buffer(72);size=c.c_size_t(72);assert self.call('ecdsa_signature_serialize_der',der,c.byref(size),signature)
   pair=c.create_string_buffer(96);assert self.call('keypair_create',pair,secret);schnorr=c.create_string_buffer(64);assert self.call('schnorrsig_sign32',schnorr,msg,pair,bytes(32))
   for op,k,s in [('ecdsa',key.raw,der.raw[:size.value]),('schnorr',key.raw[1:],schnorr.raw)]:
    yield op,k,msg,s
    yield op,k,bytes(32),s
    yield op,k,msg,s[:-1]
    yield op,k,msg,s+bytes([0])
    yield op,k[:-1],msg,s
    mutated=bytearray(s);mutated[-1]^=1;yield op,k,msg,bytes(mutated)
   yield 'tweak',key.raw[1:],msg,b''
   yield 'tweak',key.raw[1:],bytes(32),b''
   yield 'tweak',key.raw[1:],n.to_bytes(32,'big'),b''
def main():
 p=argparse.ArgumentParser();p.add_argument('--reference',type=Path,required=True);p.add_argument('--candidate',type=Path);p.add_argument('--trace',type=Path);p.add_argument('--output',type=Path,required=True);p.add_argument('--count',type=int,default=32);a=p.parse_args();ref=Reference(a.reference);failures=[];count=0;ops={}
 if a.trace:
  cases=[]
  for line in a.trace.read_text().splitlines():
   if not line.startswith('rb.crypto_call '):continue
   op,key,msg,sig,result=line[len('rb.crypto_call '):].split(' ')
   cases.append((op,bytes.fromhex(key),bytes.fromhex(msg),bytes.fromhex(sig),result))
 else:cases=[(*row,None) for row in ref.cases(a.count)]
 for op,key,msg,sig,result in cases:
  want=ref.run(op,key,msg,sig)
  if result is None:
   result=subprocess.check_output([str(a.candidate.resolve()),op,key.hex(),msg.hex(),sig.hex()],text=True).strip()
  got=result if ':' in result else result in ('true','valid')
  if got!=want:failures.append({'index':count,'operation':op,'key':key.hex(),'message':msg.hex(),'signature':sig.hex(),'got':got,'expected':want})
  count+=1;ops[op]=ops.get(op,0)+1
 result={'reference_commit':COMMIT,'reference_archive_sha256':ARCHIVE_SHA256,'reference_binary_sha256':hashlib.sha256(a.reference.read_bytes()).hexdigest(),'cases':count,'operations':ops,'failures':failures,'result':'passed' if count and not failures else 'failed','high_s':'normalized in reference','error_mapping':'shared vectors check structured errors; reference API compares acceptance'}
 a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({k:v for k,v in result.items() if k!='failures'}));return 0 if result['result']=='passed' else 1
if __name__=='__main__':raise SystemExit(main())
