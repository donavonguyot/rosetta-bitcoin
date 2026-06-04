use anyhow::{bail, ensure, Context, Result};
use chrono::Utc;
use rayon::prelude::*;
use serde::Serialize;
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::time::{Duration, Instant};

use crate::refsync;
use crate::script_verify::{self, SpentPrevout};
use crate::storage::{
    ChainstateBlockCommit, ConnectTimings, Store, StoredUtxo, UtxoOutpoint, UtxoUndoEntry,
};
use crate::tx::{self, Transaction};

#[derive(Serialize, Clone, Default)]
pub struct TimingSummary {
    pub total_ms: i64,
    pub stage_totals_ms: HashMap<String, i64>,
    pub slow_blocks: Vec<SlowBlock>,
}

#[derive(Serialize, Clone)]
pub struct SlowBlock {
    pub height: u32,
    pub ms: i64,
}

#[derive(Serialize)]
pub struct ConnectSummary {
    pub implementation: &'static str,
    pub runtime_surface: String,
    pub mode: String,
    pub target_height: u32,
    pub header_height: i64,
    pub stored_block_height: i64,
    pub validated_height: i64,
    pub validated_hash: String,
    pub chainstate_utxo_count: i64,
    pub sync_status: String,
    pub current_blocker: Option<Value>,
    pub reached_target: bool,
    pub started_at: String,
    pub updated_at: String,
    pub blocks_connected: u32,
    pub script_runner_mode: &'static str,
    pub storage_codec_version: u32,
    pub rocksdb_tuning: &'static str,
    pub rocksdb_wal_disabled: bool,
    pub timing_summary: TimingSummary,
}

pub struct ConnectOptions<'a> {
    pub datadir: &'a Path,
    pub target: u32,
    pub progress: u32,
    pub quiet: bool,
    pub runtime_surface: &'a str,
}

pub fn run(opts: ConnectOptions<'_>) -> Result<ConnectSummary> {
    let store = Store::open(opts.datadir)?;
    run_store(
        &store,
        opts.target,
        opts.progress,
        opts.quiet,
        opts.runtime_surface,
    )
}

pub fn run_store(
    store: &Store,
    target: u32,
    progress: u32,
    quiet: bool,
    runtime_surface: &str,
) -> Result<ConnectSummary> {
    let progress = progress.max(1);
    let mut meta = store.metadata()?;
    ensure!(
        target as i64 <= meta.stored_block_height,
        "target {} exceeds stored block height {}",
        target,
        meta.stored_block_height
    );
    let started = Utc::now().to_rfc3339();
    let mut timing = TimingCollector::new();
    let mut connected = 0u32;
    let mut prev_hash = meta.validated_hash.clone();
    let start_height = if meta.validated_height == 0 && meta.validated_hash.is_empty() {
        0
    } else {
        u32::try_from(meta.validated_height + 1).unwrap_or(0)
    };

    for height in start_height..=target {
        let block_started = Instant::now();
        let mut raw = Vec::new();
        timing.measure("block_read", || {
            raw = store.read_block(height)?;
            Ok(())
        })?;
        let expected_prev = if height == 0 {
            None
        } else {
            Some(prev_hash.as_str())
        };
        let mut info = None;
        let mut txs = Vec::new();
        timing.measure("block_parse_validate", || {
            let (block_info, parsed_txs) = refsync::decode_block(&raw, None, expected_prev)?;
            info = Some(block_info);
            txs = parsed_txs;
            Ok(())
        })?;
        let info = info.context("decoded block info missing")?;
        match connect_transactions(store, &mut timing, height, &info.hash, &txs)? {
            ConnectOutcome::Blocker(blocker) => {
                meta.current_blocker = Some(blocker.clone());
                meta.sync_status = "blocks_blocked".to_string();
                meta.chainstate_status = "blocked".to_string();
                meta.last_error = blocker["failure"].as_str().unwrap_or_default().to_string();
                store.put_metadata(&meta)?;
                return Ok(summary_from(
                    meta,
                    target,
                    started,
                    connected,
                    false,
                    runtime_surface,
                    timing,
                ));
            }
            ConnectOutcome::Commit(commit) => {
                let mut storage_timings = ConnectTimings::default();
                timing.measure("commit", || {
                    store.commit_block(commit, &mut storage_timings)?;
                    Ok(())
                })?;
                merge_storage_timings(&mut timing, &storage_timings);
            }
        }
        prev_hash = info.hash.clone();
        connected += 1;
        meta = store.metadata()?;
        timing.record_block(height, block_started.elapsed());
        if !quiet && (height % progress == 0 || height == target) {
            println!(
                "rsbitnode-connect height={} hash={} txs={} utxos={}",
                height, info.hash, info.tx_count, meta.chainstate_utxo_count
            );
        }
    }

    Ok(summary_from(
        meta,
        target,
        started,
        connected,
        true,
        runtime_surface,
        timing,
    ))
}

pub fn connect_decoded_block(
    store: &Store,
    height: u32,
    target: u32,
    info: &refsync::BlockInfo,
    txs: &[Transaction],
    runtime_surface: &str,
) -> Result<ConnectSummary> {
    let started = Utc::now().to_rfc3339();
    let mut timing = TimingCollector::new();
    let block_started = Instant::now();
    let mut meta = store.metadata()?;
    let expected_height = if meta.validated_height == 0 && meta.validated_hash.is_empty() {
        0
    } else {
        u32::try_from(meta.validated_height + 1).unwrap_or(0)
    };
    ensure!(
        height == expected_height,
        "decoded block height {} does not match expected connect height {}",
        height,
        expected_height
    );
    if height > 0 {
        ensure!(
            info.prev_hash == meta.validated_hash,
            "decoded block previous hash mismatch: got {} want {}",
            info.prev_hash,
            meta.validated_hash
        );
    }

    let mut connected = 0u32;
    match connect_transactions(store, &mut timing, height, &info.hash, txs)? {
        ConnectOutcome::Blocker(blocker) => {
            meta.current_blocker = Some(blocker.clone());
            meta.sync_status = "blocks_blocked".to_string();
            meta.chainstate_status = "blocked".to_string();
            meta.last_error = blocker["failure"].as_str().unwrap_or_default().to_string();
            store.put_metadata(&meta)?;
            return Ok(summary_from(
                meta,
                target,
                started,
                connected,
                false,
                runtime_surface,
                timing,
            ));
        }
        ConnectOutcome::Commit(commit) => {
            let mut storage_timings = ConnectTimings::default();
            timing.measure("commit", || {
                store.commit_block(commit, &mut storage_timings)?;
                Ok(())
            })?;
            merge_storage_timings(&mut timing, &storage_timings);
            connected = 1;
        }
    }

    let meta = store.metadata()?;
    timing.record_block(height, block_started.elapsed());
    let mut summary = summary_from(
        meta,
        target,
        started,
        connected,
        height >= target,
        runtime_surface,
        timing,
    );
    summary.mode = "decoded_block_connect".to_string();
    Ok(summary)
}

enum ConnectOutcome {
    Commit(ChainstateBlockCommit),
    Blocker(Value),
}

struct ScriptVerifyJob {
    tx_index: usize,
    spent_prevouts: Vec<SpentPrevout>,
}

fn connect_transactions(
    store: &Store,
    timing: &mut TimingCollector,
    height: u32,
    block_hash: &str,
    txs: &[Transaction],
) -> Result<ConnectOutcome> {
    if txs.is_empty() || !txs[0].is_coinbase() {
        return Ok(ConnectOutcome::Blocker(blocker(
            height,
            block_hash,
            "",
            0,
            "block_first_transaction_not_coinbase",
            "block does not begin with a coinbase transaction",
        )));
    }

    let prevouts = gather_prevouts(txs);
    let loaded = timing.measure_value("prevout_batch_load", || {
        store.get_many_utxos("testnet4", &prevouts)
    })?;
    timing.add_stage("utxo_load", Duration::ZERO);
    let mut view = BlockView::new();
    for (outpoint, utxo) in prevouts.into_iter().zip(loaded) {
        if let Some(utxo) = utxo {
            view.loaded.insert(outpoint, utxo);
        }
    }

    let txids = txs.iter().map(Transaction::txid).collect::<Vec<_>>();
    let txid_internals = txs
        .iter()
        .map(Transaction::txid_internal)
        .collect::<Vec<_>>();
    let mut script_jobs = Vec::new();
    for (tx_index, transaction) in txs.iter().enumerate() {
        if tx_index == 0 {
            if height != 0 {
                view.add_created(outputs_for(
                    height,
                    transaction,
                    txid_internals[tx_index],
                    true,
                )?);
            }
            continue;
        }
        if transaction.inputs.is_empty() {
            return Ok(ConnectOutcome::Blocker(blocker(
                height,
                block_hash,
                &txids[tx_index],
                0,
                "transaction_without_inputs",
                "non-coinbase transaction has no inputs",
            )));
        }
        let mut spent_prevouts = Vec::with_capacity(transaction.inputs.len());
        let mut input_utxos = Vec::with_capacity(transaction.inputs.len());
        let mut input_outpoints = Vec::with_capacity(transaction.inputs.len());
        let mut input_seen = HashSet::new();
        for (input_index, input) in transaction.inputs.iter().enumerate() {
            let outpoint =
                UtxoOutpoint::new(input.previous_output.hash, input.previous_output.index);
            if !input_seen.insert(outpoint) || view.spent.contains_key(&outpoint) {
                return Ok(ConnectOutcome::Blocker(blocker(
                    height,
                    block_hash,
                    &txids[tx_index],
                    input_index,
                    "duplicate_spend",
                    "duplicate spend inside block",
                )));
            }
            let Some(utxo) = view.find(&outpoint).cloned() else {
                return Ok(ConnectOutcome::Blocker(blocker(
                    height,
                    block_hash,
                    &txids[tx_index],
                    input_index,
                    "missing_utxo",
                    "Rust connect replay could not find the spent prevout",
                )));
            };
            if utxo.coinbase && height.saturating_sub(utxo.height) < 100 {
                return Ok(ConnectOutcome::Blocker(blocker(
                    height,
                    block_hash,
                    &txids[tx_index],
                    input_index,
                    "coinbase_maturity",
                    "coinbase spend before 100 confirmations",
                )));
            }
            spent_prevouts.push(SpentPrevout {
                amount: utxo.value_sats as i64,
                script_pubkey: utxo.script_pubkey.clone(),
            });
            input_utxos.push(utxo);
            input_outpoints.push(outpoint);
        }
        script_jobs.push(ScriptVerifyJob {
            tx_index,
            spent_prevouts,
        });
        for (input_index, outpoint) in input_outpoints.iter().copied().enumerate() {
            view.mark_spent(outpoint, input_utxos[input_index].clone());
        }
        view.add_created(outputs_for(
            height,
            transaction,
            txid_internals[tx_index],
            false,
        )?);
    }
    let failure = timing.measure("script_verify", || {
        Ok(verify_script_jobs(txs, &script_jobs))
    })?;
    if let Some((tx_index, input, failure)) = failure {
        return Ok(ConnectOutcome::Blocker(blocker(
            height,
            block_hash,
            &txids[tx_index],
            input,
            "script_verify_failed",
            &failure,
        )));
    }

    Ok(ConnectOutcome::Commit(ChainstateBlockCommit {
        chain: "testnet4".to_string(),
        height,
        block_hash_internal: tx::parse_display_hash(block_hash)?,
        spent_external: view.external_spends(),
        created_utxos: view.created_utxos(),
        undo_entries: view.undo_entries(),
    }))
}

fn verify_script_jobs(
    txs: &[Transaction],
    jobs: &[ScriptVerifyJob],
) -> Option<(usize, usize, String)> {
    if script_parallel_enabled() && jobs.len() > 1 {
        jobs.par_iter()
            .filter_map(|job| verify_script_job(txs, job))
            .min_by_key(|(tx_index, input_index, _)| (*tx_index, *input_index))
    } else {
        jobs.iter().find_map(|job| verify_script_job(txs, job))
    }
}

fn verify_script_job(txs: &[Transaction], job: &ScriptVerifyJob) -> Option<(usize, usize, String)> {
    let transaction = &txs[job.tx_index];
    for input_index in 0..job.spent_prevouts.len() {
        if let Err(err) = script_verify::verify_transaction_input_borrowed(
            transaction,
            input_index,
            &job.spent_prevouts[input_index].script_pubkey,
            job.spent_prevouts[input_index].amount,
            &job.spent_prevouts,
        ) {
            return Some((job.tx_index, input_index, err.to_string()));
        }
    }
    None
}

fn script_parallel_enabled() -> bool {
    !std::env::var("RSBITNODE_SCRIPT_VERIFY_PARALLEL").is_ok_and(|value| value == "0")
}

#[derive(Default)]
struct BlockView {
    loaded: HashMap<UtxoOutpoint, StoredUtxo>,
    created: HashMap<UtxoOutpoint, StoredUtxo>,
    spent: HashMap<UtxoOutpoint, UtxoUndoEntry>,
}

impl BlockView {
    fn new() -> Self {
        Self::default()
    }

    fn add_created(&mut self, utxos: Vec<StoredUtxo>) {
        for utxo in utxos {
            self.created.insert(utxo.outpoint, utxo);
        }
    }

    fn find(&self, outpoint: &UtxoOutpoint) -> Option<&StoredUtxo> {
        self.created
            .get(outpoint)
            .or_else(|| self.loaded.get(outpoint))
    }

    fn mark_spent(&mut self, outpoint: UtxoOutpoint, utxo: StoredUtxo) {
        if self.created.remove(&outpoint).is_some() {
            self.spent.insert(outpoint, undo_from(utxo));
            return;
        }
        self.spent.insert(outpoint, undo_from(utxo));
    }

    fn created_utxos(&self) -> Vec<StoredUtxo> {
        let mut out = self.created.values().cloned().collect::<Vec<_>>();
        out.sort_by_key(|utxo| (utxo.outpoint.txid_internal, utxo.outpoint.vout));
        out
    }

    fn external_spends(&self) -> Vec<UtxoOutpoint> {
        let mut out = self
            .spent
            .keys()
            .filter(|outpoint| self.loaded.contains_key(outpoint))
            .copied()
            .collect::<Vec<_>>();
        out.sort_by_key(|outpoint| (outpoint.txid_internal, outpoint.vout));
        out
    }

    fn undo_entries(&self) -> Vec<UtxoUndoEntry> {
        let mut out = self
            .spent
            .iter()
            .filter(|(outpoint, _)| self.loaded.contains_key(outpoint))
            .map(|(_, undo)| undo.clone())
            .collect::<Vec<_>>();
        out.sort_by_key(|undo| (undo.outpoint.txid_internal, undo.outpoint.vout));
        out
    }
}

fn undo_from(utxo: StoredUtxo) -> UtxoUndoEntry {
    UtxoUndoEntry {
        outpoint: utxo.outpoint,
        height: utxo.height,
        value_sats: utxo.value_sats,
        coinbase: utxo.coinbase,
        script_pubkey: utxo.script_pubkey,
    }
}

fn gather_prevouts(txs: &[Transaction]) -> Vec<UtxoOutpoint> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for transaction in txs.iter().skip(1) {
        for input in &transaction.inputs {
            let outpoint =
                UtxoOutpoint::new(input.previous_output.hash, input.previous_output.index);
            if seen.insert(outpoint) {
                out.push(outpoint);
            }
        }
    }
    out.sort_by_key(|outpoint| (outpoint.txid_internal, outpoint.vout));
    out
}

fn outputs_for(
    height: u32,
    transaction: &Transaction,
    txid_internal: [u8; 32],
    coinbase: bool,
) -> Result<Vec<StoredUtxo>> {
    transaction
        .outputs
        .iter()
        .enumerate()
        .map(|(vout, output)| {
            if output.value < 0 {
                bail!("negative output value")
            }
            Ok(StoredUtxo {
                outpoint: UtxoOutpoint::new(txid_internal, u32::try_from(vout)?),
                height,
                value_sats: output.value as u64,
                coinbase,
                script_pubkey: output.script_pubkey.clone(),
            })
        })
        .collect()
}

fn blocker(
    height: u32,
    block_hash: &str,
    txid: &str,
    input: usize,
    missing_rule: &str,
    failure: &str,
) -> Value {
    serde_json::json!({
        "height": height,
        "block_hash": block_hash,
        "txid": txid,
        "input": input,
        "failure": failure,
        "missing_rule": missing_rule,
        "source": "rsbitnode-connect",
        "created_at": Utc::now().to_rfc3339()
    })
}

fn summary_from(
    meta: crate::storage::Metadata,
    target: u32,
    started: String,
    connected: u32,
    reached: bool,
    runtime_surface: &str,
    timing: TimingCollector,
) -> ConnectSummary {
    ConnectSummary {
        implementation: "RustNode",
        runtime_surface: runtime_surface.to_string(),
        mode: "stored_block_connect".to_string(),
        target_height: target,
        header_height: meta.header_height,
        stored_block_height: meta.stored_block_height,
        validated_height: meta.validated_height,
        validated_hash: meta.validated_hash,
        chainstate_utxo_count: meta.chainstate_utxo_count,
        sync_status: meta.sync_status,
        current_blocker: meta.current_blocker,
        reached_target: reached,
        started_at: started,
        updated_at: Utc::now().to_rfc3339(),
        blocks_connected: connected,
        script_runner_mode: script_runner_mode(),
        storage_codec_version: 2,
        rocksdb_tuning: "block_cache=256MiB,bloom=10,write_buffer=64MiB,max_write_buffers=4,max_background_jobs=4",
        rocksdb_wal_disabled: std::env::var("RSBITNODE_ROCKSDB_DISABLE_WAL").is_ok_and(|v| v == "1"),
        timing_summary: timing.summary(),
    }
}

fn script_runner_mode() -> &'static str {
    if script_parallel_enabled() {
        "parallel"
    } else {
        "sequential"
    }
}

struct TimingCollector {
    started: Instant,
    stage_totals: HashMap<String, Duration>,
    slow_blocks: Vec<SlowBlock>,
}

impl TimingCollector {
    fn new() -> Self {
        Self {
            started: Instant::now(),
            stage_totals: HashMap::new(),
            slow_blocks: Vec::new(),
        }
    }

    fn measure<T>(&mut self, stage: &str, f: impl FnOnce() -> Result<T>) -> Result<T> {
        let started = Instant::now();
        let result = f();
        self.add_stage(stage, started.elapsed());
        result
    }

    fn measure_value<T>(&mut self, stage: &str, f: impl FnOnce() -> Result<T>) -> Result<T> {
        self.measure(stage, f)
    }

    fn add_stage(&mut self, stage: &str, elapsed: Duration) {
        *self.stage_totals.entry(stage.to_string()).or_default() += elapsed;
    }

    fn record_block(&mut self, height: u32, elapsed: Duration) {
        self.slow_blocks.push(SlowBlock {
            height,
            ms: elapsed.as_millis() as i64,
        });
        self.slow_blocks.sort_by_key(|block| -block.ms);
        self.slow_blocks.truncate(10);
    }

    fn summary(self) -> TimingSummary {
        TimingSummary {
            total_ms: self.started.elapsed().as_millis() as i64,
            stage_totals_ms: self
                .stage_totals
                .into_iter()
                .map(|(k, v)| (k, v.as_millis() as i64))
                .collect(),
            slow_blocks: self.slow_blocks,
        }
    }
}

fn merge_storage_timings(timing: &mut TimingCollector, storage_timings: &ConnectTimings) {
    for stage in [
        "utxo_load",
        "prevout_batch_load",
        "utxo_apply",
        "commit",
        "block_connect_store_commit",
        "script_verify",
    ] {
        let millis = storage_timings.millis(stage);
        if millis > 0 {
            timing.add_stage(stage, Duration::from_millis(millis as u64));
        }
    }
}
