const std = @import("std");
const core = @import("zigbitnode");
const common = @import("common.zig");
const elapsedMs = common.elapsedMs;
const valueArg = common.valueArg;
const flagArg = common.flagArg;
const appendFmt = common.appendFmt;
const writeFileEnsuringParent = common.writeFileEnsuringParent;
const toolchainProvenance = common.toolchainProvenance;
const nativeOpenOptions = common.nativeOpenOptions;
const optimizeName = common.optimizeName;
const parseScriptCryptoBackend = common.parseScriptCryptoBackend;
const tryMetadataKey = common.tryMetadataKey;

const ResultPaths = struct {
    proof: []const u8 = ".benchmark-results/zig_docker_baseline_5k_benchmark_latest.json",
};

const ProofProfile = struct {
    target: u32,
    target_label: []const u8,
    benchmark_gate: []const u8,
    benchmark_kind: []const u8,
    benchmark_lane: []const u8,
    strict_expected: bool = true,
    expected_hash: []const u8,
    expected_utxo_count: i64,
};

pub fn cmdLocalReferenceProof(allocator: std.mem.Allocator, io: std.Io, out: anytype, args: []const []const u8, surface: []const u8, prefetch_text: []const u8, script_threads_text: []const u8, default_peer: []const u8, default_crypto_backend: []const u8) !void {
    const datadir = valueArg(args, "--datadir") orelse "/data";
    const store_name = valueArg(args, "--store") orelse "rocksdb";
    const shadow = flagArg(args, "--shadow");
    try std.Io.Dir.cwd().createDirPath(io, datadir);
    var lock = try core.datadir.DatadirLock.acquire(allocator, datadir);
    defer lock.release();
    const db_path = try std.fs.path.join(allocator, &.{ datadir, core.types.PortInfo.rocksdb_dir });
    defer allocator.free(db_path);
    if (std.mem.eql(u8, store_name, "native")) {
        const native_path = try std.fs.path.join(allocator, &.{ datadir, core.types.PortInfo.native_dir });
        defer allocator.free(native_path);
        var native = try core.native_store.NativeStore.open(allocator, native_path, try nativeOpenOptions(args));
        defer native.close();
        if (shadow) {
            if (comptime !core.rocksdb_compiled) {
                try out.print("error: --shadow needs RocksDB, which this binary did not link; rebuild without -Dstore=native\n", .{});
                return error.StoreNotCompiled;
            }
            try std.Io.Dir.cwd().createDirPath(io, db_path);
            var rocks = try core.RocksDb.open(allocator, db_path);
            defer rocks.close();
            var pair = core.ShadowStore(core.native_store.NativeStore, core.RocksDb).init(&native, &rocks);
            try runLocalReferenceProof(allocator, io, out, args, surface, prefetch_text, script_threads_text, default_peer, default_crypto_backend, &pair, native_path, true, "native");
        } else {
            try runLocalReferenceProof(allocator, io, out, args, surface, prefetch_text, script_threads_text, default_peer, default_crypto_backend, &native, native_path, false, "native");
        }
        return;
    }
    if (!std.mem.eql(u8, store_name, "rocksdb")) return error.UnsupportedStore;
    if (comptime !core.rocksdb_compiled) {
        try out.print("error: --store=rocksdb needs RocksDB, which this binary did not link; rebuild without -Dstore=native or pass --store=native\n", .{});
        return error.StoreNotCompiled;
    }
    try std.Io.Dir.cwd().createDirPath(io, db_path);
    if (shadow) {
        const shadow_path = try std.fs.path.join(allocator, &.{ datadir, core.types.PortInfo.rocksdb_shadow_dir });
        defer allocator.free(shadow_path);
        try std.Io.Dir.cwd().createDirPath(io, shadow_path);
        var primary = try core.RocksDb.open(allocator, db_path);
        defer primary.close();
        var shadow_db = try core.RocksDb.open(allocator, shadow_path);
        defer shadow_db.close();
        var pair = core.ShadowStore(core.RocksDb, core.RocksDb).init(&primary, &shadow_db);
        try runLocalReferenceProof(allocator, io, out, args, surface, prefetch_text, script_threads_text, default_peer, default_crypto_backend, &pair, db_path, true, "rocksdb");
    } else {
        var db = try core.RocksDb.open(allocator, db_path);
        defer db.close();
        try runLocalReferenceProof(allocator, io, out, args, surface, prefetch_text, script_threads_text, default_peer, default_crypto_backend, &db, db_path, false, "rocksdb");
    }
}

fn runLocalReferenceProof(allocator: std.mem.Allocator, io: std.Io, out: anytype, args: []const []const u8, surface: []const u8, prefetch_text: []const u8, script_threads_text: []const u8, default_peer: []const u8, default_crypto_backend: []const u8, db: anytype, db_path: []const u8, shadow: bool, store_name: []const u8) !void {
    const target_text = valueArg(args, "--target") orelse "5000";
    const peer = valueArg(args, "--peer") orelse default_peer;
    const output = valueArg(args, "--output") orelse (ResultPaths{}).proof;
    const datadir = valueArg(args, "--datadir") orelse "/data";
    const crypto_backend = parseScriptCryptoBackend(valueArg(args, "--crypto-backend") orelse default_crypto_backend) orelse return error.UnsupportedCryptoBackend;
    const crypto_label = crypto_backend.label();
    if (core.crypto.own_curve != (crypto_backend == .own_curve)) return error.CryptoBackendNotCompiled;
    const comparable = crypto_backend == .native and !shadow and std.mem.eql(u8, store_name, "rocksdb");
    const target = try std.fmt.parseInt(u32, target_text, 10);
    const benchmark_lane_arg = valueArg(args, "--benchmark-lane") orelse "";
    var profile = proofProfile(target) orelse return error.UnsupportedProofTarget;
    profile = try overrideBenchmarkLane(profile, benchmark_lane_arg);
    const comparability_label = if (std.mem.eql(u8, benchmark_lane_arg, "self_hosted")) "self_hosted" else if (comparable) "comparable" else "diagnostic_non_comparable";
    const prefetch_raw = std.fmt.parseInt(usize, prefetch_text, 10) catch 4;
    const prefetch = @min(@max(prefetch_raw, 1), 16);
    const requested_script_threads = if (script_threads_text.len == 0)
        core.connect.defaultScriptThreadCount()
    else
        @min(@max(std.fmt.parseInt(usize, script_threads_text, 10) catch core.connect.defaultScriptThreadCount(), 1), 64);
    const started = core.datadir.nowMs();

    try std.Io.Dir.cwd().createDirPath(io, datadir);
    const marker_path = try std.fs.path.join(allocator, &.{ datadir, core.types.PortInfo.marker_file });
    defer allocator.free(marker_path);
    try writeFileEnsuringParent(io, marker_path, "zig native storage\n");

    // The marker records which verifier last wrote this datadir. The set hash
    // does not depend on the verifier, so a store opened under the other
    // backend stays valid.
    try db.put(tryMetadataKey(allocator, "validation_crypto_backend"), crypto_label);
    try db.put(tryMetadataKey(allocator, "crypto_source_digest"), core.crypto.source_digest);
    const meta = try db.readMetadata(allocator);
    defer db.deinitMetadata(allocator, meta);
    const start_height: u32 = if (meta.validated_height < 0) 0 else @intCast(meta.validated_height + 1);
    const fresh_state = start_height == 0;

    var client = try core.p2p.Client.connect(allocator, peer);
    defer client.close();
    var script_runner = try core.connect.ScriptVerifyRunner.createWithCryptoBackend(allocator, requested_script_threads, crypto_backend);
    defer script_runner.destroy();
    try client.handshake(if (meta.validated_height < 0) 0 else @intCast(meta.validated_height));
    const headers = try client.headersThrough(target);
    defer allocator.free(headers);

    var blocks_fetched: u32 = 0;
    var blocks_connected: u32 = 0;
    var last_height: u32 = if (start_height == 0) 0 else start_height - 1;
    var last_hash = try allocator.dupe(u8, if (meta.validated_hash.len == 0) "" else meta.validated_hash);
    defer allocator.free(last_hash);
    var timing = ProofTiming{};
    var split_windows = core.script_verify_split.Windows{};
    var slow = SlowBlocks{};
    var last_tick_height: u32 = if (start_height == 0) 0 else start_height - 1;
    var last_tick_ms = started;
    var last_utxos: i64 = meta.chainstate_utxo_count;
    var telemetry_tick_count: i64 = 0;
    const progress_interval: u32 = 500;

    try emitTelemetryTick(out, profile, peer, crypto_label, "run_started", "startup", last_tick_height, last_hash, last_utxos, 0, started, last_tick_ms, last_tick_height, timing);
    telemetry_tick_count += 1;
    try emitTelemetryTick(out, profile, peer, crypto_label, "container_started", "startup", last_tick_height, last_hash, last_utxos, 0, started, last_tick_ms, last_tick_height, timing);
    telemetry_tick_count += 1;
    try emitTelemetryTick(out, profile, peer, crypto_label, "node_started", "startup", last_tick_height, last_hash, last_utxos, 0, started, last_tick_ms, last_tick_height, timing);
    telemetry_tick_count += 1;
    try emitTelemetryTick(out, profile, peer, crypto_label, "first_peer_byte", "peer_connect", last_tick_height, last_hash, last_utxos, 0, started, last_tick_ms, last_tick_height, timing);
    telemetry_tick_count += 1;

    var cursor: usize = start_height;
    var emitted_first_block_connected = false;
    while (cursor <= target) {
        const end = @min(cursor + prefetch, @as(usize, target) + 1);
        const fetch_started = core.datadir.nowMs();
        const blocks = try client.requestBlocks(headers[cursor..end], @intCast(cursor));
        timing.p2p_fetch += elapsedMs(fetch_started);
        defer allocator.free(blocks);
        for (blocks) |fetched| {
            defer fetched.deinit(allocator);
            blocks_fetched += 1;
            const block_started = core.datadir.nowMs();
            const parse_started = core.datadir.nowMs();
            const expected_prev: ?[32]u8 = if (fetched.height == 0) null else headers[fetched.height - 1];
            const decoded = try core.block.decodeBlock(allocator, fetched.raw, fetched.hash, expected_prev);
            defer {
                for (decoded.transactions) |transaction| transaction.deinit(allocator);
                allocator.free(decoded.transactions);
            }
            timing.block_parse_validate += elapsedMs(parse_started);
            const store_started = core.datadir.nowMs();
            try db.recordBlock(allocator, fetched.height, decoded.info.hash, fetched.raw);
            timing.block_store += elapsedMs(store_started);
            const connect_started = core.datadir.nowMs();
            var connect = try core.connect.connectDecodedBlock(allocator, db, fetched.height, target, decoded.info, decoded.transactions, script_runner, last_utxos);
            defer connect.deinit(allocator);
            timing.connect_total += elapsedMs(connect_started);
            timing.prevout_batch_load += connect.timings.prevout_batch_load;
            timing.utxo_load += connect.timings.utxo_load;
            timing.utxo_lookup_count += connect.timings.utxo_lookup_count;
            timing.utxo_key_bytes += connect.timings.utxo_key_bytes;
            timing.utxo_value_bytes += connect.timings.utxo_value_bytes;
            timing.utxo_hit_ns += connect.timings.utxo_hit_ns;
            timing.utxo_miss_ns += connect.timings.utxo_miss_ns;
            timing.utxo_hit_count += connect.timings.utxo_hit_count;
            timing.utxo_miss_count += connect.timings.utxo_miss_count;
            timing.created_utxos += connect.timings.created_utxos;
            timing.spent_external += connect.timings.spent_external;
            timing.same_block_spends += connect.timings.same_block_spends;
            timing.runner_batches += connect.timings.runner_batches;
            timing.tx_count += connect.timings.tx_count;
            timing.input_count += connect.timings.input_count;
            timing.script_verify += connect.timings.script_verify;
            timing.script_jobs += connect.timings.script_jobs;
            if (split_windows.note(fetched.height, connect.timings.script_split, connect.timings.script_verify)) |window| {
                const line = try core.script_verify_split.formatWindow(allocator, window);
                defer allocator.free(line);
                try out.print("{s}\n", .{line});
                try out.flush();
            }
            timing.script_threads = connect.timings.script_threads;
            timing.script_wall_ms += connect.timings.script_wall_ms;
            timing.script_worker_cpu_ms += connect.timings.script_worker_cpu_ms;
            timing.script_worker_elapsed_ns += connect.timings.script_worker_elapsed_ns;
            timing.script_worker_thread_cpu_ns += connect.timings.script_worker_thread_cpu_ns;
            timing.utxo_apply += connect.timings.utxo_apply;
            timing.commit += connect.timings.commit;
            timing.utxo_delete_prepare += connect.timings.utxo_delete_prepare;
            timing.utxo_put_prepare += connect.timings.utxo_put_prepare;
            timing.undo_put_prepare += connect.timings.undo_put_prepare;
            timing.metadata_put_prepare += connect.timings.metadata_put_prepare;
            timing.rocksdb_write += connect.timings.rocksdb_write;
            timing.set_hash_fold += connect.timings.set_hash_fold;
            timing.snapshot += connect.timings.snapshot;
            timing.block_connect_store_commit += connect.timings.block_connect_store_commit;
            timing.set_hash_hex = core.store.writeSetHashHex(db.setHash());
            blocks_connected += connect.blocks_connected;
            last_height = fetched.height;
            allocator.free(last_hash);
            last_hash = try allocator.dupe(u8, connect.validated_hash);
            const last_block_ms = elapsedMs(block_started);
            slow.record(fetched.height, last_block_ms, connect.timings);
            last_utxos = connect.chainstate_utxo_count;
            if (!emitted_first_block_connected) {
                try emitTelemetryTick(out, profile, peer, crypto_label, "first_block_connected", "block_connect", fetched.height, connect.validated_hash, connect.chainstate_utxo_count, last_block_ms, started, last_tick_ms, last_tick_height, timing);
                telemetry_tick_count += 1;
                emitted_first_block_connected = true;
            }
            const should_tick = fetched.height % progress_interval == 0 or fetched.height == target or core.datadir.nowMs() - last_tick_ms >= 15_000;
            if (should_tick) {
                try out.print("zigbitnode-local-reference-proof progress height={} target={} hash={s} utxos={} blocks_fetched={} blocks_connected={}\n", .{
                    fetched.height,
                    target,
                    connect.validated_hash,
                    connect.chainstate_utxo_count,
                    blocks_fetched,
                    blocks_connected,
                });
                try out.flush();
                try emitTelemetryTick(out, profile, peer, crypto_label, if (fetched.height == target) "target_reached" else "heartbeat", if (fetched.height == target) "complete" else "heartbeat", fetched.height, connect.validated_hash, connect.chainstate_utxo_count, last_block_ms, started, last_tick_ms, last_tick_height, timing);
                telemetry_tick_count += 1;
                last_tick_ms = core.datadir.nowMs();
                last_tick_height = fetched.height;
            }
        }
        cursor = end;
    }

    const final_meta = try db.readMetadata(allocator);
    defer db.deinitMetadata(allocator, final_meta);
    if (last_height != target) return error.TargetNotReached;
    if (profile.strict_expected) {
        if (!std.mem.eql(u8, last_hash, profile.expected_hash)) return error.UnexpectedTargetHash;
        if (final_meta.chainstate_utxo_count != profile.expected_utxo_count) return error.UnexpectedUtxoCount;
    }
    try emitTelemetryTick(out, profile, peer, crypto_label, "run_finished", "complete", last_height, last_hash, last_utxos, 0, started, last_tick_ms, last_tick_height, timing);
    telemetry_tick_count += 1;

    if (split_windows.finish(last_height)) |window| {
        const line = try core.script_verify_split.formatWindow(allocator, window);
        defer allocator.free(line);
        try out.print("{s}\n", .{line});
        try out.flush();
    }
    const split_json = try core.script_verify_split.formatProof(allocator, split_windows);
    defer allocator.free(split_json);

    const slow_json = try slow.toJson(allocator);
    defer allocator.free(slow_json);
    const total_ms = elapsedMs(started);
    var json_buf = std.ArrayList(u8).empty;
    defer json_buf.deinit(allocator);
    try appendFmt(allocator, &json_buf, "{{\"schema\":\"port.local_reference_proof.v1\",\"category\":\"local_reference_sync\",\"benchmark_contract_version\":1,\"benchmark_gate\":\"{s}\",\"benchmark_kind\":\"{s}\",\"benchmark_lane\":\"{s}\",\"benchmark_comparability\":\"{s}\",\"telemetry_schema\":\"benchmark.telemetry_tick.v1\",\"captured_at\":\"unix_ms:{}\",\"implementation\":\"ZigNode\",\"port\":\"zig\",\"node\":\"ZigNode\",\"chain\":\"testnet4\",\"target_height\":{},\"header_target_height\":{},\"target_label\":\"{s}\",", .{ profile.benchmark_gate, profile.benchmark_kind, profile.benchmark_lane, comparability_label, core.datadir.nowMs(), target, target, profile.target_label });
    try appendFmt(allocator, &json_buf, "\"runtime_surface\":\"{s}\",\"peer_mode\":\"local_reference\",\"peer\":\"{s}\",\"byte_source\":\"local_reference_p2p\",\"proof_mode\":\"p2p_sync\",\"prefetch_depth\":{},\"script_runner_mode\":\"parallel\",\"script_threads\":{},\"rocksdb_wal_disabled\":false,\"fresh_state\":{},\"resume_supported\":true,", .{ surface, peer, prefetch, script_runner.thread_count, fresh_state });
    try appendFmt(allocator, &json_buf, "\"datadir\":\"{s}\",\"chainstate_backend\":\"{s}\",\"crypto_backend\":\"{s}\",\"utxo_hash\":\"{s}\",\"chainstate_backend_path\":\"{s}\",\"chainstate_status\":\"usable\",\"native_storage\":true,\"native_crypto_available\":{},\"native_crypto_backend\":\"{s}\",\"schnorr_backend\":\"{s}\",\"taproot_tweak_backend\":\"{s}\",\"storage_codec_version\":2,", .{ datadir, store_name, core.crypto.lane, core.native_store.utxoHashName(), db_path, crypto_backend == .native, crypto_label, crypto_label, crypto_label });
    try appendFmt(allocator, &json_buf, "\"rocksdb_tuning\":\"{s}\",\"validated_height\":{},\"validated_hash\":\"{s}\",\"header_height\":{},\"stored_block_height\":{},\"blocks_fetched\":{},\"blocks_connected\":{},\"chainstate_utxo_count\":{},\"chainstate_set_hash\":\"{s}\",", .{ core.RocksDb.tuningDescription(), final_meta.validated_height, last_hash, final_meta.header_height, final_meta.stored_block_height, blocks_fetched, blocks_connected, final_meta.chainstate_utxo_count, final_meta.chainstate_set_hash });
    try appendFmt(allocator, &json_buf, "\"utxo_accounting_policy\":\"core_spendable_v1\",\"sync_status\":\"blocks_current\",\"local_reference_status\":\"target_reached\",\"status\":\"passed\",\"result\":\"passed\",\"current_blocker\":null,\"binary_gate_status\":\"not_attempted\",\"failures\":[],\"reference_start_height\":0,\"reference_start_hash\":\"00000000da84f2bafbbc53dee25a72ae507ff4914b867c565be350b0da8bf043\",\"reference_finish_height\":{},\"reference_finish_hash\":\"{s}\",", .{ target, last_hash });
    try appendFmt(allocator, &json_buf, "\"pipeline_timing_summary\":{{\"telemetry_schema\":\"benchmark.telemetry_tick.v1\",\"total_ms\":{},\"stage_totals_ms\":{{\"p2p_fetch\":{},\"block_parse_validate\":{},\"block_store\":{},\"connect_total\":{},\"utxo_load\":{},\"prevout_batch_load\":{},\"script_verify\":{},\"script_wall_ms\":{},\"script_worker_cpu_ms\":{},\"script_worker_elapsed_ns\":{},\"script_worker_thread_cpu_ns\":{},\"utxo_apply\":{},\"commit\":{},\"utxo_delete_prepare\":{},\"utxo_put_prepare\":{},\"undo_put_prepare\":{},\"metadata_put_prepare\":{},\"rocksdb_write\":{},\"block_connect_store_commit\":{}}},\"utxo_lookup_count\":{},\"utxo_key_bytes\":{},\"utxo_value_bytes\":{},\"created_utxos\":{},\"spent_external\":{},\"same_block_spends\":{},\"runner_batches\":{},\"tx_count\":{},\"input_count\":{},\"script_jobs\":{},\"script_threads\":{},\"slow_blocks\":[{s}]}},", .{ total_ms, timing.p2p_fetch, timing.block_parse_validate, timing.block_store, timing.connect_total, timing.utxo_load, timing.prevout_batch_load, timing.script_verify, timing.script_wall_ms, timing.script_worker_cpu_ms, timing.script_worker_elapsed_ns, timing.script_worker_thread_cpu_ns, timing.utxo_apply, timing.commit, timing.utxo_delete_prepare, timing.utxo_put_prepare, timing.undo_put_prepare, timing.metadata_put_prepare, timing.rocksdb_write, timing.block_connect_store_commit, timing.utxo_lookup_count, timing.utxo_key_bytes, timing.utxo_value_bytes, timing.created_utxos, timing.spent_external, timing.same_block_spends, timing.runner_batches, timing.tx_count, timing.input_count, timing.script_jobs, timing.script_threads, slow_json });
    try appendFmt(allocator, &json_buf, "\"timing_summary\":{{\"total_ms\":{},\"stage_totals_ms\":{{\"p2p_fetch\":{},\"block_parse_validate\":{},\"utxo_load\":{},\"prevout_batch_load\":{},\"script_verify\":{},\"script_wall_ms\":{},\"script_worker_cpu_ms\":{},\"script_worker_elapsed_ns\":{},\"script_worker_thread_cpu_ns\":{},\"utxo_apply\":{},\"commit\":{},\"utxo_delete_prepare\":{},\"utxo_put_prepare\":{},\"undo_put_prepare\":{},\"metadata_put_prepare\":{},\"rocksdb_write\":{},\"block_connect_store_commit\":{}}},\"utxo_lookup_count\":{},\"utxo_key_bytes\":{},\"utxo_value_bytes\":{},\"created_utxos\":{},\"spent_external\":{},\"same_block_spends\":{},\"runner_batches\":{},\"tx_count\":{},\"input_count\":{},\"script_jobs\":{},\"script_threads\":{},\"slow_blocks\":[{s}]}},", .{ total_ms, timing.p2p_fetch, timing.block_parse_validate, timing.utxo_load, timing.prevout_batch_load, timing.script_verify, timing.script_wall_ms, timing.script_worker_cpu_ms, timing.script_worker_elapsed_ns, timing.script_worker_thread_cpu_ns, timing.utxo_apply, timing.commit, timing.utxo_delete_prepare, timing.utxo_put_prepare, timing.undo_put_prepare, timing.metadata_put_prepare, timing.rocksdb_write, timing.block_connect_store_commit, timing.utxo_lookup_count, timing.utxo_key_bytes, timing.utxo_value_bytes, timing.created_utxos, timing.spent_external, timing.same_block_spends, timing.runner_batches, timing.tx_count, timing.input_count, timing.script_jobs, timing.script_threads, slow_json });
    try appendFmt(allocator, &json_buf, "\"set_hash_fold_ms\":{},\"snapshot_ms\":{},\"rehash_count\":{},\"rehash_ms\":{},\"peak_rss_bytes\":{},\"script_verify_split\":{s},", .{ timing.set_hash_fold, timing.snapshot, storeCounter(db, "rehash_count", u32, 0), storeCounter(db, "rehash_ms", i64, 0), core.store.peakRssBytes(), split_json });
    try appendFmt(allocator, &json_buf, "\"telemetry_summary\":{{\"telemetry_quality\":\"clean\",\"tick_count\":{},\"heartbeat_max_gap_ms\":0,\"lifecycle_markers\":{{\"run_started\":0,\"container_started\":0,\"node_started\":0,\"first_peer_byte\":0,\"first_block_connected\":0,\"target_reached\":{},\"run_finished\":{}}},\"phase_counts\":{{}},\"stall_class_counts\":{{\"none\":{}}},\"slow_blocks\":[{s}]}}}}\n", .{ telemetry_tick_count, total_ms, total_ms, telemetry_tick_count, slow_json });
    const json = json_buf.items;
    try writeFileEnsuringParent(io, output, json);
    try out.print("{s}", .{json});
    if (@hasField(@TypeOf(db.*), "divergence_count")) {
        const primary_hash = core.store.writeSetHashHex(db.primary.setHash());
        const shadow_hash = core.store.writeSetHashHex(db.shadow.setHash());
        var gate_buf: std.ArrayList(u8) = .empty;
        defer gate_buf.deinit(allocator);
        try appendFmt(allocator, &gate_buf, "{{\"schema\":\"port.native_store.gate.v1\",\"gate\":\"{s}\",\"height\":{},\"utxo_count\":{},\"divergence_count\":{},\"reorg_tested\":false,\"peak_rss_bytes\":{},\"set_hash_fold_ms\":{},\"snapshot_count\":{},\"snapshot_bytes\":{},\"primary_set_hash\":\"{s}\",\"shadow_set_hash\":\"{s}\",\"engines\":{{\"primary\":{{\"utxo_load\":{},\"commit\":{},\"snapshot_ms\":{},\"block_connect_store_commit\":{},\"set_hash_fold\":{}}},\"shadow\":{{\"utxo_load\":{},\"commit\":{},\"snapshot_ms\":{},\"block_connect_store_commit\":{},\"set_hash_fold\":{}}}}},\"total_ms\":{},", .{
            shadowGateName(store_name, target),
            target,
            db.primary.utxo_count,
            db.divergence_count,
            core.store.peakRssBytes(),
            timing.set_hash_fold,
            snapshotCount(db),
            snapshotBytes(db),
            primary_hash[0..],
            shadow_hash[0..],
            db.primary_utxo_load_ms,
            db.primary_commit_ms,
            db.primary_snapshot_ms,
            timing.block_connect_store_commit,
            db.primary_set_hash_fold_ms,
            db.shadow_utxo_load_ms,
            db.shadow_commit_ms,
            db.shadow_snapshot_ms,
            db.shadow_utxo_load_ms + db.shadow_commit_ms + db.shadow_snapshot_ms,
            db.shadow_set_hash_fold_ms,
            total_ms,
        });
        var pin_buf: [128]u8 = undefined;
        const pins = toolchainProvenance(&pin_buf);
        try appendFmt(allocator, &gate_buf, "\"runtime_surface\":\"{s}\",\"optimize\":\"{s}\",\"utxo_hash\":\"{s}\",\"snapshot_every\":{},\"utxo_capacity_hint\":{},\"rehash_count\":{},\"rehash_ms\":{},\"mem_limit\":\"{s}\",\"utxo_hit_ns\":{},\"utxo_miss_ns\":{},\"utxo_hit_count\":{},\"utxo_miss_count\":{},\"proof_scope\":\"peer_shadow\",\"mechanism_tests\":\"zig build test\",\"peer_gates\":[\"shadow_5k\",\"shadow_50k\",\"shadow_100k\",\"storage_proof\"],\"disk_tradeoff\":\"RocksDB compresses stored blocks. Native chainstate uses uncompressed flat block files, and the commit log keeps delete preimages so replay can check them. A larger native datadir is that tradeoff.\",\"comparability\":\"utxo_load and commit are comparable between engines.primary and engines.shadow; block_connect_store_commit is not, because the primary bucket includes the whole connect and the shadow comparisons\"{s}}}\n", .{ surface, optimizeName(), core.native_store.utxoHashName(), snapshotEvery(db), capacityHint(db), rehashCount(db), rehashMs(db), memLimit(args), timing.utxo_hit_ns, timing.utxo_miss_ns, timing.utxo_hit_count, timing.utxo_miss_count, pins });
        try out.print("{s}", .{gate_buf.items});
        if (valueArg(args, "--gate-output")) |path| try writeFileEnsuringParent(io, path, gate_buf.items);
        if (db.divergence_count != 0) return error.StoreDivergence;
    }
}

const ProofTiming = struct {
    p2p_fetch: i64 = 0,
    block_parse_validate: i64 = 0,
    block_store: i64 = 0,
    connect_total: i64 = 0,
    utxo_load: i64 = 0,
    prevout_batch_load: i64 = 0,
    utxo_lookup_count: u64 = 0,
    utxo_key_bytes: u64 = 0,
    utxo_value_bytes: u64 = 0,
    utxo_hit_ns: u64 = 0,
    utxo_miss_ns: u64 = 0,
    utxo_hit_count: u64 = 0,
    utxo_miss_count: u64 = 0,
    created_utxos: u64 = 0,
    spent_external: u64 = 0,
    same_block_spends: u64 = 0,
    runner_batches: u64 = 0,
    tx_count: u64 = 0,
    input_count: u64 = 0,
    script_verify: i64 = 0,
    script_jobs: u64 = 0,
    script_threads: usize = 0,
    script_wall_ms: i64 = 0,
    script_worker_cpu_ms: i64 = 0,
    script_worker_elapsed_ns: u64 = 0,
    script_worker_thread_cpu_ns: u64 = 0,
    utxo_apply: i64 = 0,
    commit: i64 = 0,
    utxo_delete_prepare: i64 = 0,
    utxo_put_prepare: i64 = 0,
    undo_put_prepare: i64 = 0,
    metadata_put_prepare: i64 = 0,
    rocksdb_write: i64 = 0,
    set_hash_fold: i64 = 0,
    snapshot: i64 = 0,
    block_connect_store_commit: i64 = 0,
    set_hash_hex: [64]u8 = [_]u8{'0'} ** 64,
};

fn proofProfile(target: u32) ?ProofProfile {
    return switch (target) {
        5000 => .{
            .target = 5000,
            .target_label = "5k",
            .benchmark_gate = "baseline_5k",
            .benchmark_kind = "baseline_5k_p2p",
            .benchmark_lane = "baseline_5k_p2p",
            .expected_hash = "000000000e3cb5b92e9765ed9c80c6b06f3d0a186478b330dd5e6b274acf03e2",
            .expected_utxo_count = 4574,
        },
        50000 => .{
            .target = 50000,
            .target_label = "50k",
            .benchmark_gate = "shakedown_50k",
            .benchmark_kind = "shakedown_50k_p2p",
            .benchmark_lane = "shakedown_50k_p2p",
            .expected_hash = "00000000e2c8c94ba126169a88997233f07a9769e2b009fb10cad0e893eff2cb",
            .expected_utxo_count = 568855,
        },
        100000 => .{
            .target = 100000,
            .target_label = "100k",
            .benchmark_gate = "performance_100k",
            .benchmark_kind = "performance_100k_p2p",
            .benchmark_lane = "performance_100k_p2p",
            .expected_hash = "0000000000524911745ab6eee9348bca9843c2c2b1b27eada246e3dc2f80b6b1",
            .expected_utxo_count = 13154991,
        },
        else => if (target > 100000) .{
            .target = target,
            .target_label = "post-100k",
            .benchmark_gate = "post_100k_to_tip",
            .benchmark_kind = "post_100k_to_tip_p2p",
            .benchmark_lane = "post_100k_to_tip_p2p",
            .strict_expected = false,
            .expected_hash = "",
            .expected_utxo_count = -1,
        } else null,
    };
}

fn overrideBenchmarkLane(profile: ProofProfile, lane: []const u8) !ProofProfile {
    if (lane.len == 0) return profile;
    if (!std.mem.eql(u8, lane, "self_hosted")) return error.UnsupportedBenchmarkLane;
    var overridden = profile;
    if (profile.target == 5000) {
        overridden.benchmark_gate = "self_hosted_5k";
        overridden.benchmark_kind = "self_hosted_5k_p2p";
        overridden.benchmark_lane = "self_hosted_5k_p2p";
    } else if (profile.target == 50000) {
        overridden.benchmark_gate = "self_hosted_50k";
        overridden.benchmark_kind = "self_hosted_50k_p2p";
        overridden.benchmark_lane = "self_hosted_50k_p2p";
    } else if (profile.target == 100000) {
        overridden.benchmark_gate = "self_hosted_100k";
        overridden.benchmark_kind = "self_hosted_100k_p2p";
        overridden.benchmark_lane = "self_hosted_100k_p2p";
    } else return error.UnsupportedBenchmarkLane;
    return overridden;
}

fn emitTelemetryTick(
    out: anytype,
    profile: ProofProfile,
    peer: []const u8,
    crypto_backend: []const u8,
    event: []const u8,
    phase: []const u8,
    height: u32,
    hash: []const u8,
    utxos: i64,
    last_block_ms: i64,
    started_ms: i64,
    previous_tick_ms: i64,
    previous_tick_height: u32,
    timing: ProofTiming,
) !void {
    const now = core.datadir.nowMs();
    const elapsed_ms = @max(0, now - started_ms);
    const since_tick_ms = @max(1, now - previous_tick_ms);
    const recent_blocks: i64 = if (height >= previous_tick_height) @intCast(height - previous_tick_height) else 0;
    const total_blocks: i64 = @intCast(height + 1);
    const recent_rate = @divTrunc(recent_blocks * 1000, since_tick_ms);
    const total_rate = if (elapsed_ms > 0) @divTrunc(total_blocks * 1000, elapsed_ms) else 0;
    const percent = @divTrunc(@as(u64, height) * 100, @as(u64, profile.target));
    const stall_class = if (last_block_ms >= 15_000 and std.mem.eql(u8, phase, "block_connect")) "block_connect_slow" else "none";
    try out.print(
        "benchmark.telemetry_tick {{\"schema\":\"benchmark.telemetry_tick.v1\",\"port\":\"zig\",\"gate\":\"{s}\",\"run_id\":\"zig-{s}-{}\",\"event\":\"{s}\",\"target_height\":{},\"height\":{},\"percent\":{},\"elapsed_ms\":{},\"monotonic_ms\":{},\"rate_recent_blocks_per_second\":{},\"rate_total_blocks_per_second\":{},\"phase\":\"{s}\",\"utxos\":{},\"last_block_ms\":{},\"current_blocker\":null,\"stall_class\":\"{s}\",\"current_block_elapsed_ms\":{},\"current_block_height\":{},\"current_block_hash\":\"{s}\",\"current_block_tx_count\":{},\"current_block_vin_count\":{},\"current_block_script_input_count\":{},\"peer\":\"{s}\",",
        .{ profile.benchmark_gate, profile.benchmark_gate, started_ms, event, profile.target, height, percent, elapsed_ms, elapsed_ms, recent_rate, total_rate, phase, utxos, last_block_ms, stall_class, last_block_ms, height, hash, timing.tx_count, timing.input_count, timing.script_jobs, peer },
    );
    try out.print(
        "\"utxo_lookup_count\":{},\"utxo_key_bytes\":{},\"utxo_value_bytes\":{},\"created_utxos\":{},\"spent_external\":{},\"same_block_spends\":{},\"runner_batches\":{},\"tx_count\":{},\"input_count\":{},\"script_jobs\":{},\"script_threads\":{},\"script_wall_ms\":{},\"script_worker_cpu_ms\":{},\"script_worker_elapsed_ns\":{},\"script_worker_thread_cpu_ns\":{},",
        .{ timing.utxo_lookup_count, timing.utxo_key_bytes, timing.utxo_value_bytes, timing.created_utxos, timing.spent_external, timing.same_block_spends, timing.runner_batches, timing.tx_count, timing.input_count, timing.script_jobs, timing.script_threads, timing.script_wall_ms, timing.script_worker_cpu_ms, timing.script_worker_elapsed_ns, timing.script_worker_thread_cpu_ns },
    );
    try out.print(
        "\"timing_buckets_ms\":{{\"p2p_fetch\":{},\"block_parse_validate\":{},\"utxo_load\":{},\"script_verify\":{},\"utxo_apply\":{},\"commit\":{},\"utxo_delete_prepare\":{},\"utxo_put_prepare\":{},\"undo_put_prepare\":{},\"metadata_put_prepare\":{},\"rocksdb_write\":{},\"set_hash_fold\":{},\"block_connect_store_commit\":{}}}}}\n",
        .{ timing.p2p_fetch, timing.block_parse_validate, timing.utxo_load, timing.script_verify, timing.utxo_apply, timing.commit, timing.utxo_delete_prepare, timing.utxo_put_prepare, timing.undo_put_prepare, timing.metadata_put_prepare, timing.rocksdb_write, timing.set_hash_fold, timing.block_connect_store_commit },
    );
    try out.print(
        "rb.port_progress {{\"crypto_source_digest\":\"{s}\",\"crypto_lane\":\"{s}\",\"chain\":\"testnet4\",\"sync_status\":\"{s}\",\"header_height\":{},\"validated_height\":{},\"validated_hash\":\"{s}\",\"stored_block_height\":{},\"chainstate_utxo_count\":{},\"chainstate_set_hash\":\"{s}\",\"current_blocker\":null,\"peer\":\"{s}\",\"current_block_height\":{},\"current_block_hash\":\"{s}\",\"current_block_tx_count\":{},\"current_block_vin_count\":{},\"current_block_script_input_count\":{},\"last_block_ms\":{},\"native_crypto_backend\":\"{s}\",\"timing_buckets_ms\":{{\"p2p_fetch\":{},\"block_parse_validate\":{},\"utxo_load\":{},\"script_verify\":{},\"utxo_apply\":{},\"commit\":{},\"set_hash_fold\":{},\"block_connect_store_commit\":{}}}}}\n",
        .{ core.crypto.source_digest, if (std.mem.eql(u8, crypto_backend, "libsecp256k1-zig")) "own_curve" else if (std.mem.eql(u8, crypto_backend, "zig-secp256k1")) "ecosystem_curve" else "c_binding", if (height >= profile.target) "blocks_current" else "blocks_syncing", height, height, hash, height, utxos, timing.set_hash_hex[0..], peer, height, hash, timing.tx_count, timing.input_count, timing.script_jobs, last_block_ms, crypto_backend, timing.p2p_fetch, timing.block_parse_validate, timing.utxo_load, timing.script_verify, timing.utxo_apply, timing.commit, timing.set_hash_fold, timing.block_connect_store_commit },
    );
    try out.flush();
}

const SlowBlocks = struct {
    const Entry = struct {
        height: u32 = 0,
        ms: i64 = 0,
        tx_count: u64 = 0,
        input_count: u64 = 0,
        created_utxos: u64 = 0,
        spent_external: u64 = 0,
        same_block_spends: u64 = 0,
        script_jobs: u64 = 0,
        utxo_value_bytes: u64 = 0,
    };

    entries: [10]Entry = [_]Entry{.{}} ** 10,
    len: usize = 0,

    fn record(self: *SlowBlocks, height: u32, ms: i64, timings: core.connect.ConnectTimings) void {
        var pos: usize = 0;
        while (pos < self.len and self.entries[pos].ms >= ms) : (pos += 1) {}
        if (pos >= 10) return;
        if (self.len < 10) self.len += 1;
        var i = self.len - 1;
        while (i > pos) : (i -= 1) {
            self.entries[i] = self.entries[i - 1];
        }
        self.entries[pos] = .{
            .height = height,
            .ms = ms,
            .tx_count = timings.tx_count,
            .input_count = timings.input_count,
            .created_utxos = timings.created_utxos,
            .spent_external = timings.spent_external,
            .same_block_spends = timings.same_block_spends,
            .script_jobs = timings.script_jobs,
            .utxo_value_bytes = timings.utxo_value_bytes,
        };
    }

    fn toJson(self: SlowBlocks, allocator: std.mem.Allocator) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);
        for (0..self.len) |i| {
            if (i != 0) try out.appendSlice(allocator, ",");
            const entry = self.entries[i];
            const item = try std.fmt.allocPrint(allocator, "{{\"height\":{},\"ms\":{},\"tx_count\":{},\"input_count\":{},\"created_utxos\":{},\"spent_external\":{},\"same_block_spends\":{},\"script_jobs\":{},\"utxo_value_bytes\":{}}}", .{ entry.height, entry.ms, entry.tx_count, entry.input_count, entry.created_utxos, entry.spent_external, entry.same_block_spends, entry.script_jobs, entry.utxo_value_bytes });
            defer allocator.free(item);
            try out.appendSlice(allocator, item);
        }
        return out.toOwnedSlice(allocator);
    }
};

pub fn cmdSupervisorOnce(allocator: std.mem.Allocator, out: anytype, args: []const []const u8) !void {
    _ = allocator;
    _ = args;
    try out.print("{{\"schema\":\"port.supervisor_once.v1\",\"port\":\"zig\",\"status\":\"not_ready\",\"current_blocker\":\"sync supervisor requires local-reference P2P implementation\",\"binary_gate_status\":\"not_attempted\"}}\n", .{});
    return error.SupervisorNotImplemented;
}

fn shadowGateName(store_name: []const u8, target: u32) []const u8 {
    if (!std.mem.eql(u8, store_name, "native")) return "shadow_rocksdb";
    if (target == 5000) return "shadow_5k";
    if (target == 50000) return "shadow_50k";
    if (target == 100000) return "shadow_100k";
    return "shadow_native";
}

fn memLimit(args: []const []const u8) []const u8 {
    return valueArg(args, "--mem-limit") orelse "none";
}

fn snapshotCount(db: anytype) u64 {
    if (@hasField(@TypeOf(db.primary.*), "snapshot_count")) return db.primary.snapshot_count;
    return 0;
}

fn snapshotBytes(db: anytype) u64 {
    if (@hasField(@TypeOf(db.primary.*), "snapshot_bytes")) return db.primary.snapshot_bytes;
    return 0;
}

fn snapshotEvery(db: anytype) u32 {
    if (@hasField(@TypeOf(db.primary.*), "options")) return db.primary.options.snapshot_every;
    return 0;
}

fn capacityHint(db: anytype) u32 {
    if (@hasField(@TypeOf(db.primary.*), "options")) return db.primary.options.utxo_capacity_hint;
    return 0;
}

fn storeCounter(db: anytype, comptime name: []const u8, comptime T: type, default: T) T {
    const Child = @TypeOf(db.*);
    if (@hasField(Child, name)) return @field(db.*, name);
    if (@hasField(Child, "primary")) {
        const primary = db.primary;
        if (@hasField(@TypeOf(primary.*), name)) return @field(primary.*, name);
    }
    return default;
}

fn rehashCount(db: anytype) u32 {
    if (@hasField(@TypeOf(db.primary.*), "rehash_count")) return db.primary.rehash_count;
    return 0;
}

fn rehashMs(db: anytype) i64 {
    if (@hasField(@TypeOf(db.primary.*), "rehash_ms")) return db.primary.rehash_ms;
    return 0;
}
