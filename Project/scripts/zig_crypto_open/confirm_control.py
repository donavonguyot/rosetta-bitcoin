"""Confirm the strongest tuning configurations on a disjoint workload set."""
import json
import math
import statistics
from common import WORK, docker, save, digest, exclusive
from control import WINDOWS


def score(rows):
    return math.prod(statistics.median(r['total_ns']/r['iterations'] for r in rows if r['operation']==op) for op in ('ecdsa/valid','schnorr/valid','parse/valid'))**(1/3)


def main():
    configurations=[json.loads(path.read_text()) for path in WORK.glob('c-w*-lto?.json')]
    expected={(w,t,l) for w in WINDOWS for t in ('generic','native') for l in (False,True)}
    if {(r['window'],r['target'],r['lto']) for r in configurations}!=expected:raise ValueError('Incomplete control sweep')
    finalists=sorted(configurations,key=lambda r:score(r['measurements']))[:3]
    reports={r['name']:dict(configuration=r,measurements=[]) for r in finalists}
    with exclusive():
        for batch in range(2):
            for r in (finalists if batch==0 else reversed(finalists)):
                rows=[json.loads(line) for line in docker(['/work/'+r['name']+'-bench','/work/confirmation.json',str(batch)]).splitlines()]
                reports[r['name']]['measurements'].extend(rows)
    winner=min(reports,key=lambda name:score(reports[name]['measurements']))
    save(WORK/'control-selection.json',dict(selected=reports[winner]['configuration'],confirmation=reports,
      input_sha256=digest(WORK/'confirmation.json'),selection_rule='lowest equal-weight three-operation geometric mean on disjoint confirmation set',sweep_configurations=len(configurations)))
    print(winner)

if __name__=='__main__':main()
