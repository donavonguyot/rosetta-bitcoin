"""Unchanged-package ReleaseSafe/ReleaseFast diagnostic, never shipping selection."""

import sys as _rb_sys
from pathlib import Path as _RBPath
_rb_sys.path.insert(0, str(_RBPath(__file__).resolve().parents[3] / 'Project/scripts'))
from state_root import operational_paths as _rb_paths
import shutil
import statistics
from common import ROOT, WORK, FROZEN, BUILDER, run, docker, save, digest, exclusive


def main():
    shutil.copy(ROOT/'Project/scripts/zig_crypto_residual/bench.zig', WORK/'safety-bench.zig')
    shutil.copy((_rb_paths()['campaigns'] / 'zig-residual/tuning.json'), WORK/'safety-inputs.json')
    result = {'schema': 'rb.zig_open_safety_diagnostic.v1', 'builder': BUILDER,
              'input_sha256': digest(WORK/'safety-inputs.json'),
              'baseline': __import__('json').loads((ROOT/'Project/scripts/zig_crypto_open/baseline.json').read_text()),
              'measurements': {}, 'interpretation': 'Whole-build counterfactual, not an upper bound on scoped arithmetic savings.'}
    with exclusive():
        result['environment'] = docker(['sh','-c','uname -a; zig version; cat /proc/self/status | sed -n "/Cpus_allowed_list/p"; cat /proc/loadavg'])
        result['host_thermal_observation'] = run(['pmset', '-g', 'therm'])
        for mode in ('ReleaseSafe','ReleaseFast'):
            docker(['zig','build-exe','-O',mode,'--dep','secp256k1','-Mroot=/work/safety-bench.zig',
                    '-O',mode,'-Msecp256k1=/work/frozen/Libraries/Zig/libsecp256k1-zig/src/root.zig',
                    '-femit-bin=/work/safety-'+mode])
            result['measurements'][mode] = []
        for batch in range(2):
            for mode in (('ReleaseSafe','ReleaseFast') if batch==0 else ('ReleaseFast','ReleaseSafe')):
                output=docker(['/work/safety-'+mode,'/work/safety-inputs.json',str(batch)])
                result['measurements'][mode].extend(__import__('json').loads(s) for s in output.splitlines())
    ops=('ecdsa/valid','schnorr/valid','parse/valid','tweak/valid')
    result['medians_ns']={mode:{op:statistics.median(r['total_ns']/r['iterations'] for r in rows if r['operation']==op) for op in ops} for mode,rows in result['measurements'].items()}
    result['time_reduction']={op:1-result['medians_ns']['ReleaseFast'][op]/result['medians_ns']['ReleaseSafe'][op] for op in ops}
    save(WORK/'safety.json',result)
    print(result['medians_ns']);print(result['time_reduction'])

if __name__=='__main__': main()
