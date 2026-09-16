#!/usr/bin/env python3
import hashlib,json,subprocess
from pathlib import Path
from corpus import cases
ROOT=Path(__file__).resolve().parents[1]
def main():
    rows=[r for r in cases() if r['request']['op'].startswith('decode')]
    requests=[]
    for row in rows:
        req=row['request'];raw=bytes.fromhex(req['bytes'])[int(req.get('offset','0')):]
        requests.append({'bytes':raw.hex(),'mode':req['mode']})
    result=subprocess.run([str(ROOT/'.local/btcd-comparison')],input=''.join(json.dumps(r)+'\n' for r in requests),capture_output=True,text=True,check=True)
    outcomes=[json.loads(line) for line in result.stdout.splitlines()];assert len(outcomes)==len(rows)
    compared=[]
    for row,actual in zip(rows,outcomes):
        expected=row['expected'];different=(expected['status']=='ok')!=(actual['status']=='ok')
        if 'consumed' in expected and actual.get('consumed')!=expected['consumed']:different=True
        compared.append({'id':row['id'],'profile_status':expected['status'],'btcd':actual,'difference':different,'interpretation':'Comparison witness only; btcd has its own deserialization limits, cursor/error order and no exact/profile budget operation.'})
    report={'schema':'rosettanode.btcd_comparison.v1','version':'v0.24.2','go_sum_sha256':hashlib.sha256((ROOT/'comparisons/btcd/go.sum').read_bytes()).hexdigest(),'rows':compared,'differences':sum(r['difference'] for r in compared),'authority':False}
    (ROOT/'evidence/btcd-comparison.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({'cases':len(rows),'differences':report['differences']}))
if __name__=='__main__':main()
