#!/usr/bin/env python3
"""Render both PDFs and contact sheets; human/agent inspection is a separate step."""
import argparse,hashlib,json,re,subprocess
from pathlib import Path
from PIL import Image,ImageDraw
ROOT=Path(__file__).resolve().parents[1]

def main():
    p=argparse.ArgumentParser();p.add_argument('--label',default='final-review');a=p.parse_args()
    if not re.fullmatch(r'[a-zA-Z0-9_-]+',a.label):raise ValueError('Bad review label')
    directory=ROOT/'.local/transaction-book';out=directory/a.label;out.mkdir()
    documents={}
    for name in ['rosettanode','reconstruction']:
        source=directory/(name+'.pdf')
        subprocess.run(['pdftoppm','-r','120','-png',str(source),str(out/name)],check=True,capture_output=True)
        files=sorted(out.glob(name+'-*.png'))
        documents[name+'.pdf']={'pages':len(files),'sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'renders':[str(path.relative_to(ROOT)) for path in files]}
        for start in range(0,len(files),6):
            sheet=Image.new('RGB',(1080,3*540),'#e5e5e5');draw=ImageDraw.Draw(sheet)
            for i,path in enumerate(files[start:start+6]):
                page=Image.open(path);page.thumbnail((515,510));x=(i%2)*540;y=(i//2)*540
                sheet.paste(page,(x+10,y+25));draw.text((x+10,y+6),path.stem,fill='black')
            sheet.save(out/(name+f'-contact-{start//6}.png'))
    manifest={'schema':'rosettanode.pdf_render.v1','status':'awaiting_visual_review','documents':documents,'figures':[]}
    (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n');print(json.dumps(manifest))
if __name__=='__main__':main()
