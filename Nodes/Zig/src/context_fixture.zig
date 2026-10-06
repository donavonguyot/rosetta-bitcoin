//! Must-reject block fixtures for finality and BIP68, loaded into a memory store.

const std = @import("std");
const root = @import("root.zig");
const consensus_context = @import("consensus_context.zig");
const chain_params = @import("chain_params.zig");
const tx = root.tx;
const template = @import("template.zig");
const coins_view = @import("coins_view.zig");

const Mutation = enum {
    finality_height,
    finality_mtp,
    bip68_height,
    bip68_time,
    bip68_same_block,

    fn reason(self: Mutation) []const u8 {
        return switch (self) {
            .finality_height, .finality_mtp => "tx_not_final",
            .bip68_height, .bip68_time, .bip68_same_block => "sequence_lock_unsatisfied",
        };
    }

    fn name(self: Mutation) []const u8 {
        return switch (self) {
            .finality_height => "consensus.tx_finality_height",
            .finality_mtp => "consensus.tx_finality_mtp",
            .bip68_height => "consensus.bip68_height",
            .bip68_time => "consensus.bip68_time",
            .bip68_same_block => "consensus.bip68_same_block",
        };
    }
};

const BlockJob = struct {
    mutation: Mutation,
    height: u32,
};

const jobs = [_]BlockJob{
    .{ .mutation = .finality_height, .height = 38010 },
    .{ .mutation = .finality_mtp, .height = 38010 },
    .{ .mutation = .bip68_height, .height = 38010 },
    .{ .mutation = .bip68_time, .height = 32712 },
    .{ .mutation = .bip68_same_block, .height = 32712 },
};

pub fn rejectReasonName(err: anyerror) []const u8 {
    return switch (err) {
        error.TxNotFinal => "tx_not_final",
        error.SequenceLockUnsatisfied => "sequence_lock_unsatisfied",
        error.NbitsMismatch => "nbits_mismatch",
        error.Timewarp => "timewarp",
        else => @errorName(err),
    };
}

pub fn runManifest(allocator: std.mem.Allocator, io: std.Io, manifest_path: []const u8, out: anytype) !bool {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(8 * 1024 * 1024));
    defer allocator.free(text);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    const fixtures = parsed.value.object.get("fixtures").?.array;
    var passed: usize = 0;
    var failed: usize = 0;
    for (fixtures.items) |item| {
        const obj = item.object;
        const id = obj.get("id").?.string;
        const kind = obj.get("kind").?.string;
        if (std.mem.eql(u8, kind, "header")) {
            const reason = obj.get("reject_reason").?.string;
            const accept_text = try headerVerdict(allocator, obj.get("accept").?.object);
            const reject_text = try headerVerdict(allocator, obj.get("reject").?.object);
            const accept_ok = std.mem.eql(u8, accept_text, "pass");
            const reject_ok = std.mem.eql(u8, reject_text, reason);
            if (accept_ok and reject_ok) passed += 1 else failed += 1;
            try out.print("{{\"fixture_id\":\"{s}\",\"accept\":\"{s}\",\"reject\":\"{s}\",\"expect\":\"{s}\"}}\n", .{ id, accept_text, reject_text, reason });
            continue;
        }
        if (!std.mem.eql(u8, kind, "block")) continue;
        const height: u32 = @intCast(obj.get("height").?.integer);
        const reason = obj.get("reject_reason").?.string;
        const accept = try readRelative(allocator, io, manifest_path, obj.get("accept").?.string);
        defer allocator.free(accept);
        const reject = try readRelative(allocator, io, manifest_path, obj.get("reject").?.string);
        defer allocator.free(reject);
        const undo = try readRelative(allocator, io, manifest_path, obj.get("undo").?.string);
        defer allocator.free(undo);
        const headers = try readRelative(allocator, io, manifest_path, obj.get("headers").?.string);
        defer allocator.free(headers);
        const header_base: u32 = @intCast(obj.get("header_base").?.integer);
        const accept_err = runBlock(allocator, undo, headers, header_base, accept, height);
        const reject_err = runBlock(allocator, undo, headers, header_base, reject, height);
        const accept_text = if (accept_err) |_| "pass" else |err| rejectReasonName(err);
        const reject_text = if (reject_err) |_| "accepted" else |err| rejectReasonName(err);
        const accept_ok = std.mem.eql(u8, accept_text, "pass");
        const reject_ok = std.mem.eql(u8, reject_text, reason);
        if (accept_ok and reject_ok) passed += 1 else failed += 1;
        try out.print("{{\"fixture_id\":\"{s}\",\"accept\":\"{s}\",\"reject\":\"{s}\",\"expect\":\"{s}\"}}\n", .{ id, accept_text, reject_text, reason });
    }
    const ok = failed == 0 and passed > 0;
    try out.print("{{\"schema\":\"port.consensus_context.v1\",\"command\":\"consensus-context\",\"passed\":{s},\"passed_count\":{d},\"failed_count\":{d}}}\n", .{ if (ok) "true" else "false", passed, failed });
    return ok;
}

fn runBlock(allocator: std.mem.Allocator, undo: []const u8, headers: []const u8, header_base: u32, raw: []const u8, height: u32) !void {
    var store = try storeFromParts(allocator, undo, headers, header_base);
    defer store.deinit();
    try template.testBlockValidity(allocator, &store, raw, height, 0);
}

fn storeFromParts(allocator: std.mem.Allocator, undo: []const u8, headers: []const u8, header_base: u32) !coins_view.MemoryStore {
    var store = coins_view.MemoryStore.init(allocator);
    errdefer store.deinit();
    const entries = try decodeUndo(allocator, undo);
    defer {
        for (entries) |entry| allocator.free(entry.utxo.script_pubkey);
        allocator.free(entries);
    }
    for (entries) |entry| try store.putUtxo(entry.outpoint, entry.utxo);
    if (headers.len % 80 != 0) return error.ShortHeader;
    var index: usize = 0;
    while (index < headers.len) : (index += 80) {
        var header: [80]u8 = undefined;
        @memcpy(header[0..], headers[index .. index + 80]);
        try store.putHeader(header_base + @as(u32, @intCast(index / 80)), header);
    }
    return store;
}

pub fn writeBlockFixtures(allocator: std.mem.Allocator, io: std.Io, db: anytype, out_dir: []const u8) !void {
    var manifest: std.ArrayList(u8) = .empty;
    defer manifest.deinit(allocator);
    try manifest.appendSlice(allocator, "{\n  \"family\": \"consensus.context\",\n  \"fixtures\": [\n");
    for (jobs, 0..) |job, index| {
        const raw_key = try root.codec.encodeRawBlockKey(allocator, "testnet4", job.height);
        defer allocator.free(raw_key);
        const raw = (try db.getAlloc(allocator, raw_key)) orelse return error.MissingBlock;
        defer allocator.free(raw);
        const undo_key = try root.codec.encodeUndoKey(allocator, "testnet4", job.height);
        defer allocator.free(undo_key);
        const undo = (try db.getAlloc(allocator, undo_key)) orelse return error.MissingUndo;
        defer allocator.free(undo);
        const header_base: u32 = job.height - 11;
        var headers: std.ArrayList(u8) = .empty;
        defer headers.deinit(allocator);
        var cursor = header_base;
        while (cursor < job.height) : (cursor += 1) {
            const header = (try db.headerAt(allocator, cursor)) orelse return error.MissingHeader;
            try headers.appendSlice(allocator, header[0..]);
        }
        runBlock(allocator, undo, headers.items, header_base, raw, job.height) catch |err| {
            std.debug.print("accept {s} failed: {s}\n", .{ job.mutation.name(), rejectReasonName(err) });
            return err;
        };
        const transactions = try tx.parseBlockTransactions(allocator, raw);
        defer {
            for (transactions) |transaction| transaction.deinit(allocator);
            allocator.free(transactions);
        }
        try applyMutation(allocator, transactions, job.height, job.mutation);
        const mutated = try serializeBlock(allocator, raw[0..80], transactions);
        defer allocator.free(mutated);
        if (runBlock(allocator, undo, headers.items, header_base, mutated, job.height)) |_| {
            return error.RejectWasAccepted;
        } else |err| {
            if (!std.mem.eql(u8, rejectReasonName(err), job.mutation.reason())) {
                std.debug.print("reject {s} got {s}\n", .{ job.mutation.name(), rejectReasonName(err) });
                return err;
            }
        }

        const dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ out_dir, job.mutation.name() });
        defer allocator.free(dir);
        const accept_path = try std.fmt.allocPrint(allocator, "{s}/accept.bin", .{dir});
        defer allocator.free(accept_path);
        const reject_path = try std.fmt.allocPrint(allocator, "{s}/reject.bin", .{dir});
        defer allocator.free(reject_path);
        const undo_path = try std.fmt.allocPrint(allocator, "{s}/undo.bin", .{dir});
        defer allocator.free(undo_path);
        const headers_path = try std.fmt.allocPrint(allocator, "{s}/headers.bin", .{dir});
        defer allocator.free(headers_path);
        try writeFile(io, accept_path, raw);
        try writeFile(io, reject_path, mutated);
        try writeFile(io, undo_path, undo);
        try writeFile(io, headers_path, headers.items);
        if (index != 0) try manifest.appendSlice(allocator, ",\n");
        const row = try std.fmt.allocPrint(allocator,
            \\    {{"id":"{s}","kind":"block","height":{d},"accept":"{s}/accept.bin","reject":"{s}/reject.bin","undo":"{s}/undo.bin","headers":"{s}/headers.bin","header_base":{d},"reject_reason":"{s}"}}
        , .{ job.mutation.name(), job.height, job.mutation.name(), job.mutation.name(), job.mutation.name(), job.mutation.name(), header_base, job.mutation.reason() });
        defer allocator.free(row);
        try manifest.appendSlice(allocator, row);
    }
    try appendHeaderFixtures(allocator, &manifest);
    try manifest.appendSlice(allocator, "\n  ]\n}\n");
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{out_dir});
    defer allocator.free(manifest_path);
    try writeFile(io, manifest_path, manifest.items);
}

fn applyMutation(allocator: std.mem.Allocator, transactions: []tx.Transaction, height: u32, mutation: Mutation) !void {
    switch (mutation) {
        .finality_height => {
            transactions[1].lock_time = height;
            transactions[1].inputs[0].sequence = 0xfffffffe;
            try refreshRaw(allocator, &transactions[1]);
        },
        .finality_mtp => {
            transactions[1].lock_time = 0xffffffff;
            transactions[1].inputs[0].sequence = 0xfffffffe;
            try refreshRaw(allocator, &transactions[1]);
        },
        .bip68_height => {
            transactions[1].version = 2;
            transactions[1].inputs[0].sequence = 0x0000ffff;
            try refreshRaw(allocator, &transactions[1]);
        },
        .bip68_time, .bip68_same_block => {
            const loc = try findSameBlockSpend(transactions);
            transactions[loc.tx].version = 2;
            transactions[loc.tx].inputs[loc.input].sequence = if (mutation == .bip68_time) 0x00400001 else 1;
            try refreshRaw(allocator, &transactions[loc.tx]);
        },
    }
    const commitment = try witnessCommitment(allocator, transactions);
    try patchWitnessCommitment(allocator, &transactions[0], commitment);
    try refreshRaw(allocator, &transactions[0]);
}

const SpendLoc = struct { tx: usize, input: usize };

fn findSameBlockSpend(transactions: []const tx.Transaction) !SpendLoc {
    var txids = try std.heap.page_allocator.alloc([32]u8, transactions.len);
    defer std.heap.page_allocator.free(txids);
    for (transactions, 0..) |transaction, index| txids[index] = transaction.txid();
    for (transactions[1..], 1..) |transaction, tx_index| {
        for (transaction.inputs, 0..) |input, input_index| {
            for (txids[1..tx_index], 1..) |txid, parent| {
                if (std.mem.eql(u8, &input.previous_output.hash, &txid)) {
                    _ = parent;
                    return .{ .tx = tx_index, .input = input_index };
                }
            }
        }
    }
    return error.NoSameBlockSpend;
}

fn refreshRaw(allocator: std.mem.Allocator, transaction: *tx.Transaction) !void {
    const next = try tx.serializeNoWitness(allocator, transaction.*);
    allocator.free(transaction.raw_no_witness);
    transaction.raw_no_witness = next;
}

fn witnessCommitment(allocator: std.mem.Allocator, transactions: []const tx.Transaction) ![32]u8 {
    const coinbase = transactions[0];
    if (coinbase.witness.len == 0 or coinbase.witness[0].len == 0 or coinbase.witness[0][0].len != 32) return error.InvalidCoinbaseWitnessReservedValue;
    const reserved = coinbase.witness[0][0];
    var wtxids = try allocator.alloc([32]u8, transactions.len);
    defer allocator.free(wtxids);
    wtxids[0] = [_]u8{0} ** 32;
    for (transactions[1..], 1..) |transaction, index| wtxids[index] = try transaction.wtxid(allocator);
    const witness_root = try root.block.merkleRoot(allocator, wtxids);
    var payload: [64]u8 = undefined;
    @memcpy(payload[0..32], witness_root[0..]);
    @memcpy(payload[32..64], reserved);
    return root.crypto.doubleSha256(payload[0..]);
}

fn patchWitnessCommitment(allocator: std.mem.Allocator, coinbase: *tx.Transaction, commitment: [32]u8) !void {
    for (coinbase.outputs) |*output| {
        const script = output.script_pubkey;
        if (script.len >= 38 and script[0] == 0x6a and script[1] == 0x24 and script[2] == 0xaa and script[3] == 0x21 and script[4] == 0xa9 and script[5] == 0xed) {
            const next = try allocator.dupe(u8, script);
            @memcpy(next[6..38], &commitment);
            allocator.free(script);
            output.script_pubkey = next;
            return;
        }
    }
    return error.MissingWitnessCommitment;
}

fn serializeBlock(allocator: std.mem.Allocator, header: []const u8, transactions: []const tx.Transaction) ![]u8 {
    var txids = try allocator.alloc([32]u8, transactions.len);
    defer allocator.free(txids);
    for (transactions, 0..) |transaction, index| txids[index] = transaction.txid();
    const merkle = try root.block.merkleRoot(allocator, txids);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, header);
    @memcpy(out.items[36..68], &merkle);
    try tx.writeCompactSize(allocator, &out, transactions.len);
    for (transactions) |transaction| {
        const encoded = try tx.serialize(allocator, transaction, transaction.witness.len != 0);
        defer allocator.free(encoded);
        try out.appendSlice(allocator, encoded);
    }
    return out.toOwnedSlice(allocator);
}

const SliceHeaders = struct {
    items: []const consensus_context.HeaderFields,
    pub fn header(self: @This(), height: u32) !consensus_context.HeaderFields {
        if (height >= self.items.len) return error.MissingHeader;
        return self.items[height];
    }
};

fn headerVerdict(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ![]const u8 {
    const height: u32 = @intCast(obj.get("height").?.integer);
    const time: u32 = @intCast(obj.get("time").?.integer);
    const bits: u32 = @intCast(obj.get("bits").?.integer);
    const encoded = obj.get("ancestors").?.array;
    const ancestors = try allocator.alloc(consensus_context.HeaderFields, encoded.items.len);
    defer allocator.free(ancestors);
    for (encoded.items, 0..) |item, index| {
        ancestors[index] = .{
            .time = @intCast(item.object.get("time").?.integer),
            .bits = @intCast(item.object.get("bits").?.integer),
        };
    }
    const required = try consensus_context.requiredBits(SliceHeaders{ .items = ancestors }, height, time);
    if (bits != required) return "nbits_mismatch";
    if (height > 0 and consensus_context.timewarpViolation(height, time, ancestors[height - 1].time)) return "timewarp";
    return "pass";
}

pub const HeaderCheck = struct {
    heights: u32 = 0,
    retarget_boundaries: u32 = 0,
    min_difficulty_blocks: u32 = 0,
    timewarp_checks: u32 = 0,
};

pub fn checkStoredHeaders(allocator: std.mem.Allocator, db: anytype, tip: u32) !HeaderCheck {
    _ = allocator;
    try db.ensureHeaderIndex();
    const index = db.headerIndex();
    if (index.items.items.len < @as(usize, tip) + 1) return error.MissingHeader;
    var counts = HeaderCheck{};
    var height: u32 = 0;
    while (height <= tip) : (height += 1) {
        const view = index.items.items[height];
        const required = try consensus_context.requiredBits(index, height, view.time);
        if (view.bits != required) {
            std.debug.print("nbits mismatch height={d} have={x} required={x}\n", .{ height, view.bits, required });
            return error.NbitsMismatch;
        }
        if (height > 0 and consensus_context.timewarpViolation(height, view.time, index.items.items[height - 1].time)) {
            std.debug.print("timewarp height={d} time={d} prev={d}\n", .{ height, view.time, index.items.items[height - 1].time });
            return error.Timewarp;
        }
        if (height > 0 and height % chain_params.interval == 0) {
            counts.retarget_boundaries += 1;
            counts.timewarp_checks += 1;
        }
        if (height % chain_params.interval != 0 and view.bits == chain_params.pow_limit_bits) counts.min_difficulty_blocks += 1;
        counts.heights += 1;
    }
    return counts;
}

fn appendHeaderFixtures(allocator: std.mem.Allocator, manifest: *std.ArrayList(u8)) !void {
    try appendMinDifficulty(allocator, manifest);
    try appendRetarget(allocator, manifest, "consensus.nbits_retarget_wrong", "nbits_mismatch", false);
    try appendRetarget(allocator, manifest, "consensus.bip94_first_block_bits", "nbits_mismatch", true);
    try appendTimewarp(allocator, manifest);
}

fn appendAncestor(allocator: std.mem.Allocator, out: *std.ArrayList(u8), header: consensus_context.HeaderFields, first: bool) !void {
    if (!first) try out.append(allocator, ',');
    const row = try std.fmt.allocPrint(allocator, "{{\"time\":{d},\"bits\":{d}}}", .{ header.time, header.bits });
    defer allocator.free(row);
    try out.appendSlice(allocator, row);
}

fn appendHeaderCase(
    allocator: std.mem.Allocator,
    manifest: *std.ArrayList(u8),
    id: []const u8,
    reason: []const u8,
    ancestors: []const consensus_context.HeaderFields,
    accept_time: u32,
    accept_bits: u32,
    reject_time: u32,
    reject_bits: u32,
) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    const head = try std.fmt.allocPrint(allocator, ",\n    {{\"id\":\"{s}\",\"kind\":\"header\",\"reject_reason\":\"{s}\",\"accept\":{{\"height\":{d},\"time\":{d},\"bits\":{d},\"ancestors\":[", .{ id, reason, ancestors.len, accept_time, accept_bits });
    defer allocator.free(head);
    try body.appendSlice(allocator, head);
    for (ancestors, 0..) |header, index| try appendAncestor(allocator, &body, header, index == 0);
    const mid = try std.fmt.allocPrint(allocator, "]}},\"reject\":{{\"height\":{d},\"time\":{d},\"bits\":{d},\"ancestors\":[", .{ ancestors.len, reject_time, reject_bits });
    defer allocator.free(mid);
    try body.appendSlice(allocator, mid);
    for (ancestors, 0..) |header, index| try appendAncestor(allocator, &body, header, index == 0);
    try body.appendSlice(allocator, "]}}");
    try manifest.appendSlice(allocator, body.items);
}

fn fillSpan(headers: []consensus_context.HeaderFields, first_bits: u32, first_time: u32, prev_bits: u32, prev_time: u32) void {
    for (headers, 0..) |*header, index| header.* = .{ .time = first_time +% @as(u32, @intCast(index)), .bits = first_bits };
    headers[0] = .{ .time = first_time, .bits = first_bits };
    headers[headers.len - 1] = .{ .time = prev_time, .bits = prev_bits };
}

fn appendMinDifficulty(allocator: std.mem.Allocator, manifest: *std.ArrayList(u8)) !void {
    const ancestors = [_]consensus_context.HeaderFields{
        .{ .time = 1_000_000, .bits = 0x1d00fffe },
        .{ .time = 1_000_600, .bits = chain_params.pow_limit_bits },
    };
    const time: u32 = 1_001_200;
    const required = try consensus_context.requiredBits(SliceHeaders{ .items = &ancestors }, 2, time);
    try appendHeaderCase(allocator, manifest, "consensus.nbits_min_difficulty_misuse", "nbits_mismatch", &ancestors, time, required, time, chain_params.pow_limit_bits);
}

fn appendRetarget(allocator: std.mem.Allocator, manifest: *std.ArrayList(u8), id: []const u8, reason: []const u8, use_first_bits: bool) !void {
    const headers = try allocator.alloc(consensus_context.HeaderFields, chain_params.interval);
    defer allocator.free(headers);
    const first_time: u32 = 1_000_000;
    const prev_time: u32 = first_time + @as(u32, @intCast(chain_params.timespan));
    const first_bits: u32 = if (use_first_bits) 0x1d00fffe else chain_params.pow_limit_bits;
    fillSpan(headers, first_bits, first_time, chain_params.pow_limit_bits, prev_time);
    const required = try consensus_context.requiredBits(SliceHeaders{ .items = headers }, chain_params.interval, prev_time);
    const wrong = if (use_first_bits)
        try consensus_context.retargetBits(chain_params.pow_limit_bits, first_time, prev_time)
    else
        0x1d00fffe;
    try appendHeaderCase(allocator, manifest, id, reason, headers, prev_time, required, prev_time, wrong);
}

fn appendTimewarp(allocator: std.mem.Allocator, manifest: *std.ArrayList(u8)) !void {
    const headers = try allocator.alloc(consensus_context.HeaderFields, chain_params.interval);
    defer allocator.free(headers);
    const first_time: u32 = 1_000_000;
    const prev_time: u32 = first_time + @as(u32, @intCast(chain_params.timespan));
    fillSpan(headers, chain_params.pow_limit_bits, first_time, chain_params.pow_limit_bits, prev_time);
    const required = try consensus_context.requiredBits(SliceHeaders{ .items = headers }, chain_params.interval, prev_time - chain_params.timewarp);
    try appendHeaderCase(allocator, manifest, "consensus.bip94_timewarp", "timewarp", headers, prev_time - chain_params.timewarp, required, prev_time - chain_params.timewarp - 1, required);
}

fn decodeUndo(allocator: std.mem.Allocator, bytes: []const u8) ![]root.types.UndoEntry {
    if (bytes.len < 4) return error.UndoTooShort;
    var offset: usize = 0;
    const count = std.mem.readInt(u32, bytes[0..4], .big);
    offset = 4;
    const entries = try allocator.alloc(root.types.UndoEntry, count);
    var filled: usize = 0;
    errdefer {
        for (entries[0..filled]) |entry| allocator.free(entry.utxo.script_pubkey);
        allocator.free(entries);
    }
    for (entries) |*entry| {
        if (offset + 49 > bytes.len) return error.UndoTooShort;
        var txid: [32]u8 = undefined;
        @memcpy(txid[0..], bytes[offset .. offset + 32]);
        offset += 32;
        const vout = std.mem.readInt(u32, bytes[offset..][0..4], .big);
        offset += 4;
        const height = std.mem.readInt(u32, bytes[offset..][0..4], .big);
        offset += 4;
        const value = std.mem.readInt(u64, bytes[offset..][0..8], .big);
        offset += 8;
        const coinbase = bytes[offset] == 1;
        offset += 1;
        if (offset + 4 > bytes.len) return error.UndoTooShort;
        const script_len = std.mem.readInt(u32, bytes[offset..][0..4], .big);
        offset += 4;
        if (offset + script_len > bytes.len) return error.UndoTooShort;
        const script = try allocator.dupe(u8, bytes[offset .. offset + script_len]);
        offset += script_len;
        entry.* = .{
            .outpoint = .{ .txid = txid, .vout = vout },
            .utxo = .{
                .height = height,
                .vout = vout,
                .value_sats = value,
                .coinbase = coinbase,
                .script_pubkey = script,
            },
        };
        filled += 1;
    }
    return entries;
}

fn readRelative(allocator: std.mem.Allocator, io: std.Io, manifest_path: []const u8, rel: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(manifest_path) orelse ".";
    const path = try std.fs.path.join(allocator, &.{ dir, rel });
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(32 * 1024 * 1024));
}

fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        std.Io.Dir.cwd().access(io, parent, .{}) catch {
            try std.Io.Dir.cwd().createDirPath(io, parent);
        };
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes, .flags = .{} });
}
