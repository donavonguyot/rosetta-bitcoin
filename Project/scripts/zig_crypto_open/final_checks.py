"""Bind integration evidence to the final package and explicit failure reason."""

import sys as _rb_sys
from pathlib import Path as _RBPath
_rb_sys.path.insert(0, str(_RBPath(__file__).resolve().parents[3] / 'Project/scripts'))
from state_root import operational_paths as _rb_paths
import json,re
from common import ROOT,WORK,LIB,source_digest,save


def main():
    path=WORK/'validation.json';validation=json.loads(path.read_text());checks=validation['checks']
    assert validation['source_digest']==source_digest(LIB)
    fault=checks['fault_injection'];status=fault['settled_status']
    log=((_rb_paths()['campaigns'] / 'crypto-lanes/zig-open-fault.log')).read_text()
    assert 'error: ScriptTerminalFalse' in log
    assert status['validated_height']==738 and status['stored_block_height']==738
    match=re.search(r'zig script verify failure tx_index=(\d+) input_index=(\d+) txid=([0-9a-f]{64}) err=ScriptTerminalFalse',log)
    assert match
    fault.update(failure='ScriptTerminalFalse',failing_next_height=739,stored_height_after_failure=738,tx_index=int(match[1]),input_index=int(match[2]),txid=match[3],scope='injected ECDSA rejection stops the first script-bearing block; Schnorr/tweak rejection is exercised in corpus fixtures')
    save(path,validation)

if __name__=='__main__':main()
