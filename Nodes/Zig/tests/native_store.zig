const std = @import("std");
const core = @import("zigbitnode");

test "set hash fold is its own inverse" {
    var hash = core.store.emptySetHash();
    core.store.foldSetHash(&hash, "key", "value");
    try std.testing.expect(!std.mem.eql(u8, &hash, &core.store.emptySetHash()));
    core.store.foldSetHash(&hash, "key", "value");
    try std.testing.expectEqualSlices(u8, &core.store.emptySetHash(), &hash);
}

test "rocks shadow create and spend returns set hash to zero" {
    if (comptime !core.rocksdb_compiled) return;
    const allocator = std.testing.allocator;
    const seed = std.testing.random_seed;
    const primary_path = try std.fmt.allocPrint(allocator, ".zig-cache/native-store-primary-{}", .{seed});
    defer allocator.free(primary_path);
    const shadow_path = try std.fmt.allocPrint(allocator, ".zig-cache/native-store-shadow-{}", .{seed});
    defer allocator.free(shadow_path);

    var primary = try core.RocksDb.open(allocator, primary_path);
    defer primary.close();
    var shadow = try core.RocksDb.open(allocator, shadow_path);
    defer shadow.close();
    var pair = core.ShadowStore(core.RocksDb, core.RocksDb).init(&primary, &shadow);

    const script_bytes = try core.fromHexAlloc(allocator, "51");
    defer allocator.free(script_bytes);
    var txid = [_]u8{0} ** 32;
    txid[0] = 9;
    const outpoint = core.Outpoint{ .txid = txid, .vout = 0 };
    const utxo = core.StoredUtxo{
        .height = 1,
        .vout = 0,
        .value_sats = 42,
        .coinbase = false,
        .script_pubkey = script_bytes,
    };
    const created = core.CreatedUtxo{ .outpoint = outpoint, .utxo = utxo };
    const block_one = [_]u8{1} ** 32;
    const create_timings = try pair.commitBlock(allocator, .{
        .height = 1,
        .block_hash = block_one,
        .spent_external = &.{},
        .created_utxos = &.{created},
        .undo_entries = &.{},
        .new_utxo_count = 1,
    });
    try std.testing.expect(create_timings.set_hash_fold >= 0);
    try std.testing.expect(create_timings.total() >= create_timings.set_hash_fold);
    const created_hash = pair.setHash();
    try std.testing.expect(!std.mem.eql(u8, &created_hash, &core.store.emptySetHash()));
    try std.testing.expectEqualSlices(u8, &created_hash, &shadow.setHash());

    const raw = try pair.getManyUtxoRaw(allocator, "testnet4", &.{outpoint}, null);
    defer {
        for (raw) |value| if (value) |bytes| allocator.free(bytes);
        allocator.free(raw);
    }
    try std.testing.expect(raw[0] != null);

    const undo = core.UndoEntry{ .outpoint = outpoint, .utxo = utxo };
    const block_two = [_]u8{2} ** 32;
    _ = try pair.commitBlock(allocator, .{
        .height = 2,
        .block_hash = block_two,
        .spent_external = &.{outpoint},
        .created_utxos = &.{},
        .undo_entries = &.{undo},
        .new_utxo_count = 0,
    });
    const spent_hash = pair.setHash();
    try std.testing.expectEqualSlices(u8, &core.store.emptySetHash(), &spent_hash);
    try std.testing.expectEqualSlices(u8, &spent_hash, &shadow.setHash());
    try std.testing.expectEqual(@as(i64, 0), primary.utxo_count);
    try std.testing.expectEqual(@as(i64, 0), shadow.utxo_count);
    try std.testing.expectEqual(@as(u64, 0), pair.divergence_count);

    const missing = try pair.getManyUtxoRaw(allocator, "testnet4", &.{outpoint}, null);
    defer {
        for (missing) |value| if (value) |bytes| allocator.free(bytes);
        allocator.free(missing);
    }
    try std.testing.expect(missing[0] == null);
}

test "peak rss is reported in bytes" {
    try std.testing.expect(core.store.peakRssBytes() > 0);
}

const Native = core.native_store.NativeStore;

var fresh_seq: u64 = 0;

fn freshPath(allocator: std.mem.Allocator, label: []const u8) ![]u8 {
    fresh_seq += 1;
    return std.fmt.allocPrint(allocator, ".zig-cache/native-{s}-{}-{}", .{ label, std.testing.random_seed, fresh_seq });
}

fn oneUtxo(script_bytes: []const u8, mark: u8) core.CreatedUtxo {
    var txid = [_]u8{0} ** 32;
    txid[0] = mark;
    return .{
        .outpoint = .{ .txid = txid, .vout = 0 },
        .utxo = .{
            .height = 1,
            .vout = 0,
            .value_sats = 42,
            .coinbase = false,
            .script_pubkey = script_bytes,
        },
    };
}

fn commitCreate(db: anytype, allocator: std.mem.Allocator, created: core.CreatedUtxo, height: u32) !void {
    var hash = [_]u8{0} ** 32;
    hash[0] = @intCast(height);
    _ = try db.commitBlock(allocator, .{
        .height = height,
        .block_hash = hash,
        .spent_external = &.{},
        .created_utxos = &.{created},
        .undo_entries = &.{},
        .new_utxo_count = 1,
    });
}

test "native shadow create and spend matches rocksdb bytes" {
    if (comptime !core.rocksdb_compiled) return;
    const allocator = std.testing.allocator;
    const native_path = try freshPath(allocator, "shadow-native");
    defer allocator.free(native_path);
    const rocks_path = try freshPath(allocator, "shadow-rocks");
    defer allocator.free(rocks_path);
    var native = try Native.open(allocator, native_path, .{});
    defer native.close();
    var rocks = try core.RocksDb.open(allocator, rocks_path);
    defer rocks.close();
    var pair = core.ShadowStore(Native, core.RocksDb).init(&native, &rocks);
    const script_bytes = try core.fromHexAlloc(allocator, "51");
    defer allocator.free(script_bytes);
    const created = oneUtxo(script_bytes, 9);
    try commitCreate(&pair, allocator, created, 1);
    const raw = try pair.getManyUtxoRaw(allocator, "testnet4", &.{created.outpoint}, null);
    defer {
        for (raw) |value| if (value) |bytes| allocator.free(bytes);
        allocator.free(raw);
    }
    try std.testing.expect(raw[0] != null);
    const undo = core.UndoEntry{ .outpoint = created.outpoint, .utxo = created.utxo };
    const spend_hash = [_]u8{2} ** 32;
    _ = try pair.commitBlock(allocator, .{
        .height = 2,
        .block_hash = spend_hash,
        .spent_external = &.{created.outpoint},
        .created_utxos = &.{},
        .undo_entries = &.{undo},
        .new_utxo_count = 0,
    });
    try std.testing.expectEqualSlices(u8, &core.store.emptySetHash(), &pair.setHash());
    try std.testing.expectEqualSlices(u8, &native.setHash(), &rocks.setHash());
    try std.testing.expectEqual(@as(u64, 0), pair.divergence_count);
    const missing = try pair.getManyUtxoRaw(allocator, "testnet4", &.{created.outpoint}, null);
    defer {
        for (missing) |value| if (value) |bytes| allocator.free(bytes);
        allocator.free(missing);
    }
    try std.testing.expect(missing[0] == null);
}

test "native restart replays the commit log" {
    const allocator = std.testing.allocator;
    const path = try freshPath(allocator, "restart");
    defer allocator.free(path);
    const script_bytes = try core.fromHexAlloc(allocator, "51");
    defer allocator.free(script_bytes);
    const created = oneUtxo(script_bytes, 4);
    var first_hash: [32]u8 = undefined;
    {
        var db = try Native.open(allocator, path, .{});
        defer db.close();
        const key = try core.encodeMetadataKey(allocator, "validation_crypto_backend");
        defer allocator.free(key);
        try db.put(key, "libsecp256k1");
        try commitCreate(&db, allocator, created, 1);
        first_hash = db.setHash();
    }
    var db = try Native.open(allocator, path, .{});
    defer db.close();
    try std.testing.expectEqualSlices(u8, &first_hash, &db.setHash());
    try std.testing.expectEqual(@as(i64, 1), db.validated_height);
    const key = try core.encodeMetadataKey(allocator, "validation_crypto_backend");
    defer allocator.free(key);
    const backend = (try db.getAlloc(allocator, key)).?;
    defer allocator.free(backend);
    try std.testing.expectEqualStrings("libsecp256k1", backend);
    const raw = try db.getManyUtxoRaw(allocator, "testnet4", &.{created.outpoint}, null);
    defer {
        for (raw) |value| if (value) |bytes| allocator.free(bytes);
        allocator.free(raw);
    }
    try std.testing.expect(raw[0] != null);
}

test "direct apply and replay apply match map bytes and set hash" {
    const allocator = std.testing.allocator;
    const path = try freshPath(allocator, "direct-replay");
    defer allocator.free(path);
    const script_bytes = try core.fromHexAlloc(allocator, "51");
    defer allocator.free(script_bytes);
    const created = oneUtxo(script_bytes, 7);
    var live_hash: [32]u8 = undefined;
    var live_raw: []u8 = undefined;
    {
        var db = try Native.open(allocator, path, .{});
        defer db.close();
        try commitCreate(&db, allocator, created, 1);
        live_hash = db.setHash();
        const raw = try db.getManyUtxoRaw(allocator, "testnet4", &.{created.outpoint}, null);
        defer {
            for (raw) |value| if (value) |bytes| allocator.free(bytes);
            allocator.free(raw);
        }
        live_raw = try allocator.dupe(u8, raw[0].?);
    }
    defer allocator.free(live_raw);
    var db = try Native.open(allocator, path, .{});
    defer db.close();
    try std.testing.expectEqualSlices(u8, &live_hash, &db.setHash());
    const raw = try db.getManyUtxoRaw(allocator, "testnet4", &.{created.outpoint}, null);
    defer {
        for (raw) |value| if (value) |bytes| allocator.free(bytes);
        allocator.free(raw);
    }
    try std.testing.expectEqualSlices(u8, live_raw, raw[0].?);
    try std.testing.expectEqual(@as(i64, 1), db.utxo_count);
}

test "snapshot rename before log truncate does not double apply" {
    const allocator = std.testing.allocator;
    const path = try freshPath(allocator, "snapshot-crash");
    defer allocator.free(path);
    const script_bytes = try core.fromHexAlloc(allocator, "51");
    defer allocator.free(script_bytes);
    const created = oneUtxo(script_bytes, 5);
    var expected: [32]u8 = undefined;
    var planted: []u8 = &.{};
    {
        var db = try Native.open(allocator, path, .{ .snapshot_every = 1000 });
        defer db.close();
        try commitCreate(&db, allocator, created, 1);
        const undo = core.UndoEntry{ .outpoint = created.outpoint, .utxo = created.utxo };
        const spend_hash = [_]u8{2} ** 32;
        _ = try db.commitBlock(allocator, .{
            .height = 2,
            .block_hash = spend_hash,
            .spent_external = &.{created.outpoint},
            .created_utxos = &.{},
            .undo_entries = &.{undo},
            .new_utxo_count = 0,
        });
        expected = db.setHash();
        planted = try db.testingReadLog(allocator);
        try db.writeSnapshot();
        try db.testingWriteLogFile(planted);
    }
    defer allocator.free(planted);
    var db = try Native.open(allocator, path, .{});
    defer db.close();
    try std.testing.expectEqualSlices(u8, &expected, &db.setHash());
    try std.testing.expectEqual(@as(i64, 0), db.utxo_count);
    try std.testing.expectEqual(@as(i64, 2), db.validated_height);
}

test "record block survives restart before connect" {
    const allocator = std.testing.allocator;
    const path = try freshPath(allocator, "record-block");
    defer allocator.free(path);
    const raw = [_]u8{7} ** 80;
    const hash = [_]u8{9} ** 32;
    {
        var db = try Native.open(allocator, path, .{});
        defer db.close();
        try db.recordBlock(allocator, 3, hash, &raw);
        try std.testing.expectEqual(@as(i64, -1), db.validated_height);
    }
    var db = try Native.open(allocator, path, .{});
    defer db.close();
    const key = try core.encodeRawBlockKey(allocator, "testnet4", 3);
    defer allocator.free(key);
    const loaded = (try db.getAlloc(allocator, key)).?;
    defer allocator.free(loaded);
    try std.testing.expectEqualSlices(u8, &raw, loaded);
    try std.testing.expectEqual(@as(i64, -1), db.validated_height);
}

test "flat files truncate to the last committed extent" {
    const allocator = std.testing.allocator;
    const path = try freshPath(allocator, "truncate");
    defer allocator.free(path);
    const raw = [_]u8{4} ** 80;
    const hash = [_]u8{1} ** 32;
    {
        var db = try Native.open(allocator, path, .{});
        defer db.close();
        try db.recordBlock(allocator, 1, hash, &raw);
        try db.testingExtend(.blocks, "orphan-tail");
    }
    var db = try Native.open(allocator, path, .{});
    defer db.close();
    try std.testing.expectEqual(@as(u64, raw.len), db.blocks_len);
    const key = try core.encodeRawBlockKey(allocator, "testnet4", 1);
    defer allocator.free(key);
    const loaded = (try db.getAlloc(allocator, key)).?;
    defer allocator.free(loaded);
    try std.testing.expectEqualSlices(u8, &raw, loaded);
}

test "torn commit record and one corrupted byte keep the previous tip" {
    const allocator = std.testing.allocator;
    const path = try freshPath(allocator, "atomic");
    defer allocator.free(path);
    const script_bytes = try core.fromHexAlloc(allocator, "51");
    defer allocator.free(script_bytes);
    const first = oneUtxo(script_bytes, 1);
    const second = oneUtxo(script_bytes, 2);
    var hash_one: [32]u8 = undefined;
    var log_copy: []u8 = undefined;
    var record_off: usize = 0;
    {
        var db = try Native.open(allocator, path, .{ .snapshot_every = 1000 });
        defer db.close();
        try commitCreate(&db, allocator, first, 1);
        hash_one = db.setHash();
        record_off = @intCast(db.log_len);
        try commitCreate(&db, allocator, second, 2);
        log_copy = try db.testingReadLog(allocator);
        try std.testing.expect(db.log_len > record_off);
    }
    defer allocator.free(log_copy);
    var cut = record_off;
    while (cut < log_copy.len) : (cut += 1) {
        try Native.testingRewriteLog(path, log_copy, cut);
        var db = try Native.open(allocator, path, .{});
        defer db.close();
        try std.testing.expectEqualSlices(u8, &hash_one, &db.setHash());
        try std.testing.expectEqual(@as(i64, 1), db.validated_height);
    }
    var flipped = try allocator.dupe(u8, log_copy);
    defer allocator.free(flipped);
    flipped[record_off + 8] ^= 0xff;
    try Native.testingRewriteLog(path, flipped, flipped.len);
    var db = try Native.open(allocator, path, .{});
    defer db.close();
    try std.testing.expectEqualSlices(u8, &hash_one, &db.setHash());
}

test "crash before append drops the commit and after append keeps it" {
    const allocator = std.testing.allocator;
    const script_bytes = try core.fromHexAlloc(allocator, "51");
    defer allocator.free(script_bytes);
    const created = oneUtxo(script_bytes, 8);
    const before_path = try freshPath(allocator, "crash-before");
    defer allocator.free(before_path);
    {
        var db = try Native.open(allocator, before_path, .{
            .crash_after_block = 1,
            .crash_point = .before_append,
            .crash_exit = false,
        });
        defer db.close();
        try std.testing.expectError(error.CrashInjected, commitCreate(&db, allocator, created, 1));
    }
    {
        var db = try Native.open(allocator, before_path, .{});
        defer db.close();
        try std.testing.expectEqualSlices(u8, &core.store.emptySetHash(), &db.setHash());
        try std.testing.expectEqual(@as(i64, -1), db.validated_height);
    }

    const after_path = try freshPath(allocator, "crash-after");
    defer allocator.free(after_path);
    var expected: [32]u8 = undefined;
    const done_path = try freshPath(allocator, "crash-done");
    defer allocator.free(done_path);
    {
        var done = try Native.open(allocator, done_path, .{});
        defer done.close();
        try commitCreate(&done, allocator, created, 1);
        expected = done.setHash();
    }
    {
        var db = try Native.open(allocator, after_path, .{
            .crash_after_block = 1,
            .crash_point = .after_append,
            .crash_exit = false,
        });
        defer db.close();
        try std.testing.expectError(error.CrashInjected, commitCreate(&db, allocator, created, 1));
        try std.testing.expectEqualSlices(u8, &core.store.emptySetHash(), &db.setHash());
    }
    {
        var db = try Native.open(allocator, after_path, .{});
        defer db.close();
        try std.testing.expectEqualSlices(u8, &expected, &db.setHash());
        try std.testing.expectEqual(@as(i64, 1), db.validated_height);
    }
}
