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

    const script_bytes = try core.codec.fromHexAlloc(allocator, "51");
    defer allocator.free(script_bytes);
    var txid = [_]u8{0} ** 32;
    txid[0] = 9;
    const outpoint = core.types.Outpoint{ .txid = txid, .vout = 0 };
    const utxo = core.types.StoredUtxo{
        .height = 1,
        .vout = 0,
        .value_sats = 42,
        .coinbase = false,
        .script_pubkey = script_bytes,
    };
    const created = core.types.CreatedUtxo{ .outpoint = outpoint, .utxo = utxo };
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

    const undo = core.types.UndoEntry{ .outpoint = outpoint, .utxo = utxo };
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

fn oneUtxo(script_bytes: []const u8, mark: u8) core.types.CreatedUtxo {
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

fn commitCreate(db: anytype, allocator: std.mem.Allocator, created: core.types.CreatedUtxo, height: u32) !void {
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
    const script_bytes = try core.codec.fromHexAlloc(allocator, "51");
    defer allocator.free(script_bytes);
    const created = oneUtxo(script_bytes, 9);
    try commitCreate(&pair, allocator, created, 1);
    const raw = try pair.getManyUtxoRaw(allocator, "testnet4", &.{created.outpoint}, null);
    defer {
        for (raw) |value| if (value) |bytes| allocator.free(bytes);
        allocator.free(raw);
    }
    try std.testing.expect(raw[0] != null);
    const undo = core.types.UndoEntry{ .outpoint = created.outpoint, .utxo = created.utxo };
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
    const script_bytes = try core.codec.fromHexAlloc(allocator, "51");
    defer allocator.free(script_bytes);
    const created = oneUtxo(script_bytes, 4);
    var first_hash: [32]u8 = undefined;
    {
        var db = try Native.open(allocator, path, .{});
        defer db.close();
        const key = try core.codec.encodeMetadataKey(allocator, "validation_crypto_backend");
        defer allocator.free(key);
        try db.put(key, "libsecp256k1");
        try commitCreate(&db, allocator, created, 1);
        first_hash = db.setHash();
    }
    var db = try Native.open(allocator, path, .{});
    defer db.close();
    try std.testing.expectEqualSlices(u8, &first_hash, &db.setHash());
    try std.testing.expectEqual(@as(i64, 1), db.validated_height);
    const key = try core.codec.encodeMetadataKey(allocator, "validation_crypto_backend");
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
    const script_bytes = try core.codec.fromHexAlloc(allocator, "51");
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
    const script_bytes = try core.codec.fromHexAlloc(allocator, "51");
    defer allocator.free(script_bytes);
    const created = oneUtxo(script_bytes, 5);
    var expected: [32]u8 = undefined;
    var planted: []u8 = &.{};
    {
        var db = try Native.open(allocator, path, .{ .snapshot_every = 1000 });
        defer db.close();
        try commitCreate(&db, allocator, created, 1);
        const undo = core.types.UndoEntry{ .outpoint = created.outpoint, .utxo = created.utxo };
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
    const key = try core.codec.encodeRawBlockKey(allocator, "testnet4", 3);
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
    const key = try core.codec.encodeRawBlockKey(allocator, "testnet4", 1);
    defer allocator.free(key);
    const loaded = (try db.getAlloc(allocator, key)).?;
    defer allocator.free(loaded);
    try std.testing.expectEqualSlices(u8, &raw, loaded);
}

test "torn commit record and one corrupted byte keep the previous tip" {
    const allocator = std.testing.allocator;
    const path = try freshPath(allocator, "atomic");
    defer allocator.free(path);
    const script_bytes = try core.codec.fromHexAlloc(allocator, "51");
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
    const script_bytes = try core.codec.fromHexAlloc(allocator, "51");
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

test "disconnect restores the recorded set hash" {
    const allocator = std.testing.allocator;
    const native_path = try freshPath(allocator, "reorg");
    defer allocator.free(native_path);
    {
        var db = try Native.open(allocator, native_path, .{});
        defer db.close();
        try exerciseDisconnect(&db, allocator);
        try expectNoRecordedNative(allocator);
        try expectCorruptUndoNative(allocator);
    }
    try expectReplayAndSnapshot(allocator);
    if (comptime core.rocksdb_compiled) {
        const rocks_path = try freshPath(allocator, "reorg-rocks");
        defer allocator.free(rocks_path);
        var rocks = try core.RocksDb.open(allocator, rocks_path);
        defer rocks.close();
        try exerciseDisconnect(&rocks, allocator);
        try expectNoRecordedRocks(allocator);
        try expectCorruptUndoRocks(allocator);

        const primary_path = try freshPath(allocator, "reorg-shadow-primary");
        defer allocator.free(primary_path);
        const shadow_path = try freshPath(allocator, "reorg-shadow");
        defer allocator.free(shadow_path);
        var primary = try Native.open(allocator, primary_path, .{});
        defer primary.close();
        var shadow = try core.RocksDb.open(allocator, shadow_path);
        defer shadow.close();
        var pair = core.ShadowStore(Native, core.RocksDb).init(&primary, &shadow);
        try exerciseDisconnect(&pair, allocator);
        const spend_primary_path = try freshPath(allocator, "reorg-spend-primary");
        defer allocator.free(spend_primary_path);
        const spend_shadow_path = try freshPath(allocator, "reorg-spend-shadow");
        defer allocator.free(spend_shadow_path);
        var spend_primary = try Native.open(allocator, spend_primary_path, .{});
        defer spend_primary.close();
        var spend_shadow = try core.RocksDb.open(allocator, spend_shadow_path);
        defer spend_shadow.close();
        var spend_pair = core.ShadowStore(Native, core.RocksDb).init(&spend_primary, &spend_shadow);
        try expectSpendRestore(&spend_pair, allocator);
    }
    const spend_native_path = try freshPath(allocator, "reorg-spend");
    defer allocator.free(spend_native_path);
    {
        var db = try Native.open(allocator, spend_native_path, .{});
        defer db.close();
        try expectSpendRestore(&db, allocator);
    }
    if (comptime core.rocksdb_compiled) {
        const spend_rocks_path = try freshPath(allocator, "reorg-spend-rocks");
        defer allocator.free(spend_rocks_path);
        var rocks = try core.RocksDb.open(allocator, spend_rocks_path);
        defer rocks.close();
        try expectSpendRestore(&rocks, allocator);
    }
}

fn expectSpendRestore(db: anytype, allocator: std.mem.Allocator) !void {
    const zero = [_]u8{0} ** 32;
    const block0 = try buildCoinbaseBlock(allocator, zero, 21);
    defer allocator.free(block0.raw);
    const block1 = try buildCoinbaseBlock(allocator, block0.hash, 22);
    defer allocator.free(block1.raw);
    var utxos: i64 = 0;
    utxos = try connectBuilt(db, allocator, 0, block0, utxos);
    utxos = try connectBuilt(db, allocator, 1, block1, utxos);
    const hash1 = db.setHash();
    const created = try core.tx.parseBlockTransactions(allocator, block1.raw);
    defer {
        for (created) |transaction| transaction.deinit(allocator);
        allocator.free(created);
    }
    const spend_txid = created[0].txid();
    const block2 = try buildSpendBlock(allocator, block1.hash, 23, spend_txid);
    defer allocator.free(block2.raw);
    const transactions = try core.tx.parseBlockTransactions(allocator, block2.raw);
    defer {
        for (transactions) |transaction| transaction.deinit(allocator);
        allocator.free(transactions);
    }
    var txids = [_][32]u8{ transactions[0].txid(), transactions[1].txid() };
    var spent = std.AutoHashMap(core.types.Outpoint, void).init(allocator);
    defer spent.deinit();
    const outpoint = core.types.Outpoint{ .txid = spend_txid, .vout = 0 };
    try spent.put(outpoint, {});
    const script = [_]u8{0x51};
    const undo = [_]core.types.UndoEntry{.{
        .outpoint = outpoint,
        .utxo = .{
            .height = 1,
            .vout = 0,
            .value_sats = 5_000_000_000,
            .coinbase = true,
            .script_pubkey = &script,
        },
    }};
    try db.recordBlock(allocator, 2, block2.hash, block2.raw);
    _ = try db.commitConnectedBlock(allocator, 2, block2.hash, &.{outpoint}, &undo, transactions, &txids, &spent, utxos - 1 + 2);
    const removed = try db.disconnectTip(allocator);
    try std.testing.expectEqual(@as(u32, 2), removed.utxos_removed);
    try std.testing.expectEqual(@as(u32, 1), removed.utxos_restored);
    try std.testing.expectEqualSlices(u8, &hash1, &removed.set_hash_after);
    try std.testing.expectEqualSlices(u8, &hash1, &db.setHash());
    try std.testing.expectEqual(utxos, dbUtxoCount(db));
}

fn buildSpendBlock(allocator: std.mem.Allocator, prev: [32]u8, marker: u8, spend_txid: [32]u8) !BuiltBlock {
    const coinbase = try coinbaseTx(allocator, marker);
    defer allocator.free(coinbase);
    const spend = try spendTx(allocator, spend_txid);
    defer allocator.free(spend);
    const txids = [_][32]u8{ core.crypto.doubleSha256(coinbase), core.crypto.doubleSha256(spend) };
    const merkle = try core.block.merkleRoot(allocator, &txids);
    var raw: std.ArrayList(u8) = .empty;
    errdefer raw.deinit(allocator);
    var version = std.mem.toBytes(@as(u32, 1));
    try putInt(&raw, allocator, &version);
    try putInt(&raw, allocator, &prev);
    try putInt(&raw, allocator, &merkle);
    var time = std.mem.toBytes(@as(u32, 1_700_000_000));
    try putInt(&raw, allocator, &time);
    var bits = std.mem.toBytes(@as(u32, 0x1d00ffff));
    try putInt(&raw, allocator, &bits);
    var nonce = std.mem.toBytes(@as(u32, marker));
    try putInt(&raw, allocator, &nonce);
    try raw.append(allocator, 2);
    try putInt(&raw, allocator, coinbase);
    try putInt(&raw, allocator, spend);
    const hash = core.crypto.doubleSha256(raw.items[0..80]);
    return .{ .raw = try raw.toOwnedSlice(allocator), .hash = hash, .prev = prev };
}

fn coinbaseTx(allocator: std.mem.Allocator, marker: u8) ![]u8 {
    var tx: std.ArrayList(u8) = .empty;
    errdefer tx.deinit(allocator);
    var version = std.mem.toBytes(@as(u32, 1));
    try putInt(&tx, allocator, &version);
    try tx.append(allocator, 1);
    try tx.appendNTimes(allocator, 0, 32);
    var null_vout = std.mem.toBytes(@as(u32, 0xffffffff));
    try putInt(&tx, allocator, &null_vout);
    try tx.append(allocator, 1);
    try tx.append(allocator, marker);
    try putInt(&tx, allocator, &null_vout);
    try tx.append(allocator, 1);
    var value = std.mem.toBytes(@as(u64, 5_000_000_000));
    try putInt(&tx, allocator, &value);
    try tx.append(allocator, 1);
    try tx.append(allocator, 0x51);
    var lock_time = std.mem.toBytes(@as(u32, 0));
    try putInt(&tx, allocator, &lock_time);
    return tx.toOwnedSlice(allocator);
}

fn spendTx(allocator: std.mem.Allocator, spend_txid: [32]u8) ![]u8 {
    var tx: std.ArrayList(u8) = .empty;
    errdefer tx.deinit(allocator);
    var version = std.mem.toBytes(@as(u32, 1));
    try putInt(&tx, allocator, &version);
    try tx.append(allocator, 1);
    try putInt(&tx, allocator, &spend_txid);
    var vout = std.mem.toBytes(@as(u32, 0));
    try putInt(&tx, allocator, &vout);
    try tx.append(allocator, 0);
    var sequence = std.mem.toBytes(@as(u32, 0xffffffff));
    try putInt(&tx, allocator, &sequence);
    try tx.append(allocator, 1);
    var value = std.mem.toBytes(@as(u64, 1000));
    try putInt(&tx, allocator, &value);
    try tx.append(allocator, 1);
    try tx.append(allocator, 0x51);
    var lock_time = std.mem.toBytes(@as(u32, 0));
    try putInt(&tx, allocator, &lock_time);
    return tx.toOwnedSlice(allocator);
}

const BuiltBlock = struct {
    raw: []u8,
    hash: [32]u8,
    prev: [32]u8,
};

fn putInt(list: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
    try list.appendSlice(allocator, bytes);
}

fn buildCoinbaseBlock(allocator: std.mem.Allocator, prev: [32]u8, marker: u8) !BuiltBlock {
    var tx: std.ArrayList(u8) = .empty;
    errdefer tx.deinit(allocator);
    var version = std.mem.toBytes(@as(u32, 1));
    try putInt(&tx, allocator, &version);
    try tx.append(allocator, 1);
    try tx.appendNTimes(allocator, 0, 32);
    var null_vout = std.mem.toBytes(@as(u32, 0xffffffff));
    try putInt(&tx, allocator, &null_vout);
    try tx.append(allocator, 1);
    try tx.append(allocator, marker);
    try putInt(&tx, allocator, &null_vout);
    try tx.append(allocator, 1);
    var value = std.mem.toBytes(@as(u64, 5_000_000_000));
    try putInt(&tx, allocator, &value);
    try tx.append(allocator, 1);
    try tx.append(allocator, 0x51);
    var lock_time = std.mem.toBytes(@as(u32, 0));
    try putInt(&tx, allocator, &lock_time);
    const txid = core.crypto.doubleSha256(tx.items);

    var raw: std.ArrayList(u8) = .empty;
    errdefer raw.deinit(allocator);
    try putInt(&raw, allocator, &version);
    try putInt(&raw, allocator, &prev);
    try putInt(&raw, allocator, &txid);
    var time = std.mem.toBytes(@as(u32, 1_700_000_000));
    try putInt(&raw, allocator, &time);
    var bits = std.mem.toBytes(@as(u32, 0x1d00ffff));
    try putInt(&raw, allocator, &bits);
    var nonce = std.mem.toBytes(@as(u32, marker));
    try putInt(&raw, allocator, &nonce);
    try raw.append(allocator, 1);
    try putInt(&raw, allocator, tx.items);
    tx.deinit(allocator);
    const hash = core.crypto.doubleSha256(raw.items[0..80]);
    return .{ .raw = try raw.toOwnedSlice(allocator), .hash = hash, .prev = prev };
}

fn connectBuilt(db: anytype, allocator: std.mem.Allocator, height: u32, block: BuiltBlock, utxos: i64) !i64 {
    return connectBuiltRecord(db, allocator, height, block, utxos, true);
}

fn connectBuiltRecord(db: anytype, allocator: std.mem.Allocator, height: u32, block: BuiltBlock, utxos: i64, record: bool) !i64 {
    const transactions = try core.tx.parseBlockTransactions(allocator, block.raw);
    defer {
        for (transactions) |transaction| transaction.deinit(allocator);
        allocator.free(transactions);
    }
    if (record) try db.recordBlock(allocator, height, block.hash, block.raw);
    const connected = try core.connect.connectDecodedBlock(allocator, db, height, height, .{
        .hash = block.hash,
        .prev_hash = block.prev,
        .merkle_root = block.hash,
        .tx_count = 1,
        .bits = 0x1d00ffff,
    }, transactions, null, utxos);
    defer connected.deinit(allocator);
    return connected.chainstate_utxo_count;
}

fn exerciseDisconnect(db: anytype, allocator: std.mem.Allocator) !void {
    const zero = [_]u8{0} ** 32;
    const block0 = try buildCoinbaseBlock(allocator, zero, 1);
    defer allocator.free(block0.raw);
    const block1 = try buildCoinbaseBlock(allocator, block0.hash, 2);
    defer allocator.free(block1.raw);
    const block2 = try buildCoinbaseBlock(allocator, block1.hash, 3);
    defer allocator.free(block2.raw);
    const fork = try buildCoinbaseBlock(allocator, block0.hash, 9);
    defer allocator.free(fork.raw);

    var utxos: i64 = 0;
    utxos = try connectBuilt(db, allocator, 0, block0, utxos);
    const hash0 = db.setHash();
    const count0 = utxos;
    utxos = try connectBuilt(db, allocator, 1, block1, utxos);
    const hash1 = db.setHash();
    const count1 = utxos;
    utxos = try connectBuilt(db, allocator, 2, block2, utxos);
    const hash2 = db.setHash();
    try std.testing.expectEqualSlices(u8, &hash2, &db.setHash());
    const recorded0 = (try db.setHashAt(0)).?;
    const recorded1 = (try db.setHashAt(1)).?;
    try std.testing.expectEqualSlices(u8, &hash0, &recorded0);
    try std.testing.expectEqualSlices(u8, &hash1, &recorded1);

    try std.testing.expectError(error.ParentMismatch, connectBuiltRecord(db, allocator, 1, fork, utxos, false));

    const removed = try db.disconnectTip(allocator);
    try std.testing.expectEqual(@as(u32, 2), removed.height);
    try std.testing.expectEqual(@as(u32, 1), removed.utxos_removed);
    try std.testing.expectEqual(@as(u32, 0), removed.utxos_restored);
    try std.testing.expectEqualSlices(u8, &hash1, &removed.set_hash_after);
    try std.testing.expectEqualSlices(u8, &hash1, &db.setHash());
    try std.testing.expectEqual(count1, dbUtxoCount(db));

    utxos = count1;
    utxos = try connectBuilt(db, allocator, 2, block2, utxos);
    try std.testing.expectEqualSlices(u8, &hash2, &db.setHash());

    _ = try db.disconnectTip(allocator);
    const back = try db.disconnectTip(allocator);
    try std.testing.expectEqual(@as(u32, 1), back.height);
    try std.testing.expectEqualSlices(u8, &hash0, &back.set_hash_after);
    try std.testing.expectEqual(count0, dbUtxoCount(db));
    utxos = try connectBuilt(db, allocator, 1, fork, count0);
    try std.testing.expect(utxos == count1);
    try std.testing.expect(!std.mem.eql(u8, &db.setHash(), &hash1));
}

fn dbUtxoCount(db: anytype) i64 {
    const Child = @TypeOf(db.*);
    if (@hasField(Child, "utxo_count")) return db.utxo_count;
    return db.primary.utxo_count;
}

fn expectNoRecordedNative(allocator: std.mem.Allocator) !void {
    const path = try freshPath(allocator, "reorg-norecord");
    defer allocator.free(path);
    var db = try Native.open(allocator, path, .{});
    defer db.close();
    try expectNoRecordedOn(&db, allocator);
}

fn expectNoRecordedRocks(allocator: std.mem.Allocator) !void {
    const path = try freshPath(allocator, "reorg-norecord-rocks");
    defer allocator.free(path);
    var db = try core.RocksDb.open(allocator, path);
    defer db.close();
    try expectNoRecordedOn(&db, allocator);
}

fn expectNoRecordedOn(db: anytype, allocator: std.mem.Allocator) !void {
    const zero = [_]u8{0} ** 32;
    const block0 = try buildCoinbaseBlock(allocator, zero, 4);
    defer allocator.free(block0.raw);
    const block1 = try buildCoinbaseBlock(allocator, block0.hash, 5);
    defer allocator.free(block1.raw);
    try db.recordBlock(allocator, 0, block0.hash, block0.raw);
    try db.recordBlock(allocator, 1, block1.hash, block1.raw);
    const transactions = try core.tx.parseBlockTransactions(allocator, block1.raw);
    defer {
        for (transactions) |transaction| transaction.deinit(allocator);
        allocator.free(transactions);
    }
    var txids = [_][32]u8{transactions[0].txid()};
    var spent = std.AutoHashMap(core.types.Outpoint, void).init(allocator);
    defer spent.deinit();
    _ = try db.commitConnectedBlock(allocator, 1, block1.hash, &.{}, &.{}, transactions, &txids, &spent, 1);
    try std.testing.expect((try db.setHashAt(0)) == null);
    const before = db.setHash();
    try std.testing.expectError(error.NoRecordedSetHash, db.disconnectTip(allocator));
    try std.testing.expectEqualSlices(u8, &before, &db.setHash());
    try std.testing.expectEqual(@as(i64, 1), dbUtxoCount(db));
}

fn expectCorruptUndoNative(allocator: std.mem.Allocator) !void {
    const path = try freshPath(allocator, "reorg-bad-undo");
    defer allocator.free(path);
    var db = try Native.open(allocator, path, .{});
    defer db.close();
    const zero = [_]u8{0} ** 32;
    const block0 = try buildCoinbaseBlock(allocator, zero, 6);
    defer allocator.free(block0.raw);
    const block1 = try buildCoinbaseBlock(allocator, block0.hash, 7);
    defer allocator.free(block1.raw);
    var utxos: i64 = 0;
    utxos = try connectBuilt(&db, allocator, 0, block0, utxos);
    _ = try connectBuilt(&db, allocator, 1, block1, utxos);
    const before = db.setHash();
    try flipNativeUndo(path);
    try std.testing.expectError(error.UndoTruncated, db.disconnectTip(allocator));
    try std.testing.expectEqualSlices(u8, &before, &db.setHash());
    try std.testing.expectEqual(@as(i64, 1), db.utxo_count);
    try std.testing.expectEqual(@as(i64, 1), db.validated_height);
}

fn flipNativeUndo(path: []const u8) !void {
    const undo_path = try std.fs.path.join(std.testing.allocator, &.{ path, "undo.dat" });
    defer std.testing.allocator.free(undo_path);
    const path_z = try std.testing.allocator.dupeZ(u8, undo_path);
    defer std.testing.allocator.free(path_z);
    const fd = std.c.open(path_z, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.NativeIo;
    defer _ = std.c.close(fd);
    const len = std.c.lseek(fd, 0, std.c.SEEK.END);
    if (len < 4) return error.NativeIo;
    var byte = [_]u8{0};
    const at: i64 = @intCast(len - 4);
    if (std.c.pread(fd, &byte, 1, at) != 1) return error.NativeIo;
    byte[0] ^= 0xff;
    if (std.c.pwrite(fd, &byte, 1, at) != 1) return error.NativeIo;
}

fn expectCorruptUndoRocks(allocator: std.mem.Allocator) !void {
    const path = try freshPath(allocator, "reorg-bad-undo-rocks");
    defer allocator.free(path);
    var db = try core.RocksDb.open(allocator, path);
    defer db.close();
    const zero = [_]u8{0} ** 32;
    const block0 = try buildCoinbaseBlock(allocator, zero, 8);
    defer allocator.free(block0.raw);
    const block1 = try buildCoinbaseBlock(allocator, block0.hash, 10);
    defer allocator.free(block1.raw);
    var utxos: i64 = 0;
    utxos = try connectBuilt(&db, allocator, 0, block0, utxos);
    _ = try connectBuilt(&db, allocator, 1, block1, utxos);
    const before = db.setHash();
    const key = try core.codec.encodeUndoKey(allocator, "testnet4", 1);
    defer allocator.free(key);
    const undo = (try db.getAlloc(allocator, key)).?;
    defer allocator.free(undo);
    undo[0] ^= 0xff;
    try db.put(key, undo);
    try std.testing.expectError(error.UndoTruncated, db.disconnectTip(allocator));
    try std.testing.expectEqualSlices(u8, &before, &db.setHash());
    try std.testing.expectEqual(@as(i64, 1), db.utxo_count);
    try std.testing.expectEqual(@as(i64, 1), db.validated_height);
}

fn expectReplayAndSnapshot(allocator: std.mem.Allocator) !void {
    const path = try freshPath(allocator, "reorg-replay");
    defer allocator.free(path);
    const zero = [_]u8{0} ** 32;
    const block0 = try buildCoinbaseBlock(allocator, zero, 11);
    defer allocator.free(block0.raw);
    const block1 = try buildCoinbaseBlock(allocator, block0.hash, 12);
    defer allocator.free(block1.raw);
    const block2 = try buildCoinbaseBlock(allocator, block1.hash, 13);
    defer allocator.free(block2.raw);
    var hash1: [32]u8 = undefined;
    var hash2: [32]u8 = undefined;
    var count1: i64 = 0;
    {
        var db = try Native.open(allocator, path, .{});
        var utxos: i64 = 0;
        utxos = try connectBuilt(&db, allocator, 0, block0, utxos);
        utxos = try connectBuilt(&db, allocator, 1, block1, utxos);
        hash1 = db.setHash();
        count1 = utxos;
        _ = try connectBuilt(&db, allocator, 2, block2, utxos);
        hash2 = db.setHash();
        _ = try db.disconnectTip(allocator);
        db.close();
    }
    {
        var db = try Native.open(allocator, path, .{});
        defer db.close();
        try std.testing.expectEqualSlices(u8, &hash1, &db.setHash());
        try std.testing.expectEqual(count1, db.utxo_count);
        const again = try connectBuilt(&db, allocator, 2, block2, count1);
        try std.testing.expectEqualSlices(u8, &hash2, &db.setHash());
        _ = try db.disconnectTip(allocator);
        try db.writeSnapshot();
        try std.testing.expectEqualSlices(u8, &hash1, &db.setHash());
        _ = again;
    }
    {
        var db = try Native.open(allocator, path, .{});
        defer db.close();
        try std.testing.expectEqualSlices(u8, &hash1, &db.setHash());
        try std.testing.expectEqual(count1, db.utxo_count);
        try std.testing.expectEqualSlices(u8, &hash1, &(try db.setHashAt(1)).?);
    }
}
