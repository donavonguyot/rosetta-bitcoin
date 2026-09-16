"""Assemble comparison-only evidence after gates; never curate or import claims."""
import datetime,hashlib,statistics,re
from common import *
from comparison import validate
from selection import assess

def main():
 measurements=json.loads((WORK/'measurements.json').read_text())
 validation=json.loads((WORK/'validation.json').read_text());validation['checks']['x86_correctness']=json.loads((WORK/'x86.json').read_text())
 historical=[]
 for script in (ROOT/'Project/scripts/test_crypto_lanes.py',ROOT/'Project/scripts/zig_crypto_campaign/test_comparison.py'):
  output=run([sys.executable,script]);historical.append(dict(command=[sys.executable,str(script)],output=output))
 for section,name,extra in [('baseline-5k','baseline',[]),('leaderboard','leaderboard',['--gate','baseline_5k'])]:
  now=run([sys.executable,ROOT/'Project/scripts/report.py','--db',ROOT/'Project/project.db','--section',section,*extra])
  assert now==(WORK/(name+'-before.txt')).read_text(),section
 curated=hashlib.sha256((ROOT/'Nodes/Shared/conformance/current_evidence.json').read_bytes()).hexdigest();assert curated==(WORK/'curated-before.sha256').read_text()
 experiments=[]
 for path in sorted(WORK.glob('*-tuning-bench.json')):
  data=json.loads(path.read_text());cfgpath=WORK/(data['name']+'-source.json');cfg=json.loads(cfgpath.read_text()) if cfgpath.exists() else {}
  asm=WORK/('bench-'+data['name']+'.s');stack=[]
  if asm.exists():
   for m in re.finditer(r'sub\s+sp, sp, #(\d+)(?:, lsl #(\d+))?',asm.read_text()):stack.append(int(m[1])<<int(m[2] or 0))
  data['configuration']=cfg;data['generator_table_bytes']=(2 if cfg.get('glv') else 1)*96*(1<<(cfg.get('gw',5)-2));data['variable_table_bytes']=(2 if cfg.get('glv') else 1)*96*(1<<(cfg.get('pw',5)-2))
  data['stack_observation']={'largest_emitted_sp_decrement':max(stack) if stack else None,'coverage':'static assembly observation, not a total call-stack bound'}
  data['comptime_branch_quota']=20_000_000 if data['name']!='baseline' else 1_000_000
  experiments.append(data)
 stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
 report=dict(schema='rb.zig_crypto_residual_comparison.v1',report_label='campaign_comparable',captured_at=stamp,result='passed',curated_current=False,binary_gate_status='not_attempted',freeze=json.loads((HERE/'baseline.json').read_text()),toolchains=json.loads((HERE/'toolchains.lock.json').read_text()),profile=json.loads((WORK/'profile-ledger.json').read_text()),derivation=json.loads((WORK/'derivation.json').read_text()),experiments=experiments,holdout=json.loads((WORK/'holdout-decision.json').read_text()),preparation=json.loads((WORK/'candidate-preparation.json').read_text()),validation=validation,arithmetic=json.loads((WORK/'candidate-arithmetic.json').read_text()),operation_counts={name:json.loads(path.read_text()) for name in ('baseline','scalar','chain','half','tweak','glv','candidate') if (path:=WORK/(name+'-counts.json')).exists()},historical_compatibility={'result':'passed','tests':historical,'baseline_and_leaderboard':'byte-for-byte unchanged'},curated_index_sha256=curated,**measurements)
 report['environment']=json.loads((WORK/'environment.json').read_text())
 report['primitive_benchmarks']={name:json.loads((WORK/(name+'-primitives.json')).read_text()) for name in ('baseline','candidate','limbs')}
 report['holdout_measurements']={name:json.loads((WORK/(name+'-holdout-bench.json')).read_text()) for name in ('baseline','candidate')}
 report['documentation_check']={'result':'passed','command':'python3 Project/scripts/check_doc_drift.py','output':run([sys.executable,ROOT/'Project/scripts/check_doc_drift.py']),'initial_observation':'Initial check reported Docs/rosettabitcoin_paper_publication.md:73 missing substrate_pipeline.pdf; the final check passes. This campaign did not edit that document.'}
 report['allocation_measurement']='not instrumented; operation APIs do not accept allocators, setup is outside timing'
 report['rejected_limb_correctness']=json.loads((WORK/'limbs-arithmetic.json').read_text())
 report['validation']['source_digest']=source_digest(LIB)
 rows=[]
 for name in ('baseline','candidate','c_control'):
  runs=[r for r in report['runs'] if r['variant']==name]
  median=lambda field:statistics.median(r[field] for r in runs)
  rows.append(dict(variant=name,elapsed_ms=median('node_elapsed_ms'),script_wall_ms=median('script_wall_ms'),worker_cpu_us_per_job=median('worker_cpu_ns_per_job')/1000,worker_elapsed_us_per_job=median('worker_elapsed_ns_per_job')/1000))
 report['component_summary']={}
 for variant,samples in report['components'].items():
  report['component_summary'][variant]={}
  for op in sorted({r['operation'] for r in samples}):
   values=[r['total_ns']/r['iterations']/1000 for r in samples if r['operation']==op]
   report['component_summary'][variant][op]={'median_us':statistics.median(values),'minimum_us':min(values),'maximum_us':max(values),'repetitions':len(values),'operations_per_repetition':1024}
 report['summary']=rows
 report['illustrative_substitution_ms']=rows[0]['elapsed_ms']-rows[0]['script_wall_ms']+rows[2]['script_wall_ms']
 errors=validate(report)
 if errors:raise RuntimeError(errors)
 directory=ROOT/'Nodes/Shared/conformance/crypto_comparisons';directory.mkdir(exist_ok=True)
 path=directory/('zig_residual_'+stamp+'.json');save(path,report)
 text=['# Independent Zig residual comparison','', 'Experimental public-input verification only. Binary tip gate: `not_attempted`.','', '| Variant | Node elapsed (ms) | Script wall (ms) | Worker CPU (μs/job) |','|---|---:|---:|---:|']
 for r in rows:text.append(f"| {r['variant']} | {r['elapsed_ms']:.2f} | {r['script_wall_ms']:.2f} | {r['worker_cpu_us_per_job']:.2f} |")
 text+=['',f"{len(report['runs'])} sequential fresh-volume measurements. Worker CPU includes interpreter and hashing.",f"Paired elapsed-regression 95% interval: {report['elapsed_regression_95']}.",'','The candidate retains independently generated scalar reduction, square-root chain,','coefficient halving, GLV with generator width 8 / variable width 4, and specialized','tweaks. Canonical four-limb arithmetic and limb GCD lost their experiments.','', 'The illustrative baseline non-script remainder plus C script time is',f"{report['illustrative_substitution_ms']:.2f} ms; this is not a target or guaranteed floor.",'','x86 correctness passed under Docker linux/amd64 with an explicit baseline CPU target.', 'Native-feature inference failed a package-independent wide-remainder probe; the', 'compiler/emulator cause remains unresolved. No emulated timing selected this candidate.', '', 'All stronger gates are campaign-local. Curated evidence, historical validators,','and canonical baseline/leaderboard output are unchanged.','',f'[Machine-readable evidence]({path.name})','']
 path.with_suffix('.md').write_text('\n'.join(text));print(path);print(json.dumps(rows,indent=2))
if __name__=='__main__':main()
