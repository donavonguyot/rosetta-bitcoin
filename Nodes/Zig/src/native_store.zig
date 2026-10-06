//! Native testnet4 chainstate: commit log, snapshot, and the in-memory UTXO map.
//! After open, complete log records are applied and the flat files end at the committed extent.
//! `std.HashMap` linear-probes `hash & mask` and does not mix a custom hash. Outputs of one
//! transaction differ only in vout, so an unmixed `txid[0..8] XOR vout` clusters: 22 rehashes
//! at about 78 s, against 0.7 s after the odd multiply, and misses at height 50000 cost about
//! 4 µs. `zig_native_store_hash_mix_host_2026-10-06.json` records those 22 rehashes at 702 ms.
//! The capacity hint that hid the clustering was a symptom fix and was removed from the shadow
//! recipes (commit 91e5d2d). A zero hint still leaves doubling alone.
//! Snapshots run every 10000 blocks and `snapshot_ms` stays outside `commit`.
//! Replay skips by sequence, and by height after a snapshot, covering the rename-before-truncate
//! window (test "snapshot rename before log truncate does not double apply").
//! Flat files truncate to the committed extent (test "flat files truncate to the last committed extent").
//! `recordBlock` is its own log record (test "record block survives restart before connect").
//! Delete preimages stay in the commit record so replay can check them.
//! Durability class is `process_crash`. `--fsync` is the power-loss class (storage-proof).
//! RocksDB compresses blocks. Native files do not. The 100k datadir was 9.6 GB native against
//! 6.0 GB RocksDB; testnet4 spam compresses far more than the 10 to 20 percent mainnet expectation
//! (`zig_native_store_hash_mix_host_2026-10-06.json`).
//! Does not validate scripts, proof of work, or the next nBits.

const std = @import("std");
const root = @import("root.zig");
const store = root.store;

/// Test hook that fails a commit just before or just after the log append.
/// before_append drops the commit. after_append keeps it.
/// test "crash before append drops the commit and after append keeps it"
pub const CrashPoint = enum { none, before_append, after_append };

/// Snapshot interval, fsync, crash injection, and the optional UTXO reserve.
/// snapshot_every 0 disables snapshots. fsync_enabled is power-loss; the default is process_crash.
/// storage-proof
pub const OpenOptions = struct {
    snapshot_every: u32 = 10000,
    fsync_enabled: bool = false,
    crash_after_block: ?u32 = null,
    crash_point: CrashPoint = .none,
    /// CLI crash points exit 86. Tests set this false and get `error.CrashInjected`.
    crash_exit: bool = true,
    /// 0 keeps HashMap doubling. A positive hint reserves that many entries at open.
    utxo_capacity_hint: u32 = 0,
};

const kind_meta: u8 = 1;
const kind_record_block: u8 = 2;
const kind_commit: u8 = 3;

const build_options = @import("crypto_options");
const utxo_hash_wyhash = std.mem.eql(u8, build_options.utxo_hash, "wyhash");
const utxo_hash_mix = std.mem.eql(u8, build_options.utxo_hash, "txid64_mix");

/// txid64_mix unless this binary was built to compare wyhash or the unmixed hash.
/// The mix is the default because the unmixed hash clustered.
/// zig_native_store_hash_mix_host_2026-10-06.json
pub fn utxoHashName() []const u8 {
    if (utxo_hash_wyhash) return "wyhash";
    if (utxo_hash_mix) return "txid64_mix";
    return "txid64";
}

const OutpointContext = struct {
    /// Outpoint hash for the UTXO map.
    /// std.HashMap does not mix. The odd multiply keeps one transaction's outputs out of one probe run.
    /// zig_native_store_hash_mix_host_2026-10-06.json
    pub fn hash(_: @This(), key: root.types.Outpoint) u64 {
        if (comptime utxo_hash_wyhash) {
            if (@sizeOf(root.types.Outpoint) != 36) @compileError("outpoint hash expects 36 bytes");
            return std.hash.Wyhash.hash(0, std.mem.asBytes(&key));
        }
        const mixed = std.mem.readInt(u64, key.txid[0..8], .little) ^ @as(u64, key.vout);
        if (comptime utxo_hash_mix) return mixed *% 0x9E3779B97F4A7C15;
        return mixed;
    }

    /// Outpoints match on txid and vout. Padding is not part of the key.
    /// test "native shadow create and spend matches rocksdb bytes"
    pub fn eql(_: @This(), a: root.types.Outpoint, b: root.types.Outpoint) bool {
        return std.mem.eql(u8, &a.txid, &b.txid) and a.vout == b.vout;
    }
};

const UtxoMap = std.HashMap(root.types.Outpoint, []u8, OutpointContext, 80);

const Extent = struct {
    offset: u64,
    len: u32,
};

const BlockLoc = struct {
    raw: Extent,
    header: Extent,
    display_hash: [64]u8,
};

/// Open native chainstate: commit log, flat files, and the UTXO map.
/// After open, complete records are applied and flat files end at the committed extent.
/// test "native restart replays the commit log"
pub const NativeStore = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    options: OpenOptions,
    log_fd: std.c.fd_t = -1,
    blocks_fd: std.c.fd_t = -1,
    headers_fd: std.c.fd_t = -1,
    undo_fd: std.c.fd_t = -1,
    utxos: UtxoMap,
    meta: std.StringHashMap([]u8),
    blocks: std.AutoHashMap(u32, BlockLoc),
    undos: std.AutoHashMap(u32, Extent),
    set_hash: store.SetHash = store.emptySetHash(),
    utxo_count: i64 = 0,
    validated_height: i64 = -1,
    last_seq: u64 = 0,
    snapshot_height: i64 = -1,
    log_len: u64 = 0,
    blocks_len: u64 = 0,
    headers_len: u64 = 0,
    undo_len: u64 = 0,
    last_record_off: u64 = 0,
    snapshot_count: u32 = 0,
    snapshot_bytes: u64 = 0,
    rehash_count: u32 = 0,
    rehash_ms: i64 = 0,
    header_index: root.consensus_context.HeaderIndex = .{},

    /// Open the datadir, load the snapshot, replay the log, then truncate flat files.
    /// A torn tail is ignored. The map matches the last complete record.
    /// test "native restart replays the commit log"
    pub fn open(allocator: std.mem.Allocator, path: []const u8, options: OpenOptions) !NativeStore {
        try root.datadir.rejectUnapprovedRuntimeDbArtifacts(path);
        var self = NativeStore{
            .allocator = allocator,
            .path = try allocator.dupe(u8, path),
            .options = options,
            .utxos = UtxoMap.init(allocator),
            .meta = std.StringHashMap([]u8).init(allocator),
            .blocks = std.AutoHashMap(u32, BlockLoc).init(allocator),
            .undos = std.AutoHashMap(u32, Extent).init(allocator),
        };
        errdefer self.close();
        try mkdir(self.path);
        self.log_fd = try openAt(self.path, "commit.log", true);
        self.blocks_fd = try openAt(self.path, "blocks.dat", true);
        self.headers_fd = try openAt(self.path, "headers.dat", true);
        self.undo_fd = try openAt(self.path, "undo.dat", true);
        try self.loadSnapshot();
        try self.replayLog();
        try self.truncateFlatFiles();
        try self.loadCounters();
        try self.reserveUtxoCapacity();
        try self.loadHeaderIndex();
        return self;
    }

    /// Free the map and close the log and flat-file descriptors.
    /// The datadir stays. A later open replays it.
    /// test "native restart replays the commit log"
    pub fn close(self: *NativeStore) void {
        var utxo_it = self.utxos.iterator();
        while (utxo_it.next()) |entry| self.allocator.free(entry.value_ptr.*);
        self.utxos.deinit();
        var meta_it = self.meta.iterator();
        while (meta_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.meta.deinit();
        self.blocks.deinit();
        self.undos.deinit();
        self.header_index.deinit(self.allocator);
        if (self.log_fd >= 0) _ = std.c.close(self.log_fd);
        if (self.blocks_fd >= 0) _ = std.c.close(self.blocks_fd);
        if (self.headers_fd >= 0) _ = std.c.close(self.headers_fd);
        if (self.undo_fd >= 0) _ = std.c.close(self.undo_fd);
        self.log_fd = -1;
        self.blocks_fd = -1;
        self.headers_fd = -1;
        self.undo_fd = -1;
        self.allocator.free(self.path);
    }

    /// Set hash after the last applied commit.
    /// Shadow comparison reads this. Replay must reproduce it.
    /// test "direct apply and replay apply match map bytes and set hash"
    pub fn setHash(self: *NativeStore) store.SetHash {
        return self.set_hash;
    }

    /// Append a metadata record and apply it. UTXO creates go through commit, not here.
    /// The caller keeps the slices it passed.
    /// test "native shadow create and spend matches rocksdb bytes"
    pub fn put(self: *NativeStore, key: []const u8, value: []const u8) !void {
        var payload = Buf.init(self.allocator);
        defer payload.deinit();
        try payload.putU8(kind_meta);
        try payload.putU64(self.last_seq + 1);
        try payload.putU32(@intCast(key.len));
        try payload.bytes(key);
        try payload.putU32(@intCast(value.len));
        try payload.bytes(value);
        try self.appendRecord(payload.slice());
        try self.applyPayload(payload.slice());
    }

    /// Owned bytes for one codec key, or null when it is absent.
    /// Prefix `u` is a UTXO, `r` raw block, `h` header, `b` display hash, `d` undo. Anything else is metadata.
    /// test "native shadow create and spend matches rocksdb bytes"
    pub fn getAlloc(self: *NativeStore, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
        if (key.len == 0) return null;
        switch (key[0]) {
            'u' => {
                const outpoint = try decodeOutpoint(key);
                const value = self.utxos.get(outpoint) orelse return null;
                return try allocator.dupe(u8, value);
            },
            'r' => {
                const loc = self.blocks.get(try keyHeight(key)) orelse return null;
                return try readFile(allocator, self.blocks_fd, loc.raw);
            },
            'h' => {
                const loc = self.blocks.get(try keyHeight(key)) orelse return null;
                return try readFile(allocator, self.headers_fd, loc.header);
            },
            'b' => {
                const loc = self.blocks.get(try keyHeight(key)) orelse return null;
                return try allocator.dupe(u8, &loc.display_hash);
            },
            'd' => {
                const loc = self.undos.get(try keyHeight(key)) orelse return null;
                return try readFile(allocator, self.undo_fd, loc);
            },
            else => {
                const value = self.meta.get(key) orelse return null;
                return try allocator.dupe(u8, value);
            },
        }
    }

    /// The 80-byte header at a height, or null past the stored tip.
    /// Bytes come from headers.dat at the extent recordBlock saved.
    /// test "record block survives restart before connect"
    pub fn headerAt(self: *NativeStore, allocator: std.mem.Allocator, height: u32) !?[80]u8 {
        const key = try root.codec.encodeHeaderKey(allocator, "testnet4", height);
        defer allocator.free(key);
        const raw = (try self.getAlloc(allocator, key)) orelse return null;
        defer allocator.free(raw);
        if (raw.len < 80) return error.ShortHeader;
        var header: [80]u8 = undefined;
        @memcpy(header[0..], raw[0..80]);
        return header;
    }

    /// Raw UTXO values in request order. A missing outpoint stays null.
    /// Same-block spends are not in this list; connect resolved those already.
    /// test "native shadow create and spend matches rocksdb bytes"
    pub fn getManyUtxoRaw(self: *NativeStore, allocator: std.mem.Allocator, chain: []const u8, outpoints: []const root.types.Outpoint, stats: ?*root.connect.UtxoLoadStats) ![]?[]u8 {
        const out = try allocator.alloc(?[]u8, outpoints.len);
        errdefer allocator.free(out);
        const key_len = try root.codec.encodedUtxoKeyLen(chain);
        if (stats) |s| {
            s.lookup_count += outpoints.len;
            s.key_bytes += key_len * outpoints.len;
        }
        var copied: usize = 0;
        errdefer {
            for (out[0..copied]) |value| if (value) |bytes| allocator.free(bytes);
        }
        for (outpoints, 0..) |outpoint, i| {
            const started = monoNs();
            if (self.utxos.get(outpoint)) |value| {
                if (stats) |s| s.value_bytes += value.len;
                out[i] = try allocator.dupe(u8, value);
                copied += 1;
                if (stats) |s| {
                    s.utxo_hit_count += 1;
                    s.utxo_hit_ns += monoNs() - started;
                }
            } else {
                out[i] = null;
                if (stats) |s| {
                    s.utxo_miss_count += 1;
                    s.utxo_miss_ns += monoNs() - started;
                }
            }
        }
        return out;
    }

    /// Decoded UTXOs plus hit and miss timing for the lookups connect issued.
    /// Order matches the request. A miss is an absent outpoint, not a same-block spend.
    /// zig_native_store_miss_cost_host_2026-10-05.json
    pub fn getManyUtxosWithStats(self: *NativeStore, allocator: std.mem.Allocator, chain: []const u8, outpoints: []const root.types.Outpoint, stats: ?*root.connect.UtxoLoadStats) ![]?root.types.StoredUtxo {
        const raw = try self.getManyUtxoRaw(allocator, chain, outpoints, stats);
        defer {
            for (raw) |value| if (value) |bytes| allocator.free(bytes);
            allocator.free(raw);
        }
        const out = try allocator.alloc(?root.types.StoredUtxo, outpoints.len);
        var decoded: usize = 0;
        errdefer {
            for (out[0..decoded]) |value| if (value) |utxo| utxo.deinit(allocator);
            allocator.free(out);
        }
        for (outpoints, raw, 0..) |outpoint, value, i| {
            out[i] = if (value) |bytes| try root.codec.decodeUtxoValue(allocator, outpoint, bytes) else null;
            decoded += 1;
        }
        return out;
    }

    /// Append raw block bytes and a log record of their own, before connect commits spends.
    /// A restart before connect still finds the block.
    /// test "record block survives restart before connect"
    pub fn recordBlock(self: *NativeStore, allocator: std.mem.Allocator, height: u32, hash: [32]u8, raw: []const u8) !void {
        const raw_off = self.blocks_len;
        try pwriteAll(self.blocks_fd, raw, raw_off);
        const header_len: u32 = @intCast(@min(raw.len, 80));
        const header_off = self.headers_len;
        try pwriteAll(self.headers_fd, raw[0..header_len], header_off);
        try self.syncFd(self.blocks_fd);
        try self.syncFd(self.headers_fd);
        const display = try root.crypto.displayHashAlloc(allocator, hash[0..]);
        defer allocator.free(display);
        if (display.len != 64) return error.BadKey;
        var payload = Buf.init(self.allocator);
        defer payload.deinit();
        try payload.putU8(kind_record_block);
        try payload.putU64(self.last_seq + 1);
        try payload.putU32(height);
        try payload.bytes(&hash);
        try payload.putU64(raw_off);
        try payload.putU32(@intCast(raw.len));
        try payload.putU64(header_off);
        try payload.putU32(header_len);
        try payload.bytes(display);
        try self.appendRecord(payload.slice());
        try self.applyPayload(payload.slice());
        if (header_len >= 80) {
            var header_bytes: [80]u8 = undefined;
            @memcpy(header_bytes[0..], raw[0..80]);
            try self.header_index.set(self.allocator, height, root.consensus_context.fieldsFromHeader(&header_bytes));
        }
    }

    /// Header time and bits are already loaded by open.
    /// Connect calls this on every store. Here it does not re-read the files.
    /// test "record block survives restart before connect"
    pub fn ensureHeaderIndex(_: *NativeStore) !void {}

    /// The dense header index connect and the mempool use for MTP.
    /// Filled from headers.dat at open and from recordBlock after that.
    /// test "header index median matches the header walk"
    pub fn headerIndex(self: *NativeStore) root.consensus_context.HeaderIndex {
        return self.header_index;
    }

    /// Median of up to 11 indexed timestamps ending at a height.
    /// BIP113 locktime and the template both use this. Height 0 is 0.
    /// test "header index median matches the header walk"
    pub fn medianTimePast(self: *NativeStore, height: u32) !u32 {
        return self.header_index.mtp(height);
    }

    /// Indexed time and nBits at a height, or null when that height was not stored.
    /// nBits checks read this instead of re-parsing the header.
    /// test "record block survives restart before connect"
    pub fn headerFields(self: *NativeStore, height: u32) !?root.consensus_context.HeaderFields {
        return self.header_index.fields(height);
    }

    fn loadHeaderIndex(self: *NativeStore) !void {
        if (self.blocks.count() == 0 or self.headers_len == 0) return;
        if (self.headers_len > std.math.maxInt(u32)) return error.NativeIo;
        const bytes = try readFile(self.allocator, self.headers_fd, .{ .offset = 0, .len = @intCast(self.headers_len) });
        defer self.allocator.free(bytes);
        var max_height: u32 = 0;
        var it = self.blocks.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.* > max_height) max_height = entry.key_ptr.*;
        }
        var height: u32 = 0;
        while (height <= max_height) : (height += 1) {
            const loc = self.blocks.get(height) orelse {
                try self.header_index.set(self.allocator, height, .{ .time = 0, .bits = 0 });
                continue;
            };
            if (loc.header.len < 80) return error.ShortHeader;
            const start: usize = @intCast(loc.header.offset);
            if (start + 80 > bytes.len) return error.ShortHeader;
            var header: [80]u8 = undefined;
            @memcpy(header[0..], bytes[start..][0..80]);
            try self.header_index.set(self.allocator, height, root.consensus_context.fieldsFromHeader(&header));
        }
    }

    /// Apply a prepared chainstate commit and fold its UTXOs into the set hash.
    /// The log record includes delete preimages so replay can check them.
    /// test "direct apply and replay apply match map bytes and set hash"
    pub fn commitBlock(self: *NativeStore, allocator: std.mem.Allocator, commit: root.types.ChainstateBlockCommit) !root.connect.CommitTimings {
        var timings = root.connect.CommitTimings{};
        var next_hash = self.set_hash;
        const spend_started = store.nowMs();
        try root.connect.foldSpends(allocator, &next_hash, commit.spent_external, commit.undo_entries);
        timings.set_hash_fold += elapsedMs(spend_started);

        var puts = std.ArrayList(StagedPut).empty;
        defer {
            for (puts.items) |item| allocator.free(item.value);
            puts.deinit(allocator);
        }
        const put_started = store.nowMs();
        var put_fold: i64 = 0;
        for (commit.created_utxos) |created| {
            const value = try root.codec.encodeUtxoValue(allocator, created.utxo);
            const hash_started = store.nowMs();
            const key = try root.codec.encodeUtxoKey(allocator, "testnet4", created.outpoint);
            defer allocator.free(key);
            store.foldSetHash(&next_hash, key, value);
            put_fold += elapsedMs(hash_started);
            try puts.append(allocator, .{ .outpoint = created.outpoint, .value = value });
        }
        const prepare = elapsedMs(put_started) - put_fold;
        timings.utxo_put_prepare += if (prepare < 0) 0 else prepare;
        timings.set_hash_fold += put_fold;
        try self.finishCommit(allocator, commit.height, commit.block_hash, commit.spent_external, commit.undo_entries, puts.items, commit.new_utxo_count, next_hash, &timings);
        return timings;
    }

    /// Apply spends and creates from a block connect has already checked.
    /// Direct apply and a later replay produce the same map bytes and set hash.
    /// test "direct apply and replay apply match map bytes and set hash"
    pub fn commitConnectedBlock(
        self: *NativeStore,
        allocator: std.mem.Allocator,
        height: u32,
        block_hash: [32]u8,
        spent_external: []const root.types.Outpoint,
        undo_entries: []const root.types.UndoEntry,
        transactions: []const root.tx.Transaction,
        txids: []const [32]u8,
        spent: *std.AutoHashMap(root.types.Outpoint, void),
        new_utxo_count: i64,
    ) !root.connect.CommitTimings {
        var timings = root.connect.CommitTimings{};
        var next_hash = self.set_hash;
        const spend_started = store.nowMs();
        try root.connect.foldSpends(allocator, &next_hash, spent_external, undo_entries);
        timings.set_hash_fold += elapsedMs(spend_started);

        var puts = std.ArrayList(StagedPut).empty;
        defer {
            for (puts.items) |item| allocator.free(item.value);
            puts.deinit(allocator);
        }
        const put_started = store.nowMs();
        var put_fold: i64 = 0;
        for (transactions, 0..) |transaction, tx_index| {
            if (height == 0 and tx_index == 0) continue;
            for (transaction.outputs, 0..) |output, vout| {
                if (output.value < 0) return error.NegativeOutputValue;
                if (!root.connect.isSpendableOutput(output.script_pubkey)) continue;
                const outpoint = root.types.Outpoint{ .txid = txids[tx_index], .vout = @intCast(vout) };
                if (spent.contains(outpoint)) continue;
                const value = try root.codec.encodeUtxoValue(allocator, .{
                    .height = height,
                    .vout = @intCast(vout),
                    .value_sats = @intCast(output.value),
                    .coinbase = tx_index == 0,
                    .script_pubkey = output.script_pubkey,
                });
                const hash_started = store.nowMs();
                const key = try root.codec.encodeUtxoKey(allocator, "testnet4", outpoint);
                defer allocator.free(key);
                store.foldSetHash(&next_hash, key, value);
                put_fold += elapsedMs(hash_started);
                try puts.append(allocator, .{ .outpoint = outpoint, .value = value });
            }
        }
        const prepare = elapsedMs(put_started) - put_fold;
        timings.utxo_put_prepare += if (prepare < 0) 0 else prepare;
        timings.set_hash_fold += put_fold;
        try self.finishCommit(allocator, height, block_hash, spent_external, undo_entries, puts.items, new_utxo_count, next_hash, &timings);
        return timings;
    }

    /// Named chainstate fields as owned strings.
    /// The caller frees them with deinitMetadata.
    /// storage-proof
    pub fn readMetadata(self: *NativeStore, allocator: std.mem.Allocator) !root.types.Metadata {
        const validated_height = try self.metaI64(allocator, "validated_height", -1);
        return .{
            .validated_height = validated_height,
            .validated_hash = try self.metaString(allocator, "validated_hash", ""),
            .header_height = try self.metaI64(allocator, "header_height", validated_height),
            .header_hash = try self.metaString(allocator, "header_hash", ""),
            .stored_block_height = try self.metaI64(allocator, "stored_block_height", validated_height),
            .stored_block_hash = try self.metaString(allocator, "stored_block_hash", ""),
            .chainstate_backend = try self.metaString(allocator, "chainstate_backend", "native"),
            .chainstate_status = try self.metaString(allocator, "chainstate_status", "missing"),
            .sync_status = try self.metaString(allocator, "sync_status", "starting"),
            .chainstate_utxo_count = try self.metaI64(allocator, "chainstate_utxo_count", 0),
            .chainstate_set_hash = try store.formatSetHash(allocator, self.set_hash),
            .current_blocker = try self.metaString(allocator, "current_blocker", ""),
        };
    }

    /// Free the strings readMetadata returned.
    /// The store itself stays open.
    /// storage-proof
    pub fn deinitMetadata(_: *NativeStore, allocator: std.mem.Allocator, meta: root.types.Metadata) void {
        allocator.free(meta.validated_hash);
        allocator.free(meta.header_hash);
        allocator.free(meta.stored_block_hash);
        allocator.free(meta.chainstate_backend);
        allocator.free(meta.chainstate_status);
        allocator.free(meta.sync_status);
        allocator.free(meta.chainstate_set_hash);
        allocator.free(meta.current_blocker);
    }

    /// One-key write used by the storage proof, not by block connect.
    /// Durability class of that proof is process_crash unless fsync was set.
    /// storage-proof
    pub fn writeBatchSmoke(self: *NativeStore, allocator: std.mem.Allocator) !void {
        var txid: [32]u8 = undefined;
        for (&txid, 0..) |*byte, i| byte.* = @intCast(i);
        const script_bytes = try root.codec.fromHexAlloc(allocator, "76a914000102030405060708090a0b0c0d0e0f1011121388ac");
        defer allocator.free(script_bytes);
        const utxo = root.types.StoredUtxo{
            .height = 1,
            .vout = 1,
            .value_sats = 5_000_000_000,
            .coinbase = true,
            .script_pubkey = script_bytes,
        };
        const created = root.types.CreatedUtxo{ .outpoint = .{ .txid = txid, .vout = 1 }, .utxo = utxo };
        const block_hash = [_]u8{2} ** 32;
        _ = try self.commitBlock(allocator, .{
            .height = 2,
            .block_hash = block_hash,
            .spent_external = &.{},
            .created_utxos = &.{created},
            .undo_entries = &.{},
            .new_utxo_count = 1,
        });
        var raw = [_]u8{0} ** 80;
        raw[0] = 1;
        try self.recordBlock(allocator, 2, block_hash, &raw);
    }

    /// Replace snapshot.bin by rename, then truncate the log.
    /// Replay must tolerate a crash in that window and must not apply the snapshotted records twice.
    /// test "snapshot rename before log truncate does not double apply"
    pub fn writeSnapshot(self: *NativeStore) !void {
        if (self.validated_height < 0) return;
        var body = Buf.init(self.allocator);
        defer body.deinit();
        try body.bytes("ZN01");
        try body.putU32(1);
        try body.putU64(self.last_seq);
        try body.putU32(@intCast(self.validated_height));
        try body.bytes(&self.set_hash);
        try body.putI64(self.utxo_count);
        try body.putU64(self.blocks_len);
        try body.putU64(self.headers_len);
        try body.putU64(self.undo_len);
        try body.putU32(@intCast(self.utxos.count()));
        var utxo_it = self.utxos.iterator();
        while (utxo_it.next()) |entry| {
            try body.bytes(&entry.key_ptr.txid);
            try body.putU32(entry.key_ptr.vout);
            try body.putU32(@intCast(entry.value_ptr.*.len));
            try body.bytes(entry.value_ptr.*);
        }
        try body.putU32(@intCast(self.meta.count()));
        var meta_it = self.meta.iterator();
        while (meta_it.next()) |entry| {
            try body.putU32(@intCast(entry.key_ptr.*.len));
            try body.bytes(entry.key_ptr.*);
            try body.putU32(@intCast(entry.value_ptr.*.len));
            try body.bytes(entry.value_ptr.*);
        }
        try body.putU32(@intCast(self.blocks.count()));
        var block_it = self.blocks.iterator();
        while (block_it.next()) |entry| {
            try body.putU32(entry.key_ptr.*);
            try body.putU64(entry.value_ptr.raw.offset);
            try body.putU32(entry.value_ptr.raw.len);
            try body.putU64(entry.value_ptr.header.offset);
            try body.putU32(entry.value_ptr.header.len);
            try body.bytes(&entry.value_ptr.display_hash);
        }
        try body.putU32(@intCast(self.undos.count()));
        var undo_it = self.undos.iterator();
        while (undo_it.next()) |entry| {
            try body.putU32(entry.key_ptr.*);
            try body.putU64(entry.value_ptr.offset);
            try body.putU32(entry.value_ptr.len);
        }
        var crc_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &crc_bytes, std.hash.Crc32.hash(body.slice()), .little);
        try body.bytes(&crc_bytes);

        const tmp = try std.fs.path.join(self.allocator, &.{ self.path, "snapshot.bin.tmp" });
        defer self.allocator.free(tmp);
        const final = try std.fs.path.join(self.allocator, &.{ self.path, "snapshot.bin" });
        defer self.allocator.free(final);
        const tmp_fd = try openPath(tmp, true);
        defer _ = std.c.close(tmp_fd);
        try pwriteAll(tmp_fd, body.slice(), 0);
        if (std.c.ftruncate(tmp_fd, @intCast(body.slice().len)) != 0) return error.NativeIo;
        if (std.c.fsync(tmp_fd) != 0) return error.NativeIo;
        const tmp_z = try self.allocator.dupeZ(u8, tmp);
        defer self.allocator.free(tmp_z);
        const final_z = try self.allocator.dupeZ(u8, final);
        defer self.allocator.free(final_z);
        if (std.c.rename(tmp_z, final_z) != 0) return error.NativeIo;
        if (std.c.ftruncate(self.log_fd, 0) != 0) return error.NativeIo;
        self.log_len = 0;
        self.last_record_off = 0;
        self.snapshot_height = self.validated_height;
        self.snapshot_count += 1;
        self.snapshot_bytes = body.slice().len;
    }

    /// Read the commit log as stored, including a torn tail.
    /// test "torn commit record and one corrupted byte keep the previous tip"
    pub fn testingReadLog(self: *NativeStore, allocator: std.mem.Allocator) ![]u8 {
        const out = try allocator.alloc(u8, @intCast(self.log_len));
        if (out.len > 0) try preadAll(self.log_fd, out, 0);
        return out;
    }

    /// Overwrite the open log and its length so a test can plant a torn tail.
    /// test "torn commit record and one corrupted byte keep the previous tip"
    pub fn testingWriteLogFile(self: *NativeStore, bytes: []const u8) !void {
        if (bytes.len > 0) try pwriteAll(self.log_fd, bytes, 0);
        if (std.c.ftruncate(self.log_fd, @intCast(bytes.len)) != 0) return error.NativeIo;
        self.log_len = bytes.len;
    }

    /// Replace the log file the way a crash between snapshot rename and truncate would.
    /// test "snapshot rename before log truncate does not double apply"
    pub fn testingRewriteLog(dir: []const u8, bytes: []const u8, len: usize) !void {
        const fd = try openAt(dir, "commit.log", true);
        defer _ = std.c.close(fd);
        if (bytes.len > 0) try pwriteAll(fd, bytes, 0);
        if (std.c.ftruncate(fd, @intCast(len)) != 0) return error.NativeIo;
    }

    /// Append bytes past the committed end so truncate has something to cut.
    /// test "flat files truncate to the last committed extent"
    pub fn testingExtend(self: *NativeStore, which: enum { blocks, headers, undo, log }, extra: []const u8) !void {
        const fd = switch (which) {
            .blocks => self.blocks_fd,
            .headers => self.headers_fd,
            .undo => self.undo_fd,
            .log => self.log_fd,
        };
        const end = try fileLen(fd);
        try pwriteAll(fd, extra, end);
    }

    fn finishCommit(
        self: *NativeStore,
        allocator: std.mem.Allocator,
        height: u32,
        block_hash: [32]u8,
        spent: []const root.types.Outpoint,
        undo_entries: []const root.types.UndoEntry,
        puts: []const StagedPut,
        new_utxo_count: i64,
        next_hash: store.SetHash,
        timings: *root.connect.CommitTimings,
    ) !void {
        const undo_started = store.nowMs();
        const undo_bytes = try root.codec.encodeUndoValue(allocator, undo_entries);
        defer allocator.free(undo_bytes);
        const undo_off = self.undo_len;
        try pwriteAll(self.undo_fd, undo_bytes, undo_off);
        try self.syncFd(self.undo_fd);
        timings.undo_put_prepare += elapsedMs(undo_started);

        const metadata_started = store.nowMs();
        var payload = Buf.init(self.allocator);
        defer payload.deinit();
        try payload.putU8(kind_commit);
        try payload.putU64(self.last_seq + 1);
        try payload.putU32(height);
        try payload.bytes(&block_hash);
        try payload.bytes(&next_hash);
        try payload.putI64(new_utxo_count);
        try payload.putU64(undo_off);
        try payload.putU32(@intCast(undo_bytes.len));
        try payload.putU32(@intCast(puts.len));
        try payload.putU32(@intCast(spent.len));
        for (puts) |item| {
            try payload.bytes(&item.outpoint.txid);
            try payload.putU32(item.outpoint.vout);
            try payload.putU32(@intCast(item.value.len));
            try payload.bytes(item.value);
        }
        for (undo_entries) |entry| {
            const preimage = try root.codec.encodeUtxoValue(allocator, entry.utxo);
            defer allocator.free(preimage);
            try payload.bytes(&entry.outpoint.txid);
            try payload.putU32(entry.outpoint.vout);
            try payload.putU32(@intCast(preimage.len));
            try payload.bytes(preimage);
        }
        timings.metadata_put_prepare += elapsedMs(metadata_started);

        try self.crashCommit(height, .before_append);
        const write_started = store.nowMs();
        try self.appendRecord(payload.slice());
        timings.rocksdb_write += elapsedMs(write_started);
        try self.crashCommit(height, .after_append);
        try self.applyCommitDirect(height, block_hash, spent, puts, new_utxo_count, next_hash, undo_off, @intCast(undo_bytes.len));
        if (self.options.snapshot_every != 0 and height > 0 and height % self.options.snapshot_every == 0) {
            const snapshot_started = store.nowMs();
            try self.writeSnapshot();
            timings.snapshot += elapsedMs(snapshot_started);
        }
    }

    fn applyCommitDirect(
        self: *NativeStore,
        height: u32,
        block_hash: [32]u8,
        spent: []const root.types.Outpoint,
        puts: []const StagedPut,
        new_utxo_count: i64,
        next_hash: store.SetHash,
        undo_off: u64,
        undo_len: u32,
    ) !void {
        for (spent) |outpoint| {
            const removed = self.utxos.fetchRemove(outpoint) orelse return error.MissingUtxo;
            self.allocator.free(removed.value);
        }
        for (puts) |item| try self.putUtxoBytes(item.outpoint, item.value);
        try self.putCommitMeta(height, block_hash, new_utxo_count, next_hash);
        try self.undos.put(height, .{ .offset = undo_off, .len = undo_len });
        self.undo_len = undo_off + undo_len;
        self.set_hash = next_hash;
        self.utxo_count = new_utxo_count;
        self.validated_height = height;
        self.last_seq += 1;
    }

    fn crashCommit(self: *NativeStore, height: u32, point: CrashPoint) !void {
        const target = self.options.crash_after_block orelse return;
        if (target != height or self.options.crash_point != point) return;
        if (self.options.crash_exit) std.process.exit(86);
        return error.CrashInjected;
    }

    fn appendRecord(self: *NativeStore, payload: []const u8) !void {
        if (payload.len > std.math.maxInt(u32)) return error.RecordTooLarge;
        const framed = try self.allocator.alloc(u8, 8 + payload.len);
        defer self.allocator.free(framed);
        std.mem.writeInt(u32, framed[0..4], @intCast(payload.len), .little);
        @memcpy(framed[4..][0..payload.len], payload);
        std.mem.writeInt(u32, framed[4 + payload.len ..][0..4], std.hash.Crc32.hash(framed[0 .. 4 + payload.len]), .little);
        const off = self.log_len;
        try pwriteAll(self.log_fd, framed, off);
        try self.syncFd(self.log_fd);
        self.last_record_off = off;
        self.log_len = off + framed.len;
    }

    fn applyPayload(self: *NativeStore, payload: []const u8) !void {
        var rd = Rd{ .bytes = payload };
        const kind = try rd.readU8();
        const seq = try rd.readU64();
        switch (kind) {
            kind_meta => try self.applyMeta(&rd),
            kind_record_block => try self.applyRecordBlock(&rd),
            kind_commit => try self.applyCommit(&rd),
            else => return error.BadRecord,
        }
        self.last_seq = seq;
    }

    fn applyMeta(self: *NativeStore, rd: *Rd) !void {
        const key_len = try rd.readU32();
        const key = try rd.take(key_len);
        const value_len = try rd.readU32();
        const value = try rd.take(value_len);
        if (key.len > 0 and key[0] == 'u') {
            try self.putUtxoBytes(try decodeOutpoint(key), value);
            return;
        }
        try self.putMeta(key, value);
    }

    fn applyRecordBlock(self: *NativeStore, rd: *Rd) !void {
        const height = try rd.readU32();
        _ = try rd.take(32);
        const raw_off = try rd.readU64();
        const raw_len = try rd.readU32();
        const header_off = try rd.readU64();
        const header_len = try rd.readU32();
        const display = try rd.take(64);
        if (raw_off != self.blocks_len or header_off != self.headers_len) return error.ExtentMismatch;
        var loc = BlockLoc{
            .raw = .{ .offset = raw_off, .len = raw_len },
            .header = .{ .offset = header_off, .len = header_len },
            .display_hash = undefined,
        };
        @memcpy(&loc.display_hash, display);
        try self.blocks.put(height, loc);
        self.blocks_len = raw_off + raw_len;
        self.headers_len = header_off + header_len;
    }

    fn applyCommit(self: *NativeStore, rd: *Rd) !void {
        const height = try rd.readU32();
        const block_hash = try rd.take(32);
        const logged_hash = try rd.take(32);
        const new_count = try rd.readI64();
        const undo_off = try rd.readU64();
        const undo_len = try rd.readU32();
        const n_puts = try rd.readU32();
        const n_dels = try rd.readU32();
        const puts_at = rd.i;
        var i: u32 = 0;
        while (i < n_puts) : (i += 1) _ = try rd.blobAfterOutpoint();
        const dels_at = rd.i;
        var check = self.set_hash;
        i = 0;
        while (i < n_dels) : (i += 1) {
            const outpoint = try rd.outpoint();
            const preimage = try rd.blob();
            const current = self.utxos.get(outpoint) orelse return error.MissingUtxo;
            // The logged preimage is a replay check. The map already holds the
            // bytes that were folded out; removing this compare drops the check.
            if (!std.mem.eql(u8, current, preimage)) return error.ReplayPreimageMismatch;
            const key = try root.codec.encodeUtxoKey(self.allocator, "testnet4", outpoint);
            defer self.allocator.free(key);
            store.foldSetHash(&check, key, preimage);
        }
        rd.i = puts_at;
        i = 0;
        while (i < n_puts) : (i += 1) {
            const outpoint = try rd.outpoint();
            const value = try rd.blob();
            const key = try root.codec.encodeUtxoKey(self.allocator, "testnet4", outpoint);
            defer self.allocator.free(key);
            store.foldSetHash(&check, key, value);
        }
        if (!std.mem.eql(u8, logged_hash, &check)) return error.SetHashMismatch;
        if (undo_off != self.undo_len) return error.ExtentMismatch;

        rd.i = dels_at;
        i = 0;
        while (i < n_dels) : (i += 1) {
            const outpoint = try rd.outpoint();
            const preimage = try rd.blob();
            const current = self.utxos.get(outpoint) orelse return error.MissingUtxo;
            if (!std.mem.eql(u8, current, preimage)) return error.ReplayPreimageMismatch;
            const removed = self.utxos.fetchRemove(outpoint).?;
            self.allocator.free(removed.value);
        }
        rd.i = puts_at;
        i = 0;
        while (i < n_puts) : (i += 1) {
            const outpoint = try rd.outpoint();
            const value = try rd.blob();
            try self.putUtxoBytes(outpoint, value);
        }
        var hash_bytes: [32]u8 = undefined;
        @memcpy(&hash_bytes, block_hash);
        var set_bytes: store.SetHash = undefined;
        @memcpy(&set_bytes, logged_hash);
        try self.putCommitMeta(height, hash_bytes, new_count, set_bytes);
        try self.undos.put(height, .{ .offset = undo_off, .len = undo_len });
        self.undo_len = undo_off + undo_len;
        self.set_hash = set_bytes;
        self.utxo_count = new_count;
        self.validated_height = height;
    }

    fn putCommitMeta(self: *NativeStore, height: u32, block_hash: [32]u8, utxo_count: i64, set_hash: store.SetHash) !void {
        const tip_key = try root.codec.encodeTipKey(self.allocator, "testnet4");
        defer self.allocator.free(tip_key);
        const tip_value = try root.codec.encodeTipValue(self.allocator, height, block_hash);
        defer self.allocator.free(tip_value);
        try self.putMeta(tip_key, tip_value);
        var height_buf: [16]u8 = undefined;
        const height_value = std.fmt.bufPrint(&height_buf, "{}", .{height}) catch return error.NativeIo;
        try self.putMetaName("validated_height", height_value);
        const display = try root.crypto.displayHashAlloc(self.allocator, block_hash[0..]);
        defer self.allocator.free(display);
        try self.putMetaName("validated_hash", display);
        try self.putMetaName("header_height", height_value);
        try self.putMetaName("header_hash", display);
        try self.putMetaName("stored_block_height", height_value);
        try self.putMetaName("stored_block_hash", display);
        try self.putMetaName("sync_status", "blocks_current");
        try self.putMetaName("chainstate_status", "usable");
        try self.putMetaName("current_blocker", "");
        try self.putMetaName("chainstate_backend", "native");
        var count_buf: [32]u8 = undefined;
        const count_value = std.fmt.bufPrint(&count_buf, "{}", .{utxo_count}) catch return error.NativeIo;
        try self.putMetaName("chainstate_utxo_count", count_value);
        const hex = store.writeSetHashHex(set_hash);
        try self.putMetaName("chainstate_set_hash", &hex);
    }

    fn putMetaName(self: *NativeStore, name: []const u8, value: []const u8) !void {
        const key = try root.codec.encodeMetadataKey(self.allocator, name);
        defer self.allocator.free(key);
        try self.putMeta(key, value);
    }

    fn putMeta(self: *NativeStore, key: []const u8, value: []const u8) !void {
        if (self.meta.getPtr(key)) |slot| {
            self.allocator.free(slot.*);
            slot.* = try self.allocator.dupe(u8, value);
            return;
        }
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);
        try self.meta.put(owned_key, owned_value);
    }

    fn putUtxoBytes(self: *NativeStore, outpoint: root.types.Outpoint, value: []const u8) !void {
        const owned = try self.allocator.dupe(u8, value);
        const before = self.utxos.capacity();
        const grow_started = store.nowMs();
        self.utxos.ensureUnusedCapacity(1) catch |err| {
            self.allocator.free(owned);
            return err;
        };
        self.rehash_ms += elapsedMs(grow_started);
        if (self.utxos.capacity() != before) self.rehash_count += 1;
        const old = self.utxos.fetchPut(outpoint, owned) catch |err| {
            self.allocator.free(owned);
            return err;
        };
        if (old) |kv| self.allocator.free(kv.value);
    }

    fn reserveUtxoCapacity(self: *NativeStore) !void {
        if (self.options.utxo_capacity_hint == 0) return;
        const before = self.utxos.capacity();
        try self.utxos.ensureTotalCapacity(self.options.utxo_capacity_hint);
        if (self.utxos.capacity() != before) self.rehash_count += 1;
    }

    fn loadSnapshot(self: *NativeStore) !void {
        const path = try std.fs.path.join(self.allocator, &.{ self.path, "snapshot.bin" });
        defer self.allocator.free(path);
        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);
        const fd = std.c.open(path_z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(std.c.mode_t, 0));
        if (fd < 0) {
            if (std.c.errno(-1) == .NOENT) return;
            return error.NativeIo;
        }
        defer _ = std.c.close(fd);
        const len = try fileLen(fd);
        const bytes = try self.allocator.alloc(u8, @intCast(len));
        defer self.allocator.free(bytes);
        if (bytes.len > 0) try preadAll(fd, bytes, 0);
        if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..4], "ZN01")) return error.SnapshotCorrupt;
        const stored = std.mem.readInt(u32, bytes[bytes.len - 4 ..][0..4], .little);
        if (stored != std.hash.Crc32.hash(bytes[0 .. bytes.len - 4])) return error.SnapshotCorrupt;
        var rd = Rd{ .bytes = bytes[0 .. bytes.len - 4] };
        _ = try rd.take(4);
        if (try rd.readU32() != 1) return error.SnapshotCorrupt;
        self.last_seq = try rd.readU64();
        self.snapshot_height = try rd.readU32();
        self.validated_height = self.snapshot_height;
        const hash_bytes = try rd.take(32);
        @memcpy(&self.set_hash, hash_bytes);
        self.utxo_count = try rd.readI64();
        self.blocks_len = try rd.readU64();
        self.headers_len = try rd.readU64();
        self.undo_len = try rd.readU64();
        const n_utxo = try rd.readU32();
        if (n_utxo > 0) {
            const before = self.utxos.capacity();
            try self.utxos.ensureTotalCapacity(@intCast(n_utxo));
            if (self.utxos.capacity() != before) self.rehash_count += 1;
        }
        var i: u32 = 0;
        while (i < n_utxo) : (i += 1) {
            const outpoint = try rd.outpoint();
            const value = try rd.blob();
            try self.putUtxoBytes(outpoint, value);
        }
        const n_meta = try rd.readU32();
        i = 0;
        while (i < n_meta) : (i += 1) {
            const key = try rd.blob();
            const value = try rd.blob();
            try self.putMeta(key, value);
        }
        const n_blocks = try rd.readU32();
        i = 0;
        while (i < n_blocks) : (i += 1) {
            const height = try rd.readU32();
            var loc = BlockLoc{
                .raw = .{ .offset = try rd.readU64(), .len = try rd.readU32() },
                .header = .{ .offset = try rd.readU64(), .len = try rd.readU32() },
                .display_hash = undefined,
            };
            @memcpy(&loc.display_hash, try rd.take(64));
            try self.blocks.put(height, loc);
        }
        const n_undo = try rd.readU32();
        i = 0;
        while (i < n_undo) : (i += 1) {
            const height = try rd.readU32();
            try self.undos.put(height, .{ .offset = try rd.readU64(), .len = try rd.readU32() });
        }
        self.snapshot_bytes = bytes.len;
        self.snapshot_count = 1;
    }

    fn replayLog(self: *NativeStore) !void {
        const len = try fileLen(self.log_fd);
        const bytes = try self.allocator.alloc(u8, @intCast(len));
        defer self.allocator.free(bytes);
        if (bytes.len > 0) try preadAll(self.log_fd, bytes, 0);
        var offset: usize = 0;
        while (offset + 4 <= bytes.len) {
            const payload_len = std.mem.readInt(u32, bytes[offset..][0..4], .little);
            const total = 4 + @as(usize, payload_len) + 4;
            if (payload_len > bytes.len or offset + total > bytes.len) {
                try self.noteTorn(offset);
                return;
            }
            const payload = bytes[offset + 4 .. offset + 4 + payload_len];
            const crc = std.mem.readInt(u32, bytes[offset + 4 + payload_len ..][0..4], .little);
            if (crc != std.hash.Crc32.hash(bytes[offset .. offset + 4 + payload_len])) {
                try self.noteTorn(offset);
                return;
            }
            if (payload.len < 9) {
                try self.noteTorn(offset);
                return;
            }
            const kind = payload[0];
            const seq = std.mem.readInt(u64, payload[1..9], .little);
            if (seq <= self.last_seq) {
                offset += total;
                continue;
            }
            if (self.snapshot_height >= 0 and (kind == kind_commit or kind == kind_record_block)) {
                const height = std.mem.readInt(u32, payload[9..13], .little);
                if (height <= self.snapshot_height) {
                    self.last_seq = seq;
                    offset += total;
                    continue;
                }
            }
            try self.applyPayload(payload);
            offset += total;
        }
        if (offset != bytes.len) try self.noteTorn(offset);
        self.log_len = offset;
    }

    fn noteTorn(self: *NativeStore, offset: usize) !void {
        std.debug.print("{{\"schema\":\"port.native_store.torn_tail.v1\",\"offset\":{},\"file_len\":{}}}\n", .{ offset, try fileLen(self.log_fd) });
        if (std.c.ftruncate(self.log_fd, @intCast(offset)) != 0) return error.NativeIo;
        self.log_len = offset;
    }

    fn truncateFlatFiles(self: *NativeStore) !void {
        if (std.c.ftruncate(self.blocks_fd, @intCast(self.blocks_len)) != 0) return error.NativeIo;
        if (std.c.ftruncate(self.headers_fd, @intCast(self.headers_len)) != 0) return error.NativeIo;
        if (std.c.ftruncate(self.undo_fd, @intCast(self.undo_len)) != 0) return error.NativeIo;
    }

    fn loadCounters(self: *NativeStore) !void {
        if (self.metaStringRaw("chainstate_set_hash")) |hex| {
            if (hex.len == 64) self.set_hash = store.parseSetHashHex(hex) catch self.set_hash;
        }
        if (self.metaStringRaw("validated_height")) |text| {
            self.validated_height = std.fmt.parseInt(i64, text, 10) catch self.validated_height;
        }
        if (self.metaStringRaw("chainstate_utxo_count")) |text| {
            self.utxo_count = std.fmt.parseInt(i64, text, 10) catch self.utxo_count;
        }
    }

    fn metaStringRaw(self: *NativeStore, name: []const u8) ?[]const u8 {
        const key = root.codec.encodeMetadataKey(self.allocator, name) catch return null;
        defer self.allocator.free(key);
        return self.meta.get(key);
    }

    fn metaString(self: *NativeStore, allocator: std.mem.Allocator, name: []const u8, default: []const u8) ![]u8 {
        if (self.metaStringRaw(name)) |value| return allocator.dupe(u8, value);
        return allocator.dupe(u8, default);
    }

    fn metaI64(self: *NativeStore, allocator: std.mem.Allocator, name: []const u8, default: i64) !i64 {
        _ = allocator;
        const value = self.metaStringRaw(name) orelse return default;
        if (value.len == 0) return default;
        return std.fmt.parseInt(i64, value, 10) catch default;
    }

    fn syncFd(self: *NativeStore, fd: std.c.fd_t) !void {
        if (!self.options.fsync_enabled) return;
        if (std.c.fsync(fd) != 0) return error.NativeIo;
    }
};

const StagedPut = struct {
    outpoint: root.types.Outpoint,
    value: []u8,
};

const Buf = struct {
    list: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) Buf {
        return .{ .list = .empty, .allocator = allocator };
    }

    fn deinit(self: *Buf) void {
        self.list.deinit(self.allocator);
    }

    fn slice(self: *Buf) []u8 {
        return self.list.items;
    }

    fn putU8(self: *Buf, value: u8) !void {
        try self.list.append(self.allocator, value);
    }

    fn bytes(self: *Buf, value: []const u8) !void {
        try self.list.appendSlice(self.allocator, value);
    }

    fn putU32(self: *Buf, value: u32) !void {
        var tmp: [4]u8 = undefined;
        std.mem.writeInt(u32, &tmp, value, .little);
        try self.bytes(&tmp);
    }

    fn putU64(self: *Buf, value: u64) !void {
        var tmp: [8]u8 = undefined;
        std.mem.writeInt(u64, &tmp, value, .little);
        try self.bytes(&tmp);
    }

    fn putI64(self: *Buf, value: i64) !void {
        var tmp: [8]u8 = undefined;
        std.mem.writeInt(i64, &tmp, value, .little);
        try self.bytes(&tmp);
    }
};

const Rd = struct {
    bytes: []const u8,
    i: usize = 0,

    fn take(self: *Rd, n: usize) ![]const u8 {
        if (self.i + n > self.bytes.len) return error.TruncatedRecord;
        const out = self.bytes[self.i..][0..n];
        self.i += n;
        return out;
    }

    fn readU8(self: *Rd) !u8 {
        return (try self.take(1))[0];
    }

    fn readU32(self: *Rd) !u32 {
        return std.mem.readInt(u32, (try self.take(4))[0..4], .little);
    }

    fn readU64(self: *Rd) !u64 {
        return std.mem.readInt(u64, (try self.take(8))[0..8], .little);
    }

    fn readI64(self: *Rd) !i64 {
        return std.mem.readInt(i64, (try self.take(8))[0..8], .little);
    }

    fn outpoint(self: *Rd) !root.types.Outpoint {
        var txid: [32]u8 = undefined;
        @memcpy(&txid, try self.take(32));
        return .{ .txid = txid, .vout = try self.readU32() };
    }

    fn blob(self: *Rd) ![]const u8 {
        const len = try self.readU32();
        return self.take(len);
    }

    fn blobAfterOutpoint(self: *Rd) !void {
        _ = try self.outpoint();
        _ = try self.blob();
    }
};

fn decodeOutpoint(key: []const u8) !root.types.Outpoint {
    if (key.len < 1 + 1 + 32 + 4 or key[0] != 'u') return error.BadKey;
    const chain_len: usize = key[1];
    const txid_at = 2 + chain_len;
    if (key.len != txid_at + 32 + 4) return error.BadKey;
    var txid: [32]u8 = undefined;
    @memcpy(&txid, key[txid_at..][0..32]);
    return .{ .txid = txid, .vout = std.mem.readInt(u32, key[txid_at + 32 ..][0..4], .big) };
}

fn keyHeight(key: []const u8) !u32 {
    if (key.len < 4) return error.BadKey;
    return std.mem.readInt(u32, key[key.len - 4 ..][0..4], .big);
}

fn monoNs() u64 {
    var value: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &value) != 0) return 0;
    return @as(u64, @intCast(value.sec)) * 1_000_000_000 + @as(u64, @intCast(value.nsec));
}

fn elapsedMs(start_ms: i64) i64 {
    return @max(0, store.nowMs() - start_ms);
}

fn mkdir(path: []const u8) !void {
    const path_z = try std.heap.c_allocator.dupeZ(u8, path);
    defer std.heap.c_allocator.free(path_z);
    const rc = std.c.mkdir(path_z, 0o755);
    if (rc != 0 and std.c.errno(rc) != .EXIST) return error.NativeIo;
}

fn openAt(dir: []const u8, name: []const u8, create: bool) !std.c.fd_t {
    const path = try std.fs.path.join(std.heap.c_allocator, &.{ dir, name });
    defer std.heap.c_allocator.free(path);
    return openPath(path, create);
}

fn openPath(path: []const u8, create: bool) !std.c.fd_t {
    const path_z = try std.heap.c_allocator.dupeZ(u8, path);
    defer std.heap.c_allocator.free(path_z);
    const fd = if (create)
        std.c.open(path_z, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o644))
    else
        std.c.open(path_z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.NativeIo;
    return fd;
}

fn fileLen(fd: std.c.fd_t) !u64 {
    const n = std.c.lseek(fd, 0, std.c.SEEK.END);
    if (n < 0) return error.NativeIo;
    return @intCast(n);
}

fn pwriteAll(fd: std.c.fd_t, bytes: []const u8, offset: u64) !void {
    var rest = bytes;
    var at = offset;
    while (rest.len > 0) {
        const n = std.c.pwrite(fd, rest.ptr, rest.len, @intCast(at));
        if (n <= 0) return error.NativeIo;
        const wrote: usize = @intCast(n);
        rest = rest[wrote..];
        at += wrote;
    }
}

fn preadAll(fd: std.c.fd_t, bytes: []u8, offset: u64) !void {
    var rest = bytes;
    var at = offset;
    while (rest.len > 0) {
        const n = std.c.pread(fd, rest.ptr, rest.len, @intCast(at));
        if (n <= 0) return error.NativeIo;
        const got: usize = @intCast(n);
        rest = rest[got..];
        at += got;
    }
}

fn readFile(allocator: std.mem.Allocator, fd: std.c.fd_t, extent: Extent) ![]u8 {
    const out = try allocator.alloc(u8, extent.len);
    errdefer allocator.free(out);
    if (extent.len > 0) try preadAll(fd, out, extent.offset);
    return out;
}
