use anyhow::{bail, ensure, Context, Result};
use chrono::Utc;
use rayon::prelude::*;
use serde::Serialize;
use serde_json::Value;
use std::collections::{BTreeMap, HashMap, HashSet};
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
    pub tx_count: usize,
    pub vin_count: usize,
    pub vout_count: usize,
    pub script_input_count: usize,
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
    let load_started = Instant::now();
    let loaded = store.get_many_utxos("testnet4", &prevouts)?;
    let load_elapsed = load_started.elapsed();
    timing.add_stage("prevout_batch_load", load_elapsed);
    timing.add_stage("utxo_load", load_elapsed);
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
            spent_prevouts: spent_prevouts.clone(),
        });
        view.add_spent_prevout_script_types(&spent_prevouts);
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
    timing.set_spent_prevout_script_types(view.spent_prevout_script_types.clone());
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
    let tasks = script_verify_tasks(jobs);
    if script_parallel_enabled() && tasks.len() > 1 {
        first_failure_by_order(
            tasks
                .par_iter()
                .filter_map(|task| verify_script_task(txs, jobs, task))
                .collect::<Vec<_>>(),
        )
    } else {
        tasks
            .iter()
            .find_map(|task| verify_script_task(txs, jobs, task))
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
) -> Option<(usize, usize, String)> {
    let job = &jobs[task.job_index];
    let transaction = &txs[task.tx_index];
    script_verify::verify_transaction_input_borrowed(
        transaction,
        task.input_index,
        &job.spent_prevouts[task.input_index].script_pubkey,
        job.spent_prevouts[task.input_index].amount,
        &job.spent_prevouts,
    )
    .err()
    .map(|err| (task.tx_index, task.input_index, err.to_string()))
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

#[derive(Default)]
struct BlockView {
    loaded: HashMap<UtxoOutpoint, StoredUtxo>,
    created: HashMap<UtxoOutpoint, StoredUtxo>,
    spent: HashMap<UtxoOutpoint, UtxoUndoEntry>,
    spent_prevout_script_types: BTreeMap<String, usize>,
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
    slow_blocks: Vec<SlowBlock>,
    spent_prevout_script_types: BTreeMap<String, usize>,
}

impl TimingCollector {
    fn new() -> Self {
        Self {
            started: Instant::now(),
            stage_totals: HashMap::new(),
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
            input_shape_counts: shape.input_shape_counts,
            spent_prevout_script_types: shape.spent_prevout_script_types,
            output_script_types: shape.output_script_types,
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
