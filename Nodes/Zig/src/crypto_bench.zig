//! Microbenchmark of own_curve against the public libsecp256k1 verify API.
//! Paired ops interleave own_curve and the C binding in one loop. Field and
//! group ops stay own_curve only: those entry points are not in the C headers.
const std = @import("std");
const core = @import("zigbitnode");
const secp = @import("secp256k1");
const c = @cImport({
    @cInclude("secp256k1.h");
    @cInclude("secp256k1_extrakeys.h");
    @cInclude("secp256k1_schnorrsig.h");
});

const verify_iters: usize = 800;
const scalar_iters: usize = 800;
const point_iters: usize = 200_000;
const field_iters: usize = 2_000_000;
const inv_iters: usize = 30_000;
const norm_iters: usize = 16_000_000;
const max_batches: usize = 256;
const min_batches: usize = 3;
const qos_user_interactive: c_uint = 0x21;
const batch_cap_ns: i128 = 20_000_000_000;
const centi: i128 = 100;

const ecdsa_id = "ecdsa-valid-privkey-1-deadbeef";
const schnorr_id = "schnorr-valid-privkey-12345-cafebabe";
const tweak_id = "taproot-valid-privkey-300-c0ffee";

extern "c" fn sysctlbyname(name: [*:0]const u8, oldp: ?*anyopaque, oldlenp: *usize, newp: ?*anyopaque, newlen: usize) c_int;
extern "c" fn getloadavg(loadavg: *[3]f64, nelem: c_int) c_int;
extern "c" fn getpid() c_int;
extern "c" fn getppid() c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn pthread_set_qos_class_self_np(class: c_uint, relative: c_int) c_int;
extern "c" fn popen(command: [*:0]const u8, mode: [*:0]const u8) ?*std.c.FILE;
extern "c" fn pclose(stream: *std.c.FILE) c_int;
extern "c" fn fgets(s: [*]u8, n: c_int, stream: *std.c.FILE) ?[*]u8;

const OwnFn = *const fn (*const Inputs) void;
const CFn = *const fn (*const Inputs, *c.secp256k1_context) void;
const SoloFn = *const fn () void;

const Arm = struct { min_centi: u64, median_centi: u64, p90_centi: u64 };
const Measured = struct {
    iterations: usize,
    batches: usize,
    capped: bool,
    stable: bool,
    own: Arm,
    c_arm: ?Arm,
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
    // Leave the task class alone unless BENCH_QOS asks. taskpolicy -c utility
    // was the stable mode; forcing interactive fought the concurrent UI.
    const qos_ok = applyRequestedQos();
    const digest = try binarySha256(allocator, io);
    const ambient_before = collectAmbient(allocator);
    defer if (ambient_before.thermal) |text| allocator.free(text);
    var first_ops: std.ArrayList(u8) = .empty;
    var second_ops: std.ArrayList(u8) = .empty;
    defer first_ops.deinit(allocator);
    defer second_ops.deinit(allocator);
    // Each op is measured twice back to back, so the two lines see the same clock.
    try writePairTwice(allocator, &first_ops, &second_ops, io, "ecdsa_verify", verify_iters, inputs, ctx, timeEcdsaOwn, timeEcdsaC, false);
    try writePairTwice(allocator, &first_ops, &second_ops, io, "schnorr_verify", verify_iters, inputs, ctx, timeSchnorrOwn, timeSchnorrC, true);
    try writePairTwice(allocator, &first_ops, &second_ops, io, "taproot_tweak_check", verify_iters, inputs, ctx, timeTweakOwn, timeTweakC, true);
    try writePairTwice(allocator, &first_ops, &second_ops, io, "pubkey_parse", verify_iters, inputs, ctx, timeParseOwn, timeParseC, true);
    try writeSoloTwice(allocator, &first_ops, &second_ops, io, "double_scalar_mul", scalar_iters, timeDouble, true);
    try writeSoloTwice(allocator, &first_ops, &second_ops, io, "scalar_mul_fixed", scalar_iters, timeFixed, true);
    try writeSoloTwice(allocator, &first_ops, &second_ops, io, "scalar_mul_var", scalar_iters, timeVar, true);
    try writeSoloTwice(allocator, &first_ops, &second_ops, io, "point_add", point_iters, timeAdd, true);
    try writeSoloTwice(allocator, &first_ops, &second_ops, io, "point_double", point_iters, timeDoublePoint, true);
    try writeSoloTwice(allocator, &first_ops, &second_ops, io, "to_affine", scalar_iters, timeAffine, true);
    try writeSoloTwice(allocator, &first_ops, &second_ops, io, "fe_mul", field_iters, timeFeMul, true);
    try writeSoloTwice(allocator, &first_ops, &second_ops, io, "fe_sqr", field_iters, timeFeSqr, true);
    try writeSoloTwice(allocator, &first_ops, &second_ops, io, "fe_inv", inv_iters, timeFeInv, true);
    try writeSoloTwice(allocator, &first_ops, &second_ops, io, "fe_normalize", norm_iters, timeFeNorm, true);
    try writeSoloTwice(allocator, &first_ops, &second_ops, io, "sc_mul", field_iters, timeScMul, true);
    try writeSoloTwice(allocator, &first_ops, &second_ops, io, "sc_inv", inv_iters, timeScInv, true);
    const ambient_after = collectAmbient(allocator);
    defer if (ambient_after.thermal) |text| allocator.free(text);
    try writeLine(out, &digest, qos_ok, ambient_before, first_ops.items);
    try writeLine(out, &digest, qos_ok, ambient_after, second_ops.items);
    std.mem.doNotOptimizeAway(fe_running);
    std.mem.doNotOptimizeAway(sink_u);
}

fn writeLine(out: anytype, digest: *const [64]u8, qos_ok: bool, ambient: Ambient, ops: []const u8) !void {
    try out.print(
        "{{\"schema\":\"port.own_curve.bench.v2\",\"port\":\"zig\",\"cpu\":\"{s}\",\"optimize\":\"ReleaseSafe\",\"source_commit\":\"{s}\",\"binary_sha256\":\"{s}\",\"judge\":\"ratio_min\",\"scheduling\":\"{s}\",\"c_field_group\":\"not_exposed\",\"vectors\":[\"{s}\",\"{s}\",\"{s}\"],",
        .{ cpuBrand(), core.crypto.source_commit, digest, schedulingMode(), ecdsa_id, schnorr_id, tweak_id },
    );
    try writeAmbient(out, ambient, qos_ok);
    try out.writeAll(",\"operations\":[");
    try out.writeAll(ops);
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

fn now(io: std.Io) i128 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

const ListWriter = struct {
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    fn writeAll(self: *@This(), bytes: []const u8) !void {
        try self.list.appendSlice(self.allocator, bytes);
    }
    fn writeByte(self: *@This(), byte: u8) !void {
        try self.list.append(self.allocator, byte);
    }
    fn print(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
        try self.list.print(self.allocator, fmt, args);
    }
};

fn writePairTwice(allocator: std.mem.Allocator, first: *std.ArrayList(u8), second: *std.ArrayList(u8), io: std.Io, name: []const u8, iters: usize, inputs: *const Inputs, ctx: *c.secp256k1_context, own_fn: OwnFn, c_fn: CFn, comma: bool) !void {
    const a = measurePair(io, iters, inputs, ctx, own_fn, c_fn);
    const b = measurePair(io, iters, inputs, ctx, own_fn, c_fn);
    var left = ListWriter{ .list = first, .allocator = allocator };
    var right = ListWriter{ .list = second, .allocator = allocator };
    try writeMeasured(&left, name, a, comma);
    try writeMeasured(&right, name, b, comma);
}

fn writeSoloTwice(allocator: std.mem.Allocator, first: *std.ArrayList(u8), second: *std.ArrayList(u8), io: std.Io, name: []const u8, iters: usize, body: SoloFn, comma: bool) !void {
    const a = measureSolo(io, iters, body);
    const b = measureSolo(io, iters, body);
    var left = ListWriter{ .list = first, .allocator = allocator };
    var right = ListWriter{ .list = second, .allocator = allocator };
    try writeMeasured(&left, name, a, comma);
    try writeMeasured(&right, name, b, comma);
}

fn measurePair(io: std.Io, iters: usize, inputs: *const Inputs, ctx: *c.secp256k1_context, own_fn: OwnFn, c_fn: CFn) Measured {
    fe_running = secp.benchBasePoint().x;
    // One discarded batch pays the first cache fill before the recorded mins.
    _ = pairBatch(io, iters, inputs, ctx, own_fn, c_fn);
    var own_samples: [max_batches]u64 = undefined;
    var c_samples: [max_batches]u64 = undefined;
    var batches: usize = 0;
    var capped = false;
    var spent: i128 = 0;
    while (batches < max_batches and spent < batch_cap_ns) {
        const start = now(io);
        const batch = pairBatch(io, iters, inputs, ctx, own_fn, c_fn);
        own_samples[batches] = batch.own;
        c_samples[batches] = batch.c_ns;
        batches += 1;
        spent += now(io) - start;
        if (batches >= min_batches and agrees(own_samples[batches - 3 .. batches]) and agrees(c_samples[batches - 3 .. batches])) break;
    } else capped = true;
    if (batches >= 3 and agrees(own_samples[batches - 3 .. batches]) and agrees(c_samples[batches - 3 .. batches])) capped = false;
    return finish(iters, batches, capped, &own_samples, c_samples[0..batches]);
}

fn measureSolo(io: std.Io, iters: usize, body: SoloFn) Measured {
    fe_running = secp.benchBasePoint().x;
    _ = soloBatch(io, iters, body);
    var own_samples: [max_batches]u64 = undefined;
    var batches: usize = 0;
    var capped = false;
    var spent: i128 = 0;
    while (batches < max_batches and spent < batch_cap_ns) {
        const start = now(io);
        own_samples[batches] = soloBatch(io, iters, body);
        batches += 1;
        spent += now(io) - start;
        if (batches >= min_batches and agrees(own_samples[batches - 3 .. batches])) break;
    } else capped = true;
    if (batches >= 3 and agrees(own_samples[batches - 3 .. batches])) capped = false;
    return finish(iters, batches, capped, &own_samples, null);
}

fn pairBatch(io: std.Io, iters: usize, inputs: *const Inputs, ctx: *c.secp256k1_context, own_fn: OwnFn, c_fn: CFn) struct { own: u64, c_ns: u64 } {
    var own_elapsed: i128 = 0;
    var c_elapsed: i128 = 0;
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        const t0 = now(io);
        own_fn(inputs);
        const t1 = now(io);
        c_fn(inputs, ctx);
        const t2 = now(io);
        own_elapsed += t1 - t0;
        c_elapsed += t2 - t1;
    }
    return .{ .own = centiPerOp(own_elapsed, iters), .c_ns = centiPerOp(c_elapsed, iters) };
}

fn soloBatch(io: std.Io, iters: usize, body: SoloFn) u64 {
    const start = now(io);
    var i: usize = 0;
    while (i < iters) : (i += 1) body();
    return centiPerOp(now(io) - start, iters);
}

fn centiPerOp(elapsed: i128, iters: usize) u64 {
    return @intCast(@divTrunc(elapsed * centi, @as(i128, @intCast(iters))));
}

fn agrees(samples: []const u64) bool {
    const lo = @min(samples[0], @min(samples[1], samples[2]));
    const hi = @max(samples[0], @max(samples[1], samples[2]));
    return hi * 100 <= lo * 102;
}

fn finish(iters: usize, batches: usize, capped: bool, own_samples: *[max_batches]u64, c_samples: ?[]const u64) Measured {
    const own = armStats(own_samples[0..batches]);
    return .{
        .iterations = iters,
        .batches = batches,
        .capped = capped,
        .stable = !capped,
        .own = own,
        .c_arm = if (c_samples) |samples| armStats(samples) else null,
    };
}

fn armStats(samples: []const u64) Arm {
    var ordered: [max_batches]u64 = undefined;
    @memcpy(ordered[0..samples.len], samples);
    std.mem.sort(u64, ordered[0..samples.len], {}, std.sort.asc(u64));
    const n = samples.len;
    const p90 = ordered[if (n == 1) 0 else (n * 9 + 9) / 10 - 1];
    // The published min is the agreeing tail. An earlier outlier is not the stable min.
    const min_centi = if (n >= 3 and agrees(samples[n - 3 ..])) windowMin(samples[n - 3 ..]) else ordered[0];
    return .{
        .min_centi = min_centi,
        .median_centi = ordered[n / 2],
        .p90_centi = p90,
    };
}

fn windowMin(samples: []const u64) u64 {
    return @min(samples[0], @min(samples[1], samples[2]));
}

fn writeMeasured(out: anytype, name: []const u8, measured: Measured, comma: bool) !void {
    if (comma) try out.writeAll(",");
    try out.print(
        "{{\"name\":\"{s}\",\"iterations\":{d},\"batches\":{d},\"capped\":{s},\"stable\":{s},\"own\":{{\"min_ns\":",
        .{ name, measured.iterations, measured.batches, boolText(measured.capped), boolText(measured.stable) },
    );
    try writeCentiNs(out, measured.own.min_centi);
    try out.writeAll(",\"median_ns\":");
    try writeCentiNs(out, measured.own.median_centi);
    try out.writeAll(",\"p90_ns\":");
    try writeCentiNs(out, measured.own.p90_centi);
    try out.writeAll("}");
    if (measured.c_arm) |arm| {
        try out.writeAll(",\"c_binding\":{\"min_ns\":");
        try writeCentiNs(out, arm.min_centi);
        try out.writeAll(",\"median_ns\":");
        try writeCentiNs(out, arm.median_centi);
        try out.writeAll(",\"p90_ns\":");
        try writeCentiNs(out, arm.p90_centi);
        try out.writeAll("},\"ratio_min\":");
        try writeRatio(out, measured.own.min_centi, arm.min_centi);
        try out.writeAll(",\"ratio_median\":");
        try writeRatio(out, measured.own.median_centi, arm.median_centi);
        try out.writeAll("}");
    } else {
        try out.writeAll(",\"c_binding\":\"not_exposed\"}");
    }
}

fn writeCentiNs(out: anytype, value_centi: u64) !void {
    try out.print("{d}.{d:0>2}", .{ value_centi / 100, value_centi % 100 });
}

fn writeRatio(out: anytype, own_centi: u64, c_centi: u64) !void {
    const milli = if (c_centi == 0) 0 else own_centi * 1000 / c_centi;
    try out.print("{d}.{d:0>3}", .{ milli / 1000, milli % 1000 });
}

fn boolText(value: bool) []const u8 {
    return if (value) "true" else "false";
}

const Ambient = struct {
    load_centi: [3]u64,
    load_ok: bool,
    other_zig_build: ?bool,
    sync_running: ?bool,
    thermal: ?[]u8,
};

fn collectAmbient(allocator: std.mem.Allocator) Ambient {
    var load: [3]f64 = undefined;
    const load_ok = getloadavg(&load, 3) == 3;
    var load_centi = [_]u64{0} ** 3;
    if (load_ok) {
        for (load, &load_centi) |value, *slot| slot.* = @intFromFloat(@max(value, 0) * 100.0);
    }
    const ps = slurp(allocator, "ps -axo pid=,command=") catch null;
    defer if (ps) |text| allocator.free(text);
    const flags = if (ps) |text| scanProcesses(text) else null;
    const raw_thermal = slurp(allocator, "pmset -g therm") catch null;
    const thermal = if (raw_thermal) |text| collapseThermal(allocator, text) catch null else null;
    if (raw_thermal) |text| allocator.free(text);
    return .{
        .load_centi = load_centi,
        .load_ok = load_ok,
        .other_zig_build = if (flags) |found| found.zig_build else null,
        .sync_running = if (flags) |found| found.syncing else null,
        .thermal = thermal,
    };
}

fn writeAmbient(out: anytype, ambient: Ambient, qos_ok: bool) !void {
    try out.writeAll("\"ambient\":{\"loadavg\":");
    if (ambient.load_ok) {
        try out.writeAll("[");
        for (ambient.load_centi, 0..) |value, i| {
            if (i != 0) try out.writeAll(",");
            try out.print("{d}.{d:0>2}", .{ value / 100, value % 100 });
        }
        try out.writeAll("]");
    } else try out.writeAll("null");
    try out.print(",\"other_zig_build\":{s},\"sync_running\":{s},\"thermal\":", .{ optionalBool(ambient.other_zig_build), optionalBool(ambient.sync_running) });
    if (ambient.thermal) |text| {
        try out.writeAll("\"");
        try writeJsonString(out, text);
        try out.writeAll("\"");
    } else try out.writeAll("null");
    const qos_name = if (qos_ok) schedulingOrQos() else "unset";
    try out.print(",\"qos\":\"{s}\"}}", .{qos_name});
}

fn optionalBool(value: ?bool) []const u8 {
    return if (value) |bit| boolText(bit) else "null";
}

fn schedulingMode() []const u8 {
    const raw = getenv("BENCH_SCHEDULING") orelse return "default";
    return std.mem.span(raw);
}

fn schedulingOrQos() []const u8 {
    const raw = getenv("BENCH_QOS") orelse return "unset";
    return std.mem.span(raw);
}

fn applyRequestedQos() bool {
    const raw = getenv("BENCH_QOS") orelse return false;
    const mode = std.mem.span(raw);
    const class: c_uint = if (std.mem.eql(u8, mode, "utility")) 0x11 else if (std.mem.eql(u8, mode, "user_interactive")) qos_user_interactive else return false;
    return pthread_set_qos_class_self_np(class, 0) == 0;
}

fn slurp(allocator: std.mem.Allocator, command: [*:0]const u8) ![]u8 {
    const file = popen(command, "r") orelse return error.Spawn;
    defer _ = pclose(file);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var chunk: [1024]u8 = undefined;
    while (fgets(&chunk, @intCast(chunk.len), file)) |_| {
        const len = std.mem.len(@as([*:0]u8, @ptrCast(&chunk)));
        try out.appendSlice(allocator, chunk[0..len]);
        if (out.items.len > 512 * 1024) break;
    }
    return out.toOwnedSlice(allocator);
}

fn scanProcesses(text: []const u8) struct { zig_build: bool, syncing: bool } {
    const self = getpid();
    var zig_build = false;
    var syncing = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;
        const space = std.mem.indexOfAny(u8, trimmed, " \t") orelse continue;
        const pid = std.fmt.parseInt(c_int, trimmed[0..space], 10) catch continue;
        if (pid == self or pid == getppid()) continue;
        const cmd = trimmed[space..];
        if (std.mem.indexOf(u8, cmd, "crypto-bench") != null) continue;
        if (std.mem.indexOf(u8, cmd, "zig") != null and std.mem.indexOf(u8, cmd, " build") != null) zig_build = true;
        if (std.mem.indexOf(u8, cmd, "pybitnode") != null or
            std.mem.indexOf(u8, cmd, "tsbitnode") != null or
            std.mem.indexOf(u8, cmd, "sync_batch") != null or
            std.mem.indexOf(u8, cmd, "syncRunner") != null or
            (std.mem.indexOf(u8, cmd, "zigbitnode") != null and std.mem.indexOf(u8, cmd, " sync") != null))
            syncing = true;
    }
    return .{ .zig_build = zig_build, .syncing = syncing };
}

fn collapseThermal(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var pending_space = false;
    for (text) |byte| {
        if (byte == '\n' or byte == '\r' or byte == '\t') {
            pending_space = out.items.len != 0;
            continue;
        }
        if (pending_space) {
            try out.append(allocator, ' ');
            pending_space = false;
        }
        try out.append(allocator, byte);
        if (out.items.len == 240) break;
    }
    if (out.items.len == 0) {
        out.deinit(allocator);
        return error.Empty;
    }
    return out.toOwnedSlice(allocator);
}

fn writeJsonString(out: anytype, text: []const u8) !void {
    for (text) |byte| switch (byte) {
        '\\' => try out.writeAll("\\\\"),
        '"' => try out.writeAll("\\\""),
        else => try out.writeByte(byte),
    };
}

fn timeEcdsaOwn(inputs: *const Inputs) void {
    sink_b +%= @intFromBool(secp.verifyEcdsa(&inputs.ecdsa_key, &inputs.ecdsa_msg, &inputs.ecdsa_sig) catch false);
}
fn timeSchnorrOwn(inputs: *const Inputs) void {
    sink_b +%= @intFromBool(secp.verifySchnorr(&inputs.schnorr_key, &inputs.schnorr_msg, &inputs.schnorr_sig) catch false);
}
fn timeTweakOwn(inputs: *const Inputs) void {
    sink_b +%= @intFromBool(secp.checkXOnlyTweak(&inputs.tweak_key, &inputs.tweak, &inputs.tweak_out, inputs.tweak_parity) catch false);
}
fn timeParseOwn(inputs: *const Inputs) void {
    sink_b +%= @intFromBool(if (secp.parsePublicKey(&inputs.ecdsa_key)) |_| true else |_| false);
}
fn timeEcdsaC(inputs: *const Inputs, ctx: *c.secp256k1_context) void {
    var key: c.secp256k1_pubkey = undefined;
    var sig: c.secp256k1_ecdsa_signature = undefined;
    const parsed = c.secp256k1_ec_pubkey_parse(ctx, &key, &inputs.ecdsa_key, inputs.ecdsa_key.len) == 1 and
        c.secp256k1_ecdsa_signature_parse_der(ctx, &sig, &inputs.ecdsa_sig, inputs.ecdsa_sig.len) == 1;
    if (parsed) _ = c.secp256k1_ecdsa_signature_normalize(ctx, &sig, &sig);
    sink_b +%= @intFromBool(parsed and c.secp256k1_ecdsa_verify(ctx, &sig, &inputs.ecdsa_msg, &key) == 1);
}
fn timeSchnorrC(inputs: *const Inputs, ctx: *c.secp256k1_context) void {
    var key: c.secp256k1_xonly_pubkey = undefined;
    const parsed = c.secp256k1_xonly_pubkey_parse(ctx, &key, &inputs.schnorr_key) == 1;
    sink_b +%= @intFromBool(parsed and c.secp256k1_schnorrsig_verify(ctx, &inputs.schnorr_sig, &inputs.schnorr_msg, inputs.schnorr_msg.len, &key) == 1);
}
fn timeTweakC(inputs: *const Inputs, ctx: *c.secp256k1_context) void {
    var key: c.secp256k1_xonly_pubkey = undefined;
    const parsed = c.secp256k1_xonly_pubkey_parse(ctx, &key, &inputs.tweak_key) == 1;
    sink_b +%= @intFromBool(parsed and c.secp256k1_xonly_pubkey_tweak_add_check(ctx, &inputs.tweak_out, inputs.tweak_parity, &key, &inputs.tweak) == 1);
}
fn timeParseC(inputs: *const Inputs, ctx: *c.secp256k1_context) void {
    var key: c.secp256k1_pubkey = undefined;
    sink_b +%= @intFromBool(c.secp256k1_ec_pubkey_parse(ctx, &key, &inputs.ecdsa_key, inputs.ecdsa_key.len) == 1);
}

fn timeDouble() void {
    const q = secp.benchDoubleScalar(prepared.scalar_s, prepared.point, prepared.scalar_z);
    sink_u +%= q.x;
}
fn timeFixed() void {
    sink_u +%= secp.benchScalarMulFixed(prepared.scalar_s).x;
}
fn timeVar() void {
    sink_u +%= secp.benchScalarMulVar(prepared.point, prepared.scalar_s).x;
}
fn timeAdd() void {
    sink_u +%= secp.benchPointAdd(secp.benchBasePoint(), prepared.doubled).x;
}
fn timeDoublePoint() void {
    sink_u +%= secp.benchPointDouble(secp.benchBasePoint()).x;
}
fn timeAffine() void {
    sink_u +%= (secp.benchToAffine(prepared.doubled) catch unreachable).x;
}
fn timeFeMul() void {
    fe_running = secp.benchFeMul(fe_running, prepared.field_z);
    sink_u +%= fe_running;
}
fn timeFeSqr() void {
    fe_running = secp.benchFeSqr(fe_running);
    sink_u +%= fe_running;
}
fn timeFeInv() void {
    sink_u +%= secp.benchFeInv(secp.benchBasePoint().x) catch unreachable;
}
fn timeFeNorm() void {
    fe_running = secp.benchFeNormalize(fe_running);
    sink_u +%= fe_running;
}
fn timeScMul() void {
    fe_running = secp.benchScMul(fe_running, prepared.scalar_z);
    sink_u +%= fe_running;
}
fn timeScInv() void {
    sink_u +%= secp.benchScInv(prepared.scalar_s) catch unreachable;
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
