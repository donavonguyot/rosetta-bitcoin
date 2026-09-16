"""Warm versus deliberately disturbed cache diagnostics, never selection timings."""
import json
from common import HERE,WORK,docker,exclusive,save


def main():
    source=(HERE/'bench.zig').read_text();start=source.index(' for(0..5) |rep|')
    source=source[:start]+'''
 const scratch=try a.alloc(u64,4*1024*1024);@memset(scratch,1);
 for(0..2) |mode| {for(0..4) |op| {for(0..256) |j| {
  if(mode==1) {for(scratch,0..) |*word,k| {if(k%8==0) word.* +%= j+1;} std.mem.doNotOptimizeAway(scratch.ptr);}
  else std.mem.doNotOptimizeAway(operation(inputs[op][j],op));
  const start=std.Io.Clock.awake.now(init.io).nanoseconds;
  std.mem.doNotOptimizeAway(operation(inputs[op][j],op));
  const elapsed=std.Io.Clock.awake.now(init.io).nanoseconds-start;
  try out.print("{{\\\"operation\\\":\\\"{s}\\\",\\\"mode\\\":{d},\\\"input\\\":{d},\\\"total_ns\\\":{d}}}\\n",.{names[op],mode,j,elapsed});
 }}}
 try out.flush();
}
'''
    source=source.replace(' const batch=try std.fmt.parseInt(usize,args[2],10);',' _=try std.fmt.parseInt(usize,args[2],10);')
    (WORK/'cache-bench.zig').write_text(source)
    with exclusive():
        availability=docker(['sh','-c','ls /sys/bus/event_source/devices; cat /proc/sys/kernel/perf_event_paranoid; command -v perf || true'])
        if set(availability.split())-{'breakpoint','kprobe','software','tracepoint','uprobe','-1','0','1','2','3','4'}:raise ValueError('Additional PMU or perf available; collect counters before continuing: '+availability)
        docker(['zig','build-exe','-O','ReleaseSafe','--dep','secp256k1','-Mroot=/work/cache-bench.zig','-O','ReleaseSafe','-Msecp256k1=/work/candidate/src/root.zig','-femit-bin=/work/cache-bench'])
        rows=[json.loads(s) for s in docker(['/work/cache-bench','/work/tuning.json','0']).splitlines()]
    save(WORK/'cache-diagnostic.json',dict(measurements=rows,environment=availability,hardware_cache_misses='unavailable in this guest: only software/trace event devices are exposed; no architectural CPU PMU or perf executable',diagnostic='32 MiB sequential read/write disturbance before each call versus same-input warmed call; includes timer overhead, does not measure cache misses or select configurations'))

if __name__=='__main__':main()
