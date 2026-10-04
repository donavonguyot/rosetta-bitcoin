const std = @import("std");

const c = @cImport({
    @cInclude("time.h");
});

pub fn nowNs() u64 {
    var value: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &value) != 0) return 0;
    return @as(u64, @intCast(value.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(value.tv_nsec));
}

pub const Kind = enum { ecdsa, schnorr, taproot_tweak };

pub const KindStats = struct {
    count: u64 = 0,
    total_ns: u64 = 0,

    pub fn meanNs(self: KindStats) u64 {
        if (self.count == 0) return 0;
        return self.total_ns / self.count;
    }

    pub fn add(self: *KindStats, other: KindStats) void {
        self.count += other.count;
        self.total_ns += other.total_ns;
    }
};

pub const Split = struct {
    ecdsa: KindStats = .{},
    schnorr: KindStats = .{},
    taproot_tweak: KindStats = .{},

    pub fn add(self: *Split, other: Split) void {
        self.ecdsa.add(other.ecdsa);
        self.schnorr.add(other.schnorr);
        self.taproot_tweak.add(other.taproot_tweak);
    }

    pub fn since(self: Split, before: Split) Split {
        return .{
            .ecdsa = .{ .count = self.ecdsa.count - before.ecdsa.count, .total_ns = self.ecdsa.total_ns - before.ecdsa.total_ns },
            .schnorr = .{ .count = self.schnorr.count - before.schnorr.count, .total_ns = self.schnorr.total_ns - before.schnorr.total_ns },
            .taproot_tweak = .{ .count = self.taproot_tweak.count - before.taproot_tweak.count, .total_ns = self.taproot_tweak.total_ns - before.taproot_tweak.total_ns },
        };
    }
};

const Counters = struct {
    count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    fn add(self: *Counters, ns: u64) void {
        _ = self.count.fetchAdd(1, .monotonic);
        _ = self.total_ns.fetchAdd(ns, .monotonic);
    }

    fn load(self: *Counters) KindStats {
        return .{
            .count = self.count.load(.monotonic),
            .total_ns = self.total_ns.load(.monotonic),
        };
    }

    fn reset(self: *Counters) void {
        self.count.store(0, .monotonic);
        self.total_ns.store(0, .monotonic);
    }
};

var ecdsa_counters = Counters{};
var schnorr_counters = Counters{};
var tweak_counters = Counters{};

/// Set by a script worker so its signatures stay on that thread's split.
/// Unbound calls keep the process counters, which the direct verifier tests use.
threadlocal var bound_split: ?*Split = null;

pub fn bind(split: ?*Split) void {
    bound_split = split;
}

fn counters(kind: Kind) *Counters {
    return switch (kind) {
        .ecdsa => &ecdsa_counters,
        .schnorr => &schnorr_counters,
        .taproot_tweak => &tweak_counters,
    };
}

pub fn record(kind: Kind, started_ns: u64) void {
    const now = nowNs();
    const ns = if (now > started_ns) now - started_ns else 0;
    if (bound_split) |split| {
        const stats = switch (kind) {
            .ecdsa => &split.ecdsa,
            .schnorr => &split.schnorr,
            .taproot_tweak => &split.taproot_tweak,
        };
        stats.count += 1;
        stats.total_ns += ns;
        return;
    }
    counters(kind).add(ns);
}

pub fn snapshot() Split {
    return .{
        .ecdsa = ecdsa_counters.load(),
        .schnorr = schnorr_counters.load(),
        .taproot_tweak = tweak_counters.load(),
    };
}

pub fn reset() void {
    ecdsa_counters.reset();
    schnorr_counters.reset();
    tweak_counters.reset();
}

pub const Window = struct {
    height_start: u32,
    height_end: u32,
    script_verify_ms: i64,
    split: Split,
};

pub const Windows = struct {
    items: [16]Window = undefined,
    len: usize = 0,
    open_start: u32 = 0,
    open_split: Split = .{},
    open_script_ms: i64 = 0,
    open: bool = false,

    pub fn note(self: *Windows, height: u32, block: Split, script_ms: i64) ?Window {
        if (!self.open) {
            self.open = true;
            self.open_start = height;
        }
        self.open_split.add(block);
        self.open_script_ms += script_ms;
        if ((height + 1) % 10_000 != 0) return null;
        return self.close(height);
    }

    pub fn finish(self: *Windows, height: u32) ?Window {
        if (!self.open) return null;
        return self.close(height);
    }

    pub fn total(self: Windows) Split {
        var sum = Split{};
        for (self.items[0..self.len]) |window| sum.add(window.split);
        return sum;
    }

    fn close(self: *Windows, height: u32) Window {
        const window = Window{
            .height_start = self.open_start,
            .height_end = height,
            .script_verify_ms = self.open_script_ms,
            .split = self.open_split,
        };
        if (self.len < self.items.len) {
            self.items[self.len] = window;
            self.len += 1;
        }
        self.open = false;
        self.open_split = .{};
        self.open_script_ms = 0;
        return window;
    }
};

pub fn formatWindow(allocator: std.mem.Allocator, window: Window) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"schema":"port.script_verify_split.v1","height_start":{},"height_end":{},"script_verify_ms":{},"ecdsa":{{"count":{},"total_ns":{},"mean_ns":{}}},"schnorr":{{"count":{},"total_ns":{},"mean_ns":{}}},"taproot_tweak":{{"count":{},"total_ns":{},"mean_ns":{}}}}}
    , .{
        window.height_start,
        window.height_end,
        window.script_verify_ms,
        window.split.ecdsa.count,
        window.split.ecdsa.total_ns,
        window.split.ecdsa.meanNs(),
        window.split.schnorr.count,
        window.split.schnorr.total_ns,
        window.split.schnorr.meanNs(),
        window.split.taproot_tweak.count,
        window.split.taproot_tweak.total_ns,
        window.split.taproot_tweak.meanNs(),
    });
}

pub fn formatProof(allocator: std.mem.Allocator, windows: Windows) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    const totals = windows.total();
    try buf.append(allocator, '{');
    try appendSplitObject(allocator, &buf, totals);
    try buf.appendSlice(allocator, ",\"windows\":[");
    for (windows.items[0..windows.len], 0..) |window, index| {
        if (index != 0) try buf.append(allocator, ',');
        const item = try std.fmt.allocPrint(allocator, "{{\"height_start\":{},\"height_end\":{},\"script_verify_ms\":{},", .{ window.height_start, window.height_end, window.script_verify_ms });
        defer allocator.free(item);
        try buf.appendSlice(allocator, item);
        try appendSplitObject(allocator, &buf, window.split);
        try buf.append(allocator, '}');
    }
    try buf.appendSlice(allocator, "]}");
    return buf.toOwnedSlice(allocator);
}

fn appendSplitObject(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), split: Split) !void {
    try buf.appendSlice(allocator, "\"ecdsa\":");
    try appendKind(allocator, buf, split.ecdsa);
    try buf.appendSlice(allocator, ",\"schnorr\":");
    try appendKind(allocator, buf, split.schnorr);
    try buf.appendSlice(allocator, ",\"taproot_tweak\":");
    try appendKind(allocator, buf, split.taproot_tweak);
}

fn appendKind(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), stats: KindStats) !void {
    const text = try std.fmt.allocPrint(allocator, "{{\"count\":{},\"total_ns\":{},\"mean_ns\":{}}}", .{ stats.count, stats.total_ns, stats.meanNs() });
    defer allocator.free(text);
    try buf.appendSlice(allocator, text);
}

fn recordMany() void {
    var i: usize = 0;
    while (i < 100) : (i += 1) record(.ecdsa, nowNs());
}

test "kind mean is total divided by count" {
    const stats = KindStats{ .count = 4, .total_ns = 40 };
    try std.testing.expectEqual(@as(u64, 10), stats.meanNs());
    try std.testing.expectEqual(@as(u64, 0), (KindStats{}).meanNs());
}

test "script verify split adds across threads" {
    reset();
    const threads = try std.testing.allocator.alloc(std.Thread, 4);
    defer std.testing.allocator.free(threads);
    for (threads) |*thread| thread.* = try std.Thread.spawn(.{}, recordMany, .{});
    for (threads) |thread| thread.join();
    const got = snapshot();
    try std.testing.expectEqual(@as(u64, 400), got.ecdsa.count);
    try std.testing.expectEqual(@as(u64, 0), got.schnorr.count);
    try std.testing.expectEqual(@as(u64, 0), got.taproot_tweak.count);
}

test "script verify windows close every 10000 blocks" {
    var windows = Windows{};
    var height: u32 = 0;
    while (height < 10000) : (height += 1) {
        const closed = windows.note(height, .{ .ecdsa = .{ .count = 1, .total_ns = 10 } }, 2);
        if (height < 9999) {
            try std.testing.expect(closed == null);
        } else {
            const window = closed.?;
            try std.testing.expectEqual(@as(u32, 0), window.height_start);
            try std.testing.expectEqual(@as(u32, 9999), window.height_end);
            try std.testing.expectEqual(@as(i64, 20000), window.script_verify_ms);
            try std.testing.expectEqual(@as(u64, 10000), window.split.ecdsa.count);
            try std.testing.expectEqual(@as(u64, 10), window.split.ecdsa.meanNs());
        }
    }
    try std.testing.expect(windows.note(10000, .{ .schnorr = .{ .count = 4, .total_ns = 40 } }, 5) == null);
    const tail = windows.finish(10000).?;
    try std.testing.expectEqual(@as(u32, 10000), tail.height_start);
    try std.testing.expectEqual(@as(u32, 10000), tail.height_end);
    try std.testing.expectEqual(@as(i64, 5), tail.script_verify_ms);
    try std.testing.expectEqual(@as(u64, 4), tail.split.schnorr.count);
    try std.testing.expectEqual(@as(u64, 10), tail.split.schnorr.meanNs());
    try std.testing.expect(windows.finish(10000) == null);
    const line = try formatWindow(std.testing.allocator, tail);
    defer std.testing.allocator.free(line);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"schema\":\"port.script_verify_split.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"script_verify_ms\":5") != null);
}
