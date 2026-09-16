"""Package the confirmed configuration before final, untouched holdout."""
import json,shutil
from common import WORK,HERE,FROZEN,save,source_digest,run


def main():
    choice=json.loads((WORK/'selection-confirmation.json').read_text())['selected']
    source=FROZEN if choice=='baseline' else WORK/choice
    dest=WORK/'candidate'
    if dest.exists():raise ValueError('Refusing to replace existing candidate')
    shutil.copytree(source,dest,ignore=shutil.ignore_patterns('.zig-cache','zig-out'))
    if choice!='baseline':
        if not choice.startswith('shared-z-g'):raise ValueError('Add explicit packaging for non-window winner')
        config=json.loads((WORK/(choice+'-tables.json')).read_text())
        shutil.copy(HERE/'generate_tables.py.in',dest/'tools/generate_tables.py')
        save(dest/'tools/tables.json',config)
        run(['python3',dest/'tools/generate_tables.py'])
        with (dest/'DERIVATIONS.md').open('a') as f:
            f.write('\n## Common-Z variable tables and packed generator tables\n\n'+(HERE/'README.md').read_text().split('## Common-Z derivation\n\n')[1].split('## Batched inversion')[0])
            f.write('\nGenerator tables store canonical affine x/y coordinates as big-endian bytes. `tools/generate_tables.py` reproduces every entry by the package-owned affine recurrence; it verifies curve membership and independent scalar spot checks. `tools/tables.json` records the selected widths and byte identities. Ordinary builds require neither Python nor repository files. Signed width-16 recoding uses i16 digits and i32 residues to retain the carry without overflow.\n')
        with (dest/'README.md').open('a') as f:
            f.write('\nGenerator table data is packaged with the source. Audit it with `python3 tools/generate_tables.py`; normal builds remain standalone. Variable tables use a common coordinate scale without field inversion. Inversion and scalar multiplication remain variable-time on public inputs. This remains an experimental verification-only package.\n')
    if choice!='baseline':
        path=dest/'DERIVATIONS.md'
        text=path.read_text().replace('separate-base width-5 design','separate-base signed-window design').replace('and normalized once, then transformed by x -> beta*x. Compile-time generator\ntables are calculated from package arithmetic.','on one common scale without inversion, then transformed by x -> beta*x.\nPacked generator tables are generated with package-owned arithmetic.').replace('there is no joint matrix or shared-Z table.','there is no joint matrix. Coordinate scales are handled as described below.')
        path.write_text(text)
    save(WORK/'candidate-configuration.json',dict(selected=choice,source_digest=source_digest(dest),field='widened u256/u512',inversion='binary GCD',shared_z=choice!='baseline',scoped_unchecked=False,assembly=False))
    print(choice,source_digest(dest))

if __name__=='__main__':main()
