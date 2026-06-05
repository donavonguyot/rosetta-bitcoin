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

pub fn run(opts: LocalReferenceOptions<'_>) -> Result<Value> {
    let started = Utc::now();
    let p2p_source = opts.byte_source == "p2p";
    let peer_mode = if p2p_source {
        "local_reference"
    } else {
        "local_reference_rpc"
    };
    let peer = if p2p_source { opts.peer } else { opts.rpc_url };
    let byte_source = if p2p_source {
        "local_reference_p2p"
    } else {
        "local_reference_rpc"
    };
    let proof_mode = if p2p_source { "p2p_sync" } else { opts.mode };
    let benchmark_lane = if p2p_source {
        "supporting_5k_p2p"
    } else {
        "supporting_5k_rpc_replay"
    };
    let mut doc = Map::new();
    doc.insert("implementation".into(), "RustNode".into());
    doc.insert("category".into(), "local_reference_sync".into());
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
    doc.insert("target_label".into(), target_label(opts.target).into());
    doc.insert("reference_start_height".into(), 0.into());
    doc.insert(
        "reference_start_hash".into(),
        "00000000da84f2bafbbc53dee25a72ae507ff4914b867c565be350b0da8bf043".into(),
    );
    doc.insert("reference_finish_height".into(), opts.target.into());
    doc.insert("benchmark_contract_version".into(), 1.into());
    doc.insert(
        "benchmark_kind".into(),
        benchmark_kind(opts.target, opts.byte_source).into(),
    );
    doc.insert("benchmark_lane".into(), benchmark_lane.into());
    doc.insert("utxo_accounting_policy".into(), "core_spendable_v1".into());
    doc.insert("byte_source".into(), byte_source.into());
    doc.insert("resume_supported".into(), true.into());
    doc.insert("fresh_state".into(), true.into());
    doc.insert("proof_mode".into(), proof_mode.into());
    doc.insert("prefetch_depth".into(), (prefetch_depth() as i64).into());
    doc.insert("result".into(), "failed".into());
    doc.insert("failures".into(), Value::Array(Vec::new()));

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
    doc.insert("connect_summary".into(), connect_summary.clone());
    doc.insert(
        "connect_summary_kind".into(),
        "final_connect_snapshot".into(),
    );
    doc.insert(
        "pipeline_timing_summary".into(),
        pipeline_timing_summary.clone(),
    );

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
    doc.insert("validated_hash".into(), status_doc.validated_hash.into());
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

    let reached = connect_summary["reached_target"].as_bool().unwrap_or(false)
        && status_doc.validated_height >= opts.target as i64
        && status_doc.current_blocker.is_none();
    if reached {
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

fn benchmark_kind(target: u32, byte_source: &str) -> &'static str {
    if byte_source == "p2p" {
        return match target {
            5000 => "supporting_5k_p2p",
            _ => "local_reference_p2p",
        };
    }
    match target {
        5000 => "supporting_5k_durable_local_reference_replay",
        10000 => "supporting_10k_durable_local_reference_replay",
        50000 => "supporting_50k_durable_local_reference_replay",
        100000 => "primary_100k_durable_local_reference_replay",
        _ => "local_reference_replay",
    }
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
    let receiver = p2p::fetch_blocks(p2p::FetchOptions {
        peer: opts.peer.to_string(),
        target: opts.target,
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
        last_connect = serde_json::to_value(&connect)?;
        fetched += 1;
        let elapsed_block = block_started.elapsed();
        timing.record_block(block.height, elapsed_block);
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
    let sync = serde_json::json!({
        "implementation": "RustNode",
        "runtime_surface": opts.runtime_surface,
        "peer_mode": "local_reference",
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
        last_connect = serde_json::to_value(&connect)?;
        fetched += 1;
        let block_ms = block
            .timings
            .total()
            .saturating_add(connect_started.elapsed());
        let elapsed_block = block_started.elapsed().max(block_ms);
        timing.record_block(block.height, elapsed_block);
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
    stage_totals: BTreeMap<&'static str, Duration>,
    slow_blocks: Vec<Value>,
    blocks_fetched: u32,
    blocks_connected: u32,
    prefetch_depth: usize,
}

impl PipelineTiming {
    fn new(prefetch_depth: usize) -> Self {
        Self {
            started: Instant::now(),
            stage_totals: BTreeMap::new(),
            slow_blocks: Vec::new(),
            blocks_fetched: 0,
            blocks_connected: 0,
            prefetch_depth,
        }
    }

    fn add(&mut self, stage: &'static str, elapsed: Duration) {
        *self.stage_totals.entry(stage).or_default() += elapsed;
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
                    _ => "connect_other",
                },
                Duration::from_millis(*millis as u64),
            );
        }
    }

    fn record_block(&mut self, height: u32, elapsed: Duration) {
        self.slow_blocks.push(serde_json::json!({
            "height": height,
            "ms": elapsed.as_millis() as i64,
        }));
        self.slow_blocks
            .sort_by_key(|value| -value["ms"].as_i64().unwrap_or_default());
        self.slow_blocks.truncate(10);
    }

    fn as_json(&self) -> Value {
        let mut doc = Map::new();
        let mut stage_totals = self.stage_totals.clone();
        if !stage_totals.contains_key("block_connect_store_commit") {
            if let Some(connect_total) = stage_totals.get("connect_total").copied() {
                stage_totals.insert("block_connect_store_commit", connect_total);
            }
        }
        doc.insert(
            "total_wall".into(),
            (self.started.elapsed().as_millis() as i64).into(),
        );
        doc.insert("prefetch_depth".into(), (self.prefetch_depth as i64).into());
        doc.insert("blocks_fetched".into(), self.blocks_fetched.into());
        doc.insert("blocks_connected".into(), self.blocks_connected.into());
        for stage in [
            "rpc_getblockhash",
            "rpc_getblock",
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
        doc.insert("slow_blocks".into(), Value::Array(self.slow_blocks.clone()));
        Value::Object(doc)
    }
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
