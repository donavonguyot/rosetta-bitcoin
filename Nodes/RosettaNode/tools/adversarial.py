#!/usr/bin/env python3
import ctypes as C,hashlib,importlib.util,json,re,subprocess,time
from pathlib import Path
from protocol import Engine,ROOT
from corpus import cases,evaluate
OUT=ROOT/'.local/tx'
def compile_module(text,name,host='host/sha256.c'):
    path=OUT/(name+'.ll');path.write_text(text)
    subprocess.run(['opt','-passes=verify,lint','-disable-output',str(path)],check=True,capture_output=True)
    subprocess.run(['clang','-O0','-shared','-fPIC',str(path),host,'-lcrypto','-o',str(OUT/(name+'.so'))],cwd=ROOT,check=True,capture_output=True)
def main():
    started=time.monotonic();source=(OUT/'module.ll').read_text();rows=cases()
    control=evaluate(Engine());assert all(r['pass'] for r in control.values())
    definitions=[
      ('canonicality','%canonical = icmp uge i64 %decoded, %minimum','%canonical = icmp uge i64 %decoded, 0','noncanonical',['decode_plain','identify_plain']),
      ('bounds','%fits = icmp ule i64 %n, %remain\n  %failed','%fits = icmp ult i64 %n, %remain\n  %failed','decode_plain',['unknown2','unknown3']),
      ('witness','%some = icmp ne i64 %n, 0','%some = icmp ugt i64 %n, 1','decode_empty_item',['decode_plain','identify_plain']),
      ('consumed','  ret i64 %status\nmalformed:', '  %earlier = sub i64 %pos, 1\n  call void @scan_pos_set(ptr %s, i64 %earlier)\n  ret i64 %status\nmalformed:','prefix_plain',['identify_plain','unknown2']),
      ('resource','%over = icmp ugt i64 %items, %budget','%over = icmp ugt i64 0, %budget','budget_complete',['decode_plain','budget_truncated']),
      ('hashing','@rn_sha256(ptr %first, i64 32, ptr %digest)','@rn_sha256(ptr %data, i64 %len, ptr %digest)','identify_plain',['decode_plain','serialize_plain_True']),
      ('structured','output:\n  call void @write_number(ptr %w, i64 %a, i64 8)','output:\n  call void @write_number(ptr %w, i64 0, i64 8)','modify_amount',['decode_plain','unknown2'])]
    explanations={
      'canonicality':'Only the deliberately non-shortest CompactSize case changes; ordinary single-byte encodings and structured emission remain unchanged.',
      'bounds':'Changing <= to < rejects reads that exactly exhaust the remaining bytes, including final locktime reads. Unknown optional flags still fail before that read, so those designated controls are unaffected.',
      'witness':'The changed presence predicate requires more than one item. One-item witness and budget fixtures therefore become superfluous-witness errors; ordinary transactions and their identifiers do not use this predicate.',
      'consumed':'Subtracting one from the successful cursor changes every successful decode consumption field, including zero-flags and prefix cases. Serialization and pre-success unknown-flag rejection do not use that return path.',
      'resource':'Disabling the final item-budget comparison accepts both explicit-budget and default-budget complete oversized fixtures. Truncation still exits before the budget verdict; in-budget decodes are unchanged.',
      'hashing':'The second SHA-256 hashes the original serialization again instead of the first digest. All identity and modified-structure identity cases change; byte-only parsing and serialization remain unaffected.',
      'structured':'Writing zero instead of the supplied output amount changes serialization and identifiers of every nonzero-amount fixture. Decoding uses separate code, so its designated controls remain unaffected.'}
    mutations={}
    for name,before,after,intended,unaffected in definitions:
        assert source.count(before)==1,(name,source.count(before))
        changed=source.replace(before,after);compile_module(changed,'mutant_'+name)
        result=evaluate(Engine('mutant_'+name));assert not result[intended]['pass'];assert all(result[x]['pass'] for x in unaffected)
        failures=[k for k,v in result.items() if not v['pass']]
        mutations[name]={'applied':True,'compiled':True,'intended':intended,'intended_kill':True,'unaffected_controls':unaffected,'matrix':result,'additional_failures':[x for x in failures if x!=intended],'additional_failure_explanation':explanations[name]+' No build error or crash is counted as a semantic kill.','module_sha256':hashlib.sha256(changed.encode()).hexdigest()}
    # Display reversal is presentation in the ABI marshaler, not parsing IR.
    path=OUT/'mutant_byte_order.py';original=(ROOT/'tools/protocol.py').read_text();assert original.count('txid[::-1].hex()')==2
    changed=original.replace('txid[::-1].hex()','txid.hex()').replace("ROOT=Path(__file__).resolve().parents[1]",f'ROOT=Path({str(ROOT)!r})');path.write_text(changed)
    subprocess.run(['python3','-m','py_compile',str(path)],check=True)
    spec=importlib.util.spec_from_file_location('byteorder_mutant',path);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    result=evaluate(module.Engine());assert not result['identify_plain']['pass'] and result['decode_plain']['pass']
    mutations['byte_order']={'applied':True,'compiled':True,'layer':'presentation marshaler','intended':'identify_plain','intended_kill':True,'unaffected_controls':['decode_plain'],'matrix':result,'additional_failures':[k for k,v in result.items() if not v['pass'] and k!='identify_plain'],'additional_failure_explanation':'Removing digest-to-display reversal changes all identify outputs, including modified-structure identifiers. Decode and serialization-only results have no display-order field.','module_sha256':hashlib.sha256(changed.encode()).hexdigest()}
    # Disposable counters record authored blocks, with phi nodes left first.
    authored=set(re.findall(r'define(?: internal)? [^@]+@([^ (]+)',(ROOT/'generated/compactsize.ll').read_text()+(ROOT/'generated/transactions.ll').read_text()))
    mapping={};current=None;lines=[];pending=None
    for line in source.splitlines():
        m=re.match(r'define.*@([^ (]+)',line)
        if m:current=m[1]
        if pending is not None and not re.match(r'\s+%.* = phi ',line):
            lines.append(f'  call void @rn_hit(i32 {pending})');pending=None
        lines.append(line)
        if re.match(r'^[A-Za-z][A-Za-z0-9_]*:',line) and current in authored:
            idx=len(mapping);mapping[idx]=current+':'+line.strip()[:-1];pending=idx
    instrumented='\n'.join(lines)+'\ndeclare void @rn_hit(i32)\n'
    host=OUT/'counter.c';host.write_text((ROOT/'host/sha256.c').read_text()+f'\nstatic unsigned long hits[{len(mapping)}];\nvoid rn_hit(int n){{hits[n]++;}}\nunsigned long rn_count(int n){{return hits[n];}}\n')
    compile_module(instrumented,'coverage',str(host));engine=Engine('coverage');assert all(x['pass'] for x in evaluate(engine).values())
    engine.lib.rn_count.argtypes=[C.c_int];engine.lib.rn_count.restype=C.c_ulong
    hit=[i for i in mapping if engine.lib.rn_count(i)]
    reached={mapping[i].split(':')[0] for i in hit};assert reached==authored,(authored-reached)
    report={'schema':'rosettanode.adversarial.v1','status':'passed','control':control,'mutations':mutations,'coverage':{'authored_symbols':sorted(authored),'reached_symbols':sorted(reached),'blocks':mapping,'hit':hit,'branch_gaps':[mapping[i] for i in mapping if i not in hit],'exclusions':['mechanical context accessors','C SHA primitive internals','JSON marshaler internals'],'interpretation':'Block reachability, not exhaustive edge/path coverage. Gaps retained; all authored executable symbols reached.'},'elapsed_seconds':time.monotonic()-started}
    (ROOT/'evidence/adversarial.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({'status':report['status'],'mutants':len(mutations),'cases':len(rows),'symbols_reached':len(reached),'branch_gaps':report['coverage']['branch_gaps']}))
if __name__=='__main__':main()
