"""Restore one exact original source directory into a new destination."""
import argparse,hashlib,json
from pathlib import Path
ROOT=Path(__file__).resolve().parent
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('original',help='Repo-relative original directory from source-index.json')
p.add_argument('destination',type=Path)
a=p.parse_args();prefix=a.original.rstrip('/')+'/'
rows=[r for r in json.loads((ROOT/'source-index.json').read_text())['files'] if r['original'].startswith(prefix)]
if not rows:raise SystemExit('No source files for that prefix')
if a.destination.exists():raise SystemExit('Destination must not exist')
for r in rows:
 rel=Path(r['original'][len(prefix):]);assert not rel.is_absolute() and '..' not in rel.parts
 data=(ROOT/'objects'/r['sha256']).read_bytes();assert hashlib.sha256(data).hexdigest()==r['sha256']
 target=a.destination/rel;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data)
 if r['executable']:target.chmod(0o755)
print(f'Restored {len(rows)} source files; executables and caches must be rebuilt.')
