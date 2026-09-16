const std = @import("std");
const f = @import("field52.zig");
const P = f.p;
const F = f.Kernel(checked).Field(1);
const checked = @import("options").checked;
const wide = @import("options").wide;
const mask: u64 = (1 << 52) - 1;
const top: u64 = (1 << 48) - 1;
inline fn mulWide(a:u256,b:u256) u256 {
    const m:u512=std.math.maxInt(u256);const c:u512=0x1000003d1;
    var r=@as(u512,a)*b;
    inline for(0..3) |_| r=(r&m)+(r>>256)*c;
    if(r>=P) r-=P;
    return @intCast(r);
}
inline fn step(comptime op:usize,a:F,b:F) F {
    return switch(op) {
        0=>a.mul(b), 1=>a.square(),
        2,3=>blk:{
            const r=if(op==2) a.add(b) else a.sub(b);
            var v:F=undefined;
            inline for(0..4) |i| v.limbs[i]=r.limbs[i]&mask;
            v.limbs[4]=r.limbs[4]&top;
            break :blk v;
        },
        else=>a,
    };
}
noinline fn chain(comptime op:usize, comptime streams:usize, count:usize, seed:u256, operand:u256) u256 {
    if(wide) {
        var a:[streams]u256=undefined;
        inline for(0..streams) |i| a[i]=(seed+%i)%P;
        const b=operand%P;
        for(0..count) |iteration| inline for(0..streams) |i| {
            a[i]=switch(op){0=>mulWide(a[i],b),1=>mulWide(a[i],a[i]),2=>a[i]+%(b^iteration),3=>a[i]-%(b^iteration),else=>a[i]^iteration};
        };
        var result:u256=0;inline for(a) |x| result^=x;return result;
    } else {
        var a:[streams]F=undefined;
        inline for(0..streams) |i| a[i]=F.fromInt(seed+%i);
        const b=F.fromInt(operand);
        for(0..count) |iteration| inline for(0..streams) |i| {
            if(op==4) { a[i].limbs[0]^=iteration & mask; } else if(op==2 or op==3) { var operand_field=b; operand_field.limbs[0]^=iteration & mask; a[i]=step(op,a[i],operand_field); } else a[i]=step(op,a[i],b);
        };
        var result:u256=0;inline for(a) |x| result^=x.integer();return result;
    }
}
pub fn main(init:std.process.Init) !void {
    const args=try init.minimal.args.toSlice(init.arena.allocator());
    if(args.len!=2) return error.Usage;
    const batch=try std.fmt.parseInt(usize,args[1],10);
    var buf:[4096]u8=undefined;var writer:std.Io.File.Writer=.init(.stdout(),init.io,&buf);const out=&writer.interface;
    const names=[_] []const u8{"multiply","square","add_bounded","subtract_bounded","loop_control"};
    var rng=std.Random.DefaultPrng.init(0x35326f70656e + batch);
    const seeds=[_]u256{rng.random().int(u256),P-1,std.math.maxInt(u256)};
    inline for(.{1,4}) |streams| {
        for(0..5) |rep| {
            inline for(0..5) |ordinal| {
                const op=if(batch%2==0) ordinal else 4-ordinal;
                // Runtime order selects an already-specialized hot loop.
                var count:usize=65536;var elapsed:i96=0;var result:u256=0;
                while(true) {
                    const start=std.Io.Clock.awake.now(init.io).nanoseconds;
                    inline for(0..5) |which| if(op==which) {result=chain(which,streams,count,seeds[rep%3],seeds[(rep+1)%3]);};
                    elapsed=std.Io.Clock.awake.now(init.io).nanoseconds-start;
                    std.mem.doNotOptimizeAway(result);
                    if(elapsed>=10_000_000 or count>=1<<27) break;
                    count*=2;
                }
                try out.print("{{\"operation\":\"{s}\",\"streams\":{d},\"batch\":{d},\"repetition\":{d},\"iterations\":{d},\"total_ns\":{d},\"checksum\":\"{x}\"}}\n",.{names[op],streams,batch,rep,count*streams,elapsed,result});
            }
        }
    }
    try out.flush();
}
