"""One experimental own-curve shakedown; preserve state and never retry a run."""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import threading
import time

from crypto_lanes import source_digest
from validate_benchmark_telemetry import validate_log_paths

ROOT = Path(__file__).resolve().parents[2]
EXPECTED_HASH = '00000000e2c8c94ba126169a88997233f07a9769e2b009fb10cad0e893eff2cb'


def run(args):
    return subprocess.check_output(list(map(str, args)), cwd=ROOT, text=True)


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def require_fields(value, expected):
    for key, wanted in expected.items():
        if value.get(key) != wanted:
            raise ValueError(f'{key}: expected {wanted!r}, got {value.get(key)!r}')


def summarize(artifact):
    """Reassemble interval observations from saved telemetry, without running a node."""
    result = json.loads(artifact.read_text())
    work = ROOT/result['raw_directory']
    ticks = [json.loads(line.split('benchmark.telemetry_tick ',1)[1])
             for line in (work/'run.log').read_text().splitlines()
             if line.startswith('benchmark.telemetry_tick ')]
    intervals = []
    previous = dict(height=0,elapsed_ms=0,script_jobs=0,tx_count=0,
                    script_worker_thread_cpu_ns=0,script_wall_ms=0)
    for height in range(5000,50001,5000):
        tick = next(t for t in ticks if t['height'] >= height)
        jobs = tick['script_jobs']-previous['script_jobs']
        elapsed = tick['elapsed_ms']-previous['elapsed_ms']
        intervals.append(dict(start_height=previous['height'],end_height=tick['height'],
                              elapsed_ms=elapsed,script_jobs=jobs,transactions=tick['tx_count']-previous['tx_count'],
                              script_wall_ms=tick['script_wall_ms']-previous['script_wall_ms'],
                              worker_cpu_us_per_job=(tick['script_worker_thread_cpu_ns']-previous['script_worker_thread_cpu_ns'])/jobs/1000 if jobs else None,
                              jobs_per_second=jobs*1000/elapsed if elapsed else None))
        previous = tick
    result['intervals'] = intervals
    memory = []
    for sample in result['resource_samples']:
        match = re.fullmatch(r'([0-9.]+)(B|KiB|MiB|GiB)',sample['stats']['MemUsage'].split(' / ')[0])
        if match:
            memory.append(float(match[1])*{'B':1,'KiB':1024,'MiB':1024**2,'GiB':1024**3}[match[2]])
    result['sampled_container_memory_max_bytes'] = max(memory) if memory else None
    result['measurement_notes'] = [
        'One observation, without warmup or repeated measurement; no speedup claim.',
        'Worker time includes interpreter, hashing and scheduling, not only cryptography.',
        'Timing buckets overlap; utxo_apply and commit must not be added together.',
        'Docker stats are sampled container memory usage, not process peak RSS.',
        'Network bytes include protocol traffic; total serialized block bytes are not emitted.',
        'Telemetry current_block_tx_count is cumulative here; interval analysis uses tx_count.',
    ]
    save(artifact,result)
    save(work/'result.json',result)
    timing=result['timing']; b=timing['stage_totals_ms']
    rows=['# Optimized Zig: one 50k shakedown','',
          f"Result: **{result['result']}**. Height 50,000, expected hash and 568,855 spendable UTXOs verified. Telemetry: **{result['telemetry']['quality']}**.",'',
          '| Measurement | Observed |','|---|---:|',
          f"| Inside-node elapsed | {timing['total_ms']/1000:.3f} s |",
          f"| External Docker elapsed | {result['docker_elapsed_s']:.3f} s |",
          f"| Script wall | {b['script_wall_ms']/1000:.3f} s |",
          f"| Worker CPU / script job | {result['worker_cpu_ns_per_job']/1000:.2f} μs |",
          f"| Worker elapsed / script job | {result['worker_elapsed_ns_per_job']/1000:.2f} μs |",
          f"| Maximum sampled container memory | {max(memory)/1024**2:.1f} MiB |" if memory else '| Sampled memory | unavailable |',
          f"| Transactions | {timing['tx_count']:,} |",f"| Script jobs | {timing['script_jobs']:,} |",'',
          '## Progress intervals','',
          '| Heights | Elapsed s | Script jobs | Script wall s | Worker CPU μs/job |',
          '|---|---:|---:|---:|---:|']
    for i in intervals:
        cpu = 'N/A (no jobs)' if i['worker_cpu_us_per_job'] is None else f"{i['worker_cpu_us_per_job']:.2f}"
        rows.append(f"| {i['start_height']:,}–{i['end_height']:,} | {i['elapsed_ms']/1000:.3f} | {i['script_jobs']:,} | {i['script_wall_ms']/1000:.3f} | {cpu} |")
    rows += ['', 'Script verification is the largest individual timing bucket. The slowest recorded block was '
             f"{timing['slow_blocks'][0]['height']:,}: {timing['slow_blocks'][0]['ms']/1000:.3f} s, "
             f"with {timing['slow_blocks'][0]['input_count']:,} inputs. Investigating its interpreter/sighash workload is a useful follow-up; this run does not isolate its cause.", '',
             '## Interpretation and retained evidence','']
    rows += ['- '+note for note in result['measurement_notes']]
    rows += ['',f"Preserved volume: `{result['volume']}`.",f"Raw evidence: `{result['raw_directory']}`.",
             f"Image: `{result['image']['image_id']}`.",f"Package digest: `{result['image']['source_digest']}`.",'',
             'No arithmetic or node changes, canonical selections, or leaderboard updates. Experimental; binary tip gate: `not_attempted`.']
    artifact.with_suffix('.md').write_text('\n'.join(rows)+'\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image-metadata', type=Path, default=ROOT/'Project/.campaigns/zig-open/candidate-image.json')
    parser.add_argument('--summarize', type=Path, help='Summarize an existing result without replaying')
    args = parser.parse_args()
    if args.summarize:
        summarize(args.summarize)
        return
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    work = ROOT/'Project/.campaigns'/('zig-50k-' + stamp)
    work.mkdir(parents=True, exist_ok=False)
    meta = json.loads(args.image_metadata.read_text())
    require_fields(meta, {'lane': 'own_curve', 'probe': False, 'reject': ''})
    assert source_digest(ROOT/'Libraries/Zig/libsecp256k1-zig') == meta['source_digest']
    assert source_digest(ROOT/'Nodes/Zig/src') == meta['node_digest']
    volume = 'rosetta-zig-own-curve-50k-' + stamp.lower()
    container = volume + '-runner'
    result = dict(schema='rb.zig_own_curve_shakedown.v1', benchmark_gate='shakedown_50k',
                  result='failed', experimental=True, binary_gate_status='not_attempted',
                  captured_at=stamp, image=meta, git_revision=run(['git','rev-parse','HEAD']).strip(),
                  git_status=run(['git','status','--short']), volume=volume,
                  raw_directory=str(work.relative_to(ROOT)), measurements=1, warmups=0)
    artifact = ROOT/'Nodes/Shared/conformance/crypto_comparisons'/('zig_own_curve_50k_' + stamp + '.json')
    lock_path = ROOT/'Project/.campaigns/crypto-lanes/node-benchmark.lock'
    with lock_path.open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            preflight = json.loads(run(['python3','Project/scripts/preflight_consensus_runway.py','--db','Project/project.db','--port','zig','--stage','50k','--strict','--json']))
            result['preflight'] = preflight
            image = meta['image_id']
            inspect = json.loads(run(['docker','image','inspect',image]))[0]
            assert inspect['Architecture'] == 'arm64'
            result['environment'] = dict(docker=json.loads(run(['docker','info','--format','{{json .}}'])),
                                         host_load=os.getloadavg(), host=run(['uname','-a']).strip())
            result['toolchain_pins'] = json.loads((ROOT/'Project/scripts/zig_crypto_open/toolchains.lock.json').read_text())
            result['build_packages'] = run(['docker','run','--rm','--network','none',image,'cat','/usr/local/bin/build-packages.txt'])
            result['linkage'] = run(['docker','run','--rm','--network','none',image,'ldd','/usr/local/bin/zigbitnode'])
            assert 'libsecp256k1' not in result['linkage']
            packages = run(['docker','run','--rm','--network','none',image,'dpkg-query','-W'])
            assert 'libsecp256k1' not in packages
            # Reuse source-matched symbol/fallback validation without a second replay.
            validation = json.loads((ROOT/'Project/.campaigns/zig-open/validation.json').read_text())
            assert validation['source_digest'] == meta['source_digest']
            audit = validation['checks']['dependency_audit']['binary_symbol_audit']
            binary_hash = run(['docker','run','--rm','--network','none',image,'sha256sum','/usr/local/bin/zigbitnode']).split()[0]
            assert audit['runtime_binary_sha256'] == binary_hash
            result['binary_audit'] = audit
            result['backend_selection'] = validation['checks']['backend_selection']
            reference = ['docker','exec','rosetta-bitcoin-core-testnet4','bitcoin-cli','-conf=/config/bitcoin.conf','-datadir=/home/bitcoin/.bitcoin']
            assert run(reference + ['getblockhash','50000']).strip() == EXPECTED_HASH
            # Reading the endpoint also proves its block body is available, not just its header.
            endpoint = json.loads(run(reference + ['getblock',EXPECTED_HASH,'1']))
            result['reference_endpoint'] = {k:endpoint[k] for k in ('hash','height','size','weight','nTx')}
            corpus_cmd = ['docker','run','--rm','--network','none','--user','0','-e','ZIGBITNODE_RUNTIME_SURFACE=docker',
                          '-v',str(ROOT/'Nodes/Shared')+':/shared:ro','-v',str(work)+':/results',image,
                          'zigbitnode','script-corpus','--manifest','/shared/conformance/fixtures/scripts/manifest.json','--output','/results/corpus.json']
            (work/'corpus.log').write_text(run(corpus_cmd))
            corpus = json.loads((work/'corpus.json').read_text())
            require_fields(corpus, {'passed':45,'failed':0})
            result['corpus'] = corpus
            run(['docker','volume','create',volume])
            cmd = ['docker','run','--rm','--name',container,'--user','0','--network','rosetta-reference-node_default',
                   '-v',volume+':/data','-v',str(work)+':/results','-e','ZIGBITNODE_RUNTIME_SURFACE=docker',
                   '-e','ZIGBITNODE_SCRIPT_THREADS=4','-e','PREFETCH_DEPTH=4',image,'zigbitnode','local-reference-proof',
                   '--datadir','/data','--target','50000','--peer','bitcoin-core-testnet4:48333','--output','/results/proof.json']
            result['command'] = cmd
            save(work/'manifest.json', result)
            samples, stop = [], threading.Event()
            def sample():
                while not stop.wait(2):
                    p = subprocess.run(['docker','stats','--no-stream','--format','{{json .}}',container], capture_output=True,text=True)
                    if p.returncode == 0 and p.stdout.strip():
                        samples.append(dict(elapsed_s=time.monotonic()-started, stats=json.loads(p.stdout)))
            print('Starting one 50k replay; preserving ' + volume, flush=True)
            started = time.monotonic()
            with (work/'run.log').open('w') as log:
                process = subprocess.Popen(cmd,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
                sampler = threading.Thread(target=sample,daemon=True); sampler.start()
                try:
                    code = process.wait(timeout=1800)
                except subprocess.TimeoutExpired:
                    subprocess.run(['docker','stop','--time','10',container],capture_output=True)
                    process.wait(); raise RuntimeError('30-minute safety timeout; no retry')
                finally:
                    result['docker_elapsed_s'] = time.monotonic()-started
                    stop.set(); sampler.join(timeout=10)
                    save(work/'resource-samples.json', samples)
            result['returncode'] = code
            status = json.loads(run(['docker','run','--rm','--user','0','--network','none','-v',volume+':/data',image,'zigbitnode','status','--datadir','/data']))
            result['settled_status'] = status
            save(work/'status.json', status)
            if code: raise RuntimeError(f'node exited {code}; state and logs preserved')
            raw = json.loads((work/'proof.json').read_text())
            expected = dict(validated_height=50000, validated_hash=EXPECTED_HASH,chainstate_utxo_count=568855,
                            chainstate_backend='rocksdb',rocksdb_wal_disabled=False,fresh_state=True,prefetch_depth=4,
                            script_runner_mode='parallel',script_threads=4,utxo_accounting_policy='core_spendable_v1',byte_source='local_reference_p2p')
            require_fields(raw, expected)
            require_fields(status, dict(validated_height=50000,crypto_source_digest=meta['source_digest']))
            lines = (work/'run.log').read_text().splitlines()
            progress = [json.loads(x.split('rb.port_progress ',1)[1]) for x in lines if x.startswith('rb.port_progress ')]
            require_fields(progress[-1], dict(crypto_source_digest=meta['source_digest'],crypto_lane='own_curve',native_crypto_backend='libsecp256k1-zig'))
            telemetry = validate_log_paths([work/'run.log'],gate='shakedown_50k',port='zig',target_height=50000)
            result['telemetry'] = dict(quality=telemetry.quality,errors=telemetry.errors,warnings=telemetry.warnings,summary=telemetry.summary)
            result['writer_progress'] = progress[-1]
            result['timing'] = raw['pipeline_timing_summary']
            jobs = result['timing']['script_jobs']; buckets = result['timing']['stage_totals_ms']
            result['worker_cpu_ns_per_job'] = buckets['script_worker_thread_cpu_ns']/jobs
            result['worker_elapsed_ns_per_job'] = buckets['script_worker_elapsed_ns']/jobs
            result['timing_coverage'] = 'worker loops excluding verifier lifecycle; includes interpreter, hashing and scheduling'
            result['resource_samples'] = samples
            result['endpoint_checks'] = expected
            if telemetry.quality != 'clean': raise RuntimeError('telemetry is not clean')
            result['result'] = 'passed'
        except Exception as exc:
            result['failure'] = str(exc)
        finally:
            result['raw_hashes'] = {p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in work.iterdir() if p.is_file()}
            save(work/'result.json', result)
            save(artifact, result)
            print(str(artifact), result['result'], result.get('failure',''), flush=True)
    if result['result'] != 'passed': raise SystemExit(1)
    summarize(artifact)


if __name__ == '__main__':
    main()
