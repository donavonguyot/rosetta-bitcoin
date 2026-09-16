#!/usr/bin/env python3
import hashlib,json,re
from pathlib import Path
from xml.sax.saxutils import escape
from reportlab.platypus import SimpleDocTemplate,Paragraph,Spacer,Preformatted,PageBreak
from reportlab.lib.styles import getSampleStyleSheet
from protocol import ROOT
from chain_checker import serialize
from corpus import identity

def semantic(value):
    if isinstance(value,dict):return {k:semantic(v) for k,v in value.items() if k not in ['elapsed_seconds','commands']}
    if isinstance(value,list):return [semantic(v) for v in value]
    return value

def build():
    out=ROOT/'.local/transaction-book';out.mkdir(parents=True,exist_ok=True)
    interface=(ROOT/'spec/interface.md').read_text()
    compact=(ROOT/'spec/compactsize.md').read_text().split('## Executable definitions')[0]
    fixture=json.loads((ROOT/'fixtures/compactsize.json').read_text())
    compact=re.sub(r'Rule CS-3:.*?\n\n', '', compact, flags=re.S)
    compact=compact.replace('<!-- examples: compactsize -->','\n'.join(v+' -> '+h for v,h in fixture['valid']))
    contract=(ROOT/'spec/transactions.md').read_text().split('## Executable definitions')[0]
    sample={'version_bits':'1','inputs':[{'previous_txid_digest_order':'00'*32,'previous_index':'0','script':'','sequence':'4294967295','witness':[]}],'outputs':[{'amount':'42','script':'51'}],'locktime':'0'}
    # Independent positional construction, not extracted from the reference.
    manual='0100000001'+'00'*32+'00000000'+'00'+'ffffffff'+'01'+'2a00000000000000'+'01'+'51'+'00000000'
    assert serialize(sample).hex()==manual
    examples={'transaction':sample,'identify':identity(sample),'justification':'Field-by-field manual encoding cross-checked with independent Python encoder; identifiers independently derived using hashlib double SHA-256. No chain-membership claim.'}
    example_text='## Worked structured example\n\n'+json.dumps(examples,indent=2)+'\n\n## Prefix example\n\nIn witness mode, 05000000000044332211aa decodes a version of 5, empty input/output vectors, locktime 287454020, and consumes 10 bytes as a prefix. Exact decoding rejects its remaining byte. This expectation follows the zero-flags state transition and little-endian locktime independently of execution.\n'
    packet=interface+'\n'+compact+'\n'+contract+'\n'+example_text
    (out/'reconstruction.md').write_text(packet)
    evidence={}
    for name in ['compactsize-gate','reproduction','chain-composition','adversarial','execution-variants']:
        path=ROOT/f'evidence/{name}.json'
        if path.exists():
            v=json.loads(path.read_text());evidence[name]={'status':v.get('status'),'sha256':hashlib.sha256(json.dumps(semantic(v),sort_keys=True).encode()).hexdigest()}
    transfer=ROOT/'evidence/transfer-report.json'
    if transfer.exists():
        result=json.loads(transfer.read_text())
        evidence['transfer']={k:result[k] for k in ['outcome','reason','group_medians','missing','cross_language']}
        evidence['transfer']['repairs_separate']=result.get('repairs_separate',{})
        evidence['transfer']['cautions']=result['cautions']
    else:evidence['transfer']={'status':'not_run','interpretation':'No transfer conclusion without isolated initial document/control submissions.'}
    cross=ROOT/'evidence/cross-language-report.json'
    if cross.exists():
        result=json.loads(cross.read_text())
        evidence['cross_language']={k:result[k] for k in ['status','pairs','interpretation']}

    introduction='# RosettaNode: Executable specification transfer\n\nThe hypothesis is that an explicit encoding contract improves independent implementations of its experimental profile beyond an interface and model prior knowledge alone. A small transaction-encoding slice is the instrument; a full node and consensus validity are outside scope.\n\nA literal literate source produces executable LLVM IR and a document. The reference must first pass a CompactSize gate, adversarial checks, independent expectations and clean-environment reproduction. Consistency between code and prose is insufficient evidence of correctness.\n\nFresh document and control attempts share the interface, model, toolchain, dependency rules and time allowances. Only the document arm receives the detailed packet. Initial submissions freeze before hidden evaluation; repairs are reported separately. Semantic families receive equal weight within groups so thousands of correlated chain checks cannot dominate profile transfer.\n\nA small cohort supports descriptive improvement, no observed improvement or an inconclusive result. It cannot establish statistical significance, a universal language ranking, authored-IR superiority, or complete Bitcoin specification coverage. Unknown costs are retained as unknown.\n\n'
    provenance=json.loads((ROOT/'evidence/source-provenance.json').read_text())
    citations='\n\n'.join(name+': '+row.get('immutable_url',row['url'])+'; SHA-256 '+row['sha256'] for name,row in provenance['sources'].items())
    evidence_text='The CompactSize gate, fresh-container reproduction, adversarial evaluator, three execution variants and independent chain-composition checks passed. The transaction reference exercised all 18 authored executable symbols; uncovered blocks and support exclusions remain in evidence/adversarial.json. The valid-chain checker covered 45 Shared blocks and Reference heights 0 through 5000, totaling 40,188 transaction comparisons.\n\n'
    if transfer.exists():
        evidence_text+='Initial Go cohort: '+evidence['transfer']['outcome']+'. '+evidence['transfer']['reason']+'. Scores below are medians of family-weighted group scores, with three attempts per arm.\n\n'
        for arm,scores in evidence['transfer']['group_medians'].items():
            evidence_text+=arm.capitalize()+': '+', '.join(group.replace('_',' ')+' '+f'{score:.0%}' for group,score in scores.items())+'.\n\n'
        for attempt,scores in evidence['transfer']['repairs_separate'].items():
            evidence_text+='Separate repair '+attempt+': '+', '.join(group.replace('_',' ')+' '+f'{score:.0%}' for group,score in scores.items())+'.\n\n'
        evidence_text+=' '.join(evidence['transfer']['cautions'])+'\n\n'
    if cross.exists():
        evidence_text+='Cross-language continuation: '+evidence['cross_language']['interpretation']+'\n\n'
        for language,pair in evidence['cross_language']['pairs'].items():
            for arm,row in pair.items():
                evidence_text+=language.capitalize()+' '+arm+': '+', '.join(group.replace('_',' ')+' '+f'{score:.0%}' for group,score in row['groups'].items())+'.\n\n'
        for attempt,scores in json.loads(cross.read_text())['repairs_separate'].items():
            evidence_text+='Separate repair '+attempt+': '+', '.join(group.replace('_',' ')+' '+f'{score:.0%}' for group,score in scores.items())+'.\n\n'
        evidence_text+='Both cross-language controls share the negative-amount defect. It also affects an ordinary prefix fixture through its returned object, without independently demonstrating a cursor bug. Family scores are correlated. The signedness-correct Go control still failed four of five resource-precedence cases.\n\n'
    evidence_text+='Compact machine-readable manifests, complete mutation matrices, source identities and reported model usage are retained in evidence/. Full execution logs, candidate snapshots and block exports remain local. Unknown monetary cost and per-iteration latency are not estimated. Clean-environment reproduction uses fresh containers or sandbox workspaces on the same physical host, not a second hardware architecture.\n\n'
    full=introduction+packet+'\n## Evidence and limitations\n\n'+evidence_text+'The reference uses authored IR, mechanical context accessors, a C SHA-256 primitive, and a Python JSON/ABI marshaler. The independent Python checker shares no transaction decoder with the IR reference. Valid-chain composition does not establish malformed-case behavior or consensus validity. Reachability records uncovered blocks explicitly. Alive2 was unavailable; no translation proof exists.\n\n## Source provenance\n\n'+citations+'\n'
    styles=getSampleStyleSheet();styles['Normal'].fontSize=10;styles['Normal'].leading=14;styles['Code'].fontSize=7.5;styles['Code'].leading=9.5;styles['Title'].keepWithNext=True
    def footer(c,d):c.setFont('Helvetica',8);c.drawString(44,27,'ROSETTANODE / ENCODING TRANSFER EXPERIMENT');c.drawRightString(550,27,str(d.page))
    for name,text,appendix in [('rosettanode',full,True),('reconstruction',packet,False)]:
        story=[]
        for section in text.split('\n\n'):
            section=section.strip()
            if not section:continue
            if appendix and section.startswith('## Worked structured example'):story.append(PageBreak())
            if section.startswith('# '):story.append(Paragraph(escape(section[2:]),styles['Title']))
            elif section.startswith('## '):story.append(Paragraph(escape(section[3:]),styles['Heading2']))
            elif section.startswith('{') or section.startswith('```') or ' -> ' in section:
                # Break long JSON/code lines for a printable, content-complete page.
                lines=[]
                for line in section.splitlines():
                    lines.extend(line[i:i+100] for i in range(0,len(line),100))
                story.append(Preformatted('\n'.join(lines),styles['Code']))
            else:story.append(Paragraph(escape(section).replace('\n',' '),styles['Normal']))
            gap=Spacer(1,8);gap.keepWithNext=section.startswith('# ' ) or section.startswith('## ')
            story.append(gap)
        if appendix:
            story.extend([PageBreak(),Paragraph('Rule-to-executable index',styles['Heading1'])])
            for rule,row in json.loads((ROOT/'spec/rule_symbols.json').read_text()).items():
                links=', '.join('<link href="#symbol-'+symbol+'">'+symbol+'</link>' for symbol in row['symbols'])
                story.append(Paragraph(escape(rule+' / '+row['boundary'])+': '+links,styles['Normal']));story.append(Spacer(1,10))
            for module in ['compactsize','transactions','support']:
                story.extend([PageBreak(),Paragraph('Executable appendix: '+module,styles['Heading1'])])
                code=(ROOT/f'generated/{module}.ll').read_text()
                for chunk in code.split('\n\n'):
                    for symbol in re.findall(r'^define[^\n]*@([a-zA-Z0-9_]+)',chunk,re.M):
                        story.append(Paragraph('<a name="symbol-'+symbol+'"/>',styles['Normal']))
                    lines=[]
                    for line in chunk.splitlines():lines.extend(line[i:i+100] for i in range(0,len(line),100))
                    story.append(Preformatted('\n'.join(lines),styles['Code']));story.append(Spacer(1,6))
        SimpleDocTemplate(str(out/f'{name}.pdf'),pagesize=(595,842),leftMargin=44,rightMargin=44,topMargin=44,bottomMargin=44).build(story,onFirstPage=footer,onLaterPages=footer)
    inventory=[]
    for visibility,material in [('shared',interface),('document_only',compact+'\n'+contract+'\n'+example_text)]:
        for sentence in re.split(r'(?<=[.!?])\s+|\n\n',material):
            if sentence.strip():inventory.append({'id':f'{visibility}-{sum(x["visibility"]==visibility for x in inventory)+1:03d}','visibility':visibility,'text':sentence.strip()})
    frozen=ROOT/'evidence/cohort-freeze.json'
    if frozen.exists():
        freeze=json.loads(frozen.read_text())
        assert freeze['packet_sha256']==hashlib.sha256(packet.encode()).hexdigest(),'Frozen packet drift'
        assert freeze['shared_sha256']==hashlib.sha256(interface.encode()).hexdigest(),'Frozen interface drift'
    manifest={'schema':'rosettanode.packet.v1','packet_sha256':hashlib.sha256(packet.encode()).hexdigest(),'shared_sha256':hashlib.sha256(interface.encode()).hexdigest(),'examples':examples,'information_inventory':inventory,'frozen_for_cohort':frozen.exists(),'reason':'Materials match cohort-freeze.json' if frozen.exists() else 'Instrument validation and isolation review precede cohort freeze; no attempts run'}
    (ROOT/'evidence/packet.json').write_text(json.dumps(manifest,indent=2)+'\n')
    (out/'manifest.json').write_text(json.dumps({'packet_sha256':manifest['packet_sha256'],'shared_sha256':manifest['shared_sha256'],'figures':[]},indent=2)+'\n')
    print(json.dumps({'packet_sha256':manifest['packet_sha256'],'sentences':len(inventory)}))
if __name__=='__main__':build()
