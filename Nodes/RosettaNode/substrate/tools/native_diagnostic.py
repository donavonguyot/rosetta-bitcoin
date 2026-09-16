#!/usr/bin/env python3
"""Native ASan lane with swapped instrumented adapter; no whole-service claim."""
import json,os,time
from pathlib import Path
from service_probe import ROOT,Host,ITEM
from recovery_probe import complete

def main():
    base=ROOT/'.local'/('native-diagnostic-'+str(time.monotonic_ns()));base.mkdir();h=None
    try:
        h=Host(base,boundary='adapter_enter',transition='*',extra_env={'LD_PRELOAD':'/usr/lib/aarch64-linux-gnu/libasan.so.8:'+str(ROOT/'.local/interpose.so'),'ASAN_OPTIONS':'detect_leaks=0:abort_on_error=1'})
        assert h.request({'op':'submit','id':'job','items':[ITEM]})['status']=='accepted';h.barrier();h.release.touch();complete(h);h.stop()
        diagnostic=(h.root/'stderr').read_text();assert 'ERROR: AddressSanitizer' not in diagnostic
        result={'status':'passed','coverage':'native adapter/IR/arena access only; leak checking disabled for foreign runtime','diagnostics':str(h.root)}
    except Exception as e:
        diagnostic=(h.root/'stderr').read_text() if h else ''
        result={'status':'memory_fault' if 'ERROR: AddressSanitizer' in diagnostic else 'unsupported_or_execution_failure','error':repr(e),'diagnostic':diagnostic[-4000:]}
    finally:
        if h and h.process.poll() is None:h.process.kill();h.process.wait()
    Path('/output/native-diagnostic.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result));return int(result['status']!='passed')
if __name__=='__main__':raise SystemExit(main())
