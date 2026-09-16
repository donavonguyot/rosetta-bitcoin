#!/usr/bin/env python3
"""Render the experiment report from retained measurements, never estimated costs."""
import json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def read(name):return json.loads((ROOT/f'evidence/{name}.json').read_text())
def scores(row):return ' | '.join(f'{row[key]:.0%}' for key in ['encoding','profile','structured','valid_chain'])

def main():
    go=read('transfer-report');cross=read('cross-language-report');gate=read('compactsize-gate');session=read('session');adversarial=read('adversarial');chain=read('chain-composition')
    text='# RosettaNode experiment report\n\n'
    text+=f'**Go initial result: {go["outcome"]}.** The document arm passed all evaluated families in all three attempts. Every Go control passed valid-chain composition, while the synthetic profile cases exposed differences. This is a small descriptive experiment, not a statistical or language-superiority claim.\n\n'
    text+='## Initial Go submissions\n\nScores average semantic families within each group. Chain composition is reported separately; its 80,376 requests cannot outweigh the profile or structured families.\n\n| Attempt | Arm | Encoding | Profile | Structured | Valid chain |\n|---|---|---:|---:|---:|---:|\n'
    for arm,rows in go['attempts'].items():
        for row in rows:text+=f'| {row["attempt"]} | {arm} | {scores(row["groups"])} |\n'
    text+='\nThe control structured scores need care: C2 and C3 treated negative output amounts as unsigned or rejected them. The synthetic structured families share negative amounts, so a single signedness defect accounts for many failures. A zero here does **not** establish absence of a serializer. Signedness also causes the ordinary prefix fixture to fail its returned-object comparison; that failure does not independently demonstrate a cursor bug. Family scores are not independent. Their successful valid-chain checks illustrate why valid data alone was insufficient.\n\nAll three Go controls passed only 1 of 5 resource-precedence cases: they accepted complete over-budget objects and classified some truncated/trailing inputs as resource-limited. C1 had no signedness defect and still scored 84% on the profile group, isolating an observed profile disagreement beyond the correlated amount failures. The frozen scoring is retained unchanged.\n\n'
    text+='## Separate Go repairs\n\nEach failing control received one bounded counterexample-assisted repair opportunity. These results do not alter the initial transfer result. No repair was needed for the perfect document submissions.\n\n| Attempt | Encoding | Profile | Structured | Valid chain |\n|---|---:|---:|---:|---:|\n'
    for name,row in go['repairs_separate'].items():text+=f'| {name} | {scores(row)} |\n'
    text+='\n## Conditional cross-language pairs\n\n'+cross['interpretation']+'\n\n| Language | Arm | Attempt | Encoding | Profile | Structured | Valid chain |\n|---|---|---|---:|---:|---:|---:|\n'
    for language,pair in cross['pairs'].items():
        for arm,row in pair.items():text+=f'| {language} | {arm} | {row["attempt"]} | {scores(row["groups"])} |\n'
    text+='\nBoth cross-language document submissions passed every evaluated family. The Rust and Zig controls showed the same unsigned interpretation of negative amounts as C2/C3, plus resource-profile disagreements. Their zero structured scores carry the same correlated-fixture limitation; both controls passed valid-chain composition. This is consistent with the Go packet effect, not evidence of a language ranking.\n'
    if cross['repairs_separate']:
        text+='\nCross-language repairs, separately scored:\n\n| Attempt | Encoding | Profile | Structured | Valid chain |\n|---|---:|---:|---:|---:|\n'
        for name,row in cross['repairs_separate'].items():text+=f'| {name} | {scores(row)} |\n'
    text+='\n## Instrument evidence\n\n'
    text+=f'- CompactSize gate: {gate["cases_per_build"]} cases per build, JIT/unoptimized/optimized agreement, canonicality mutation and unaffected controls, ASan seeded heap fault, rendered packet. Gate wall interval was {session["gate_elapsed_upper_bound_seconds"]:.1f} seconds, an upper bound on active work and below eight hours.\n'
    text+='- Alive2: **unsupported**, because `alive-tv` was unavailable. No translation proof is claimed.\n'
    text+=f'- Transaction execution: {read("execution-variants")["cases"]} cases agree across JIT/unoptimized/optimized execution, with a clean ASan lane. Eight semantic mutations have intended kills, complete matrices and passing designated controls.\n'
    text+=f'- Reachability: {len(adversarial["coverage"]["reached_symbols"])}/{len(adversarial["coverage"]["authored_symbols"])} authored symbols reached. Block gaps remain: '+', '.join('`'+s+'`' for s in adversarial['coverage']['branch_gaps'])+'. CompactSize has additional independent gate coverage; this is not exhaustive path coverage.\n'
    text+='- Independent Python commitment checker: '+', '.join(f'{row["blocks"]:,} {name} blocks ({row["transactions"]:,} transactions)' for name,row in chain['groups'].items())+f'; {chain["transaction_comparisons"]:,} transaction comparisons. It uses the last BIP141 commitment output and exact coinbase reserved-value shape. Altered commitments and transaction order are tested.\n'
    text+='- Structured-only, modified-field and decode-history challenges prevent retained bytes alone from satisfying the contract. Bounded randomized checks supplement the frozen cohort corpus.\n'
    text+='- Core 28.2/BIP provenance is hash-pinned. btcd is an evaluator-only comparison; disagreements and the existing Python port’s first-match commitment behavior are recorded without changing other ports.\n'
    text+='- Fresh containers reproduce reference test manifests and normalized document text. Fresh sandbox workspaces reproduce every initial and repaired candidate semantic result. These are clean environments on the same physical host, not independent hardware qualification.\n\n'
    text+='## Isolation, timing and accounting\n\nAll attempts use fresh local Codex sessions and the same model/configuration. Reading has a separate 15-minute allowance, implementation 60 minutes, and one repair 30 minutes. The candidate tool filesystem denies repository, evaluator, other attempts and user configuration reads; network probes are denied. Native image access was also tested. Compiler/library preparation is outside attempt timing. Standard-library dependencies only; no Bitcoin libraries. The model service connection is separate from denied candidate tool networking.\n\n'
    text+='Agents receive the Markdown packet corresponding to the PDF’s semantic content; this tests contract transfer, not PDF-reading ability. The frozen sentence inventory specifies the information difference. Temperature and seed are not exposed by this runner.\n\n| Attempt | Reading s | Initial s | Repair s |\n|---|---:|---:|---:|\n'
    ids=['D1','D2','D3','C1','C2','C3','RD1','RC1','ZD1','ZC1'];usage={};observations={}
    for name in ids:
        a=read('attempt-'+name);values=['—' if not a[p] else f'{a[p]["elapsed_seconds"]:.1f}' for p in ['reading','initial','repair']]
        text+='| '+name+' | '+' | '.join(values)+' |\n'
        observations[name]={}
        for phase in ['reading','implementation','repair']:
            path=ROOT/f'.local/cohort/{name}/logs/{phase}.jsonl'
            if path.exists():
                messages=[]
                for line in path.read_text().splitlines():
                    try:event=json.loads(line)
                    except ValueError:continue
                    item=event.get('item',{})
                    if event.get('type')=='item.completed' and item.get('type')=='agent_message':messages.append(item.get('text',''))
                observations[name][phase]=messages[-1] if messages else None
        for phase in ['reading','initial','repair']:
            if a[phase]:
                for row in a[phase]['usage']:
                    for key,value in row.items():usage[key]=usage.get(key,0)+value
    text+='\nCLI-reported usage totals across reading, initial and repair phases (cached/reasoning fields are subsets, not additive charges):\n\n```json\n'+json.dumps(usage,indent=2)+'\n```\n\nMonetary cost, parent-agent model usage, exact parent active time and per-iteration latency are unknown. Phase times are measured; they overlap and must not be summed as wall-clock campaign duration. Final gate commands and complete candidate event logs are retained; early parent exploratory tool calls were not completely counted. Candidate-reported ambiguity and completion notes are retained verbatim in `evidence/attempt-observations.json`; they are self-reports, not evaluator findings.\n\n'
    text+='## Source and deliverables\n\n| IR artifact | Ownership | Physical lines |\n|---|---|---:|\n'
    for name in ['compactsize','transactions','support']:
        text+=f'| `generated/{name}.ll` | '+('mechanically generated' if name=='support' else 'literally extracted authored IR')+f' | {len((ROOT/f"generated/{name}.ll").read_text().splitlines())} |\n'
    text+='\nThe IR owns transaction byte parsing, emission and double-SHA composition. C supplies SHA-256; Python marshals JSON/ABI values, handles transport admission and presents digest display order. Those boundaries are disclosed rather than attributed to the IR.\n\n- Full book: `.local/transaction-book/rosettanode.pdf`.\n- Reconstruction packet: `.local/transaction-book/reconstruction.pdf` and `.md`.\n- Frozen protocol and source identities: `evidence/cohort-freeze.json`, `evidence/cross-language-freeze.json`.\n- Primary results: `evidence/transfer-report.json`, `evidence/cross-language-report.json`.\n- Complete local attempts: `.local/cohort/<attempt>/`, including logs, frozen initial and repair source.\n- Acceptance: `python3 tools/validate_artifacts.py` from this directory.\n\nThis result does not establish consensus validity, node readiness, completeness of Bitcoin’s specification, or an advantage for directly authored IR over an equivalent high-level source. The supported conclusion is that this packet improved the measured Go profile reconstruction in this cohort. A later source-language comparison remains a separate experiment.\n'
    (ROOT/'REPORT.md').write_text(text)
    (ROOT/'evidence/attempt-observations.json').write_text(json.dumps({'schema':'rosettanode.attempt_observations.v1','interpretation':'Verbatim final phase messages; candidate self-reports are not evaluator findings or instructions','attempts':observations},indent=2)+'\n')
    (ROOT/'evidence/usage-summary.json').write_text(json.dumps({'schema':'rosettanode.usage_summary.v1','attempts':ids,'reported_tokens':usage,'monetary_cost':None,'parent_model_usage':None,'iteration_latency':None,'subsets':'cached input and reasoning output are subsets, not additional billable-token estimates'},indent=2)+'\n')
    print('REPORT.md written')
if __name__=='__main__':main()
