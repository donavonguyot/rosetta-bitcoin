"""Reproduce embedded affine tables using only Python's standard library.

Ordinary Zig builds consume the packaged bytes; Python is needed only to audit
or regenerate them. This uses this package's independently derived arithmetic.
"""
import argparse,hashlib,json
from pathlib import Path
from derive_constants import G,P,derive,plus,multiply


def generate(width):
    beta,_,_,_=derive();point=G;step=plus(G,G);out=bytearray();phi=bytearray()
    count=1<<(width-2)
    for i in range(count):
        x,y=point
        assert (y*y-x*x*x-7)%P==0
        if i in (0,1,2,count//2,count-1):assert point==multiply(2*i+1)
        out.extend(x.to_bytes(32,'big')+y.to_bytes(32,'big'))
        phi.extend((beta*x%P).to_bytes(32,'big')+y.to_bytes(32,'big'))
        point=plus(point,step)
    return {'generator.bin':bytes(out),'phi-generator.bin':bytes(phi)}


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--write',action='store_true');args=parser.parse_args()
    root=Path(__file__).resolve().parents[1]
    config=json.loads((root/'tools/tables.json').read_text())
    for name,data in generate(config['generator_width']).items():
        if args.write:(root/'src'/name).write_bytes(data)
        else:assert (root/'src'/name).read_bytes()==data,name+' regeneration mismatch'
        print(name,hashlib.sha256(data).hexdigest())

if __name__=='__main__':main()
