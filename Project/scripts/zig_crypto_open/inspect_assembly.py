"""Static assembly observations, kept separate from runtime operation counts."""
import json,re
from common import WORK,save,digest
from assembly import audit


def main():
    observations={}
    for name in ('wide','checked','unchecked'):
        path=WORK/('primitive-'+name+'.s');text=path.read_text()
        observations[name]=dict(sha256=digest(path),audit=audit(text),static_mul_instructions=len(re.findall(r'^\s*mul\s',text,re.M)),static_umulh_instructions=len(re.findall(r'^\s*umulh\s',text,re.M)),scope='entire emitted file counts, including harness; not dynamic field-operation counts')
        assert observations[name]['audit']['passed']
    save(WORK/'assembly-a0.json',observations)
    path=WORK/'profile-counts.s';text=path.read_text();profile=json.loads((WORK/'profile-ledger.json').read_text())
    profile['assembly'].update(inline_schoolbook='widened field multiplication lowers into inline ARM64 mul/umulh partial products; no out-of-line field kernel calls in designated hot regions',general_division_present=True,general_division_symbols=sorted(set(re.findall(r'\bbl\s+(__\w*(?:div|mod)\w*)',text))),spills='stack loads/stores observed in joint multiplication; static stack observations recorded separately',overflow_checks='ReleaseSafe conditional branches to failure paths remain; safety counterfactual measures whole-build effects, not an isolated per-check cost')
    save(WORK/'profile-ledger.json',profile)

if __name__=='__main__':main()
