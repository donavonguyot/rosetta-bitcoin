"""Assemble gated comparison-only evidence; never curate canonical claims."""
import argparse,datetime,hashlib,json,math,re,statistics,subprocess,sys
from common import ROOT,HERE,WORK,LIB,run,save,source_digest
from comparison import validate,SCHEMA
from selection import assess


def read(name):return json.loads((WORK/name).read_text())

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--output',type=__import__('pathlib').Path);args=parser.parse_args()
    measurements=read('measurements.json');validation=read('validation.json')
    validation['checks']['x86_correctness']=read('x86.json')
    historical=[]
    for script in ('test_crypto_lanes.py','zig_crypto_campaign/test_comparison.py','zig_crypto_residual/test_comparison.py'):
        command=[sys.executable,ROOT/'Project/scripts'/script];historical.append(dict(command=list(map(str,command)),output=run(command)))
    for section,name,extra in [('baseline-5k','baseline',[]),('leaderboard','leaderboard',['--gate','baseline_5k'])]:
        now=run([sys.executable,ROOT/'Project/scripts/report.py','--db',ROOT/'Project/project.db','--section',section,*extra])
        assert now==(WORK/(name+'-before.txt')).read_text(),section
    curated=hashlib.sha256((ROOT/'Nodes/Shared/conformance/current_evidence.json').read_bytes()).hexdigest()
    assert curated==(WORK/'curated-before.sha256').read_text().strip()
    doc=subprocess.run([sys.executable,str(ROOT/'Project/scripts/check_doc_drift.py')],cwd=ROOT,capture_output=True,text=True)
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    report=dict(schema=SCHEMA,report_label='campaign_comparable',captured_at=stamp,result='passed',curated_current=False,binary_gate_status='not_attempted',node_claim='regression_gate_only',freeze=json.loads((HERE/'baseline.json').read_text()),toolchains=json.loads((HERE/'toolchains.lock.json').read_text()),profile=read('profile-ledger.json'),holdout=read('holdout-decision.json'),shipping_configuration=read('candidate-configuration.json'),validation=validation,arithmetic=read('candidate-arithmetic.json'),a0=read('a0-decision.json'),control_selection=read('control-selection.json'),decisions=read('decisions.json'),feasibility=read('feasibility.json'),safety_diagnostic=read('safety.json'),primitive_benchmarks={name:read(name+'.json') for name in ('pass0-primitives','pass1-primitives','primitives')},compile_cost=read('compile-cost.json'),cache_diagnostic=read('cache-diagnostic.json'),divstep_iterations=read('divstep-iterations.json'),historical_compatibility={'result':'passed','tests':historical,'baseline_and_leaderboard':'byte-for-byte unchanged'},curated_index_sha256=curated,**measurements)
    report['operation_counts']={name:read(name+'-counts.json') for name in ('baseline','candidate')}
    report['experiments']={p.stem:json.loads(p.read_text()) for p in sorted(WORK.glob('*-tuning-bench.json'))}
    report['sweep_original_finalist']=read('shared-z-g16-p4-sweep-bench.json')
    report['table_metadata']={p.stem:json.loads(p.read_text()) for p in sorted(WORK.glob('*-tables.json'))}
    report['control_sweep']={p.stem:json.loads(p.read_text()) for p in sorted(WORK.glob('c-w*-lto?.json'))}
    for name,control in report['control_sweep'].items():
        cache=WORK/name/'CMakeCache.txt'
        symbols=[line.split() for line in control['symbol_sizes'].splitlines()]
        control['verification_table_bytes']=sum(int(row[1],16) for row in symbols if row[-1] in ('secp256k1_pre_g','secp256k1_pre_g_128'))
        control['other_table_bytes_in_inventory']=sum(int(row[1],16) for row in symbols if row[-1]=='secp256k1_ecmult_gen_prec_table')
        control['named_historical_control']=name=='c-w15-generic-lto0'
        control['resolved_cmake']=[line for line in cache.read_text().splitlines() if line.startswith(('SECP256K1_','CMAKE_C_FLAGS','CMAKE_BUILD_TYPE','CMAKE_INTERPROCEDURAL_OPTIMIZATION','BUILD_SHARED_LIBS'))]
    report['confirmation']=read('selection-confirmation.json')
    report['holdout_measurements']={name:read(name+'-holdout-bench.json') for name in ('baseline','candidate','c_control')}
    report['documentation_check']={'result':'passed' if doc.returncode==0 else 'failed','output':doc.stdout+doc.stderr,'preexisting':read('documentation-before.json')}
    report['benchmark_driver_sha256']=hashlib.sha256((HERE/'bench.zig').read_bytes()).hexdigest()
    report['c_public_api_adapter_sha256']=hashlib.sha256((ROOT/'Project/scripts/zig_crypto_campaign/c_control.zig').read_bytes()).hexdigest()
    report['source_revision']=run(['git','rev-parse','HEAD']).strip()
    report['allocation_measurement']='No allocator parameters in the operation API; allocation counts not instrumented. Driver setup is outside timing.'
    assert report['validation']['source_digest']==source_digest(LIB)
    report['summary']=[]
    for variant in ('baseline','candidate','c_control'):
        runs=[r for r in report['runs'] if r['variant']==variant]
        median=lambda field:statistics.median(r[field] for r in runs)
        report['summary'].append(dict(variant=variant,elapsed_ms=median('node_elapsed_ms'),docker_elapsed_ms=median('wall_seconds')*1000,script_wall_ms=median('script_wall_ms'),worker_cpu_us_per_job=median('worker_cpu_ns_per_job')/1000,worker_elapsed_us_per_job=median('worker_elapsed_ns_per_job')/1000))
    report['component_summary']={}
    for variant,rows in report['components'].items():
        report['component_summary'][variant]={op:dict(median_us=statistics.median(values),minimum_us=min(values),maximum_us=max(values),repetitions=len(values),operations_per_repetition=1024) for op in sorted({r['operation'] for r in rows}) if (values:=[r['total_ns']/r['iterations']/1000 for r in rows if r['operation']==op])}
    summary=report['component_summary'];ratios={op:summary['candidate'][op]['median_us']/summary['c_control'][op]['median_us'] for op in ('ecdsa/valid','schnorr/valid','parse/valid')}
    report['zig_over_c_ratios']=ratios
    report['zig_over_c_score']=math.prod(ratios.values())**(1/3)
    wrappers={v:dict(input_sha256=hashlib.sha256((WORK/'holdout.json').read_bytes()).hexdigest(),measurements=rows) for v,rows in report['components'].items()}
    report['c_comparison']=assess(wrappers['c_control'],wrappers['candidate'])
    report['performance_claim']='C remains ahead; no faster-than-C claim.'
    if report['c_comparison']['qualifies']:
        report['performance_claim']=f"Faster than pinned C on the equal-weight three-operation score, with verification inclusive of key parsing; ECDSA ratio {ratios['ecdsa/valid']:.3f} and Schnorr ratio {ratios['schnorr/valid']:.3f}."
    base,candidate,control=report['summary']
    report['non_script_remainder_ms']=base['elapsed_ms']-base['script_wall_ms']
    report['illustrative_substitution_ms']=report['non_script_remainder_ms']+control['script_wall_ms']
    errors=validate(report)
    if errors:raise ValueError(errors)
    directory=ROOT/'Nodes/Shared/conformance/crypto_comparisons';directory.mkdir(exist_ok=True)
    path=args.output or directory/('zig_open_'+stamp+'.json');save(path,report)
    lines=['# Independent Zig open comparison','','Experimental verification only. Binary tip gate: `not_attempted`.','',report['performance_claim'],'','| Variant | ECDSA incl. parse (μs) | Schnorr incl. parse (μs) | Parse (μs) | Node elapsed (ms) | Worker CPU (μs/job) |','|---|---:|---:|---:|---:|---:|']
    for row in report['summary']:
        v=row['variant'];c=summary[v];lines.append(f"| {v} | {c['ecdsa/valid']['median_us']:.2f} | {c['schnorr/valid']['median_us']:.2f} | {c['parse/valid']['median_us']:.2f} | {row['elapsed_ms']:.2f} | {row['worker_cpu_us_per_job']:.2f} |")
    lines+=['',f"{len(report['runs'])} sequential fresh-volume measurements. Node confirmation is a regression gate. Worker metrics include interpreter and hashing.",f"Paired elapsed-regression 95% interval: {report['elapsed_regression_95']}.",'','The 5×52 kernels missed the primitive gate and remain test tooling. Batched divsteps and comb tables were not selected. See the report for independent ablations, the retained configuration, and rejected experiments.','', 'Curated evidence, historical validators, and canonical leaderboards are unchanged.', '',f'[Machine-readable evidence]({path.name})','']
    path.with_suffix('.md').write_text('\n'.join(lines));save(WORK/'report-path.json',dict(path=str(path)));print(path)

if __name__=='__main__':main()
