//! Binary GCD on little-endian limbs. Coefficients remain below the modulus.
const std=@import("std");const L=[4]u64;
comptime {if(@import("builtin").cpu.arch.endian()!=.little or @sizeOf(L)!=@sizeOf(u256)) @compileError("little endian required");}
fn cmp(a:L,b:L) std.math.Order {var i:usize=4;while(i>0){i-=1;if(a[i]<b[i]) return .lt;if(a[i]>b[i]) return .gt;}return .eq;}
fn minus(a:L,b:L) L {
 var r:L=undefined;var borrow:u1=0;
 for(0..4) |i| {const first=@subWithOverflow(a[i],b[i]);const second=@subWithOverflow(first[0],borrow);r[i]=second[0];borrow=first[1]|second[1];}
 std.debug.assert(borrow==0);return r;
}
fn half(a:L) L {var r:L=undefined;for(0..4) |i| r[i]=(a[i]>>1)|(if(i<3) a[i+1]<<63 else @as(u64,0));return r;}
fn coeff(a:L,m:L) L {
 var r=half(a);if(a[0]&1==0)return r;
 const h=half(m);var carry:u64=1;
 for(0..4) |i| {const sum=@as(u128,r[i])+h[i]+carry;r[i]=@truncate(sum);carry=@intCast(sum>>64);}
 // a,m odd and a<m implies (a+m)/2<m<2^256.
 std.debug.assert(carry==0);return r;
}
fn difference(a:L,b:L,m:L) L {return if(cmp(a,b)!=.lt) minus(a,b) else minus(m,minus(b,a));}
pub fn inverse(input:u256,modulus:u256) error{InvalidScalar}!u256 {
 if(input==0 or input>=modulus)return error.InvalidScalar;
 var u:L=@bitCast(input);const m:L=@bitCast(modulus);var v=m;var x:L=.{1,0,0,0};var y:L=@splat(0);
 const one:L=.{1,0,0,0};const zero:L=@splat(0);
 while(cmp(u,one)!=.eq and cmp(v,one)!=.eq){
  if(cmp(u,zero)==.eq or cmp(v,zero)==.eq)return error.InvalidScalar;
  while(u[0]&1==0){u=half(u);x=coeff(x,m);}
  while(v[0]&1==0){v=half(v);y=coeff(y,m);}
  if(cmp(u,v)!=.lt){u=minus(u,v);x=difference(x,y,m);}else{v=minus(v,u);y=difference(y,x,m);}
 }
 return @bitCast(if(cmp(u,one)==.eq) x else y);
}
