const std=@import("std");
test "runtime wide remainder agrees with independently evaluated constant" {
 var x:u512=std.math.maxInt(u512); std.mem.doNotOptimizeAway(&x);
 const p:u256=0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f;
 try std.testing.expectEqual(@as(u512,18446752466076602528),x%p);
}
