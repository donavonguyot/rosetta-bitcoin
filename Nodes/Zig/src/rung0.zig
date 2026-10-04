const std = @import("std");
const root = @import("root.zig");
const mempool = @import("mempool.zig");
const template = @import("template.zig");

const tx = root.tx;
const block = root.block;
const crypto = root.crypto;

pub const TraceInfo = struct {
    fixture: []const u8,
    start_height: u32,
    start_hash: []const u8,
    trace_dir: []const u8,

    pub fn deinit(self: TraceInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.fixture);
        allocator.free(self.start_hash);
        allocator.free(self.trace_dir);
    }
};

pub fn loadTraceInfo(allocator: std.mem.Allocator, io: std.Io, trace_dir: []const u8) !TraceInfo {
    const path = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{trace_dir});
    defer allocator.free(path);
    const bytes = try readFile(allocator, io, path);
    defer allocator.free(bytes);
    const fixture = try allocator.dupe(u8, jsonString(bytes, "fixture") orelse return error.MissingFixture);
    errdefer allocator.free(fixture);
    const start_hash = try allocator.dupe(u8, jsonString(bytes, "start_hash") orelse return error.MissingStartHash);
    errdefer allocator.free(start_hash);
    const start_height: u32 = @intCast(jsonInt(bytes, "start_height") orelse return error.MissingStartHeight);
    return .{
        .fixture = fixture,
        .start_height = start_height,
        .start_hash = start_hash,
        .trace_dir = try allocator.dupe(u8, trace_dir),
    };
}

pub const Boundary = struct {
    height: u32,
    set_hash: [64]u8,
    pool_count: usize,
    core_set_hash: []u8,
    port_fees: u64,
    core_fees: ?u64,
    ratio_micros: ?u64,
};

pub const Report = struct {
    boundaries: []Boundary,
    tx_checked: u32,
    verdict_mismatches: u32,
    mutation_checked: u32,
    mutation_mismatches: u32,
    template_checked: u32 = 0,
    template_failures: u32 = 0,
    stores_agree: bool = true,

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        for (self.boundaries) |row| allocator.free(row.core_set_hash);
        allocator.free(self.boundaries);
    }
};

pub fn replay(allocator: std.mem.Allocator, io: std.Io, db: anytype, trace_dir: []const u8, out: anytype) !Report {
    const Store = @TypeOf(db.*);
    const events_path = try join(allocator, trace_dir, "events.bin");
    defer allocator.free(events_path);
    const annotations_path = try join(allocator, trace_dir, "annotations.jsonl");
    defer allocator.free(annotations_path);
    const boundaries_path = try join(allocator, trace_dir, "boundaries.jsonl");
    defer allocator.free(boundaries_path);
    const mutations_path = try join(allocator, trace_dir, "mutations.json");
    defer allocator.free(mutations_path);
    const events = try readFile(allocator, io, events_path);
    defer allocator.free(events);
    const annotations = try readFile(allocator, io, annotations_path);
    defer allocator.free(annotations);
    const boundaries_text = try readFile(allocator, io, boundaries_path);
    defer allocator.free(boundaries_text);
    const mutations_text = try readFile(allocator, io, mutations_path);
    defer allocator.free(mutations_text);

    var expected = std.AutoHashMap(u32, []const u8).init(allocator);
    defer expected.deinit();
    var line_it = std.mem.splitScalar(u8, annotations, '\n');
    while (line_it.next()) |line| {
        if (jsonString(line, "expected_layer1") == null) continue;
        const seq: u32 = @intCast(jsonInt(line, "apply_seq") orelse continue);
        try expected.put(seq, jsonString(line, "expected_layer1").?);
    }
    var core_hash = std.AutoHashMap(u32, []const u8).init(allocator);
    defer core_hash.deinit();
    var core_fees = std.AutoHashMap(u32, u64).init(allocator);
    defer core_fees.deinit();
    var boundary_it = std.mem.splitScalar(u8, boundaries_text, '\n');
    while (boundary_it.next()) |line| {
        const seq_opt = jsonInt(line, "apply_seq");
        if (seq_opt == null) continue;
        const seq: u32 = @intCast(seq_opt.?);
        if (jsonString(line, "core_set_hash")) |hash| try core_hash.put(seq, hash);
        if (jsonInt(line, "fees_sat")) |fees| try core_fees.put(seq, fees);
    }

    const Mutation = struct { seq: u32, reason: []const u8, raw_hex: []const u8 };
    var mutations: std.ArrayList(Mutation) = .empty;
    defer mutations.deinit(allocator);
    var rest = mutations_text;
    while (std.mem.indexOf(u8, rest, "\"class\"")) |at| {
        const slice = rest[at..];
        const next = std.mem.indexOfPos(u8, slice, 1, "\"class\"") orelse slice.len;
        const obj = slice[0..next];
        if (jsonInt(obj, "source_apply_seq")) |seq| {
            if (jsonString(obj, "expected_reason")) |reason| {
                if (jsonString(obj, "raw_hex")) |raw_hex| {
                    try mutations.append(allocator, .{ .seq = @intCast(seq), .reason = reason, .raw_hex = raw_hex });
                }
            }
        }
        rest = slice[next..];
    }

    const meta = try db.readMetadata(allocator);
    defer db.deinitMetadata(allocator, meta);
    var height: u32 = if (meta.validated_height < 0) 0 else @intCast(meta.validated_height + 1);
    var tip_hash: ?[32]u8 = if (meta.validated_hash.len == 64) try crypto.internalHashFromDisplay(allocator, meta.validated_hash) else null;
    var utxo_count = meta.chainstate_utxo_count;
    const initial_mtp: u32 = if (meta.validated_height < 0) 0 else blk: {
        var probe = mempool.Pool(Store).init(allocator, db, height, 0);
        defer probe.deinit();
        break :blk try probe.coins.medianTimePast(@intCast(meta.validated_height));
    };
    var pool = mempool.Pool(Store).init(allocator, db, height, initial_mtp);
    defer pool.deinit();

    var tx_checked: u32 = 0;
    var verdict_mismatches: u32 = 0;
    var mutation_checked: u32 = 0;
    var mutation_mismatches: u32 = 0;
    var template_checked: u32 = 0;
    var template_failures: u32 = 0;
    var accepted: u32 = 0;
    var rejected: u32 = 0;
    var rows: std.ArrayList(Boundary) = .empty;
    errdefer rows.deinit(allocator);

    var offset: usize = 0;
    while (offset + 17 <= events.len) {
        const apply_seq = std.mem.readInt(u32, events[offset..][0..4], .little);
        const kind = events[offset + 12];
        const len = std.mem.readInt(u32, events[offset + 13 ..][0..4], .little);
        offset += 17;
        if (offset + len > events.len) return error.TruncatedEvent;
        const payload = events[offset .. offset + len];
        offset += len;

        if (kind == 1) {
            for (mutations.items) |mutation| {
                if (mutation.seq != apply_seq) continue;
                const raw = try crypto.fromHexAlloc(allocator, mutation.raw_hex);
                defer allocator.free(raw);
                const verdict = try pool.check(raw);
                mutation_checked += 1;
                if (!std.mem.eql(u8, verdict.reason.name(), mutation.reason)) {
                    mutation_mismatches += 1;
                    try out.print("mutation mismatch seq={d} have={s} want={s}\n", .{ apply_seq, verdict.reason.name(), mutation.reason });
                }
            }
            const verdict = try pool.apply(payload);
            tx_checked += 1;
            if (verdict.reason == .accepted) accepted += 1 else rejected += 1;
            if (expected.get(apply_seq)) |want| {
                if (!std.mem.eql(u8, verdict.reason.name(), want)) {
                    verdict_mismatches += 1;
                    try out.print("verdict mismatch apply_seq={d} have={s} want={s}\n", .{ apply_seq, verdict.reason.name(), want });
                }
            } else {
                verdict_mismatches += 1;
                try out.print("verdict mismatch apply_seq={d} have={s} want=missing\n", .{ apply_seq, verdict.reason.name() });
            }
        } else if (kind == 2) {
            const cb = try template.coinbaseWeight(allocator, height);
            const selected = try template.selectPackages(Store, allocator, &pool, cb.weight, cb.sigops);
            defer allocator.free(selected);
            var port_fees: u64 = 0;
            var filled: usize = 0;
            const txs = try allocator.alloc(tx.Transaction, selected.len);
            defer {
                for (txs[0..filled]) |transaction| transaction.deinit(allocator);
                allocator.free(txs);
            }
            for (selected) |wtxid| {
                const entry = pool.get(wtxid) orelse return error.MissingPoolEntry;
                port_fees += entry.fee;
                const parsed = try tx.deserialize(allocator, entry.raw, 0);
                txs[filled] = parsed.transaction;
                filled += 1;
            }
            if (tip_hash) |prev| {
                const prev_header = (try db.headerAt(allocator, height - 1)) orelse return error.MissingHeader;
                const prev_time = std.mem.readInt(u32, prev_header[68..72], .little);
                const now_i = @divTrunc(root.nowMs(), 1000);
                const now: u32 = if (now_i <= 0) 0 else if (now_i > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(now_i);
                const stamp = template.headerTimeFor(pool.tip_mtp, now, height, prev_time);
                const bits = try template.nextBits(db, allocator, height, stamp);
                const raw_template = try template.assemble(allocator, .{
                    .height = height,
                    .prev_hash = prev,
                    .time = stamp,
                    .bits = bits,
                    .fees = port_fees,
                    .transactions = txs[0..filled],
                });
                defer allocator.free(raw_template);
                template_checked += 1;
                if (template.testBlockValidity(allocator, db, raw_template, height, utxo_count)) {
                    try out.print("template height={d} valid=pass fees={d} bytes={d}\n", .{ height, port_fees, raw_template.len });
                } else |err| {
                    template_failures += 1;
                    try out.print("template height={d} valid=fail fees={d} err={s}\n", .{ height, port_fees, @errorName(err) });
                }
            }

            const expected_prev: ?[32]u8 = if (height == 0) null else tip_hash;
            const decoded = try block.decodeBlock(allocator, payload, null, expected_prev);
            defer {
                for (decoded.transactions) |transaction| transaction.deinit(allocator);
                allocator.free(decoded.transactions);
            }
            try db.recordBlock(allocator, height, decoded.info.hash, payload);
            var connected = try root.connectDecodedBlock(allocator, db, height, height, decoded.info, decoded.transactions, null, utxo_count);
            defer connected.deinit(allocator);
            var ids = try allocator.alloc([32]u8, decoded.transactions.len);
            defer allocator.free(ids);
            for (decoded.transactions, 0..) |transaction, i| ids[i] = transaction.txid();
            try pool.onBlockConnected(decoded.transactions, ids);
            utxo_count = connected.chainstate_utxo_count;
            tip_hash = decoded.info.hash;
            pool.tip_mtp = try pool.coins.medianTimePast(height);
            pool.next_height = height + 1;

            const fees = core_fees.get(apply_seq);
            const ratio: ?u64 = if (fees) |core| if (core == 0) null else port_fees * 1_000_000 / core else null;
            const hash_text = core_hash.get(apply_seq) orelse "";
            try rows.append(allocator, .{
                .height = height,
                .set_hash = pool.setHashHex(),
                .pool_count = pool.count(),
                .core_set_hash = try allocator.dupe(u8, hash_text),
                .port_fees = port_fees,
                .core_fees = fees,
                .ratio_micros = ratio,
            });
            try out.print(
                "boundary height={d} set_hash={s} pool={d} accepted={d} rejected={d} core_set_hash={s}\n",
                .{ height, pool.setHashHex(), pool.count(), accepted, rejected, hash_text },
            );
            height += 1;
        } else return error.UnknownEventKind;
    }

    const verdict_pass = verdict_mismatches == 0;
    const mutation_pass = mutation_mismatches == 0;
    try out.print(
        "gate mempool.trace_replay_set_hash=recorded mempool.layer1_verdicts={s} mempool.mutation_rejects={s} mempool.block_connect_eviction={s} tx={d} mutations={d}\n",
        .{
            if (verdict_pass) "pass" else "fail",
            if (mutation_pass) "pass" else "fail",
            if (verdict_pass) "pass" else "fail",
            tx_checked,
            mutation_checked,
        },
    );
    return .{
        .boundaries = try rows.toOwnedSlice(allocator),
        .tx_checked = tx_checked,
        .verdict_mismatches = verdict_mismatches,
        .mutation_checked = mutation_checked,
        .mutation_mismatches = mutation_mismatches,
        .template_checked = template_checked,
        .template_failures = template_failures,
    };
}

pub fn medianRatio(rows: []const Boundary) ?u64 {
    var values: [4096]u64 = undefined;
    var n: usize = 0;
    for (rows) |row| {
        if (row.ratio_micros) |value| {
            if (n == values.len) break;
            values[n] = value;
            n += 1;
        }
    }
    if (n == 0) return null;
    std.mem.sort(u64, values[0..n], {}, std.sort.asc(u64));
    return values[n / 2];
}

fn join(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(512 * 1024 * 1024));
}

fn jsonString(text: []const u8, key: []const u8) ?[]const u8 {
    const start = keyAt(text, key) orelse return null;
    var i = start;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\n' or text[i] == ':')) : (i += 1) {}
    if (i >= text.len or text[i] != '"') return null;
    i += 1;
    const value_start = i;
    while (i < text.len and text[i] != '"') : (i += 1) {}
    if (i >= text.len) return null;
    return text[value_start..i];
}

fn jsonInt(text: []const u8, key: []const u8) ?u64 {
    const start = keyAt(text, key) orelse return null;
    var i = start;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\n' or text[i] == ':')) : (i += 1) {}
    if (i >= text.len) return null;
    var value: u64 = 0;
    var digits: usize = 0;
    while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) {
        value = value * 10 + (text[i] - '0');
        digits += 1;
    }
    if (digits == 0) return null;
    return value;
}

fn keyAt(text: []const u8, key: []const u8) ?usize {
    var i: usize = 0;
    while (i + key.len + 2 <= text.len) : (i += 1) {
        if (text[i] == '"' and std.mem.startsWith(u8, text[i + 1 ..], key) and i + 1 + key.len < text.len and text[i + 1 + key.len] == '"') {
            return i + key.len + 2;
        }
    }
    return null;
}
