#!/usr/bin/env python3
"""Render the same literal source and independent fixtures to full/packet PDFs."""
import hashlib,json,re
from pathlib import Path
from xml.sax.saxutils import escape
from reportlab.platypus import SimpleDocTemplate,Paragraph,Spacer,Preformatted,PageBreak,Table,TableStyle
from reportlab.lib.styles import getSampleStyleSheet
from reportlab.lib import colors
ROOT=Path(__file__).resolve().parents[1]
def build():
    out=ROOT/'.local/book';out.mkdir(parents=True,exist_ok=True)
    source=(ROOT/'spec/compactsize.md').read_text()
    cases=json.loads((ROOT/'fixtures/compactsize.json').read_text())
    packet=source.split('## Executable definitions')[0]
    examples='\n'.join(f'{v} -> {h}' for v,h in cases['valid'])
    packet=packet.replace('<!-- examples: compactsize -->',examples)
    (out/'reconstruction.md').write_text(packet)
    styles=getSampleStyleSheet();styles['Normal'].fontSize=10;styles['Normal'].leading=14
    styles['Code'].fontSize=7;styles['Code'].leading=9
    def footer(canvas,doc):
        canvas.setFont('Helvetica',8);canvas.setFillColor(colors.HexColor('#556273'))
        canvas.drawString(44,27,'ROSETTANODE / EXPERIMENTAL ENCODING SPECIFICATION')
        canvas.drawRightString(550,27,str(doc.page))
    for name,full in [('compactsize',True),('reconstruction',False)]:
        story=[]
        for part in packet.split('\n\n'):
            part=part.strip()
            if not part:continue
            if part.startswith('# '):story.append(Paragraph(escape(part[2:]),styles['Title']))
            elif ' -> ' in part:story.append(Preformatted(part,styles['Code']))
            else:story.append(Paragraph(escape(part).replace('\n',' '),styles['Normal']))
            story.append(Spacer(1,10))
        if full:
            story.extend([PageBreak(),Paragraph('Executable appendix',styles['Heading1'])])
            ir=(ROOT/'generated/compactsize.ll').read_text()
            for chunk in ir.split('\n\n'):
                story.append(Preformatted(chunk,styles['Code']));story.append(Spacer(1,7))
        SimpleDocTemplate(str(out/(name+'.pdf')),pagesize=(595,842),leftMargin=44,rightMargin=44,topMargin=44,bottomMargin=44).build(story,onFirstPage=footer,onLaterPages=footer)
    manifest={'schema':'rosettanode.book.v1','source_sha256':hashlib.sha256(source.encode()).hexdigest(),'examples_sha256':hashlib.sha256((ROOT/'fixtures/compactsize.json').read_bytes()).hexdigest(),'packet_sha256':hashlib.sha256(packet.encode()).hexdigest(),'scope':'CompactSize only; not the transaction reconstruction packet','examples_provenance':cases['provenance']}
    (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n');return manifest
if __name__=='__main__':print(json.dumps(build()))
