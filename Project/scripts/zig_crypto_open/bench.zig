const std=@import("std");
const secp=@import("secp256k1");
const Input=struct { key:[]const u8,msg:[]const u8,sig:[]const u8,expected:bool };
fn decode(a:std.mem.Allocator,s:[]const u8) ![]u8 { return std.fmt.hexToBytes(try a.alloc(u8,s.len/2),s); }
noinline fn operation(i:Input,op:usize) bool {
 return switch(op) {
  0,4,8 => secp.verifyEcdsa(i.key,i.msg,i.sig) catch false,
  1,5 => secp.verifySchnorr(i.key,i.msg,i.sig) catch false,
  2,6 => blk: { const r=secp.parsePublicKey(i.key) catch break :blk false; std.mem.doNotOptimizeAway(r);break :blk true; },
  3,7 => blk: { const r=secp.addXOnlyTweak(i.key,i.msg) catch break :blk false; std.mem.doNotOptimizeAway(r);break :blk true; },
  else=>unreachable,
 };
}
pub fn main(init:std.process.Init) !void {
 const a=init.arena.allocator();const args=try init.minimal.args.toSlice(a);
 if(args.len!=3) return error.Usage;
 const batch=try std.fmt.parseInt(usize,args[2],10);
 const bytes=try std.Io.Dir.cwd().readFileAlloc(init.io,args[1],a,.limited(4*1024*1024));
 const parsed=try std.json.parseFromSlice(std.json.Value,a,bytes,.{});
 const names=[_][]const u8{"ecdsa/valid","schnorr/valid","parse/valid","tweak/valid","ecdsa/late_invalid","schnorr/late_invalid","parse/early_invalid","tweak/early_invalid","ecdsa/scalar_early_invalid"};
 var inputs:[9][256]Input=undefined;
 for(names,0..) |name,op| {
  const rows=parsed.value.object.get(name).?.array.items;if(rows.len!=256) return error.CaseCount;
  for(rows,0..) |row,j| {
   const o=row.object;inputs[op][j]=.{.key=try decode(a,o.get("key").?.string),.msg=try decode(a,o.get("message").?.string),.sig=try decode(a,o.get("signature").?.string),.expected=o.get("expected").?.bool};
   if(operation(inputs[op][j],op)!=inputs[op][j].expected) return error.CaseMismatch;
  }
 }
 var buffer:[4096]u8=undefined;var writer:std.Io.File.Writer=.init(.stdout(),init.io,&buffer);const out=&writer.interface;
 for(0..5) |rep| {for(0..9) |ordinal| {
  const op=if(batch%2==0) (ordinal+rep)%9 else (8-ordinal+rep)%9;
  const start=std.Io.Clock.awake.now(init.io).nanoseconds;
  for(0..1024) |j| std.mem.doNotOptimizeAway(operation(inputs[op][(j+rep*37+batch*71)%256],op));
  const elapsed=std.Io.Clock.awake.now(init.io).nanoseconds-start;
  try out.print("{{\"operation\":\"{s}\",\"batch\":{d},\"repetition\":{d},\"iterations\":1024,\"total_ns\":{d}}}\n",.{names[op],batch,rep,elapsed});
 }}
 try out.flush();
}
