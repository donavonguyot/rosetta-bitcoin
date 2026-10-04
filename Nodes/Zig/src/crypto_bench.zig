//! Microbenchmark of own_curve against the public libsecp256k1 verify API.
//! Field and group operations are own_curve only: the C headers do not expose them.
const std = @import("std");
const core = @import("zigbitnode");
const secp = @import("secp256k1");
const c = @cImport({
    @cInclude("secp256k1.h");
    @cInclude("secp256k1_extrakeys.h");
    @cInclude("secp256k1_schnorrsig.h");
});

const verify_iters: usize = 300;
const scalar_iters: usize = 200;
const point_iters: usize = 2000;
const field_iters: usize = 4000;
const repetitions: usize = 3;

const ecdsa_id = "ecdsa-valid-privkey-1-deadbeef";
const schnorr_id = "schnorr-valid-privkey-12345-cafebabe";
const tweak_id = "taproot-valid-privkey-300-c0ffee";

extern "c" fn sysctlbyname(name: [*:0]const u8, oldp: ?*anyopaque, oldlenp: *usize, newp: ?*anyopaque, newlen: usize) c_int;

const Row = struct {
    name: []const u8,
    backend: []const u8,
    iterations: usize,
    min_ns: u64,
    median_ns: u64,
};

const Inputs = struct {
    ecdsa_key: [33]u8,
    ecdsa_msg: [32]u8,
    ecdsa_sig: [70]u8,
    schnorr_key: [32]u8,
    schnorr_msg: [32]u8,
    schnorr_sig: [64]u8,
    tweak_key: [32]u8,
    tweak: [32]u8,
    tweak_out: [32]u8,
    tweak_parity: u8,

    fn fixed() Inputs {
        return .{
            .ecdsa_key = hex33("0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"),
            .ecdsa_msg = hex32("281dd50f6f56bc6e867fe73dd614a73c55a647a479704f64804b574cafb0f5c5"),
            .ecdsa_sig = hex70("3044022079be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f8179802205e23c47196cc87e523dfb62c5b644dbb626c9867080a27fde59485e5098d33e4"),
            .schnorr_key = hex32("f01d6b9018ab421dd410404cb869072065522bf85734008f105cf385a023a80f"),
            .schnorr_msg = hex32("3ad22a0437431f2d102505b27048dfce20b1f90b32fe2116130d2bd4b35084b9"),
            .schnorr_sig = hex64("632f89d23c32b7d66873d7ef89e730f44f3d063394f8661e4421469979ac5784c80478f3845b4719c92c339fe1032890f9d96b6b0b44a8ea05da6ce88a133b7b"),
            .tweak_key = hex32("85a7b790fc9d962493788317e4874a4ab07f1e9c78c773c47f2f6c96df756f05"),
            .tweak = tapTweak(
                &hex32("85a7b790fc9d962493788317e4874a4ab07f1e9c78c773c47f2f6c96df756f05"),
                &hex32("446ba384864eb34196e08044029fb463d97748e4549dfd0e2612f60d74c4f165"),
            ),
            .tweak_out = hex32("4b3e30f94e0ae82945cbb40d83088b8f3bea370c24c575b7788889ad5e64da8b"),
            .tweak_parity = 1,
        };
    }

    fn check(self: *const Inputs) !void {
        if (!(secp.verifyEcdsa(&self.ecdsa_key, &self.ecdsa_msg, &self.ecdsa_sig) catch false)) return error.BenchVectorRejected;
        if (!(secp.verifySchnorr(&self.schnorr_key, &self.schnorr_msg, &self.schnorr_sig) catch false)) return error.BenchVectorRejected;
        if (!(secp.checkXOnlyTweak(&self.tweak_key, &self.tweak, &self.tweak_out, self.tweak_parity) catch false)) return error.BenchVectorRejected;
    }
};

const Prepared = struct {
    point: secp.Point,
    doubled: secp.Point,
    scalar_s: u256,
    scalar_z: u256,
    field_z: u256,
};
var prepared: Prepared = undefined;
var fe_running: u256 = 0;
var sink_u: u256 = 0;
var sink_b: u8 = 0;
var cpu_buf: [128]u8 = undefined;

pub fn run(allocator: std.mem.Allocator, io: std.Io, out: anytype, args: []const []const u8) !void {
    const profile = flag(args, "--profile");
    if (profile and !core.crypto.curve_profile) return error.CurveProfileNotCompiled;
    if (!profile and core.crypto.curve_profile) return error.TimedBenchIncludesProfileCounters;
    const inputs = Inputs.fixed();
    try inputs.check();
    if (profile) {
        try writeProfile(allocator, io, out, &inputs);
        return;
    }
    prepare(&inputs);
    try writeBench(allocator, io, out, &inputs);
    std.mem.doNotOptimizeAway(sink_u);
    std.mem.doNotOptimizeAway(sink_b);
}

fn prepare(inputs: *const Inputs) void {
    const base = secp.benchBasePoint();
    prepared = .{
        .point = (secp.parseXOnly(&inputs.schnorr_key) catch unreachable).point,
        .doubled = secp.benchPointDouble(base),
        .scalar_s = secp.benchRead(inputs.schnorr_sig[32..64]),
        .scalar_z = secp.benchRead(&inputs.ecdsa_msg),
        .field_z = secp.benchRead(&inputs.ecdsa_msg),
    };
    fe_running = secp.benchBasePoint().x;
}

fn writeBench(allocator: std.mem.Allocator, io: std.Io, out: anytype, inputs: *const Inputs) !void {
    const ctx = try cContext();
    defer c.secp256k1_context_destroy(ctx);
    var rows: [22]Row = undefined;
    var n: usize = 0;
    n = addPair(&rows, n, io, "ecdsa_verify", verify_iters, inputs, ctx, timeEcdsaOwn, timeEcdsaC);
    n = addPair(&rows, n, io, "schnorr_verify", verify_iters, inputs, ctx, timeSchnorrOwn, timeSchnorrC);
    n = addPair(&rows, n, io, "taproot_tweak_check", verify_iters, inputs, ctx, timeTweakOwn, timeTweakC);
    n = addPair(&rows, n, io, "pubkey_parse", verify_iters, inputs, ctx, timeParseOwn, timeParseC);
    rows[n] = timeOwn(io, "double_scalar_mul", scalar_iters, timeDouble);
    n += 1;
    rows[n] = timeOwn(io, "scalar_mul_fixed", scalar_iters, timeFixed);
    n += 1;
    rows[n] = timeOwn(io, "scalar_mul_var", scalar_iters, timeVar);
    n += 1;
    rows[n] = timeOwn(io, "point_add", point_iters, timeAdd);
    n += 1;
    rows[n] = timeOwn(io, "point_double", point_iters, timeDoublePoint);
    n += 1;
    rows[n] = timeOwn(io, "to_affine", scalar_iters, timeAffine);
    n += 1;
    rows[n] = timeOwn(io, "fe_mul", field_iters, timeFeMul);
    n += 1;
    rows[n] = timeOwn(io, "fe_sqr", field_iters, timeFeSqr);
    n += 1;
    rows[n] = timeOwn(io, "fe_inv", scalar_iters, timeFeInv);
    n += 1;
    rows[n] = timeOwn(io, "fe_normalize", field_iters, timeFeNorm);
    n += 1;
    rows[n] = timeOwn(io, "sc_mul", field_iters, timeScMul);
    n += 1;
    rows[n] = timeOwn(io, "sc_inv", scalar_iters, timeScInv);
    n += 1;
    const digest = try binarySha256(allocator, io);
    try out.print(
        "{{\"schema\":\"port.own_curve.bench.v1\",\"port\":\"zig\",\"cpu\":\"{s}\",\"optimize\":\"ReleaseSafe\",\"source_commit\":\"{s}\",\"binary_sha256\":\"{s}\",\"repetitions\":{d},\"judge\":\"median\",\"c_field_group\":\"not_exposed\",\"vectors\":[\"{s}\",\"{s}\",\"{s}\"],\"operations\":[",
        .{ cpuBrand(), core.crypto.source_commit, &digest, repetitions, ecdsa_id, schnorr_id, tweak_id },
    );
    for (rows[0..n], 0..) |row, i| {
        if (i != 0) try out.writeAll(",");
        try out.print(
            "{{\"name\":\"{s}\",\"backend\":\"{s}\",\"iterations\":{d},\"min_ns\":{d},\"median_ns\":{d}}}",
            .{ row.name, row.backend, row.iterations, row.min_ns, row.median_ns },
        );
    }
    try out.writeAll("]}\n");
}

fn writeProfile(allocator: std.mem.Allocator, io: std.Io, out: anytype, inputs: *const Inputs) !void {
    const names = [_][]const u8{ "ecdsa_verify", "schnorr_verify", "taproot_tweak_check" };
    var counts: [3]secp.ProfileCounts = undefined;
    for (&counts, 0..) |*slot, i| {
        secp.profileReset();
        const ok = switch (i) {
            0 => secp.verifyEcdsa(&inputs.ecdsa_key, &inputs.ecdsa_msg, &inputs.ecdsa_sig) catch false,
            1 => secp.verifySchnorr(&inputs.schnorr_key, &inputs.schnorr_msg, &inputs.schnorr_sig) catch false,
            else => secp.checkXOnlyTweak(&inputs.tweak_key, &inputs.tweak, &inputs.tweak_out, inputs.tweak_parity) catch false,
        };
        if (!ok) return error.BenchVectorRejected;
        slot.* = secp.profileCounts();
    }
    const digest = try binarySha256(allocator, io);
    try out.print(
        "{{\"schema\":\"port.own_curve.profile.v1\",\"port\":\"zig\",\"cpu\":\"{s}\",\"optimize\":\"ReleaseSafe\",\"source_commit\":\"{s}\",\"binary_sha256\":\"{s}\",\"verifies\":[",
        .{ cpuBrand(), core.crypto.source_commit, &digest },
    );
    for (names, counts, 0..) |name, count, i| {
        if (i != 0) try out.writeAll(",");
        try out.print(
            "{{\"name\":\"{s}\",\"fe_inv\":{d},\"fe_mul_sqr\":{d},\"point_double\":{d},\"point_add\":{d},\"to_affine\":{d},\"table_hit\":{d}}}",
            .{ name, count.fe_inv, count.fe_mul_sqr, count.point_double, count.point_add, count.to_affine, count.table_hit },
        );
    }
    try out.writeAll("]}\n");
}

fn hex32(comptime text: []const u8) [32]u8 {
    return hex(32, text);
}
fn hex33(comptime text: []const u8) [33]u8 {
    return hex(33, text);
}
fn hex64(comptime text: []const u8) [64]u8 {
    return hex(64, text);
}
fn hex70(comptime text: []const u8) [70]u8 {
    return hex(70, text);
}
fn tapTweak(key: *const [32]u8, merkle: *const [32]u8) [32]u8 {
    const Sha = std.crypto.hash.sha2.Sha256;
    var tag: [32]u8 = undefined;
    Sha.hash("TapTweak", &tag, .{});
    var h = Sha.init(.{});
    h.update(&tag);
    h.update(&tag);
    h.update(key);
    h.update(merkle);
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

fn hex(comptime len: usize, comptime text: []const u8) [len]u8 {
    var out: [len]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, text) catch unreachable;
    return out;
}

fn cContext() !*c.secp256k1_context {
    return c.secp256k1_context_create(c.SECP256K1_CONTEXT_VERIFY) orelse error.NativeCryptoUnavailable;
}

const OwnBody = *const fn (*const Inputs) void;
const CBody = *const fn (*const Inputs, *c.secp256k1_context) void;

fn addPair(rows: []Row, n: usize, io: std.Io, name: []const u8, iters: usize, inputs: *const Inputs, ctx: *c.secp256k1_context, own_body: OwnBody, c_body: CBody) usize {
    var own_samples: [repetitions]u64 = undefined;
    var c_samples: [repetitions]u64 = undefined;
    for (0..repetitions) |i| {
        own_samples[i] = timeIters(io, iters, inputs, own_body);
        c_samples[i] = timeItersC(io, iters, inputs, ctx, c_body);
    }
    const own = summarize(own_samples);
    const c_stats = summarize(c_samples);
    rows[n] = .{ .name = name, .backend = "own_curve", .iterations = iters, .min_ns = own.min_ns, .median_ns = own.median_ns };
    rows[n + 1] = .{ .name = name, .backend = "c_binding", .iterations = iters, .min_ns = c_stats.min_ns, .median_ns = c_stats.median_ns };
    return n + 2;
}

fn timeOwn(io: std.Io, name: []const u8, iters: usize, body: *const fn () void) Row {
    var samples: [repetitions]u64 = undefined;
    for (&samples) |*sample| {
        const start = std.Io.Clock.awake.now(io).nanoseconds;
        for (0..iters) |_| body();
        sample.* = perOp(std.Io.Clock.awake.now(io).nanoseconds - start, iters);
    }
    const stats = summarize(samples);
    return .{ .name = name, .backend = "own_curve", .iterations = iters, .min_ns = stats.min_ns, .median_ns = stats.median_ns };
}

fn timeIters(io: std.Io, iters: usize, inputs: *const Inputs, body: OwnBody) u64 {
    const start = std.Io.Clock.awake.now(io).nanoseconds;
    for (0..iters) |_| body(inputs);
    return perOp(std.Io.Clock.awake.now(io).nanoseconds - start, iters);
}
fn timeItersC(io: std.Io, iters: usize, inputs: *const Inputs, ctx: *c.secp256k1_context, body: CBody) u64 {
    const start = std.Io.Clock.awake.now(io).nanoseconds;
    for (0..iters) |_| body(inputs, ctx);
    return perOp(std.Io.Clock.awake.now(io).nanoseconds - start, iters);
}
fn perOp(elapsed: i128, iters: usize) u64 {
    return @intCast(@divTrunc(elapsed, @as(i128, @intCast(iters))));
}
fn summarize(samples: [repetitions]u64) struct { min_ns: u64, median_ns: u64 } {
    var ordered = samples;
    if (ordered[0] > ordered[1]) std.mem.swap(u64, &ordered[0], &ordered[1]);
    if (ordered[1] > ordered[2]) std.mem.swap(u64, &ordered[1], &ordered[2]);
    if (ordered[0] > ordered[1]) std.mem.swap(u64, &ordered[0], &ordered[1]);
    return .{ .min_ns = ordered[0], .median_ns = ordered[1] };
}

fn timeEcdsaOwn(inputs: *const Inputs) void {
    sink_b ^= @intFromBool(secp.verifyEcdsa(&inputs.ecdsa_key, &inputs.ecdsa_msg, &inputs.ecdsa_sig) catch false);
}
fn timeSchnorrOwn(inputs: *const Inputs) void {
    sink_b ^= @intFromBool(secp.verifySchnorr(&inputs.schnorr_key, &inputs.schnorr_msg, &inputs.schnorr_sig) catch false);
}
fn timeTweakOwn(inputs: *const Inputs) void {
    sink_b ^= @intFromBool(secp.checkXOnlyTweak(&inputs.tweak_key, &inputs.tweak, &inputs.tweak_out, inputs.tweak_parity) catch false);
}
fn timeParseOwn(inputs: *const Inputs) void {
    sink_b ^= @intFromBool(if (secp.parsePublicKey(&inputs.ecdsa_key)) |_| true else |_| false);
}
fn timeEcdsaC(inputs: *const Inputs, ctx: *c.secp256k1_context) void {
    var key: c.secp256k1_pubkey = undefined;
    var sig: c.secp256k1_ecdsa_signature = undefined;
    const parsed = c.secp256k1_ec_pubkey_parse(ctx, &key, &inputs.ecdsa_key, inputs.ecdsa_key.len) == 1 and
        c.secp256k1_ecdsa_signature_parse_der(ctx, &sig, &inputs.ecdsa_sig, inputs.ecdsa_sig.len) == 1;
    if (parsed) _ = c.secp256k1_ecdsa_signature_normalize(ctx, &sig, &sig);
    sink_b ^= @intFromBool(parsed and c.secp256k1_ecdsa_verify(ctx, &sig, &inputs.ecdsa_msg, &key) == 1);
}
fn timeSchnorrC(inputs: *const Inputs, ctx: *c.secp256k1_context) void {
    var key: c.secp256k1_xonly_pubkey = undefined;
    const parsed = c.secp256k1_xonly_pubkey_parse(ctx, &key, &inputs.schnorr_key) == 1;
    sink_b ^= @intFromBool(parsed and c.secp256k1_schnorrsig_verify(ctx, &inputs.schnorr_sig, &inputs.schnorr_msg, inputs.schnorr_msg.len, &key) == 1);
}
fn timeTweakC(inputs: *const Inputs, ctx: *c.secp256k1_context) void {
    var key: c.secp256k1_xonly_pubkey = undefined;
    const parsed = c.secp256k1_xonly_pubkey_parse(ctx, &key, &inputs.tweak_key) == 1;
    sink_b ^= @intFromBool(parsed and c.secp256k1_xonly_pubkey_tweak_add_check(ctx, &inputs.tweak_out, inputs.tweak_parity, &key, &inputs.tweak) == 1);
}
fn timeParseC(inputs: *const Inputs, ctx: *c.secp256k1_context) void {
    var key: c.secp256k1_pubkey = undefined;
    sink_b ^= @intFromBool(c.secp256k1_ec_pubkey_parse(ctx, &key, &inputs.ecdsa_key, inputs.ecdsa_key.len) == 1);
}

fn timeDouble() void {
    const q = secp.benchDoubleScalar(prepared.scalar_s, prepared.point, prepared.scalar_z);
    sink_u ^= q.x;
}
fn timeFixed() void {
    sink_u ^= secp.benchScalarMulFixed(prepared.scalar_s).x;
}
fn timeVar() void {
    sink_u ^= secp.benchScalarMulVar(prepared.point, prepared.scalar_s).x;
}
fn timeAdd() void {
    sink_u ^= secp.benchPointAdd(secp.benchBasePoint(), prepared.doubled).x;
}
fn timeDoublePoint() void {
    sink_u ^= secp.benchPointDouble(secp.benchBasePoint()).x;
}
fn timeAffine() void {
    sink_u ^= (secp.benchToAffine(prepared.doubled) catch unreachable).x;
}
fn timeFeMul() void {
    fe_running = secp.benchFeMul(fe_running, prepared.field_z);
    sink_u ^= fe_running;
}
fn timeFeSqr() void {
    fe_running = secp.benchFeSqr(fe_running);
    sink_u ^= fe_running;
}
fn timeFeInv() void {
    sink_u ^= secp.benchFeInv(secp.benchBasePoint().x) catch unreachable;
}
fn timeFeNorm() void {
    fe_running = secp.benchFeNormalize(fe_running);
    sink_u ^= fe_running;
}
fn timeScMul() void {
    sink_u ^= secp.benchScMul(prepared.scalar_s, prepared.scalar_z);
}
fn timeScInv() void {
    sink_u ^= secp.benchScInv(prepared.scalar_s) catch unreachable;
}

fn flag(args: []const []const u8, name: []const u8) bool {
    for (args) |arg| if (std.mem.eql(u8, arg, name)) return true;
    return false;
}

fn cpuBrand() []const u8 {
    var len: usize = cpu_buf.len;
    if (sysctlbyname("machdep.cpu.brand_string", &cpu_buf, &len, null, 0) != 0 or len < 2) return "unknown";
    return cpu_buf[0 .. len - 1];
}

fn binarySha256(allocator: std.mem.Allocator, io: std.Io) ![64]u8 {
    const file = try std.process.openExecutable(io, .{});
    defer file.close(io);
    const len = try file.length(io);
    const bytes = try allocator.alloc(u8, @intCast(len));
    defer allocator.free(bytes);
    const n = try file.readPositionalAll(io, bytes, 0);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[0..n], &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}
