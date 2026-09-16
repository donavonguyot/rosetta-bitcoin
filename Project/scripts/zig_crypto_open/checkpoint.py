"""Seal profile deferrals and the prescribed post-field/common-Z checkpoint."""
import json,statistics
from common import WORK,save
from selection import samples


def main():
    profile=json.loads((WORK/'profile-ledger.json').read_text())
    scalar=max(r.get('exclusive_share',0) for r in profile['rows'] if r['primitive']=='scalar_reduce' and r['operation'] in (0,1))
    if scalar>.01:raise ValueError('Montgomery experiment triggered; must implement before sealing')
    profile['roster']['scalar_montgomery']={'decision':'deferred','exclusive_share':scalar,'threshold':.01}
    for name in ('sha256','der','byte_io','glv_split','recode'):
        shares=[r for r in profile['rows'] if r['primitive']==name and r['operation'] in (0,1,2)]
        profile['deferrals'][name]={'exclusive_shares':{str(r['operation']):r.get('exclusive_share',0) for r in shares},'reason':'provider/API unchanged; no additional speculative round after failed feasibility checkpoint'}
    profile['roster_locked']=True
    save(WORK/'profile-ledger.json',profile)
    baseline=json.loads((WORK/'shared-z-tuning-bench.json').read_text())
    control=json.loads((WORK/'control-selection.json').read_text())['selected']
    ratios={op:[statistics.median(samples(baseline,op,b))/statistics.median(samples(control,op,b)) for b in range(2)] for op in ('ecdsa/valid','schnorr/valid')}
    failed=all(min(v)>1.3 for v in ratios.values())
    save(WORK/'feasibility.json',dict(result='failed' if failed else 'passed',ratios=ratios,threshold=1.3,extra_speculative_rounds=not failed,remaining_named_experiments=['divstep','widths','comb'],field='widened; A0 rejected'))
    print(ratios)

if __name__=='__main__':main()
