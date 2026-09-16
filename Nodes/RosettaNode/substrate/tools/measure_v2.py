#!/usr/bin/env python3
"""Serial rotating repetitions; volumes prepared before timing and retained."""
import argparse,json,statistics,subprocess,time,uuid
from pathlib import Path
from campaign_v2 import ROOT,frozen,save

def repetition(submission,lineage,lane,workload,number,warmup=False):
    f=frozen();token=uuid.uuid4().hex[:12];name='rn-substrate-measure-'+token;volume=name+'-state'
    out=ROOT/'.local/measurements'/name;out.mkdir(parents=True)
    subprocess.run(['docker','volume','create','--label','rosettanode.substrate=measurement',volume],check=True,capture_output=True)
    cmd=['docker','run','--name',name,'--network','none','--security-opt','no-new-privileges','--cpus','4','--memory','4g','--label','rosettanode.substrate=measurement','-e','RN_CANDIDATE=/candidate/service','-v',str(ROOT/'.local/adapter-bundle')+':/adapter:ro','-v',str(submission)+':/candidate:ro','-v',str(out)+':/output','-v',volume+':/state',f['evaluator_image'],'python3','tools/benchmark.py','--workload',workload,'--lane',lane]
    samples=[];start=time.monotonic();timeout=False
    with (out/'log.txt').open('w') as log:
        p=subprocess.Popen(cmd,stdout=log,stderr=log);next_sample=start
        while p.poll() is None:
            now=time.monotonic()
            if now-start>900:timeout=True;subprocess.run(['docker','kill',name],capture_output=True);p.wait();break
            if now>=next_sample:
                stats=subprocess.run(['docker','stats','--no-stream','--format','{{json .}}',name],capture_output=True,text=True,timeout=10)
                try:samples.append({'host_elapsed_seconds':time.monotonic()-start,**json.loads(stats.stdout)})
                except ValueError:pass
                next_sample=now+1
            time.sleep(.05)
    result=json.loads((out/'result.json').read_text()) if (out/'result.json').exists() else {'status':'failed','reason':'no repetition result'}
    if timeout or p.returncode:result['status']='failed';result['timeout']=timeout;result['exit_code']=p.returncode
    result.update(lineage=lineage,lane=lane,repetition=number,warmup=warmup,container=name,volume=volume,host_run_seconds=time.monotonic()-start,resource_samples=samples,resource_sampling='Docker stats requested once per second; observed samples, not continuous maxima; CLI call latency may reduce frequency')
    save(out/'retained-result.json',result)
    # Keep rich activity and logs local; compact evidence carries measurements.
    compact={k:v for k,v in result.items() if k not in ['resource_samples','rocksdb_stats','compaction_flush_stall_log_lines']}
    compact['diagnostics']=str(out);compact['sample_count']=len(samples)
    compact['sampled_peak_cpu_percent']=max([float(x['CPUPerc'].rstrip('%')) for x in samples] or [0]) if samples else None
    def memory(s):
        value=s.split('/')[0].strip()
        for unit,scale in [('GiB',2**30),('MiB',2**20),('KiB',2**10),('GB',10**9),('MB',10**6),('kB',10**3),('B',1)]:
            if value.endswith(unit):return float(value[:-len(unit)])*scale
        raise ValueError(value)
    compact['sampled_peak_memory_bytes']=max(memory(x['MemUsage']) for x in samples) if samples else None
    save(ROOT/f'evidence/repetition-{token}.json',compact);return compact

def main():
    p=argparse.ArgumentParser();p.add_argument('--campaign',action='store_true');a=p.parse_args();assert a.campaign
    f=frozen();background=subprocess.check_output(['docker','ps','--format','{{json .}}'],text=True)
    # Any active non-Reference node container is a blocker until investigated.
    save(ROOT/'evidence/measurement-background.json',{'docker_ps':background,'host_processes':subprocess.check_output(['ps','-axo','pid,comm'],text=True),'unrelated_services_stopped':False})
    candidates=[]
    for language in ['zig','go','rust']:
        for n in [1,2]:
            lineage=f'{language}-{n}'
            for round,lane in [('maintenance','baseline'),('optimization','optimization')]:
                path=ROOT/f'evidence/lineage-v2-{lineage}-{round}.json'
                if path.exists():
                    r=json.loads(path.read_text())
                    if r['status']=='qualified':candidates.append((Path(r['qualified_submission']),lineage,lane))
    records=[];failed=set()
    for workload in ['1-1','1-8','1-64','3','4']:
        for candidate in candidates:
            key=(candidate[1],candidate[2],workload)
            r=repetition(*candidate,workload,0,True);records.append(r)
            if r['status']!='passed':failed.add(key)
        for rep in range(1,8):
            order=candidates[(rep-1)%max(1,len(candidates)):]+candidates[:(rep-1)%max(1,len(candidates))]
            for candidate in order:
                key=(candidate[1],candidate[2],workload)
                if key in failed:continue
                r=repetition(*candidate,workload,rep);records.append(r)
                if r['status']!='passed':failed.add(key)
    summary=[]
    for candidate in candidates:
        for workload in ['1-1','1-8','1-64','3','4']:
            rows=[r for r in records if (r['lineage'],r['lane'],r.get('workload'))==(candidate[1],candidate[2],workload) and not r['warmup']]
            times=[r['elapsed_seconds'] for r in rows if r['status']=='passed']
            summary.append({'lineage':candidate[1],'lane':candidate[2],'workload':workload,'accepted':len(times)==7,'completed_repetitions':len(times),'median_seconds':statistics.median(times) if times else None,'min_seconds':min(times) if times else None,'max_seconds':max(times) if times else None})
    save(ROOT/'evidence/measurements.json',{'schema':'rosettanode.substrate.measurements.v1','summary':summary,'repetitions':records,'tie_band':.10,'failures_replaced':False})
if __name__=='__main__':main()
