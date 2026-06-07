use anyhow::{bail, Context, Result};
use chrono::Utc;
use serde_json::{Map, Value};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use crate::{connect, p2p, refsync, status, storage};

pub struct LocalReferenceOptions<'a> {
    pub datadir: &'a Path,
    pub target: u32,
    pub rpc_url: &'a str,
    pub rpc_user: &'a str,
    pub rpc_password: &'a str,
    pub peer: &'a str,
    pub result_path: Option<&'a Path>,
    pub progress: u32,
    pub mode: &'a str,
    pub byte_source: &'a str,
    pub runtime_surface: &'a str,
}

fn is_p2p_source(opts: &LocalReferenceOptions<'_>) -> bool {
    matches!(opts.byte_source, "p2p" | "external_p2p")
}

fn is_external_manual(opts: &LocalReferenceOptions<'_>) -> bool {
    opts.byte_source == "external_p2p"
}

fn peer_mode_for(opts: &LocalReferenceOptions<'_>) -> &'static str {
    if is_external_manual(opts) {
        "external_manual"
    } else if is_p2p_source(opts) {
        "local_reference"
    } else {
        "local_reference_rpc"
    }
}

fn byte_source_for(opts: &LocalReferenceOptions<'_>) -> &'static str {
    if is_external_manual(opts) {
        "external_testnet4_p2p"
    } else if is_p2p_source(opts) {
        "local_reference_p2p"
    } else {
        "local_reference_rpc"
    }
}

pub fn run(opts: LocalReferenceOptions<'_>) -> Result<Value> {
    let started = Utc::now();
    let p2p_source = is_p2p_source(&opts);
    let peer_mode = peer_mode_for(&opts);
    let peer = if p2p_source { opts.peer } else { opts.rpc_url };
    let byte_source = byte_source_for(&opts);
    let proof_mode = if p2p_source { "p2p_sync" } else { opts.mode };
    let benchmark_lane = benchmark_lane_for(&opts);
    let mut doc = Map::new();
    doc.insert("implementation".into(), "RustNode".into());
    doc.insert(
        "category".into(),
        if is_external_manual(&opts) {
            "external_peer_sync"
        } else {
            "local_reference_sync"
        }
        .into(),
    );
    doc.insert("runtime_surface".into(), opts.runtime_surface.into());
    doc.insert("captured_at".into(), started.to_rfc3339().into());
    doc.insert("chain".into(), "testnet4".into());
    doc.insert("peer_mode".into(), peer_mode.into());
    doc.insert("peer".into(), peer.into());
    doc.insert(
        "datadir".into(),
        opts.datadir.to_string_lossy().to_string().into(),
    );
    doc.insert("target_height".into(), opts.target.into());
    doc.insert("header_target_height".into(), opts.target.into());
    doc.insert("target_label".into(), target_label_for_opts(&opts).into());
    doc.insert("reference_start_height".into(), 0.into());
    doc.insert(
        "reference_start_hash".into(),
        "00000000da84f2bafbbc53dee25a72ae507ff4914b867c565be350b0da8bf043".into(),
    );
    doc.insert("reference_finish_height".into(), opts.target.into());
    doc.insert("benchmark_contract_version".into(), 1.into());
    doc.insert("benchmark_kind".into(), benchmark_kind(&opts).into());
    doc.insert("benchmark_gate".into(), gate_id_for(&opts).into());
    doc.insert("benchmark_lane".into(), benchmark_lane.into());
    doc.insert("utxo_accounting_policy".into(), "core_spendable_v1".into());
    doc.insert("byte_source".into(), byte_source.into());
    doc.insert("resume_supported".into(), true.into());
    doc.insert("fresh_state".into(), fresh_state_for_env().into());
    doc.insert("proof_mode".into(), proof_mode.into());
    doc.insert("prefetch_depth".into(), (prefetch_depth() as i64).into());
    doc.insert("result".into(), "failed".into());
    doc.insert("failures".into(), Value::Array(Vec::new()));
    insert_tuning_source_metadata(&mut doc);
    if is_external_manual(&opts) {
        doc.insert("selected_peer".into(), opts.peer.into());
        doc.insert("disconnects".into(), 0.into());
        doc.insert("advertised_start_height".into(), 0.into());
        doc.insert("fallback_peer".into(), Value::Null);
        doc.insert("fallback_used".into(), false.into());
        doc.insert(
            "deferred_handshake_state".into(),
            "minimal_handshake_no_deferred_messages".into(),
        );
    }

    let (sync_summary, connect_summary, pipeline_timing_summary) = if opts.mode == "staged" {
        if p2p_source {
            bail!("staged mode is only supported for RPC replay");
        }
        let sync = refsync::run(refsync::SyncOptions {
            datadir: opts.datadir,
            target: opts.target,
            rpc_url: opts.rpc_url,
            rpc_user: opts.rpc_user,
            rpc_password: opts.rpc_password,
            progress: opts.progress,
            runtime_surface: opts.runtime_surface,
        })?;
        let connect = connect::run(connect::ConnectOptions {
            datadir: opts.datadir,
            target: opts.target,
            progress: opts.progress,
            quiet: false,
            runtime_surface: opts.runtime_surface,
        })?;
        (
            serde_json::to_value(sync)?,
            serde_json::to_value(connect)?,
            Value::Null,
        )
    } else if opts.mode == "pipeline" {
        if p2p_source {
            run_p2p_pipeline(&opts)?
        } else {
            run_pipeline(&opts)?
        }
    } else {
        bail!("proof mode must be pipeline or staged");
    };
    doc.insert("sync_summary".into(), sync_summary.clone());
    if let Some(resumed_from_height) = sync_summary.get("resumed_from_height") {
        doc.insert("resumed_from_height".into(), resumed_from_height.clone());
    }
    if let Some(start_height) = sync_summary.get("start_height") {
        doc.insert("start_height".into(), start_height.clone());
    }
    doc.insert("connect_summary".into(), connect_summary.clone());
    doc.insert(
        "connect_summary_kind".into(),
        "final_connect_snapshot".into(),
    );
    doc.insert(
        "pipeline_timing_summary".into(),
        pipeline_timing_summary.clone(),
    );
    if let Value::Object(pipeline) = &pipeline_timing_summary {
        doc.insert(
            "telemetry_schema".into(),
            pipeline
                .get("telemetry_schema")
                .cloned()
                .unwrap_or_else(|| Value::String("benchmark.telemetry_tick.v1".to_string())),
        );
        if let Some(summary) = pipeline.get("telemetry_summary") {
            doc.insert("telemetry_summary".into(), summary.clone());
        }
        doc.insert("timing_summary".into(), pipeline_timing_summary.clone());
    }

    let status_doc = status::build(opts.datadir, opts.runtime_surface)?;
    doc.insert("status".into(), serde_json::to_value(&status_doc)?);
    doc.insert("header_height".into(), status_doc.header_height.into());
    doc.insert(
        "reference_finish_hash".into(),
        status_doc.header_hash.clone().into(),
    );
    doc.insert(
        "validated_height".into(),
        status_doc.validated_height.into(),
    );
    doc.insert(
        "validated_hash".into(),
        status_doc.validated_hash.clone().into(),
    );
    doc.insert(
        "stored_block_height".into(),
        status_doc.stored_block_height.into(),
    );
    doc.insert("sync_status".into(), status_doc.sync_status.into());
    doc.insert(
        "current_blocker".into(),
        status_doc.current_blocker.clone().unwrap_or(Value::Null),
    );
    doc.insert(
        "chainstate_backend".into(),
        status_doc.chainstate_backend.clone().into(),
    );
    doc.insert(
        "chainstate_backend_path".into(),
        status_doc.chainstate_backend_path.into(),
    );
    doc.insert(
        "chainstate_status".into(),
        status_doc.chainstate_status.into(),
    );
    doc.insert(
        "chainstate_utxo_count".into(),
        status_doc.chainstate_utxo_count.into(),
    );
    doc.insert(
        "native_storage".into(),
        (status_doc.chainstate_backend == "rocksdb").into(),
    );
    doc.insert("binary_gate_status".into(), "not_attempted".into());
    doc.insert("native_crypto_backend".into(), "rust-secp256k1".into());
    doc.insert("native_crypto_available".into(), true.into());
    doc.insert("schnorr_backend".into(), "rust-secp256k1".into());
    doc.insert("taproot_tweak_backend".into(), "rust-secp256k1".into());
    doc.insert("storage_codec_version".into(), 2.into());
    doc.insert(
        "rocksdb_tuning".into(),
        "block_cache=256MiB,bloom=10,write_buffer=64MiB,max_write_buffers=4,max_background_jobs=4"
            .into(),
    );
    doc.insert(
        "rocksdb_wal_disabled".into(),
        std::env::var("RSBITNODE_ROCKSDB_DISABLE_WAL")
            .is_ok_and(|v| v == "1")
            .into(),
    );
    doc.insert(
        "script_runner_mode".into(),
        connect_summary["script_runner_mode"]
            .as_str()
            .unwrap_or("unknown")
            .into(),
    );
    doc.insert(
        "blocks_fetched".into(),
        sync_summary["blocks_fetched"].clone(),
    );
    doc.insert(
        "blocks_connected".into(),
        if pipeline_timing_summary.is_null() {
            connect_summary["blocks_connected"].clone()
        } else {
            pipeline_timing_summary["blocks_connected"].clone()
        },
    );
    doc.insert("updated_at".into(), Utc::now().to_rfc3339().into());

    let expected_external_5k_hash =
        "000000000e3cb5b92e9765ed9c80c6b06f3d0a186478b330dd5e6b274acf03e2";
    let reached = connect_summary["reached_target"].as_bool().unwrap_or(false)
        && status_doc.validated_height >= opts.target as i64
        && status_doc.current_blocker.is_none();
    let external_5k_reached = !is_external_manual(&opts)
        || opts.target != 5000
        || (status_doc.validated_hash == expected_external_5k_hash
            && status_doc.chainstate_utxo_count == 4574);
    if reached && external_5k_reached {
        doc.insert("result".into(), "passed".into());
        doc.insert("local_reference_status".into(), "target_reached".into());
    } else {
        doc.insert(
            "local_reference_status".into(),
            "blocked_or_incomplete".into(),
        );
        add_failure(
            &mut doc,
            "connect stopped before target or has current_blocker",
        );
        if is_external_manual(&opts) && opts.target == 5000 && !external_5k_reached {
            add_failure(
                &mut doc,
                "external 5k probe reached unexpected hash or UTXO count",
            );
        }
    }

    let value = Value::Object(doc);
    let default_path;
    let result_path = match opts.result_path {
        Some(path) => Some(path),
        None if opts.runtime_surface == "docker" => {
            default_path = default_result_path()?;
            Some(default_path.as_path())
        }
        None => None,
    };
    if let Some(path) = result_path {
        write_result(path, &value)?;
    }
    Ok(value)
}

fn target_label(target: u32) -> &'static str {
    match target {
        5000 => "5k",
        10000 => "10k",
        50000 => "50k",
        100000 => "100k",
        _ => "",
    }
}

fn env_override(name: &str) -> Option<String> {
    std::env::var(name)
        .ok()
        .filter(|value| !value.trim().is_empty())
}

fn target_label_for_opts(opts: &LocalReferenceOptions<'_>) -> String {
    env_override("RSBITNODE_TARGET_LABEL").unwrap_or_else(|| target_label(opts.target).into())
}

fn fresh_state_for_env() -> bool {
    env_override("RSBITNODE_FRESH_STATE")
        .map(|value| matches!(value.as_str(), "1" | "true" | "yes" | "on"))
        .unwrap_or(true)
}

fn insert_tuning_source_metadata(doc: &mut Map<String, Value>) {
    let mappings = [
        ("RSBITNODE_SOURCE_GATE", "source_gate"),
        ("RSBITNODE_SOURCE_BENCHMARK_LANE", "source_benchmark_lane"),
        ("RSBITNODE_SOURCE_ARTIFACT_PATH", "source_artifact_path"),
        ("RSBITNODE_SOURCE_ARTIFACT_SHA256", "source_artifact_sha256"),
        ("RSBITNODE_SOURCE_DOCKER_VOLUME", "source_docker_volume"),
        ("RSBITNODE_RESTORED_DOCKER_VOLUME", "restored_docker_volume"),
    ];
    for (env_name, field_name) in mappings {
        if let Some(value) = env_override(env_name) {
            doc.insert(field_name.into(), value.into());
        }
    }
    for (env_name, field_name) in [
        (
            "RSBITNODE_SOURCE_VALIDATED_HEIGHT",
            "source_validated_height",
        ),
        (
            "RSBITNODE_SOURCE_CHAINSTATE_UTXO_COUNT",
            "source_chainstate_utxo_count",
        ),
        ("RSBITNODE_SOURCE_HEADER_HEIGHT", "source_header_height"),
    ] {
        if let Some(value) = env_override(env_name) {
            if let Ok(parsed) = value.parse::<i64>() {
                doc.insert(field_name.into(), parsed.into());
            }
        }
    }
    if let Some(value) = env_override("RSBITNODE_SOURCE_VALIDATED_HASH") {
        doc.insert("source_validated_hash".into(), value.into());
    }
    if let Some(value) = env_override("RSBITNODE_SOURCE_UTXO_ACCOUNTING_POLICY") {
        doc.insert("source_utxo_accounting_policy".into(), value.into());
    }
}

fn benchmark_kind(opts: &LocalReferenceOptions<'_>) -> String {
    if let Some(value) = env_override("RSBITNODE_BENCHMARK_KIND") {
        return value;
    }
    if is_external_manual(opts) {
        return match opts.target {
            5000 => "diagnostic_external_5k_p2p",
            _ => "diagnostic_external_p2p",
        }
        .into();
    }
    if is_p2p_source(opts) {
        return match opts.target {
            5000 => "baseline_5k_p2p",
            10000 => "diagnostic_10k_p2p",
            50000 => "shakedown_50k_p2p",
            100000 => "performance_100k_p2p",
            _ => "local_reference_p2p",
        }
        .into();
    }
    match opts.target {
        5000 => "diagnostic_5k_durable_local_reference_replay",
        10000 => "diagnostic_10k_durable_local_reference_replay",
        50000 => "diagnostic_50k_durable_local_reference_replay",
        100000 => "diagnostic_100k_durable_local_reference_replay",
        _ => "local_reference_replay",
    }
    .into()
}

fn benchmark_lane_for(opts: &LocalReferenceOptions<'_>) -> String {
    if let Some(value) = env_override("RSBITNODE_BENCHMARK_LANE") {
        return value;
    }
    if is_external_manual(opts) {
        return match opts.target {
            5000 => "diagnostic_external_5k_p2p",
            _ => "diagnostic_external_p2p",
        }
        .into();
    }
    match (opts.target, is_p2p_source(opts)) {
        (5000, true) => "baseline_5k_p2p",
        (10000, true) => "diagnostic_10k_p2p",
        (50000, true) => "shakedown_50k_p2p",
        (100000, true) => "performance_100k_p2p",
        (5000, false) => "diagnostic_5k_rpc_replay",
        (10000, false) => "diagnostic_10k_rpc_replay",
        (50000, false) => "diagnostic_50k_rpc_replay",
        (100000, false) => "diagnostic_100k_rpc_replay",
        (_, true) => "local_reference_p2p",
        (_, false) => "local_reference_rpc",
    }
    .into()
}

fn run_p2p_pipeline(opts: &LocalReferenceOptions<'_>) -> Result<(Value, Value, Value)> {
    let store = storage::Store::open(opts.datadir)?;
    let meta = store
        .metadata()
        .unwrap_or_else(|_| storage::missing_metadata());
    let start_height = if meta.validated_height == 0 && meta.validated_hash.is_empty() {
        0
    } else {
        u32::try_from(meta.validated_height + 1).unwrap_or(0)
    };
    let resumed_from_height = if start_height == 0 {
        Value::Null
    } else {
        Value::from(meta.validated_height)
    };
    let started = Utc::now().to_rfc3339();
    let mut timing = PipelineTiming::new(prefetch_depth());
    let mut last_connect = Value::Null;
    let mut fetched = 0u32;
    let mut connected = 0u32;
    let mut last_tick_height = start_height.saturating_sub(1);
    let mut last_tick_elapsed = Duration::ZERO;
    emit_telemetry_tick(
        opts,
        "run_started",
        "startup",
        "none",
        start_height.saturating_sub(1),
        "",
        0,
        0,
        0,
        "starting",
        &Option::<Value>::None,
        Duration::ZERO,
        &mut timing,
        &mut last_tick_height,
        &mut last_tick_elapsed,
    );
    emit_telemetry_tick(
        opts,
        "container_started",
        "startup",
        "none",
        start_height.saturating_sub(1),
        "",
        0,
        0,
        0,
        "starting",
        &Option::<Value>::None,
        Duration::ZERO,
        &mut timing,
        &mut last_tick_height,
        &mut last_tick_elapsed,
    );
    emit_telemetry_tick(
        opts,
        "node_started",
        "startup",
        "none",
        start_height.saturating_sub(1),
        "",
        0,
        0,
        0,
        "starting",
        &Option::<Value>::None,
        Duration::ZERO,
        &mut timing,
        &mut last_tick_height,
        &mut last_tick_elapsed,
    );
    let mut first_peer_byte = false;
    let mut first_block_connected = false;
    let receiver = p2p::fetch_blocks(p2p::FetchOptions {
        peer: opts.peer.to_string(),
        target: opts.target,
        start_height,
        prefetch: timing.prefetch_depth,
    });

    for expected_height in start_height..=opts.target {
        let block = receiver
            .recv()
            .context("local-reference P2P fetcher stopped early")?
            .with_context(|| format!("height {expected_height}"))?;
        if block.height < start_height {
            continue;
        }
        if block.height != expected_height {
            bail!(
                "P2P height ordering mismatch: got {} want {}",
                block.height,
                expected_height
            );
        }
        if !first_peer_byte {
            emit_telemetry_tick(
                opts,
                "first_peer_byte",
                "peer_connect",
                "none",
                block.height,
                &block.hash,
                0,
                0,
                connected,
                "peer_connected",
                &Option::<Value>::None,
                Duration::ZERO,
                &mut timing,
                &mut last_tick_height,
                &mut last_tick_elapsed,
            );
            first_peer_byte = true;
        }
        timing.add(
            "p2p_fetch",
            Duration::from_millis(block.fetch_ms.max(0) as u64),
        );
        let block_started = Instant::now();
        let parse_started = Instant::now();
        let expected_prev = if block.height == 0 {
            None
        } else {
            store
                .metadata()
                .ok()
                .map(|meta| meta.validated_hash)
                .filter(|hash| !hash.is_empty())
        };
        let (info, txs) =
            refsync::decode_block(&block.raw, Some(&block.hash), expected_prev.as_deref())?;
        timing.add("block_parse_validate", parse_started.elapsed());
        let store_started = Instant::now();
        store.record_block(block.height, &info.hash, &block.raw)?;
        timing.add("block_store", store_started.elapsed());
        if block.height == 0
            || block.height % opts.progress.max(1) == 0
            || block.height == opts.target
        {
            let meta_started = Instant::now();
            let meta = refsync::metadata_after_store(
                store.metadata().ok(),
                block.height,
                &info.hash,
                &started,
            );
            store.put_metadata(&meta)?;
            timing.add("metadata_store", meta_started.elapsed());
        }

        let connect_started = Instant::now();
        let connect = connect::connect_decoded_block(
            &store,
            block.height,
            opts.target,
            &info,
            &txs,
            opts.runtime_surface,
        )?;
        timing.add("connect_total", connect_started.elapsed());
        timing.merge_connect(&connect);
        connected += connect.blocks_connected;
        let mut block_shape = connect::block_shape_summary(&txs);
        if let Some(slow_block) = connect.timing_summary.slow_blocks.first() {
            block_shape.spent_prevout_script_types = slow_block.spent_prevout_script_types.clone();
        }
        last_connect = serde_json::to_value(&connect)?;
        fetched += 1;
        let elapsed_block = block_started.elapsed();
        timing.record_block(block.height, elapsed_block, block_shape);
        if !first_block_connected && block.height > 0 {
            emit_telemetry_tick(
                opts,
                "first_block_connected",
                "block_connect",
                "none",
                block.height,
                &info.hash,
                info.tx_count,
                connect.chainstate_utxo_count,
                connected,
                &connect.sync_status,
                &connect.current_blocker,
                elapsed_block,
                &mut timing,
                &mut last_tick_height,
                &mut last_tick_elapsed,
            );
            first_block_connected = true;
        }
        if block.height % opts.progress.max(1) == 0 || block.height == opts.target {
            println!(
                "rsbitnode-local-reference-proof p2p progress {}",
                serde_json::json!({
                    "height": block.height,
                    "target_height": opts.target,
                    "start_height": start_height,
                    "resumed_from_height": resumed_from_height,
                    "percent": ((block.height as f64 / opts.target.max(1) as f64) * 100.0),
                    "hash": info.hash,
                    "txs": info.tx_count,
                    "utxos": connect.chainstate_utxo_count,
                    "blocks_fetched": fetched,
                    "blocks_connected": connected,
                    "prefetch_depth": timing.prefetch_depth,
                    "elapsed_ms": timing.started.elapsed().as_millis() as i64,
                    "last_block_ms": elapsed_block.as_millis() as i64,
                    "blocks_per_second": connected as f64 / timing.started.elapsed().as_secs_f64().max(0.001),
                    "script_runner_mode": connect.script_runner_mode,
                    "sync_status": &connect.sync_status,
                    "current_blocker": &connect.current_blocker,
                })
            );
            emit_telemetry_tick(
                opts,
                "heartbeat",
                "heartbeat",
                telemetry_stall_class(&connect.current_blocker, elapsed_block),
                block.height,
                &info.hash,
                info.tx_count,
                connect.chainstate_utxo_count,
                connected,
                &connect.sync_status,
                &connect.current_blocker,
                elapsed_block,
                &mut timing,
                &mut last_tick_height,
                &mut last_tick_elapsed,
            );
        }
        if connect.current_blocker.is_some() {
            let meta_started = Instant::now();
            let mut meta = store.metadata()?;
            meta.header_height = block.height as i64;
            meta.header_hash = info.hash.clone();
            meta.stored_block_height = block.height as i64;
            meta.stored_block_hash = info.hash;
            store.put_metadata(&meta)?;
            timing.add("metadata_store", meta_started.elapsed());
            break;
        }
    }
    emit_telemetry_tick(
        opts,
        "target_reached",
        "complete",
        "none",
        opts.target,
        last_connect["validated_hash"].as_str().unwrap_or_default(),
        0,
        last_connect["chainstate_utxo_count"]
            .as_i64()
            .unwrap_or_default(),
        connected,
        last_connect["sync_status"]
            .as_str()
            .unwrap_or("blocks_current"),
        &Option::<Value>::None,
        Duration::ZERO,
        &mut timing,
        &mut last_tick_height,
        &mut last_tick_elapsed,
    );
    emit_telemetry_tick(
        opts,
        "run_finished",
        "complete",
        "none",
        opts.target,
        last_connect["validated_hash"].as_str().unwrap_or_default(),
        0,
        last_connect["chainstate_utxo_count"]
            .as_i64()
            .unwrap_or_default(),
        connected,
        last_connect["sync_status"]
            .as_str()
            .unwrap_or("blocks_current"),
        &Option::<Value>::None,
        Duration::ZERO,
        &mut timing,
        &mut last_tick_height,
        &mut last_tick_elapsed,
    );
    let sync = serde_json::json!({
        "implementation": "RustNode",
        "runtime_surface": opts.runtime_surface,
        "peer_mode": peer_mode_for(opts),
        "peer": opts.peer,
        "target_height": opts.target,
        "start_height": start_height,
        "resumed_from_height": resumed_from_height,
        "header_height": if fetched == 0 { meta.header_height } else { i64::from(start_height + fetched - 1) },
        "stored_block_height": if fetched == 0 { meta.stored_block_height } else { i64::from(start_height + fetched - 1) },
        "validated_height": last_connect["validated_height"],
        "sync_status": last_connect["sync_status"],
        "current_blocker": last_connect["current_blocker"],
        "binary_gate_status": "not_attempted",
        "byte_source": byte_source_for(opts),
        "started_at": started,
        "updated_at": Utc::now().to_rfc3339(),
        "blocks_fetched": fetched,
        "blocks_connected": connected,
    });
    timing.blocks_fetched = fetched;
    timing.blocks_connected = connected;
    Ok((sync, last_connect, timing.as_json()))
}

fn run_pipeline(opts: &LocalReferenceOptions<'_>) -> Result<(Value, Value, Value)> {
    let store = storage::Store::open(opts.datadir)?;
    let meta = store
        .metadata()
        .unwrap_or_else(|_| storage::missing_metadata());
    let start_height = if meta.validated_height == 0 && meta.validated_hash.is_empty() {
        0
    } else {
        u32::try_from(meta.validated_height + 1).unwrap_or(0)
    };
    let resumed_from_height = if start_height == 0 {
        Value::Null
    } else {
        Value::from(meta.validated_height)
    };
    let previous_hash = if start_height == 0 {
        String::new()
    } else {
        meta.validated_hash.clone()
    };
    let started = Utc::now().to_rfc3339();
    let mut timing = PipelineTiming::new(prefetch_depth());
    let mut last_connect = Value::Null;
    let mut fetched = 0u32;
    let mut connected = 0u32;
    let mut last_tick_height = start_height.saturating_sub(1);
    let mut last_tick_elapsed = Duration::ZERO;
    emit_telemetry_tick(
        opts,
        "run_started",
        "startup",
        "none",
        start_height.saturating_sub(1),
        "",
        0,
        0,
        0,
        "starting",
        &Option::<Value>::None,
        Duration::ZERO,
        &mut timing,
        &mut last_tick_height,
        &mut last_tick_elapsed,
    );
    emit_telemetry_tick(
        opts,
        "container_started",
        "startup",
        "none",
        start_height.saturating_sub(1),
        "",
        0,
        0,
        0,
        "starting",
        &Option::<Value>::None,
        Duration::ZERO,
        &mut timing,
        &mut last_tick_height,
        &mut last_tick_elapsed,
    );
    emit_telemetry_tick(
        opts,
        "node_started",
        "startup",
        "none",
        start_height.saturating_sub(1),
        "",
        0,
        0,
        0,
        "starting",
        &Option::<Value>::None,
        Duration::ZERO,
        &mut timing,
        &mut last_tick_height,
        &mut last_tick_elapsed,
    );
    let mut first_peer_byte = false;
    let mut first_block_connected = false;
    let (sender, receiver) = mpsc::sync_channel(timing.prefetch_depth);
    let rpc_url = opts.rpc_url.to_string();
    let rpc_user = opts.rpc_user.to_string();
    let rpc_password = opts.rpc_password.to_string();
    let target = opts.target;
    thread::spawn(move || {
        let client = refsync::Client::new(&rpc_url, &rpc_user, &rpc_password);
        let mut prev = previous_hash;
        for height in start_height..=target {
            let result = fetch_prepared_block(&client, height, &prev);
            match result {
                Ok(block) => {
                    prev = block.info.hash.clone();
                    if sender.send(Ok(block)).is_err() {
                        break;
                    }
                }
                Err(err) => {
                    let _ = sender.send(Err(err));
                    break;
                }
            }
        }
    });

    for expected_height in start_height..=opts.target {
        let block = receiver
            .recv()
            .context("local-reference prefetch worker stopped early")?
            .with_context(|| format!("height {expected_height}"))?;
        if block.height != expected_height {
            bail!(
                "prefetch height ordering mismatch: got {} want {}",
                block.height,
                expected_height
            );
        }
        if !first_peer_byte {
            emit_telemetry_tick(
                opts,
                "first_peer_byte",
                "peer_connect",
                "none",
                block.height,
                &block.info.hash,
                block.info.tx_count,
                0,
                connected,
                "peer_connected",
                &Option::<Value>::None,
                Duration::ZERO,
                &mut timing,
                &mut last_tick_height,
                &mut last_tick_elapsed,
            );
            first_peer_byte = true;
        }
        timing.merge_fetch(&block.timings);
        let block_started = Instant::now();
        let store_started = Instant::now();
        store.record_block(block.height, &block.info.hash, &block.raw)?;
        timing.add("block_store", store_started.elapsed());
        if block.height == 0
            || block.height % opts.progress.max(1) == 0
            || block.height == opts.target
        {
            let meta_started = Instant::now();
            let meta = refsync::metadata_after_store(
                store.metadata().ok(),
                block.height,
                &block.info.hash,
                &started,
            );
            store.put_metadata(&meta)?;
            timing.add("metadata_store", meta_started.elapsed());
        }

        let connect_started = Instant::now();
        let connect = connect::connect_decoded_block(
            &store,
            block.height,
            opts.target,
            &block.info,
            &block.txs,
            opts.runtime_surface,
        )?;
        timing.add("connect_total", connect_started.elapsed());
        timing.merge_connect(&connect);
        connected += connect.blocks_connected;
        let mut block_shape = connect::block_shape_summary(&block.txs);
        if let Some(slow_block) = connect.timing_summary.slow_blocks.first() {
            block_shape.spent_prevout_script_types = slow_block.spent_prevout_script_types.clone();
        }
        last_connect = serde_json::to_value(&connect)?;
        fetched += 1;
        let block_ms = block
            .timings
            .total()
            .saturating_add(connect_started.elapsed());
        let elapsed_block = block_started.elapsed().max(block_ms);
        timing.record_block(block.height, elapsed_block, block_shape);
        if !first_block_connected && block.height > 0 {
            emit_telemetry_tick(
                opts,
                "first_block_connected",
                "block_connect",
                "none",
                block.height,
                &block.info.hash,
                block.info.tx_count,
                connect.chainstate_utxo_count,
                connected,
                &connect.sync_status,
                &connect.current_blocker,
                elapsed_block,
                &mut timing,
                &mut last_tick_height,
                &mut last_tick_elapsed,
            );
            first_block_connected = true;
        }
        if block.height % opts.progress.max(1) == 0 || block.height == opts.target {
            println!(
                "rsbitnode-local-reference-proof progress {}",
                serde_json::json!({
                    "height": block.height,
                    "target_height": opts.target,
                    "start_height": start_height,
                    "resumed_from_height": resumed_from_height,
                    "percent": ((block.height as f64 / opts.target.max(1) as f64) * 100.0),
                    "hash": block.info.hash,
                    "txs": block.info.tx_count,
                    "utxos": connect.chainstate_utxo_count,
                    "blocks_fetched": fetched,
                    "blocks_connected": connected,
                    "prefetch_depth": timing.prefetch_depth,
                    "elapsed_ms": timing.started.elapsed().as_millis() as i64,
                    "last_block_ms": elapsed_block.as_millis() as i64,
                    "blocks_per_second": connected as f64 / timing.started.elapsed().as_secs_f64().max(0.001),
                    "script_runner_mode": connect.script_runner_mode,
                    "sync_status": &connect.sync_status,
                    "current_blocker": &connect.current_blocker,
                })
            );
            emit_telemetry_tick(
                opts,
                "heartbeat",
                "heartbeat",
                telemetry_stall_class(&connect.current_blocker, elapsed_block),
                block.height,
                &block.info.hash,
                block.info.tx_count,
                connect.chainstate_utxo_count,
                connected,
                &connect.sync_status,
                &connect.current_blocker,
                elapsed_block,
                &mut timing,
                &mut last_tick_height,
                &mut last_tick_elapsed,
            );
        }
        if connect.current_blocker.is_some() {
            let meta_started = Instant::now();
            let mut meta = store.metadata()?;
            meta.header_height = block.height as i64;
            meta.header_hash = block.info.hash.clone();
            meta.stored_block_height = block.height as i64;
            meta.stored_block_hash = block.info.hash;
            store.put_metadata(&meta)?;
            timing.add("metadata_store", meta_started.elapsed());
            break;
        }
    }
    emit_telemetry_tick(
        opts,
        "target_reached",
        "complete",
        "none",
        opts.target,
        last_connect["validated_hash"].as_str().unwrap_or_default(),
        0,
        last_connect["chainstate_utxo_count"]
            .as_i64()
            .unwrap_or_default(),
        connected,
        last_connect["sync_status"]
            .as_str()
            .unwrap_or("blocks_current"),
        &Option::<Value>::None,
        Duration::ZERO,
        &mut timing,
        &mut last_tick_height,
        &mut last_tick_elapsed,
    );
    emit_telemetry_tick(
        opts,
        "run_finished",
        "complete",
        "none",
        opts.target,
        last_connect["validated_hash"].as_str().unwrap_or_default(),
        0,
        last_connect["chainstate_utxo_count"]
            .as_i64()
            .unwrap_or_default(),
        connected,
        last_connect["sync_status"]
            .as_str()
            .unwrap_or("blocks_current"),
        &Option::<Value>::None,
        Duration::ZERO,
        &mut timing,
        &mut last_tick_height,
        &mut last_tick_elapsed,
    );
    let sync = serde_json::json!({
        "implementation": "RustNode",
        "runtime_surface": opts.runtime_surface,
        "peer_mode": "local_reference_rpc",
        "peer": opts.rpc_url,
        "target_height": opts.target,
        "start_height": start_height,
        "resumed_from_height": resumed_from_height,
        "header_height": if fetched == 0 { meta.header_height } else { i64::from(start_height + fetched - 1) },
        "stored_block_height": if fetched == 0 { meta.stored_block_height } else { i64::from(start_height + fetched - 1) },
        "validated_height": last_connect["validated_height"],
        "sync_status": last_connect["sync_status"],
        "current_blocker": last_connect["current_blocker"],
        "binary_gate_status": "not_attempted",
        "started_at": started,
        "updated_at": Utc::now().to_rfc3339(),
        "blocks_fetched": fetched,
        "blocks_connected": connected,
    });
    timing.blocks_fetched = fetched;
    timing.blocks_connected = connected;
    Ok((sync, last_connect, timing.as_json()))
}

struct PreparedBlock {
    height: u32,
    raw: Vec<u8>,
    info: refsync::BlockInfo,
    txs: Vec<crate::tx::Transaction>,
    timings: FetchTimings,
}

#[derive(Default)]
struct FetchTimings {
    rpc_getblockhash: Duration,
    rpc_getblock: Duration,
    block_parse_validate: Duration,
}

impl FetchTimings {
    fn total(&self) -> Duration {
        self.rpc_getblockhash + self.rpc_getblock + self.block_parse_validate
    }
}

fn fetch_prepared_block(
    client: &refsync::Client,
    height: u32,
    prev: &str,
) -> Result<PreparedBlock> {
    let mut timings = FetchTimings::default();
    let started = Instant::now();
    let hash = client.block_hash(height)?;
    timings.rpc_getblockhash = started.elapsed();
    let started = Instant::now();
    let raw = client.raw_block(&hash)?;
    timings.rpc_getblock = started.elapsed();
    let started = Instant::now();
    let (info, txs) = refsync::decode_block(
        &raw,
        Some(&hash),
        if height == 0 { None } else { Some(prev) },
    )?;
    timings.block_parse_validate = started.elapsed();
    Ok(PreparedBlock {
        height,
        raw,
        info,
        txs,
        timings,
    })
}

struct PipelineTiming {
    started: Instant,
    run_id: String,
    stage_totals: BTreeMap<&'static str, Duration>,
    counts: BTreeMap<&'static str, usize>,
    lifecycle_markers: BTreeMap<String, i64>,
    phase_counts: BTreeMap<String, usize>,
    stall_class_counts: BTreeMap<String, usize>,
    telemetry_tick_count: usize,
    heartbeat_max_gap: Duration,
    last_telemetry_elapsed: Option<Duration>,
    slow_blocks: Vec<Value>,
    blocks_fetched: u32,
    blocks_connected: u32,
    prefetch_depth: usize,
}

impl PipelineTiming {
    fn new(prefetch_depth: usize) -> Self {
        Self {
            started: Instant::now(),
            run_id: format!("rust-{}", Utc::now().timestamp_millis()),
            stage_totals: BTreeMap::new(),
            counts: BTreeMap::new(),
            lifecycle_markers: BTreeMap::new(),
            phase_counts: BTreeMap::new(),
            stall_class_counts: BTreeMap::new(),
            telemetry_tick_count: 0,
            heartbeat_max_gap: Duration::ZERO,
            last_telemetry_elapsed: None,
            slow_blocks: Vec::new(),
            blocks_fetched: 0,
            blocks_connected: 0,
            prefetch_depth,
        }
    }

    fn add(&mut self, stage: &'static str, elapsed: Duration) {
        *self.stage_totals.entry(stage).or_default() += elapsed;
    }

    fn add_count(&mut self, name: &'static str, value: usize) {
        *self.counts.entry(name).or_default() += value;
    }

    fn max_count(&mut self, name: &'static str, value: usize) {
        self.counts
            .entry(name)
            .and_modify(|existing| *existing = (*existing).max(value))
            .or_insert(value);
    }

    fn merge_fetch(&mut self, timings: &FetchTimings) {
        self.add("rpc_getblockhash", timings.rpc_getblockhash);
        self.add("rpc_getblock", timings.rpc_getblock);
        self.add("block_parse_validate", timings.block_parse_validate);
    }

    fn merge_connect(&mut self, summary: &connect::ConnectSummary) {
        for (stage, millis) in &summary.timing_summary.stage_totals_ms {
            self.add(
                match stage.as_str() {
                    "prevout_batch_load" => "prevout_batch_load",
                    "script_verify" => "script_verify",
                    "commit" => "commit",
                    "utxo_apply" => "utxo_apply",
                    "utxo_load" => "utxo_load",
                    "block_read" => "block_read",
                    "block_parse_validate" => "block_parse_validate",
                    "block_connect_store_commit" => "block_connect_store_commit",
                    "utxo_delete_prepare" => "utxo_delete_prepare",
                    "utxo_put_prepare" => "utxo_put_prepare",
                    "undo_put_prepare" => "undo_put_prepare",
                    "metadata_put_prepare" => "metadata_put_prepare",
                    "rocksdb_write" => "rocksdb_write",
                    "prevout_multi_get_call" => "prevout_multi_get_call",
                    "prevout_utxo_decode" => "prevout_utxo_decode",
                    _ => "connect_other",
                },
                Duration::from_millis(*millis as u64),
            );
        }
        self.max_count("script_threads", summary.timing_summary.script_threads);
        self.add_count("script_jobs", summary.timing_summary.script_jobs);
        self.add_count("runner_batches", summary.timing_summary.runner_batches);
        self.add_count(
            "script_wall_ms",
            summary.timing_summary.script_wall_ms.max(0) as usize,
        );
        self.add_count(
            "script_worker_cpu_ms",
            summary.timing_summary.script_worker_cpu_ms.max(0) as usize,
        );
        self.add_count(
            "utxo_lookup_count",
            summary.timing_summary.utxo_lookup_count,
        );
        self.add_count(
            "same_block_spends",
            summary.timing_summary.same_block_spends,
        );
        self.add_count("created_utxos", summary.timing_summary.created_utxos);
        self.add_count("spent_external", summary.timing_summary.spent_external);
        self.add_count("utxo_key_bytes", summary.timing_summary.utxo_key_bytes);
        self.add_count("utxo_value_bytes", summary.timing_summary.utxo_value_bytes);
    }

    fn record_block(&mut self, height: u32, elapsed: Duration, shape: connect::BlockShapeSummary) {
        self.slow_blocks.push(serde_json::json!({
            "height": height,
            "ms": elapsed.as_millis() as i64,
            "tx_count": shape.tx_count,
            "vin_count": shape.vin_count,
            "vout_count": shape.vout_count,
            "script_input_count": shape.script_input_count,
            "same_block_spends": shape.same_block_spends,
            "created_utxos": shape.created_utxos,
            "spent_external": shape.spent_external,
            "input_shape_counts": shape.input_shape_counts,
            "spent_prevout_script_types": shape.spent_prevout_script_types,
            "output_script_types": shape.output_script_types,
        }));
        self.slow_blocks
            .sort_by_key(|value| -value["ms"].as_i64().unwrap_or_default());
        self.slow_blocks.truncate(10);
    }

    fn record_telemetry(&mut self, event: &str, phase: &str, stall_class: &str, elapsed: Duration) {
        self.telemetry_tick_count += 1;
        self.lifecycle_markers
            .entry(event.to_string())
            .or_insert(elapsed.as_millis() as i64);
        *self.phase_counts.entry(phase.to_string()).or_default() += 1;
        *self
            .stall_class_counts
            .entry(stall_class.to_string())
            .or_default() += 1;
        if let Some(last) = self.last_telemetry_elapsed {
            self.heartbeat_max_gap = self.heartbeat_max_gap.max(elapsed.saturating_sub(last));
        }
        self.last_telemetry_elapsed = Some(elapsed);
    }

    fn telemetry_summary_json(&self) -> Value {
        let required = [
            "run_started",
            "container_started",
            "node_started",
            "first_peer_byte",
            "first_block_connected",
            "target_reached",
            "run_finished",
        ];
        let mut quality = "clean";
        if required
            .iter()
            .any(|event| !self.lifecycle_markers.contains_key(*event))
        {
            quality = "sparse";
        }
        if self.heartbeat_max_gap > Duration::from_secs(15) {
            quality = "invalid";
        }
        serde_json::json!({
            "telemetry_quality": quality,
            "tick_count": self.telemetry_tick_count,
            "lifecycle_markers": self.lifecycle_markers,
            "heartbeat_max_gap_ms": self.heartbeat_max_gap.as_millis() as i64,
            "heartbeat_limit_ms": 15000,
            "phase_counts": self.phase_counts,
            "stall_class_counts": self.stall_class_counts,
            "slow_blocks": self.slow_blocks,
        })
    }

    fn as_json(&self) -> Value {
        let mut doc = Map::new();
        let mut stage_totals = self.stage_totals.clone();
        if !stage_totals.contains_key("block_connect_store_commit") {
            if let Some(connect_total) = stage_totals.get("connect_total").copied() {
                stage_totals.insert("block_connect_store_commit", connect_total);
            }
        }
        for stage in [
            "p2p_fetch",
            "block_parse_validate",
            "utxo_load",
            "script_verify",
            "utxo_apply",
            "commit",
            "block_connect_store_commit",
        ] {
            stage_totals.entry(stage).or_default();
        }
        let total_ms = self.started.elapsed().as_millis() as i64;
        doc.insert("total_ms".into(), total_ms.into());
        doc.insert("total_wall".into(), total_ms.into());
        doc.insert("prefetch_depth".into(), (self.prefetch_depth as i64).into());
        doc.insert("blocks_fetched".into(), self.blocks_fetched.into());
        doc.insert("blocks_connected".into(), self.blocks_connected.into());
        doc.insert(
            "telemetry_schema".into(),
            "benchmark.telemetry_tick.v1".into(),
        );
        doc.insert("telemetry_summary".into(), self.telemetry_summary_json());
        for stage in [
            "rpc_getblockhash",
            "rpc_getblock",
            "p2p_fetch",
            "block_parse_validate",
            "block_store",
            "metadata_store",
            "connect_total",
            "utxo_load",
            "prevout_batch_load",
            "script_verify",
            "commit",
            "utxo_apply",
            "block_connect_store_commit",
            "utxo_delete_prepare",
            "utxo_put_prepare",
            "undo_put_prepare",
            "metadata_put_prepare",
            "rocksdb_write",
            "prevout_multi_get_call",
            "prevout_utxo_decode",
        ] {
            doc.insert(
                stage.into(),
                (stage_totals
                    .get(stage)
                    .copied()
                    .unwrap_or_default()
                    .as_millis() as i64)
                    .into(),
            );
        }
        doc.insert(
            "stage_totals_ms".into(),
            Value::Object(
                stage_totals
                    .iter()
                    .map(|(stage, elapsed)| {
                        ((*stage).to_string(), (elapsed.as_millis() as i64).into())
                    })
                    .collect(),
            ),
        );
        for count in [
            "script_threads",
            "script_jobs",
            "runner_batches",
            "script_wall_ms",
            "script_worker_cpu_ms",
            "utxo_lookup_count",
            "same_block_spends",
            "created_utxos",
            "spent_external",
            "utxo_key_bytes",
            "utxo_value_bytes",
        ] {
            doc.insert(
                count.into(),
                ((*self.counts.get(count).unwrap_or(&0)) as i64).into(),
            );
        }
        doc.insert(
            "prevout_multi_get_call".into(),
            (stage_totals
                .get("prevout_multi_get_call")
                .copied()
                .unwrap_or_default()
                .as_millis() as i64)
                .into(),
        );
        doc.insert(
            "prevout_utxo_decode_ms".into(),
            (stage_totals
                .get("prevout_utxo_decode")
                .copied()
                .unwrap_or_default()
                .as_millis() as i64)
                .into(),
        );
        doc.insert("slow_blocks".into(), Value::Array(self.slow_blocks.clone()));
        Value::Object(doc)
    }

    fn timing_buckets_json(&self) -> Value {
        let mut buckets = Map::new();
        let p2p_fetch = self
            .stage_totals
            .get("p2p_fetch")
            .copied()
            .unwrap_or_default()
            + self
                .stage_totals
                .get("rpc_getblockhash")
                .copied()
                .unwrap_or_default()
            + self
                .stage_totals
                .get("rpc_getblock")
                .copied()
                .unwrap_or_default();
        buckets.insert("p2p_fetch".into(), (p2p_fetch.as_millis() as i64).into());
        for stage in [
            "block_parse_validate",
            "utxo_load",
            "prevout_batch_load",
            "script_verify",
            "utxo_apply",
            "commit",
            "block_connect_store_commit",
            "utxo_delete_prepare",
            "utxo_put_prepare",
            "undo_put_prepare",
            "metadata_put_prepare",
            "rocksdb_write",
        ] {
            buckets.insert(
                stage.into(),
                (self
                    .stage_totals
                    .get(stage)
                    .copied()
                    .unwrap_or_default()
                    .as_millis() as i64)
                    .into(),
            );
        }
        Value::Object(buckets)
    }
}

#[allow(clippy::too_many_arguments)]
fn emit_telemetry_tick(
    opts: &LocalReferenceOptions<'_>,
    event: &str,
    phase: &str,
    stall_class: &str,
    height: u32,
    hash: &str,
    tx_count: usize,
    utxos: i64,
    connected: u32,
    sync_status: &str,
    current_blocker: &Option<Value>,
    last_block_elapsed: Duration,
    timing: &mut PipelineTiming,
    last_tick_height: &mut u32,
    last_tick_elapsed: &mut Duration,
) {
    let elapsed = timing.started.elapsed();
    let elapsed_delta = elapsed.saturating_sub(*last_tick_elapsed);
    let height_delta = height.saturating_sub(*last_tick_height);
    let recent_rate = height_delta as f64 / elapsed_delta.as_secs_f64().max(0.001);
    let total_rate = connected as f64 / elapsed.as_secs_f64().max(0.001);
    let mut final_phase = phase;
    if stall_class == "block_connect_slow" {
        final_phase = "block_connect";
    } else if stall_class == "commit_slow" {
        final_phase = "commit";
    }
    timing.record_telemetry(event, final_phase, stall_class, elapsed);
    let current_block = telemetry_block_shape(height, hash, last_block_elapsed, timing);
    *last_tick_height = height;
    *last_tick_elapsed = elapsed;
    println!(
        "benchmark.telemetry_tick {}",
        serde_json::json!({
            "schema": "benchmark.telemetry_tick.v1",
            "port": "rust",
            "gate": gate_id_for(opts),
            "run_id": timing.run_id,
            "event": event,
            "benchmark_lane": benchmark_lane_for(opts),
            "target": target_label_for_opts(opts),
            "target_height": opts.target,
            "height": height,
            "percent": ((height as f64 / opts.target.max(1) as f64) * 100.0),
            "hash": hash,
            "tx_count": tx_count,
            "elapsed_ms": elapsed.as_millis() as i64,
            "monotonic_ms": elapsed.as_millis() as i64,
            "rate_recent_blocks_per_second": recent_rate,
            "rate_total_blocks_per_second": total_rate,
            "phase": final_phase,
            "utxos": utxos,
            "last_block_ms": last_block_elapsed.as_millis() as i64,
            "stall_class": stall_class,
            "current_block_elapsed_ms": current_block["elapsed_ms"],
            "current_block_height": current_block["height"],
            "current_block_hash": current_block["hash"],
            "current_block_tx_count": current_block["tx_count"],
            "current_block_vin_count": current_block["vin_count"],
            "current_block_script_input_count": current_block["script_input_count"],
            "slow_blocks": timing.slow_blocks,
            "current_blocker": current_blocker,
            "sync_status": sync_status,
            "timing_buckets_ms": timing.timing_buckets_json(),
        })
    );
    println!(
        "rb.port_progress {}",
        serde_json::json!({
            "chain": "testnet4",
            "sync_status": sync_status,
            "header_height": height,
            "validated_height": height,
            "validated_hash": hash,
            "stored_block_height": height,
            "chainstate_utxo_count": utxos,
            "current_blocker": current_blocker,
            "peer": opts.peer,
            "downloaded_blocks": connected,
            "connected_blocks": connected,
            "current_block_height": current_block["height"],
            "current_block_hash": current_block["hash"],
            "current_block_tx_count": current_block["tx_count"],
            "current_block_vin_count": current_block["vin_count"],
            "current_block_script_input_count": current_block["script_input_count"],
            "last_block_ms": last_block_elapsed.as_millis() as i64,
            "native_crypto_backend": "rust-secp256k1",
            "timing_buckets_ms": timing.timing_buckets_json(),
        })
    );
}

fn telemetry_block_shape(
    height: u32,
    hash: &str,
    elapsed: Duration,
    timing: &PipelineTiming,
) -> Value {
    for block in &timing.slow_blocks {
        if block["height"].as_u64() == Some(height as u64) {
            return serde_json::json!({
                "height": height,
                "hash": if hash.is_empty() { Value::Null } else { Value::String(hash.to_string()) },
                "elapsed_ms": block["ms"].as_i64().unwrap_or(elapsed.as_millis() as i64),
                "tx_count": block["tx_count"].as_i64().unwrap_or_default(),
                "vin_count": block["vin_count"].as_i64().unwrap_or_default(),
                "script_input_count": block["script_input_count"].as_i64().unwrap_or_default(),
            });
        }
    }
    serde_json::json!({
        "height": height,
        "hash": if hash.is_empty() { Value::Null } else { Value::String(hash.to_string()) },
        "elapsed_ms": elapsed.as_millis() as i64,
        "tx_count": 0,
        "vin_count": 0,
        "script_input_count": 0,
    })
}

fn telemetry_stall_class(current_blocker: &Option<Value>, elapsed: Duration) -> &'static str {
    if current_blocker.is_some() {
        "validation_blocker"
    } else if elapsed >= Duration::from_secs(15) {
        "block_connect_slow"
    } else {
        "none"
    }
}

fn gate_id_for(opts: &LocalReferenceOptions<'_>) -> String {
    if let Some(value) = env_override("RSBITNODE_BENCHMARK_GATE") {
        return value;
    }
    if is_external_manual(opts) {
        return "diagnostic_external_5k".into();
    }
    match opts.target {
        5000 => "baseline_5k",
        10000 => "diagnostic_10k",
        50000 => "shakedown_50k",
        100000 => "performance_100k",
        _ => "diagnostic",
    }
    .into()
}

fn prefetch_depth() -> usize {
    std::env::var("RSBITNODE_BLOCK_PREFETCH_DEPTH")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(4)
        .clamp(1, 16)
}

fn add_failure(doc: &mut Map<String, Value>, message: &str) {
    let failures = doc
        .entry("failures")
        .or_insert_with(|| Value::Array(Vec::new()));
    if let Value::Array(values) = failures {
        values.push(message.into());
    }
}

fn write_result(path: &Path, value: &Value) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(path, format!("{}\n", serde_json::to_string_pretty(value)?))?;
    Ok(())
}

pub fn default_result_path() -> Result<PathBuf> {
    refsync::default_result_path("local_reference_docker_sync")
}
