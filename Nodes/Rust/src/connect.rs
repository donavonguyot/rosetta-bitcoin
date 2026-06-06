use anyhow::{bail, ensure, Context, Result};
use chrono::Utc;
use rayon::{prelude::*, ThreadPool, ThreadPoolBuilder};
use serde::Serialize;
use serde_json::Value;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::Path;
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use crate::refsync;
use crate::script_verify::{self, SighashCache, SpentPrevout};
use crate::storage::{
    ChainstateBlockCommit, ConnectTimings, Store, StoredUtxo, UtxoOutpoint, UtxoReadStats,
    UtxoUndoEntry,
};
use crate::tx::{self, Transaction};

#[derive(Serialize, Clone, Default)]
pub struct TimingSummary {
    pub total_ms: i64,
    pub stage_totals_ms: HashMap<String, i64>,
    pub script_threads: usize,
    pub script_jobs: usize,
    pub runner_batches: usize,
    pub script_wall_ms: i64,
    pub script_worker_cpu_ms: i64,
    pub utxo_lookup_count: usize,
    pub same_block_spends: usize,
    pub created_utxos: usize,
    pub spent_external: usize,
    pub utxo_key_bytes: usize,
    pub utxo_value_bytes: usize,
    pub prevout_multi_get_call: i64,
    pub prevout_utxo_decode_ms: i64,
    pub slow_blocks: Vec<SlowBlock>,
}

#[derive(Serialize, Clone)]
pub struct SlowBlock {
    pub height: u32,
    pub ms: i64,
    pub tx_count: usize,
    pub vin_count: usize,
    pub vout_count: usize,
    pub script_input_count: usize,
    pub same_block_spends: usize,
    pub created_utxos: usize,
    pub spent_external: usize,
    pub input_shape_counts: BTreeMap<String, usize>,
    pub spent_prevout_script_types: BTreeMap<String, usize>,
    pub output_script_types: BTreeMap<String, usize>,
}

#[derive(Serialize, Clone, Default)]
pub struct BlockShapeSummary {
    pub tx_count: usize,
    pub vin_count: usize,
    pub vout_count: usize,
    pub script_input_count: usize,
    pub same_block_spends: usize,
    pub created_utxos: usize,
    pub spent_external: usize,
    pub input_shape_counts: BTreeMap<String, usize>,
    pub spent_prevout_script_types: BTreeMap<String, usize>,
    pub output_script_types: BTreeMap<String, usize>,
}

#[derive(Serialize)]
pub struct ConnectSummary {
    pub implementation: &'static str,
    pub runtime_surface: String,
    pub utxo_accounting_policy: &'static str,
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
        timing.add_stage("block_connect_store_commit", block_started.elapsed());
        timing.record_block(height, block_started.elapsed(), block_shape_summary(&txs));
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
    timing.add_stage("block_connect_store_commit", block_started.elapsed());
    timing.record_block(height, block_started.elapsed(), block_shape_summary(txs));
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
    sighash_cache: SighashCache,
}

struct ScriptVerifyTask {
    job_index: usize,
    tx_index: usize,
    input_index: usize,
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
    let (loaded, read_stats) = store.get_many_utxos_with_stats("testnet4", &prevouts)?;
    let load_elapsed = read_stats.multi_get + read_stats.decode;
    timing.add_stage("prevout_batch_load", load_elapsed);
    timing.add_stage("utxo_load", load_elapsed);
    timing.record_utxo_read_stats(&read_stats);
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
        view.add_spent_prevout_script_types(&spent_prevouts);
        let sighash_cache = match SighashCache::new(transaction, &spent_prevouts) {
            Ok(cache) => cache,
            Err(err) => {
                return Ok(ConnectOutcome::Blocker(blocker(
                    height,
                    block_hash,
                    &txids[tx_index],
                    0,
                    "sighash_cache_build_failed",
                    &err.to_string(),
                )));
            }
        };
        script_jobs.push(ScriptVerifyJob {
            tx_index,
            spent_prevouts,
            sighash_cache,
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
    let script_started = Instant::now();
    let verify_stats = verify_script_jobs(txs, &script_jobs);
    let script_wall = script_started.elapsed();
    timing.add_stage("script_verify", script_wall);
    timing.record_script_verify_stats(&verify_stats, script_wall);
    timing.set_spent_prevout_script_types(view.spent_prevout_script_types.clone());
    if let Some((tx_index, input, failure)) = verify_stats.failure {
        return Ok(ConnectOutcome::Blocker(blocker(
            height,
            block_hash,
            &txids[tx_index],
            input,
            "script_verify_failed",
            &failure,
        )));
    }

    let spent_external = view.external_spends();
    let created_utxos = view.created_utxos();
    let undo_entries = view.undo_entries();
    timing.add_count("created_utxos", created_utxos.len());
    timing.add_count("spent_external", spent_external.len());
    timing.add_count("same_block_spends", view.same_block_spends);

    Ok(ConnectOutcome::Commit(ChainstateBlockCommit {
        chain: "testnet4".to_string(),
        height,
        block_hash_internal: tx::parse_display_hash(block_hash)?,
        spent_external,
        created_utxos,
        undo_entries,
    }))
}

struct ScriptTaskResult {
    failure: Option<(usize, usize, String)>,
    elapsed: Duration,
}

struct ScriptVerifyStats {
    failure: Option<(usize, usize, String)>,
    jobs: usize,
    threads: usize,
    batches: usize,
    worker_cpu: Duration,
    mode: &'static str,
}

fn verify_script_jobs(txs: &[Transaction], jobs: &[ScriptVerifyJob]) -> ScriptVerifyStats {
    let tasks = script_verify_tasks(jobs);
    let runner = script_runner_config();
    let use_parallel = script_runner_uses_parallel(runner, tasks.len());
    let results = if use_parallel {
        script_pool().install(|| {
            tasks
                .par_iter()
                .map(|task| verify_script_task(txs, jobs, task))
                .collect::<Vec<_>>()
        })
    } else {
        tasks
            .iter()
            .map(|task| verify_script_task(txs, jobs, task))
            .collect::<Vec<_>>()
    };
    let worker_cpu = results.iter().map(|result| result.elapsed).sum();
    let failure =
        first_failure_by_order(results.iter().filter_map(|result| result.failure.clone()));
    ScriptVerifyStats {
        failure,
        jobs: tasks.len(),
        threads: if use_parallel { runner.threads } else { 1 },
        batches: usize::from(!tasks.is_empty()),
        worker_cpu,
        mode: if use_parallel {
            "parallel"
        } else {
            "sequential"
        },
    }
}

fn script_verify_tasks(jobs: &[ScriptVerifyJob]) -> Vec<ScriptVerifyTask> {
    let total_inputs = jobs.iter().map(|job| job.spent_prevouts.len()).sum();
    let mut tasks = Vec::with_capacity(total_inputs);
    for (job_index, job) in jobs.iter().enumerate() {
        for input_index in 0..job.spent_prevouts.len() {
            tasks.push(ScriptVerifyTask {
                job_index,
                tx_index: job.tx_index,
                input_index,
            });
        }
    }
    tasks
}

fn verify_script_task(
    txs: &[Transaction],
    jobs: &[ScriptVerifyJob],
    task: &ScriptVerifyTask,
) -> ScriptTaskResult {
    let started = Instant::now();
    let job = &jobs[task.job_index];
    let transaction = &txs[task.tx_index];
    let failure = script_verify::verify_transaction_input_borrowed_with_cache(
        transaction,
        task.input_index,
        &job.spent_prevouts[task.input_index].script_pubkey,
        job.spent_prevouts[task.input_index].amount,
        &job.spent_prevouts,
        Some(&job.sighash_cache),
    )
    .err()
    .map(|err| (task.tx_index, task.input_index, err.to_string()));
    ScriptTaskResult {
        failure,
        elapsed: started.elapsed(),
    }
}

fn first_failure_by_order(
    failures: impl IntoIterator<Item = (usize, usize, String)>,
) -> Option<(usize, usize, String)> {
    failures
        .into_iter()
        .min_by_key(|(tx_index, input_index, _)| (*tx_index, *input_index))
}

fn script_parallel_enabled() -> bool {
    !std::env::var("RSBITNODE_SCRIPT_VERIFY_PARALLEL").is_ok_and(|value| value == "0")
}

#[derive(Clone, Copy)]
struct ScriptRunnerConfig {
    parallel_enabled: bool,
    threads: usize,
    min_inputs: usize,
}

fn script_runner_config() -> ScriptRunnerConfig {
    ScriptRunnerConfig {
        parallel_enabled: script_parallel_enabled(),
        threads: parse_script_verify_threads(
            std::env::var("RSBITNODE_SCRIPT_VERIFY_THREADS")
                .ok()
                .as_deref(),
            std::thread::available_parallelism()
                .map(usize::from)
                .unwrap_or(1),
        ),
        min_inputs: parse_script_verify_min_inputs(
            std::env::var("RSBITNODE_SCRIPT_VERIFY_MIN_INPUTS")
                .ok()
                .as_deref(),
        ),
    }
}

fn parse_script_verify_threads(value: Option<&str>, available: usize) -> usize {
    value
        .and_then(|value| value.trim().parse::<usize>().ok())
        .unwrap_or(available)
        .clamp(1, 64)
}

fn parse_script_verify_min_inputs(value: Option<&str>) -> usize {
    value
        .and_then(|value| value.trim().parse::<usize>().ok())
        .unwrap_or(128)
}

fn script_runner_uses_parallel(runner: ScriptRunnerConfig, task_count: usize) -> bool {
    runner.parallel_enabled && runner.threads > 1 && task_count >= runner.min_inputs
}

fn script_pool() -> &'static ThreadPool {
    static SCRIPT_POOL: OnceLock<ThreadPool> = OnceLock::new();
    SCRIPT_POOL.get_or_init(|| {
        ThreadPoolBuilder::new()
            .num_threads(script_runner_config().threads)
            .thread_name(|index| format!("rsbitnode-script-{index}"))
            .build()
            .expect("build script verify thread pool")
    })
}

#[derive(Default)]
struct BlockView {
    loaded: HashMap<UtxoOutpoint, StoredUtxo>,
    created: HashMap<UtxoOutpoint, StoredUtxo>,
    spent: HashMap<UtxoOutpoint, UtxoUndoEntry>,
    spent_prevout_script_types: BTreeMap<String, usize>,
    same_block_spends: usize,
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
            self.same_block_spends += 1;
            self.spent.insert(outpoint, undo_from(utxo));
            return;
        }
        self.spent.insert(outpoint, undo_from(utxo));
    }

    fn add_spent_prevout_script_types(&mut self, spent_prevouts: &[SpentPrevout]) {
        for prevout in spent_prevouts {
            *self
                .spent_prevout_script_types
                .entry(script_pubkey_type(&prevout.script_pubkey).to_string())
                .or_default() += 1;
        }
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
    let mut utxos = Vec::with_capacity(transaction.outputs.len());
    for (vout, output) in transaction.outputs.iter().enumerate() {
        if output.value < 0 {
            bail!("negative output value")
        }
        if !is_spendable_output(&output.script_pubkey) {
            continue;
        }
        utxos.push(StoredUtxo {
            outpoint: UtxoOutpoint::new(txid_internal, u32::try_from(vout)?),
            height,
            value_sats: output.value as u64,
            coinbase,
            script_pubkey: output.script_pubkey.clone(),
        });
    }
    Ok(utxos)
}

fn is_spendable_output(script_pubkey: &[u8]) -> bool {
    !script_pubkey.is_empty() && script_pubkey[0] != 0x6a
}

pub fn block_shape_summary(txs: &[Transaction]) -> BlockShapeSummary {
    let mut summary = BlockShapeSummary {
        tx_count: txs.len(),
        ..BlockShapeSummary::default()
    };
    for (tx_index, transaction) in txs.iter().enumerate() {
        summary.vin_count += transaction.inputs.len();
        summary.vout_count += transaction.outputs.len();
        for (input_index, input) in transaction.inputs.iter().enumerate() {
            let kind = if tx_index == 0 && transaction.is_coinbase() {
                "coinbase"
            } else if !input.script_sig.is_empty() {
                "legacy_scriptsig"
            } else if transaction
                .witness
                .get(input_index)
                .is_some_and(|stack| !stack.is_empty())
            {
                "witness"
            } else {
                "empty_spend"
            };
            if kind != "coinbase" {
                summary.script_input_count += 1;
            }
            *summary
                .input_shape_counts
                .entry(kind.to_string())
                .or_default() += 1;
        }
        for output in &transaction.outputs {
            *summary
                .output_script_types
                .entry(script_pubkey_type(&output.script_pubkey).to_string())
                .or_default() += 1;
        }
    }
    summary
}

fn script_pubkey_type(script: &[u8]) -> &'static str {
    if script.is_empty() {
        "empty"
    } else if script[0] == 0x6a {
        "op_return"
    } else if script.len() == 25
        && script[0] == 0x76
        && script[1] == 0xa9
        && script[2] == 0x14
        && script[23] == 0x88
        && script[24] == 0xac
    {
        "p2pkh"
    } else if script.len() == 23 && script[0] == 0xa9 && script[1] == 0x14 && script[22] == 0x87 {
        "p2sh"
    } else if script.len() == 22 && script[0] == 0x00 && script[1] == 0x14 {
        "p2wpkh"
    } else if script.len() == 34 && script[0] == 0x00 && script[1] == 0x20 {
        "p2wsh"
    } else if script.len() == 34 && script[0] == 0x51 && script[1] == 0x20 {
        "p2tr"
    } else if script.len() == 35 && (script[0] == 0x02 || script[0] == 0x03) && script[34] == 0xac {
        "p2pk_compressed"
    } else if script.len() == 67 && script[0] == 0x04 && script[66] == 0xac {
        "p2pk_uncompressed"
    } else {
        "other"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tx::{OutPoint, TxIn, TxOut};

    #[test]
    fn outputs_for_skips_core_unspendable_outputs() {
        let transaction = Transaction {
            version: 1,
            inputs: vec![],
            outputs: vec![
                TxOut {
                    value: 1,
                    script_pubkey: vec![],
                },
                TxOut {
                    value: 2,
                    script_pubkey: vec![0x6a, 0x01, 0x02],
                },
                TxOut {
                    value: 3,
                    script_pubkey: vec![0x51],
                },
            ],
            lock_time: 0,
            witness: vec![],
        };

        let utxos = outputs_for(10, &transaction, [1; 32], false).expect("outputs");
        assert_eq!(utxos.len(), 1);
        assert_eq!(utxos[0].value_sats, 3);
        assert_eq!(utxos[0].outpoint.vout, 2);
    }

    #[test]
    fn parallel_failure_reduction_keeps_lowest_tx_input_order() {
        let failures = vec![
            (4, 3, "later".to_string()),
            (2, 9, "wrong".to_string()),
            (2, 1, "first".to_string()),
        ];

        let selected = first_failure_by_order(failures).expect("selected failure");
        assert_eq!(selected.0, 2);
        assert_eq!(selected.1, 1);
        assert_eq!(selected.2, "first");
    }

    #[test]
    fn script_runner_threshold_and_env_parsers_are_deterministic() {
        assert_eq!(parse_script_verify_threads(None, 12), 12);
        assert_eq!(parse_script_verify_threads(Some("0"), 12), 1);
        assert_eq!(parse_script_verify_threads(Some("128"), 12), 64);
        assert_eq!(parse_script_verify_threads(Some("bad"), 6), 6);
        assert_eq!(parse_script_verify_min_inputs(None), 128);
        assert_eq!(parse_script_verify_min_inputs(Some("7")), 7);
        assert_eq!(parse_script_verify_min_inputs(Some("bad")), 128);

        let runner = ScriptRunnerConfig {
            parallel_enabled: true,
            threads: 4,
            min_inputs: 128,
        };
        assert!(!script_runner_uses_parallel(runner, 127));
        assert!(script_runner_uses_parallel(runner, 128));
        assert!(!script_runner_uses_parallel(
            ScriptRunnerConfig {
                parallel_enabled: false,
                ..runner
            },
            256
        ));
        assert!(!script_runner_uses_parallel(
            ScriptRunnerConfig {
                threads: 1,
                ..runner
            },
            256
        ));
    }

    #[test]
    fn block_shape_summary_counts_spend_and_output_families() {
        let txs = vec![
            Transaction {
                version: 1,
                inputs: vec![TxIn {
                    previous_output: OutPoint {
                        hash: [0; 32],
                        index: u32::MAX,
                    },
                    script_sig: vec![0x51],
                    sequence: 0xffff_ffff,
                }],
                outputs: vec![TxOut {
                    value: 1,
                    script_pubkey: vec![0x6a, 0x01, 0x01],
                }],
                lock_time: 0,
                witness: vec![],
            },
            Transaction {
                version: 1,
                inputs: vec![TxIn {
                    previous_output: OutPoint {
                        hash: [1; 32],
                        index: 0,
                    },
                    script_sig: vec![0x01, 0x01],
                    sequence: 0xffff_ffff,
                }],
                outputs: vec![TxOut {
                    value: 2,
                    script_pubkey: vec![
                        0x76, 0xa9, 0x14, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
                        1, 0x88, 0xac,
                    ],
                }],
                lock_time: 0,
                witness: vec![],
            },
        ];

        let summary = block_shape_summary(&txs);
        assert_eq!(summary.tx_count, 2);
        assert_eq!(summary.vin_count, 2);
        assert_eq!(summary.script_input_count, 1);
        assert_eq!(summary.input_shape_counts["coinbase"], 1);
        assert_eq!(summary.input_shape_counts["legacy_scriptsig"], 1);
        assert_eq!(summary.output_script_types["op_return"], 1);
        assert_eq!(summary.output_script_types["p2pkh"], 1);
    }
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
        utxo_accounting_policy: "core_spendable_v1",
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
    counts: HashMap<String, usize>,
    slow_blocks: Vec<SlowBlock>,
    spent_prevout_script_types: BTreeMap<String, usize>,
}

impl TimingCollector {
    fn new() -> Self {
        Self {
            started: Instant::now(),
            stage_totals: HashMap::new(),
            counts: HashMap::new(),
            slow_blocks: Vec::new(),
            spent_prevout_script_types: BTreeMap::new(),
        }
    }

    fn measure<T>(&mut self, stage: &str, f: impl FnOnce() -> Result<T>) -> Result<T> {
        let started = Instant::now();
        let result = f();
        self.add_stage(stage, started.elapsed());
        result
    }

    fn add_stage(&mut self, stage: &str, elapsed: Duration) {
        *self.stage_totals.entry(stage.to_string()).or_default() += elapsed;
    }

    fn add_count(&mut self, name: &str, value: usize) {
        *self.counts.entry(name.to_string()).or_default() += value;
    }

    fn record_utxo_read_stats(&mut self, stats: &UtxoReadStats) {
        self.add_count("utxo_lookup_count", stats.lookup_count);
        self.add_count("utxo_key_bytes", stats.key_bytes);
        self.add_count("utxo_value_bytes", stats.value_bytes);
        self.add_stage("prevout_multi_get_call", stats.multi_get);
        self.add_stage("prevout_utxo_decode", stats.decode);
    }

    fn record_script_verify_stats(&mut self, stats: &ScriptVerifyStats, wall: Duration) {
        self.add_count("script_jobs", stats.jobs);
        self.add_count("runner_batches", stats.batches);
        self.add_count(
            "script_worker_cpu_ms",
            stats.worker_cpu.as_millis() as usize,
        );
        self.add_count("script_wall_ms", wall.as_millis() as usize);
        self.counts
            .entry("script_threads".to_string())
            .and_modify(|value| *value = (*value).max(stats.threads))
            .or_insert(stats.threads);
        self.counts
            .entry(format!("script_runner_{}_batches", stats.mode))
            .and_modify(|value| *value += stats.batches)
            .or_insert(stats.batches);
    }

    fn set_spent_prevout_script_types(&mut self, counts: BTreeMap<String, usize>) {
        self.spent_prevout_script_types = counts;
    }

    fn record_block(&mut self, height: u32, elapsed: Duration, mut shape: BlockShapeSummary) {
        if shape.spent_prevout_script_types.is_empty() {
            shape.spent_prevout_script_types = self.spent_prevout_script_types.clone();
        }
        self.slow_blocks.push(SlowBlock {
            height,
            ms: elapsed.as_millis() as i64,
            tx_count: shape.tx_count,
            vin_count: shape.vin_count,
            vout_count: shape.vout_count,
            script_input_count: shape.script_input_count,
            same_block_spends: shape.same_block_spends,
            created_utxos: shape.created_utxos,
            spent_external: shape.spent_external,
            input_shape_counts: shape.input_shape_counts,
            spent_prevout_script_types: shape.spent_prevout_script_types,
            output_script_types: shape.output_script_types,
        });
        self.slow_blocks.sort_by_key(|block| -block.ms);
        self.slow_blocks.truncate(10);
    }

    fn summary(self) -> TimingSummary {
        let count = |name: &str| self.counts.get(name).copied().unwrap_or_default();
        let stage_millis = |name: &str| {
            self.stage_totals
                .get(name)
                .map(|duration| duration.as_millis() as i64)
                .unwrap_or_default()
        };
        TimingSummary {
            total_ms: self.started.elapsed().as_millis() as i64,
            script_threads: count("script_threads"),
            script_jobs: count("script_jobs"),
            runner_batches: count("runner_batches"),
            script_wall_ms: count("script_wall_ms") as i64,
            script_worker_cpu_ms: count("script_worker_cpu_ms") as i64,
            utxo_lookup_count: count("utxo_lookup_count"),
            same_block_spends: count("same_block_spends"),
            created_utxos: count("created_utxos"),
            spent_external: count("spent_external"),
            utxo_key_bytes: count("utxo_key_bytes"),
            utxo_value_bytes: count("utxo_value_bytes"),
            prevout_multi_get_call: stage_millis("prevout_multi_get_call"),
            prevout_utxo_decode_ms: stage_millis("prevout_utxo_decode"),
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
        "utxo_delete_prepare",
        "utxo_put_prepare",
        "undo_put_prepare",
        "metadata_put_prepare",
        "rocksdb_write",
    ] {
        let millis = storage_timings.millis(stage);
        if millis > 0 {
            timing.add_stage(stage, Duration::from_millis(millis as u64));
        }
    }
}
