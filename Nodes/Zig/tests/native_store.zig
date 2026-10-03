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
