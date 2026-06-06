const std = @import("std");
const Io = std.Io;
const core = @import("zigbitnode");

const ResultPaths = struct {
    script: []const u8 = "../Shared/conformance/results/zig_script_corpus_latest.json",
    storage: []const u8 = "../Shared/conformance/results/zig_storage_gate_docker_latest.json",
    proof: []const u8 = "../Shared/conformance/results/zig_docker_baseline_5k_benchmark_latest.json",
};

const ProofProfile = struct {
    target: u32,
    target_label: []const u8,
    benchmark_gate: []const u8,
    benchmark_kind: []const u8,
    benchmark_lane: []const u8,
    expected_hash: []const u8,
    expected_utxo_count: i64,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_file_writer.interface;
    defer out.flush() catch {};

    if (args.len < 2) {
        try usage(out);
        return;
    }

    const command = args[1];
    const io = init.io;
    const surface = init.environ_map.get("ZIGBITNODE_RUNTIME_SURFACE") orelse "host";

    if (std.mem.eql(u8, command, "status")) {
        try cmdStatus(allocator, out, args[2..], surface);
    } else if (std.mem.eql(u8, command, "codec-vectors")) {
        try core.verifyCodecVectors(allocator);
        try out.print("{{\"schema\":\"port.codec_vectors.v1\",\"port\":\"zig\",\"codec_version\":2,\"passed\":true}}\n", .{});
    } else if (std.mem.eql(u8, command, "native-crypto-vectors")) {
        try cmdNativeCrypto(out);
    } else if (std.mem.eql(u8, command, "storage-proof")) {
        try cmdStorageProof(allocator, io, out, args[2..], surface);
    } else if (std.mem.eql(u8, command, "script-corpus")) {
        try cmdScriptCorpus(allocator, io, out, args[2..], surface);
    } else if (std.mem.eql(u8, command, "local-reference-proof")) {
        const prefetch_text = init.environ_map.get("PREFETCH_DEPTH") orelse "4";
        const script_threads_text = init.environ_map.get("ZIGBITNODE_SCRIPT_THREADS") orelse "";
        try cmdLocalReferenceProof(std.heap.smp_allocator, io, out, args[2..], surface, prefetch_text, script_threads_text);
    } else if (std.mem.eql(u8, command, "sync-supervisor-once")) {
        try cmdSupervisorOnce(allocator, out, args[2..]);
    } else {
        try out.print("error: unknown command: {s}\n", .{command});
        try usage(out);
        return error.UnknownCommand;
    }
}

fn usage(out: anytype) !void {
    try out.print(
        \\zigbitnode commands:
        \\  status [--datadir ./data-zig]
        \\  storage-proof [--datadir ./data-zig] [--output path]
        \\  codec-vectors
        \\  native-crypto-vectors
        \\  script-corpus [--manifest path] [--output path]
        \\  local-reference-proof [--target 5000|50000|100000] [--peer bitcoin-core-testnet4:48333] [--output path]
        \\  sync-supervisor-once [--target 5000] [--peer bitcoin-core-testnet4:48333] [--datadir ./data-zig]
        \\
    , .{});
}

fn cmdStatus(allocator: std.mem.Allocator, out: anytype, args: []const []const u8, surface: []const u8) !void {
    const datadir = valueArg(args, "--datadir") orelse core.PortInfo.default_datadir;
    const db_path = try std.fs.path.join(allocator, &.{ datadir, core.PortInfo.rocksdb_dir });
    defer allocator.free(db_path);

    var validated_height: []const u8 = "0";
    var backend: []const u8 = "none";
    var utxo_count: []const u8 = "0";
    var chainstate_status: []const u8 = "missing";
    if (core.RocksDb.open(allocator, db_path)) |db0| {
        var db = db0;
        defer db.close();
        if (try db.getAlloc(allocator, tryMetadataKey(allocator, "validated_height"))) |value| validated_height = value;
        if (try db.getAlloc(allocator, tryMetadataKey(allocator, "chainstate_backend"))) |value| backend = value;
        if (try db.getAlloc(allocator, tryMetadataKey(allocator, "chainstate_utxo_count"))) |value| utxo_count = value;
        chainstate_status = if (std.mem.eql(u8, backend, "rocksdb")) "usable" else "missing";
    } else |_| {}

    try out.print(
        "{{\"schema\":\"port.status.v1\",\"port\":\"zig\",\"node\":\"ZigNode\",\"runtime_surface\":\"{s}\",\"datadir\":\"{s}\",\"sync_status\":\"starting\",\"chainstate_backend\":\"{s}\",\"chainstate_status\":\"{s}\",\"validated_height\":{s},\"header_height\":0,\"stored_block_height\":0,\"chainstate_utxo_count\":{s},\"current_blocker\":null,\"binary_gate_status\":\"not_attempted\"}}\n",
        .{ surface, datadir, backend, chainstate_status, validated_height, utxo_count },
    );
}

fn cmdNativeCrypto(out: anytype) !void {
    const available = core.secp256k1Available();
    try out.print(
        "{{\"schema\":\"port.native_crypto_vectors.v1\",\"port\":\"zig\",\"passed\":{},\"delegated\":false,\"ecdsa_backend\":\"libsecp256k1\",\"schnorr_backend\":\"libsecp256k1\",\"taproot_tweak_backend\":\"libsecp256k1\",\"notes\":\"backend availability smoke vector only; full shared crypto vectors are next\"}}\n",
        .{available},
    );
}

fn cmdStorageProof(allocator: std.mem.Allocator, io: std.Io, out: anytype, args: []const []const u8, surface: []const u8) !void {
    const datadir = valueArg(args, "--datadir") orelse core.PortInfo.default_datadir;
    const output = valueArg(args, "--output") orelse (ResultPaths{}).storage;
    try std.Io.Dir.cwd().createDirPath(io, datadir);
    const marker_path = try std.fs.path.join(allocator, &.{ datadir, core.PortInfo.marker_file });
    defer allocator.free(marker_path);
    try writeFileEnsuringParent(io, marker_path, "zig native storage\n");

    const db_path = try std.fs.path.join(allocator, &.{ datadir, core.PortInfo.rocksdb_dir });
    defer allocator.free(db_path);
    try std.Io.Dir.cwd().createDirPath(io, db_path);
    var db = try core.RocksDb.open(allocator, db_path);
    defer db.close();
    try db.writeBatchSmoke(allocator);

    const json = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"port.storage_gate_result.v1\",\"port\":\"zig\",\"node\":\"ZigNode\",\"runtime_surface\":\"{s}\",\"storage_backend\":\"rocksdb\",\"runtime_truth_backend\":\"rocksdb\",\"rocksdb_runtime_truth\":true,\"native_marker\":\"{s}\",\"atomic_batch_commit\":true,\"validated_height\":2,\"chainstate_status\":\"usable\",\"chainstate_backend\":\"rocksdb\",\"chainstate_utxo_count\":1,\"binary_gate_status\":\"not_attempted\",\"current_blocker\":null}}\n",
        .{ surface, core.PortInfo.marker_file },
    );
    defer allocator.free(json);
    try writeFileEnsuringParent(io, output, json);
    try out.print("{s}", .{json});
}

fn cmdScriptCorpus(allocator: std.mem.Allocator, io: std.Io, out: anytype, args: []const []const u8, surface: []const u8) !void {
    const manifest = valueArg(args, "--manifest") orelse "../Shared/conformance/fixtures/scripts/manifest.json";
    const output = valueArg(args, "--output") orelse (ResultPaths{}).script;

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, manifest, allocator, .limited(20 * 1024 * 1024));
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const fixtures = root.get("fixtures") orelse return error.ManifestMissingFixtures;
    if (fixtures != .array) return error.ManifestMissingFixtures;

    var rows = std.ArrayList(u8).empty;
    defer rows.deinit(allocator);
    var failed: usize = 0;
    for (fixtures.array.items, 0..) |fixture, i| {
        const obj = fixture.object;
        const fixture_id = jsonString(obj.get("fixture_id")) orelse "unknown";
        var loader_error: ?[]const u8 = null;
        if (obj.get("files")) |files_value| {
            if (files_value == .object) {
                var iter = files_value.object.iterator();
                while (iter.next()) |entry| {
                    if (entry.value_ptr.* != .array) {
                        loader_error = "files category is not an array";
                        break;
                    }
                    for (entry.value_ptr.array.items) |path_value| {
                        const rel = jsonString(path_value) orelse {
                            loader_error = "file path is not a string";
                            break;
                        };
                        const full = try std.fs.path.join(allocator, &.{ std.fs.path.dirname(manifest) orelse ".", rel });
                        defer allocator.free(full);
                        std.Io.Dir.cwd().access(io, full, .{}) catch {
                            loader_error = "referenced file missing";
                            break;
                        };
                    }
                    if (loader_error != null) break;
                }
            } else loader_error = "files object missing";
        } else loader_error = "files object missing";

        if (i != 0) try rows.appendSlice(allocator, ",");
        if (loader_error == null) {
            verifyScriptFixture(allocator, io, manifest, obj) catch |err| {
                failed += 1;
                const row = try std.fmt.allocPrint(allocator, "{{\"fixture_id\":\"{s}\",\"result\":\"failed\",\"failure\":\"{s}\"}}", .{ fixture_id, @errorName(err) });
                defer allocator.free(row);
                try rows.appendSlice(allocator, row);
                continue;
            };
            const row = try std.fmt.allocPrint(allocator, "{{\"fixture_id\":\"{s}\",\"result\":\"passed\",\"failure\":\"\"}}", .{fixture_id});
            defer allocator.free(row);
            try rows.appendSlice(allocator, row);
        } else {
            failed += 1;
            const row = try std.fmt.allocPrint(allocator, "{{\"fixture_id\":\"{s}\",\"result\":\"failed\",\"failure\":\"{s}\"}}", .{ fixture_id, loader_error.? });
            defer allocator.free(row);
            try rows.appendSlice(allocator, row);
        }
    }
    const passed = fixtures.array.items.len - failed;
    const result = if (failed == 0) "passed" else "failed";
    const json = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"port.script_corpus_result.v1\",\"category\":\"script_corpus\",\"implementation\":\"ZigNode\",\"port\":\"zig\",\"runtime_surface\":\"{s}\",\"native_crypto_backend\":\"libsecp256k1\",\"fixture_count\":{},\"passed\":{},\"failed\":{},\"result\":\"{s}\",\"verifier\":{{\"engine\":\"zig_native\",\"delegated\":false,\"crypto_backend\":\"libsecp256k1\",\"implemented\":true,\"source\":\"Nodes/Zig/src/script.zig\"}},\"results\":[{s}]}}\n",
        .{ surface, fixtures.array.items.len, passed, failed, result, rows.items },
    );
    defer allocator.free(json);
    try writeFileEnsuringParent(io, output, json);
    try out.print("{s}", .{json});
}

fn cmdLocalReferenceProof(allocator: std.mem.Allocator, io: std.Io, out: anytype, args: []const []const u8, surface: []const u8, prefetch_text: []const u8, script_threads_text: []const u8) !void {
    const target_text = valueArg(args, "--target") orelse "5000";
    const peer = valueArg(args, "--peer") orelse "bitcoin-core-testnet4:48333";
    const output = valueArg(args, "--output") orelse (ResultPaths{}).proof;
    const datadir = valueArg(args, "--datadir") orelse "/data";
    const target = try std.fmt.parseInt(u32, target_text, 10);
    const profile = proofProfile(target) orelse return error.UnsupportedProofTarget;
    const prefetch_raw = std.fmt.parseInt(usize, prefetch_text, 10) catch 4;
    const prefetch = @min(@max(prefetch_raw, 1), 16);
    const requested_script_threads = if (script_threads_text.len == 0)
        core.defaultScriptThreadCount()
    else
        @min(@max(std.fmt.parseInt(usize, script_threads_text, 10) catch core.defaultScriptThreadCount(), 1), 64);
    const started = core.nowMs();

    try std.Io.Dir.cwd().createDirPath(io, datadir);
    const marker_path = try std.fs.path.join(allocator, &.{ datadir, core.PortInfo.marker_file });
    defer allocator.free(marker_path);
    try writeFileEnsuringParent(io, marker_path, "zig native storage\n");

    const db_path = try std.fs.path.join(allocator, &.{ datadir, core.PortInfo.rocksdb_dir });
    defer allocator.free(db_path);
    try std.Io.Dir.cwd().createDirPath(io, db_path);
    var db = try core.RocksDb.open(allocator, db_path);
    defer db.close();

    const meta = try db.readMetadata(allocator);
    defer db.deinitMetadata(allocator, meta);
    const start_height: u32 = if (meta.validated_height < 0) 0 else @intCast(meta.validated_height + 1);
    const fresh_state = start_height == 0;

    var client = try core.p2p.Client.connect(allocator, peer);
    defer client.close();
    var script_runner = try core.ScriptVerifyRunner.create(allocator, requested_script_threads);
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
    var slow = SlowBlocks{};
    var last_tick_height: u32 = if (start_height == 0) 0 else start_height - 1;
    var last_tick_ms = started;
    var last_utxos: i64 = meta.chainstate_utxo_count;
    const progress_interval: u32 = 500;

    try emitTelemetryTick(out, profile, peer, "startup", last_tick_height, last_utxos, 0, started, last_tick_ms, last_tick_height, timing);

    var cursor: usize = start_height;
    while (cursor <= target) {
        const end = @min(cursor + prefetch, @as(usize, target) + 1);
        const fetch_started = core.nowMs();
        const blocks = try client.requestBlocks(headers[cursor..end], @intCast(cursor));
        timing.p2p_fetch += elapsedMs(fetch_started);
        defer allocator.free(blocks);
        for (blocks) |fetched| {
            defer fetched.deinit(allocator);
            blocks_fetched += 1;
            const block_started = core.nowMs();
            const parse_started = core.nowMs();
            const expected_prev: ?[32]u8 = if (fetched.height == 0) null else headers[fetched.height - 1];
            const decoded = try core.block.decodeBlock(allocator, fetched.raw, fetched.hash, expected_prev);
            defer {
                for (decoded.transactions) |transaction| transaction.deinit(allocator);
                allocator.free(decoded.transactions);
            }
            timing.block_parse_validate += elapsedMs(parse_started);
            const store_started = core.nowMs();
            try db.recordBlock(allocator, fetched.height, decoded.info.hash, fetched.raw);
            timing.block_store += elapsedMs(store_started);
            const connect_started = core.nowMs();
            var connect = try core.connectDecodedBlock(allocator, &db, fetched.height, target, decoded.info, decoded.transactions, script_runner, last_utxos);
            defer connect.deinit(allocator);
            timing.connect_total += elapsedMs(connect_started);
            timing.prevout_batch_load += connect.timings.prevout_batch_load;
            timing.utxo_load += connect.timings.utxo_load;
            timing.utxo_lookup_count += connect.timings.utxo_lookup_count;
            timing.utxo_key_bytes += connect.timings.utxo_key_bytes;
            timing.utxo_value_bytes += connect.timings.utxo_value_bytes;
            timing.created_utxos += connect.timings.created_utxos;
            timing.spent_external += connect.timings.spent_external;
            timing.same_block_spends += connect.timings.same_block_spends;
            timing.runner_batches += connect.timings.runner_batches;
            timing.tx_count += connect.timings.tx_count;
            timing.input_count += connect.timings.input_count;
            timing.script_verify += connect.timings.script_verify;
            timing.script_jobs += connect.timings.script_jobs;
            timing.script_threads = connect.timings.script_threads;
            timing.script_wall_ms += connect.timings.script_wall_ms;
            timing.script_worker_cpu_ms += connect.timings.script_worker_cpu_ms;
            timing.utxo_apply += connect.timings.utxo_apply;
            timing.commit += connect.timings.commit;
            timing.utxo_delete_prepare += connect.timings.utxo_delete_prepare;
            timing.utxo_put_prepare += connect.timings.utxo_put_prepare;
            timing.undo_put_prepare += connect.timings.undo_put_prepare;
            timing.metadata_put_prepare += connect.timings.metadata_put_prepare;
            timing.rocksdb_write += connect.timings.rocksdb_write;
            timing.block_connect_store_commit += connect.timings.block_connect_store_commit;
            blocks_connected += connect.blocks_connected;
            last_height = fetched.height;
            allocator.free(last_hash);
            last_hash = try allocator.dupe(u8, connect.validated_hash);
            const last_block_ms = elapsedMs(block_started);
            slow.record(fetched.height, last_block_ms, connect.timings);
            last_utxos = connect.chainstate_utxo_count;
            const should_tick = fetched.height % progress_interval == 0 or fetched.height == target or core.nowMs() - last_tick_ms >= 30_000;
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
                try emitTelemetryTick(out, profile, peer, "connect", fetched.height, connect.chainstate_utxo_count, last_block_ms, started, last_tick_ms, last_tick_height, timing);
                last_tick_ms = core.nowMs();
                last_tick_height = fetched.height;
            }
        }
        cursor = end;
    }

    const final_meta = try db.readMetadata(allocator);
    defer db.deinitMetadata(allocator, final_meta);
    if (last_height != target) return error.TargetNotReached;
    if (!std.mem.eql(u8, last_hash, profile.expected_hash)) return error.UnexpectedTargetHash;
    if (final_meta.chainstate_utxo_count != profile.expected_utxo_count) return error.UnexpectedUtxoCount;
    try emitTelemetryTick(out, profile, peer, "success", last_height, last_utxos, 0, started, last_tick_ms, last_tick_height, timing);

    const slow_json = try slow.toJson(allocator);
    defer allocator.free(slow_json);
    const total_ms = elapsedMs(started);
    var json_buf = std.ArrayList(u8).empty;
    defer json_buf.deinit(allocator);
    try appendFmt(allocator, &json_buf, "{{\"schema\":\"port.local_reference_proof.v1\",\"category\":\"local_reference_sync\",\"benchmark_contract_version\":1,\"benchmark_gate\":\"{s}\",\"benchmark_kind\":\"{s}\",\"benchmark_lane\":\"{s}\",\"telemetry_schema\":\"benchmark.telemetry_tick.v1\",\"implementation\":\"ZigNode\",\"port\":\"zig\",\"node\":\"ZigNode\",\"chain\":\"testnet4\",\"target_height\":{},\"header_target_height\":{},\"target_label\":\"{s}\",", .{ profile.benchmark_gate, profile.benchmark_kind, profile.benchmark_lane, target, target, profile.target_label });
    try appendFmt(allocator, &json_buf, "\"runtime_surface\":\"{s}\",\"peer_mode\":\"local_reference\",\"peer\":\"{s}\",\"byte_source\":\"local_reference_p2p\",\"proof_mode\":\"p2p_sync\",\"prefetch_depth\":{},\"script_runner_mode\":\"parallel\",\"script_threads\":{},\"rocksdb_wal_disabled\":false,\"fresh_state\":{},\"resume_supported\":true,", .{ surface, peer, prefetch, script_runner.thread_count, fresh_state });
    try appendFmt(allocator, &json_buf, "\"datadir\":\"{s}\",\"chainstate_backend\":\"rocksdb\",\"chainstate_backend_path\":\"{s}\",\"chainstate_status\":\"usable\",\"native_storage\":true,\"native_crypto_available\":true,\"native_crypto_backend\":\"libsecp256k1\",\"schnorr_backend\":\"libsecp256k1\",\"taproot_tweak_backend\":\"libsecp256k1\",\"storage_codec_version\":2,", .{ datadir, db_path });
    try appendFmt(allocator, &json_buf, "\"rocksdb_tuning\":\"{s}\",\"validated_height\":{},\"validated_hash\":\"{s}\",\"header_height\":{},\"stored_block_height\":{},\"blocks_fetched\":{},\"blocks_connected\":{},\"chainstate_utxo_count\":{},", .{ core.RocksDb.tuningDescription(), final_meta.validated_height, last_hash, final_meta.header_height, final_meta.stored_block_height, blocks_fetched, blocks_connected, final_meta.chainstate_utxo_count });
    try appendFmt(allocator, &json_buf, "\"utxo_accounting_policy\":\"core_spendable_v1\",\"sync_status\":\"blocks_current\",\"local_reference_status\":\"target_reached\",\"status\":\"passed\",\"result\":\"passed\",\"current_blocker\":null,\"binary_gate_status\":\"not_attempted\",\"failures\":[],\"reference_start_height\":0,\"reference_start_hash\":\"00000000da84f2bafbbc53dee25a72ae507ff4914b867c565be350b0da8bf043\",\"reference_finish_height\":{},\"reference_finish_hash\":\"{s}\",", .{ target, last_hash });
    try appendFmt(allocator, &json_buf, "\"pipeline_timing_summary\":{{\"telemetry_schema\":\"benchmark.telemetry_tick.v1\",\"total_ms\":{},\"stage_totals_ms\":{{\"p2p_fetch\":{},\"block_parse_validate\":{},\"block_store\":{},\"connect_total\":{},\"utxo_load\":{},\"prevout_batch_load\":{},\"script_verify\":{},\"script_wall_ms\":{},\"script_worker_cpu_ms\":{},\"utxo_apply\":{},\"commit\":{},\"utxo_delete_prepare\":{},\"utxo_put_prepare\":{},\"undo_put_prepare\":{},\"metadata_put_prepare\":{},\"rocksdb_write\":{},\"block_connect_store_commit\":{}}},\"utxo_lookup_count\":{},\"utxo_key_bytes\":{},\"utxo_value_bytes\":{},\"created_utxos\":{},\"spent_external\":{},\"same_block_spends\":{},\"runner_batches\":{},\"tx_count\":{},\"input_count\":{},\"script_jobs\":{},\"script_threads\":{},\"slow_blocks\":[{s}]}},", .{ total_ms, timing.p2p_fetch, timing.block_parse_validate, timing.block_store, timing.connect_total, timing.utxo_load, timing.prevout_batch_load, timing.script_verify, timing.script_wall_ms, timing.script_worker_cpu_ms, timing.utxo_apply, timing.commit, timing.utxo_delete_prepare, timing.utxo_put_prepare, timing.undo_put_prepare, timing.metadata_put_prepare, timing.rocksdb_write, timing.block_connect_store_commit, timing.utxo_lookup_count, timing.utxo_key_bytes, timing.utxo_value_bytes, timing.created_utxos, timing.spent_external, timing.same_block_spends, timing.runner_batches, timing.tx_count, timing.input_count, timing.script_jobs, timing.script_threads, slow_json });
    try appendFmt(allocator, &json_buf, "\"timing_summary\":{{\"total_ms\":{},\"stage_totals_ms\":{{\"utxo_load\":{},\"prevout_batch_load\":{},\"script_verify\":{},\"script_wall_ms\":{},\"script_worker_cpu_ms\":{},\"utxo_apply\":{},\"commit\":{},\"utxo_delete_prepare\":{},\"utxo_put_prepare\":{},\"undo_put_prepare\":{},\"metadata_put_prepare\":{},\"rocksdb_write\":{},\"block_connect_store_commit\":{}}},\"utxo_lookup_count\":{},\"utxo_key_bytes\":{},\"utxo_value_bytes\":{},\"created_utxos\":{},\"spent_external\":{},\"same_block_spends\":{},\"runner_batches\":{},\"tx_count\":{},\"input_count\":{},\"script_jobs\":{},\"script_threads\":{},\"slow_blocks\":[{s}]}}}}\n", .{ total_ms, timing.utxo_load, timing.prevout_batch_load, timing.script_verify, timing.script_wall_ms, timing.script_worker_cpu_ms, timing.utxo_apply, timing.commit, timing.utxo_delete_prepare, timing.utxo_put_prepare, timing.undo_put_prepare, timing.metadata_put_prepare, timing.rocksdb_write, timing.block_connect_store_commit, timing.utxo_lookup_count, timing.utxo_key_bytes, timing.utxo_value_bytes, timing.created_utxos, timing.spent_external, timing.same_block_spends, timing.runner_batches, timing.tx_count, timing.input_count, timing.script_jobs, timing.script_threads, slow_json });
    const json = json_buf.items;
    try writeFileEnsuringParent(io, output, json);
    try out.print("{s}", .{json});
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
    utxo_apply: i64 = 0,
    commit: i64 = 0,
    utxo_delete_prepare: i64 = 0,
    utxo_put_prepare: i64 = 0,
    undo_put_prepare: i64 = 0,
    metadata_put_prepare: i64 = 0,
    rocksdb_write: i64 = 0,
    block_connect_store_commit: i64 = 0,
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
        else => null,
    };
}

fn emitTelemetryTick(
    out: anytype,
    profile: ProofProfile,
    peer: []const u8,
    phase: []const u8,
    height: u32,
    utxos: i64,
    last_block_ms: i64,
    started_ms: i64,
    previous_tick_ms: i64,
    previous_tick_height: u32,
    timing: ProofTiming,
) !void {
    const now = core.nowMs();
    const elapsed_ms = @max(0, now - started_ms);
    const since_tick_ms = @max(1, now - previous_tick_ms);
    const recent_blocks: i64 = if (height >= previous_tick_height) @intCast(height - previous_tick_height) else 0;
    const total_blocks: i64 = @intCast(height + 1);
    const recent_rate = @divTrunc(recent_blocks * 1000, since_tick_ms);
    const total_rate = if (elapsed_ms > 0) @divTrunc(total_blocks * 1000, elapsed_ms) else 0;
    const percent = @divTrunc(@as(u64, height) * 100, @as(u64, profile.target));
    try out.print(
        "benchmark.telemetry_tick {{\"schema\":\"benchmark.telemetry_tick.v1\",\"port\":\"zig\",\"gate\":\"{s}\",\"target_height\":{},\"height\":{},\"percent\":{},\"elapsed_ms\":{},\"rate_recent_blocks_per_second\":{},\"rate_total_blocks_per_second\":{},\"phase\":\"{s}\",\"utxos\":{},\"last_block_ms\":{},\"current_blocker\":null,\"peer\":\"{s}\",",
        .{ profile.benchmark_gate, profile.target, height, percent, elapsed_ms, recent_rate, total_rate, phase, utxos, last_block_ms, peer },
    );
    try out.print(
        "\"utxo_lookup_count\":{},\"utxo_key_bytes\":{},\"utxo_value_bytes\":{},\"created_utxos\":{},\"spent_external\":{},\"same_block_spends\":{},\"runner_batches\":{},\"tx_count\":{},\"input_count\":{},\"script_jobs\":{},\"script_threads\":{},\"script_wall_ms\":{},\"script_worker_cpu_ms\":{},",
        .{ timing.utxo_lookup_count, timing.utxo_key_bytes, timing.utxo_value_bytes, timing.created_utxos, timing.spent_external, timing.same_block_spends, timing.runner_batches, timing.tx_count, timing.input_count, timing.script_jobs, timing.script_threads, timing.script_wall_ms, timing.script_worker_cpu_ms },
    );
    try out.print(
        "\"timing_buckets_ms\":{{\"p2p_fetch\":{},\"block_parse_validate\":{},\"utxo_load\":{},\"script_verify\":{},\"utxo_apply\":{},\"commit\":{},\"utxo_delete_prepare\":{},\"utxo_put_prepare\":{},\"undo_put_prepare\":{},\"metadata_put_prepare\":{},\"rocksdb_write\":{},\"block_connect_store_commit\":{}}}}}\n",
        .{ timing.p2p_fetch, timing.block_parse_validate, timing.utxo_load, timing.script_verify, timing.utxo_apply, timing.commit, timing.utxo_delete_prepare, timing.utxo_put_prepare, timing.undo_put_prepare, timing.metadata_put_prepare, timing.rocksdb_write, timing.block_connect_store_commit },
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

    fn record(self: *SlowBlocks, height: u32, ms: i64, timings: core.ConnectTimings) void {
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

fn elapsedMs(start_ms: i64) i64 {
    return @max(0, core.nowMs() - start_ms);
}

fn verifyScriptFixture(allocator: std.mem.Allocator, io: std.Io, manifest: []const u8, obj: std.json.ObjectMap) !void {
    const tx_path = try firstFixturePath(allocator, manifest, obj, "tx");
    defer allocator.free(tx_path);
    const raw_tx = try readHexFile(allocator, io, tx_path);
    defer allocator.free(raw_tx);
    const parsed = try core.tx.deserialize(allocator, raw_tx, 0);
    defer parsed.transaction.deinit(allocator);
    if (parsed.offset != raw_tx.len) return error.TransactionTrailingBytes;

    const input_index: usize = @intCast(jsonInteger(obj.get("input_index")) orelse return error.InputIndexMissing);
    var loaded_prevouts = loadFixturePrevouts(allocator, io, manifest, obj) catch blk: {
        var fallback = try allocator.alloc(core.script.SpentPrevout, parsed.transaction.inputs.len);
        errdefer allocator.free(fallback);
        for (fallback) |*prevout| prevout.* = .{ .amount = 0, .script_pubkey = try allocator.dupe(u8, &.{}) };
        const prev_spk_path = try firstFixturePath(allocator, manifest, obj, "prev_spk");
        defer allocator.free(prev_spk_path);
        const prev_spk = try readHexFile(allocator, io, prev_spk_path);
        const amount = jsonInteger(obj.get("prev_amount_sats")) orelse 0;
        if (input_index >= fallback.len) {
            allocator.free(prev_spk);
            return error.InputIndexOutOfRange;
        }
        allocator.free(fallback[input_index].script_pubkey);
        fallback[input_index] = .{ .amount = amount, .script_pubkey = prev_spk };
        break :blk fallback;
    };
    defer {
        for (loaded_prevouts) |prevout| allocator.free(prevout.script_pubkey);
        allocator.free(loaded_prevouts);
    }
    if (loaded_prevouts.len != parsed.transaction.inputs.len) {
        if (loaded_prevouts.len != 1) return error.PrevoutCountMismatch;
        const only = loaded_prevouts[0];
        var normalized = try allocator.alloc(core.script.SpentPrevout, parsed.transaction.inputs.len);
        errdefer allocator.free(normalized);
        for (normalized) |*prevout| prevout.* = .{ .amount = 0, .script_pubkey = try allocator.dupe(u8, &.{}) };
        if (input_index >= normalized.len) return error.InputIndexOutOfRange;
        allocator.free(normalized[input_index].script_pubkey);
        normalized[input_index] = .{ .amount = only.amount, .script_pubkey = try allocator.dupe(u8, only.script_pubkey) };
        for (loaded_prevouts) |prevout| allocator.free(prevout.script_pubkey);
        allocator.free(loaded_prevouts);
        loaded_prevouts = normalized;
    }
    if (input_index >= loaded_prevouts.len) return error.InputIndexOutOfRange;

    try core.script.verifyInput(allocator, parsed.transaction, input_index, loaded_prevouts);
}

fn loadFixturePrevouts(allocator: std.mem.Allocator, io: std.Io, manifest: []const u8, obj: std.json.ObjectMap) ![]core.script.SpentPrevout {
    const prevouts_path = try firstFixturePath(allocator, manifest, obj, "prevouts");
    defer allocator.free(prevouts_path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, prevouts_path, allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidPrevoutsJson;
    var prevouts = try allocator.alloc(core.script.SpentPrevout, parsed.value.array.items.len);
    errdefer allocator.free(prevouts);
    for (parsed.value.array.items, 0..) |item, i| {
        if (item != .object) return error.InvalidPrevoutsJson;
        const amount = jsonInteger(item.object.get("amount")) orelse jsonInteger(item.object.get("value")) orelse return error.InvalidPrevoutsJson;
        const spk_hex = jsonString(item.object.get("spk")) orelse jsonString(item.object.get("script_pubkey")) orelse return error.InvalidPrevoutsJson;
        prevouts[i] = .{ .amount = amount, .script_pubkey = try core.crypto.fromHexAlloc(allocator, spk_hex) };
    }
    return prevouts;
}

fn firstFixturePath(allocator: std.mem.Allocator, manifest: []const u8, obj: std.json.ObjectMap, category: []const u8) ![]u8 {
    const files = obj.get("files") orelse return error.FixtureFilesMissing;
    if (files != .object) return error.FixtureFilesMissing;
    const values = files.object.get(category) orelse return error.FixturePathMissing;
    if (values != .array or values.array.items.len == 0) return error.FixturePathMissing;
    const rel = jsonString(values.array.items[0]) orelse return error.FixturePathMissing;
    return std.fs.path.join(allocator, &.{ std.fs.path.dirname(manifest) orelse ".", rel });
}

fn readHexFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(20 * 1024 * 1024));
    defer allocator.free(data);
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    return core.crypto.fromHexAlloc(allocator, trimmed);
}

fn cmdSupervisorOnce(allocator: std.mem.Allocator, out: anytype, args: []const []const u8) !void {
    _ = allocator;
    _ = args;
    try out.print("{{\"schema\":\"port.supervisor_once.v1\",\"port\":\"zig\",\"status\":\"not_ready\",\"current_blocker\":\"sync supervisor requires local-reference P2P implementation\",\"binary_gate_status\":\"not_attempted\"}}\n", .{});
    return error.SupervisorNotImplemented;
}

fn valueArg(args: []const []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], name) and i + 1 < args.len) return args[i + 1];
    }
    return null;
}

fn tryMetadataKey(allocator: std.mem.Allocator, name: []const u8) []u8 {
    return core.encodeMetadataKey(allocator, name) catch @panic("metadata key allocation failed");
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    if (value) |v| {
        if (v == .string) return v.string;
    }
    return null;
}

fn jsonInteger(value: ?std.json.Value) ?i64 {
    if (value) |v| {
        if (v == .integer) return v.integer;
    }
    return null;
}

fn writeFileEnsuringParent(io: std.Io, path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes, .flags = .{} });
}

fn appendFmt(allocator: std.mem.Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const part = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(part);
    try out.appendSlice(allocator, part);
}
