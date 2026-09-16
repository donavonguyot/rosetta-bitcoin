//! Canonical radix-2^64 field experiment, derived from p=2^256-2^32-977.
const std=@import("std");
const builtin=@import("builtin");
const P:u256=0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f;
const C:u64=(@as(u64,1)<<32)+977;
const Limbs=[4]u64;
comptime { if(builtin.cpu.arch.endian()!=.little or @sizeOf(Limbs)!=@sizeOf(u256)) @compileError("validated little-endian layout required"); }
fn words(x:u256) Limbs { return @bitCast(x); }
fn integer(x:Limbs) u256 { return @bitCast(x); }
fn addWord(t:*[9]u64,start:usize,word:u64) void {
 var i=start;var carry=word;
 while(carry!=0) : (i+=1) { const sum=@addWithOverflow(t[i],carry);t[i]=sum[0];carry=sum[1]; }
}
fn reduce(t0:[9]u64) u256 {
 var t=t0;
 // Each substitution replaces B^4 by C; a high carry can require another pass.
 for(0..3) |_| {
  var i:usize=9;
  while(i>4) {i-=1;const v=t[i];t[i]=0;const product=@as(u128,v)*C;addWord(&t,i-4,@truncate(product));addWord(&t,i-3,@intCast(product>>64));}
 }
 std.debug.assert(t[4]|t[5]|t[6]|t[7]|t[8]==0);
 const result=integer(t[0..4].*);
 return if(result>=P) result-P else result;
}
pub fn multiply(a:u256,b:u256) u256 {
 const x=words(a);const y=words(b);var t:[9]u64=@splat(0);
 for(0..4) |i| {
  var carry:u64=0;
  for(0..4) |j| {
   // (B-1)^2+2(B-1)=B^2-1: the complete accumulator fits u128.
   const v=@as(u128,x[i])*y[j]+t[i+j]+carry;
   t[i+j]=@truncate(v);carry=@intCast(v>>64);
  }
  addWord(&t,i+4,carry);
 }
 return reduce(t);
}
pub fn square(a:u256) u256 {
 const x=words(a);var t:[9]u64=@splat(0);
 for(0..4) |i| {
  const d=@as(u128,x[i])*x[i];addWord(&t,2*i,@truncate(d));addWord(&t,2*i+1,@intCast(d>>64));
  for(i+1..4) |j| {
   const cross=@as(u128,x[i])*x[j];
   // Two explicit additions retain the 129th bit of doubled cross products.
   for(0..2) |_| {addWord(&t,i+j,@truncate(cross));addWord(&t,i+j+1,@intCast(cross>>64));}
  }
 }
 return reduce(t);
}
pub fn add(a:u256,b:u256) u256 {
 const x=words(a);const y=words(b);var t:[9]u64=@splat(0);var carry:u64=0;
 for(0..4) |i| {const sum=@as(u128,x[i])+y[i]+carry;t[i]=@truncate(sum);carry=@intCast(sum>>64);}
 t[4]=carry;return reduce(t);
}
pub fn subtract(a:u256,b:u256) u256 { return if(a>=b) a-b else P-(b-a); }
test "layout round trips" {for([_]u256{0,1,P-1,std.math.maxInt(u256)}) |x| try std.testing.expectEqual(x,integer(words(x)));}
