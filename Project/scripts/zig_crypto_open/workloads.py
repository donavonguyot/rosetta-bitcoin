"""Disjoint deterministic public API workloads; reference is test-only."""
import hashlib
import importlib.util
import inspect
import json
import textwrap
from common import ROOT, WORK, save


def main():
    spec=importlib.util.spec_from_file_location('reference_tool', ROOT/'Nodes/Shared/conformance/tools/crypto_lanes/differential.py')
    refmod=importlib.util.module_from_spec(spec);spec.loader.exec_module(refmod)
    archive=ROOT/'Project/.campaigns/crypto-lanes/reference.tar.gz'
    assert hashlib.sha256(archive.read_bytes()).hexdigest()==refmod.ARCHIVE_SHA256
    reference=refmod.Reference(ROOT/'Project/.campaigns/crypto-lanes/reference-build/lib/libsecp256k1.dylib')
    names=('ecdsa/valid','schnorr/valid','parse/valid','tweak/valid','ecdsa/late_invalid','schnorr/late_invalid','parse/early_invalid','tweak/early_invalid','ecdsa/scalar_early_invalid')
    bad_s=bytes.fromhex('3026020101022100fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141')
    for phase in ('tuning','confirmation','holdout'):
        namespace='rosetta-open-'+phase+'-'
        source=textwrap.dedent(inspect.getsource(refmod.Reference.cases)).replace('rosetta-secp-test-',namespace)
        scope=dict(refmod.__dict__);exec(source,scope)
        cases=list(scope['cases'](reference,256));groups={name:[] for name in names}
        for i in range(256):
            e,s,t=cases[i*15],cases[i*15+6],cases[i*15+12]
            rows=(e,s,e,t,cases[i*15+1],cases[i*15+7],('parse',b'\0',b'',b''),('tweak',t[1],b'',b''),('ecdsa',e[1],e[2],bad_s))
            for j,(name,(_,key,msg,sig)) in enumerate(zip(names,rows)):
                groups[name].append(dict(key=key.hex(),message=msg.hex(),signature=sig.hex(),expected=j<4))
        data=json.dumps(groups,separators=(',',':'))
        path=WORK/(phase+'.json')
        if path.exists() and path.read_text()!=data: raise RuntimeError('Workload identity changed')
        path.write_text(data)
        save(WORK/(phase+'-identity.json'),dict(sha256=hashlib.sha256(data.encode()).hexdigest(),namespace=namespace,cases_per_group=256,reference_commit=refmod.COMMIT))

if __name__=='__main__':main()
