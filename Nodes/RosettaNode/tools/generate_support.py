#!/usr/bin/env python3
"""Mechanical context accessors only; transaction control flow is literate authored IR."""
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def generated():
    out=['; Mechanical accessors. Regenerate with tools/generate_support.py.', '%Scan = type { ptr, i64, i64, i64, i64, ptr, i64 }', '%Write = type { ptr, i64, i64, i64 }']
    for typ,fields in [('Scan',[('data','ptr'),('len','i64'),('pos','i64'),('error','i64'),('items','i64'),('events','ptr'),('used','i64')]),('Write',[('out','ptr'),('cap','i64'),('pos','i64'),('error','i64')])]:
        for i,(name,t) in enumerate(fields):
            base=typ.lower()+'_'+name
            out.append(f'''define internal {t} @{base}(ptr %ctx) {{
entry:
  %p = getelementptr %{typ}, ptr %ctx, i32 0, i32 {i}
  %v = load {t}, ptr %p, align 1
  ret {t} %v
}}
define internal void @{base}_set(ptr %ctx, {t} %v) {{
entry:
  %p = getelementptr %{typ}, ptr %ctx, i32 0, i32 {i}
  store {t} %v, ptr %p, align 1
  ret void
}}''')
    return '\n\n'.join(out)+'\n'
if __name__=='__main__':
    import sys
    path=ROOT/'generated/support.ll';value=generated()
    if '--check' in sys.argv:assert path.read_text()==value,'Mechanical IR drift'
    else:path.write_text(value)
