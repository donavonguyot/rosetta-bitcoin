use anyhow::{anyhow, bail, ensure, Context, Result};
use chrono::Utc;
use rocksdb::{BlockBasedOptions, Cache, Options, WriteBatch, WriteOptions, DB};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};
use std::time::Instant;

use crate::codec;

pub const MARKER_NAME: &str = ".rsbitnode_native_storage";
pub const LOCK_NAME: &str = ".rsbitnode.lock";
pub const BACKEND_DIR: &str = "chainstate-rocksdb";

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Metadata {
    pub node_id: String,
    pub generation_id: String,
    pub chain: String,
    pub sync_status: String,
    pub chainstate_status: String,
    pub chainstate_backend: String,
    pub validated_height: i64,
    pub validated_hash: String,
    pub header_height: i64,
    pub header_hash: String,
    pub stored_block_height: i64,
    pub stored_block_hash: String,
    pub chainstate_utxo_count: i64,
    pub current_blocker: Option<serde_json::Value>,
    pub last_error: String,
    pub updated_at: String,
}

pub struct Store {
    db: DB,
    disable_wal: bool,
    data_dir: PathBuf,
}

impl Store {
    pub fn open(datadir: &Path) -> Result<Self> {
        std::fs::create_dir_all(datadir)?;
        std::fs::write(datadir.join(MARKER_NAME), b"rsbitnode native storage\n")?;
        let options = tuned_options();
        let db = DB::open(&options, backend_path(datadir))?;
        Ok(Self {
            db,
            disable_wal: env_flag("RSBITNODE_ROCKSDB_DISABLE_WAL"),
            data_dir: datadir.to_path_buf(),
        })
    }

    pub fn put_metadata(&self, meta: &Metadata) -> Result<()> {
        let mut meta = meta.clone();
        meta.updated_at = Utc::now().to_rfc3339();
        let mut batch = WriteBatch::default();
        put_metadata_batch(&mut batch, &meta)?;
        self.write_batch(batch)?;
        Ok(())
    }

    pub fn metadata(&self) -> Result<Metadata> {
        if self.db.get(codec::metadata_key("node_id"))?.is_some() {
            return self.metadata_from_keys();
        }
        let Some(bytes) = self.db.get(b"meta")? else {
            bail!("metadata missing");
        };
        Ok(serde_json::from_slice(&bytes)?)
    }

    pub fn put_raw(&self, key: &[u8], value: &[u8]) -> Result<()> {
        self.db.put(key, value)?;
        Ok(())
    }

    pub fn record_block(&self, height: u32, hash: &str, raw: &[u8]) -> Result<()> {
        let blocks_dir = self.data_dir()?.join("blocks");
        std::fs::create_dir_all(&blocks_dir)?;
        let relative = format!("blocks/block_{height:08}.dat");
        std::fs::write(self.data_dir()?.join(&relative), raw)?;
        let index = serde_json::json!({
            "height": height,
            "hash": hash,
            "path": relative,
            "size": raw.len()
        });
        self.db.put(
            format!("block-index:{height:08}").as_bytes(),
            serde_json::to_vec(&index)?,
        )?;
        Ok(())
    }

    pub fn read_block(&self, height: u32) -> Result<Vec<u8>> {
        Ok(std::fs::read(
            self.data_dir()?
                .join(format!("blocks/block_{height:08}.dat")),
        )?)
    }

    #[cfg(test)]
    pub fn put_utxo(&self, chain: &str, utxo: &StoredUtxo) -> Result<()> {
        self.db.put(
            codec::utxo_key(chain, &utxo.outpoint.txid_internal, utxo.outpoint.vout),
            codec::utxo_value(
                utxo.height,
                utxo.value_sats,
                utxo.coinbase,
                &utxo.script_pubkey,
            ),
        )?;
        Ok(())
    }

    pub fn get_utxo(&self, chain: &str, outpoint: &UtxoOutpoint) -> Result<Option<StoredUtxo>> {
        let key = codec::utxo_key(chain, &outpoint.txid_internal, outpoint.vout);
        self.db
            .get(key)?
            .map(|value| decode_utxo(outpoint, &value))
            .transpose()
    }

    pub fn get_many_utxos(
        &self,
        chain: &str,
        outpoints: &[UtxoOutpoint],
    ) -> Result<Vec<Option<StoredUtxo>>> {
        if outpoints.len() >= 64 {
            return self.get_many_utxos_deduped(chain, outpoints);
        }
        let keys = outpoints
            .iter()
            .map(|outpoint| codec::utxo_key(chain, &outpoint.txid_internal, outpoint.vout))
            .collect::<Vec<_>>();
        self.db
            .multi_get(keys)
            .into_iter()
            .zip(outpoints.iter())
            .map(|(value, outpoint)| {
                value?
                    .map(|bytes| decode_utxo(outpoint, &bytes))
                    .transpose()
            })
            .collect()
    }

    fn get_many_utxos_deduped(
        &self,
        chain: &str,
        outpoints: &[UtxoOutpoint],
    ) -> Result<Vec<Option<StoredUtxo>>> {
        let mut unique = Vec::with_capacity(outpoints.len());
        let mut unique_index = HashMap::with_capacity(outpoints.len());
        let mut order = Vec::with_capacity(outpoints.len());
        for outpoint in outpoints {
            let index = match unique_index.get(outpoint) {
                Some(index) => *index,
                None => {
                    let index = unique.len();
                    unique.push(*outpoint);
                    unique_index.insert(*outpoint, index);
                    index
                }
            };
            order.push(index);
        }
        let keys = unique
            .iter()
            .map(|outpoint| codec::utxo_key(chain, &outpoint.txid_internal, outpoint.vout))
            .collect::<Vec<_>>();
        let decoded = self
            .db
            .multi_get(keys)
            .into_iter()
            .zip(unique.iter())
            .map(|(value, outpoint)| {
                value?
                    .map(|bytes| decode_utxo(outpoint, &bytes))
                    .transpose()
            })
            .collect::<Result<Vec<_>>>()?;
        Ok(order
            .into_iter()
            .map(|index| decoded[index].clone())
            .collect())
    }

    pub fn commit_block(
        &self,
        commit: ChainstateBlockCommit,
        timings: &mut ConnectTimings,
    ) -> Result<ChainstateCommitResult> {
        let commit_started = Instant::now();
        let existing = self.metadata().unwrap_or_else(|_| missing_metadata());
        let current_utxos = self
            .chainstate_utxo_count()
            .unwrap_or(existing.chainstate_utxo_count);
        let new_utxo_count =
            current_utxos - commit.spent_external.len() as i64 + commit.created_utxos.len() as i64;
        ensure!(
            new_utxo_count >= 0,
            "chainstate UTXO count would become negative"
        );

        let tip = ChainstateTip {
            height: commit.height,
            block_hash_internal: commit.block_hash_internal,
        };
        let mut meta = existing;
        meta.node_id = "rsbitnode-native-storage".to_string();
        meta.generation_id = if meta.generation_id.is_empty() {
            "rust-proof-generation".to_string()
        } else {
            meta.generation_id
        };
        meta.chain = commit.chain.clone();
        meta.sync_status = "blocks_current".to_string();
        meta.chainstate_status = "usable".to_string();
        meta.chainstate_backend = "rocksdb".to_string();
        meta.validated_height = commit.height as i64;
        meta.validated_hash = display_hash(&commit.block_hash_internal);
        meta.header_height = commit.height as i64;
        meta.header_hash = meta.validated_hash.clone();
        meta.stored_block_height = commit.height as i64;
        meta.stored_block_hash = meta.validated_hash.clone();
        meta.chainstate_utxo_count = new_utxo_count;
        meta.current_blocker = None;
        meta.last_error.clear();
        meta.updated_at = Utc::now().to_rfc3339();

        let mut batch = WriteBatch::default();
        let apply_started = Instant::now();
        let delete_started = Instant::now();
        for outpoint in &commit.spent_external {
            batch.delete(codec::utxo_key(
                &commit.chain,
                &outpoint.txid_internal,
                outpoint.vout,
            ));
        }
        timings.add("utxo_delete_prepare", delete_started.elapsed());
        let put_started = Instant::now();
        for utxo in &commit.created_utxos {
            batch.put(
                codec::utxo_key(
                    &commit.chain,
                    &utxo.outpoint.txid_internal,
                    utxo.outpoint.vout,
                ),
                codec::utxo_value(
                    utxo.height,
                    utxo.value_sats,
                    utxo.coinbase,
                    &utxo.script_pubkey,
                ),
            );
        }
        timings.add("utxo_put_prepare", put_started.elapsed());
        let undo_started = Instant::now();
        batch.put(
            codec::height_key(b'd', &commit.chain, commit.height),
            encode_undo_entries(&commit.undo_entries),
        );
        timings.add("undo_put_prepare", undo_started.elapsed());
        let metadata_started = Instant::now();
        batch.put(
            codec::chain_key(b't', &commit.chain),
            codec::tip_value(commit.height, &commit.block_hash_internal),
        );
        put_metadata_batch(&mut batch, &meta)?;
        timings.add("metadata_put_prepare", metadata_started.elapsed());
        timings.add("utxo_apply", apply_started.elapsed());
        let rocksdb_write_started = Instant::now();
        self.write_batch(batch)?;
        timings.add("rocksdb_write", rocksdb_write_started.elapsed());
        timings.add("commit", commit_started.elapsed());

        Ok(ChainstateCommitResult {
            tip,
            chainstate_utxo_count: new_utxo_count,
            metadata: meta,
        })
    }

    pub fn read_tip(&self, chain: &str) -> Result<Option<ChainstateTip>> {
        self.db
            .get(codec::chain_key(b't', chain))?
            .map(|value| decode_tip(&value))
            .transpose()
    }

    pub fn read_undo(&self, chain: &str, height: u32) -> Result<Vec<UtxoUndoEntry>> {
        self.db
            .get(codec::height_key(b'd', chain, height))?
            .map(|value| decode_undo_entries(&value))
            .transpose()
            .map(|value| value.unwrap_or_default())
    }

    pub fn chainstate_utxo_count(&self) -> Result<i64> {
        let Some(bytes) = self.db.get(codec::metadata_key("chainstate_utxo_count"))? else {
            bail!("chainstate_utxo_count missing");
        };
        Ok(std::str::from_utf8(&bytes)?.parse()?)
    }

    fn metadata_from_keys(&self) -> Result<Metadata> {
        Ok(Metadata {
            node_id: self.meta_string("node_id")?,
            generation_id: self.meta_string("generation_id")?,
            chain: self.meta_string("chain")?,
            sync_status: self.meta_string("sync_status")?,
            chainstate_status: self.meta_string("chainstate_status")?,
            chainstate_backend: self.meta_string("chainstate_backend")?,
            validated_height: self.meta_i64("validated_height")?,
            validated_hash: self.meta_string("validated_hash")?,
            header_height: self.meta_i64("header_height")?,
            header_hash: self.meta_string("header_hash")?,
            stored_block_height: self.meta_i64("stored_block_height")?,
            stored_block_hash: self.meta_string("stored_block_hash")?,
            chainstate_utxo_count: self.meta_i64("chainstate_utxo_count")?,
            current_blocker: self
                .meta_string("current_blocker")
                .ok()
                .filter(|value| !value.is_empty())
                .map(|value| serde_json::from_str(&value))
                .transpose()?,
            last_error: self.meta_string("last_error")?,
            updated_at: self.meta_string("updated_at")?,
        })
    }

    fn meta_string(&self, name: &str) -> Result<String> {
        let Some(bytes) = self.db.get(codec::metadata_key(name))? else {
            bail!("metadata key {name} missing");
        };
        Ok(String::from_utf8(bytes)?)
    }

    fn meta_i64(&self, name: &str) -> Result<i64> {
        Ok(self.meta_string(name)?.parse()?)
    }

    fn write_batch(&self, batch: WriteBatch) -> Result<()> {
        let mut options = WriteOptions::default();
        options.disable_wal(self.disable_wal);
        self.db.write_opt(batch, &options)?;
        Ok(())
    }

    fn data_dir(&self) -> Result<PathBuf> {
        Ok(self.data_dir.clone())
    }
}

pub fn read_metadata(datadir: &Path) -> Result<Metadata> {
    Store::open(datadir)?.metadata()
}

pub fn backend_path(datadir: &Path) -> PathBuf {
    datadir.join(BACKEND_DIR)
}

pub fn lock_path(datadir: &Path) -> PathBuf {
    datadir.join(LOCK_NAME)
}

pub fn seed_connect_proof(datadir: &Path) -> Result<ConnectProof> {
    let store = Store::open(datadir)?;
    store.put_metadata(&Metadata {
        node_id: "rsbitnode-native-storage".to_string(),
        generation_id: "rust-proof-generation".to_string(),
        chain: "testnet4".to_string(),
        sync_status: "starting".to_string(),
        chainstate_status: "initializing".to_string(),
        chainstate_backend: "rocksdb".to_string(),
        validated_height: 0,
        validated_hash: String::new(),
        header_height: 0,
        header_hash: String::new(),
        stored_block_height: 0,
        stored_block_hash: String::new(),
        chainstate_utxo_count: 0,
        current_blocker: None,
        last_error: String::new(),
        updated_at: Utc::now().to_rfc3339(),
    })?;

    let chain = "testnet4";
    let block_one_hash = display_hash_to_internal(
        "0000000012982b6d5f621229286b880e909984df669c2afabb102ce311b13f28",
    )?;
    let block_two_hash = display_hash_to_internal(
        "000000001fed1a914651afc36574003c5300cac5df738c3976f28d54f7096253",
    )?;
    let tx_one = txid_from_byte(1);
    let tx_two = txid_from_byte(2);
    let missing = txid_from_byte(99);
    let out_one = UtxoOutpoint::new(tx_one, 0);
    let out_two = UtxoOutpoint::new(tx_two, 0);

    let mut timings = ConnectTimings::default();
    let started = Instant::now();

    let mut view_one = BlockUtxoView::new(&store, chain, 1, 0, 1);
    view_one.create(out_one, 5_000_000_000, vec![0x51], true)?;
    let commit_one = view_one.to_commit(block_one_hash)?;
    timings.merge(&view_one.timings);
    let first_result = store.commit_block(commit_one, &mut timings)?;
    ensure!(
        first_result.tip.height == 1,
        "first proof commit did not advance to height 1"
    );

    let batch = store.get_many_utxos(
        chain,
        &[
            UtxoOutpoint::new(missing, 0),
            out_one,
            UtxoOutpoint::new(missing, 1),
        ],
    )?;
    let batch_prevout_order_preserved =
        batch.len() == 3 && batch[0].is_none() && batch[1].is_some() && batch[2].is_none();

    let mut view_two = BlockUtxoView::new(&store, chain, 2, 1, 1);
    view_two.prefetch_external(&[out_one])?;
    let spent = view_two
        .get(&out_one)?
        .context("proof block two expected block one UTXO")?;
    view_two.spend(&out_one)?;
    view_two.create(out_two, spent.value_sats - 1_000, vec![0x51], false)?;
    let commit_two = view_two.to_commit(block_two_hash)?;
    timings.merge(&view_two.timings);
    let second_result = store.commit_block(commit_two, &mut timings)?;
    ensure!(
        second_result.tip.height == 2 && second_result.chainstate_utxo_count == 1,
        "second proof commit did not preserve expected tip/counter"
    );
    ensure!(
        second_result.metadata.validated_height == 2,
        "second proof metadata did not advance"
    );
    ensure!(
        store.read_tip(chain)?.is_some_and(|tip| tip.height == 2),
        "proof tip readback failed"
    );
    ensure!(
        store.read_undo(chain, 2)?.len() == 1,
        "proof undo readback failed"
    );

    timings.add("script_verify", std::time::Duration::ZERO);
    timings.add("block_connect_store_commit", started.elapsed());
    store.put_raw(b"block:1", hex::encode(block_one_hash).as_bytes())?;
    store.put_raw(b"block:2", hex::encode(block_two_hash).as_bytes())?;

    Ok(ConnectProof {
        metadata: store.metadata()?,
        timings,
        batch_prevout_order_preserved,
        atomic_commit_exercised: true,
        block_local_view_exercised: true,
    })
}

pub fn lock_status(datadir: &Path) -> (String, Option<u32>) {
    let path = lock_path(datadir);
    let Ok(data) = std::fs::read_to_string(path) else {
        return ("unlocked".to_string(), None);
    };
    let pid = data
        .lines()
        .find_map(|line| line.strip_prefix("pid="))
        .and_then(|value| value.parse::<u32>().ok());
    ("locked".to_string(), pid)
}

pub fn missing_metadata() -> Metadata {
    Metadata {
        node_id: "rsbitnode-uninitialized".to_string(),
        generation_id: String::new(),
        chain: "testnet4".to_string(),
        sync_status: "starting".to_string(),
        chainstate_status: "missing".to_string(),
        chainstate_backend: "rocksdb".to_string(),
        validated_height: 0,
        validated_hash: String::new(),
        header_height: 0,
        header_hash: String::new(),
        stored_block_height: 0,
        stored_block_hash: String::new(),
        chainstate_utxo_count: 0,
        current_blocker: None,
        last_error: String::new(),
        updated_at: Utc::now().to_rfc3339(),
    }
}

pub fn ensure_parent(path: &Path) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| anyhow!("result path has no parent"))?;
    std::fs::create_dir_all(parent)?;
    Ok(())
}

#[derive(Clone, Copy, Debug, Eq)]
pub struct UtxoOutpoint {
    pub txid_internal: [u8; 32],
    pub vout: u32,
}

impl UtxoOutpoint {
    pub fn new(txid_internal: [u8; 32], vout: u32) -> Self {
        Self {
            txid_internal,
            vout,
        }
    }
}

impl PartialEq for UtxoOutpoint {
    fn eq(&self, other: &Self) -> bool {
        self.txid_internal == other.txid_internal && self.vout == other.vout
    }
}

impl Hash for UtxoOutpoint {
    fn hash<H: Hasher>(&self, state: &mut H) {
        self.txid_internal.hash(state);
        self.vout.hash(state);
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StoredUtxo {
    pub outpoint: UtxoOutpoint,
    pub height: u32,
    pub value_sats: u64,
    pub coinbase: bool,
    pub script_pubkey: Vec<u8>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UtxoUndoEntry {
    pub outpoint: UtxoOutpoint,
    pub height: u32,
    pub value_sats: u64,
    pub coinbase: bool,
    pub script_pubkey: Vec<u8>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChainstateTip {
    pub height: u32,
    pub block_hash_internal: [u8; 32],
}

#[derive(Clone, Debug)]
pub struct ChainstateBlockCommit {
    pub chain: String,
    pub height: u32,
    pub block_hash_internal: [u8; 32],
    pub spent_external: Vec<UtxoOutpoint>,
    pub created_utxos: Vec<StoredUtxo>,
    pub undo_entries: Vec<UtxoUndoEntry>,
}

#[derive(Clone, Debug)]
pub struct ChainstateCommitResult {
    pub tip: ChainstateTip,
    pub chainstate_utxo_count: i64,
    pub metadata: Metadata,
}

#[derive(Clone, Debug)]
pub struct ConnectProof {
    pub metadata: Metadata,
    pub timings: ConnectTimings,
    pub batch_prevout_order_preserved: bool,
    pub atomic_commit_exercised: bool,
    pub block_local_view_exercised: bool,
}

#[derive(Clone, Debug, Default)]
pub struct ConnectTimings {
    stages: BTreeMap<String, u128>,
}

impl ConnectTimings {
    pub fn add(&mut self, stage: &str, elapsed: std::time::Duration) {
        *self.stages.entry(stage.to_string()).or_default() += elapsed.as_millis();
    }

    pub fn merge(&mut self, other: &ConnectTimings) {
        for (stage, millis) in &other.stages {
            *self.stages.entry(stage.clone()).or_default() += millis;
        }
    }

    pub fn millis(&self, stage: &str) -> i64 {
        self.stages.get(stage).copied().unwrap_or(0) as i64
    }

    pub fn as_json(&self) -> serde_json::Value {
        serde_json::Value::Object(
            self.stages
                .iter()
                .map(|(stage, millis)| (stage.clone(), serde_json::json!(millis)))
                .collect(),
        )
    }
}

pub struct BlockUtxoView<'a> {
    store: &'a Store,
    chain: String,
    height: u32,
    loaded: HashMap<UtxoOutpoint, StoredUtxo>,
    created: HashMap<UtxoOutpoint, StoredUtxo>,
    spent: HashSet<UtxoOutpoint>,
    timings: ConnectTimings,
}

impl<'a> BlockUtxoView<'a> {
    pub fn new(
        store: &'a Store,
        chain: &str,
        height: u32,
        expected_spends: usize,
        expected_creates: usize,
    ) -> Self {
        Self {
            store,
            chain: chain.to_string(),
            height,
            loaded: HashMap::with_capacity(expected_spends.saturating_mul(2).max(16)),
            created: HashMap::with_capacity(expected_creates.saturating_mul(2).max(16)),
            spent: HashSet::with_capacity(expected_spends.saturating_mul(2).max(16)),
            timings: ConnectTimings::default(),
        }
    }

    pub fn prefetch_external(&mut self, prevouts: &[UtxoOutpoint]) -> Result<()> {
        let mut distinct = Vec::new();
        let mut seen = HashSet::new();
        for outpoint in prevouts {
            if self.loaded.contains_key(outpoint)
                || self.created.contains_key(outpoint)
                || !seen.insert(*outpoint)
            {
                continue;
            }
            distinct.push(*outpoint);
        }
        if distinct.is_empty() {
            return Ok(());
        }
        let started = Instant::now();
        let values = self.store.get_many_utxos(&self.chain, &distinct)?;
        for (outpoint, utxo) in distinct.into_iter().zip(values) {
            if let Some(utxo) = utxo {
                self.loaded.insert(outpoint, utxo);
            }
        }
        self.timings.add("prevout_batch_load", started.elapsed());
        self.timings.add("utxo_load", started.elapsed());
        Ok(())
    }

    pub fn get(&mut self, outpoint: &UtxoOutpoint) -> Result<Option<StoredUtxo>> {
        if self.spent.contains(outpoint) {
            return Ok(None);
        }
        if let Some(utxo) = self.created.get(outpoint) {
            return Ok(Some(utxo.clone()));
        }
        if let Some(utxo) = self.loaded.get(outpoint) {
            return Ok(Some(utxo.clone()));
        }
        let started = Instant::now();
        let utxo = self.store.get_utxo(&self.chain, outpoint)?;
        if let Some(utxo) = &utxo {
            self.loaded.insert(*outpoint, utxo.clone());
        }
        self.timings.add("utxo_load", started.elapsed());
        Ok(utxo)
    }

    pub fn spend(&mut self, outpoint: &UtxoOutpoint) -> Result<()> {
        ensure!(
            !self.spent.contains(outpoint),
            "double spend of {}:{}",
            hex::encode(outpoint.txid_internal),
            outpoint.vout
        );
        self.spent.insert(*outpoint);
        Ok(())
    }

    pub fn create(
        &mut self,
        outpoint: UtxoOutpoint,
        value_sats: u64,
        script_pubkey: Vec<u8>,
        coinbase: bool,
    ) -> Result<()> {
        ensure!(
            !self.created.contains_key(&outpoint),
            "duplicate UTXO {}:{}",
            hex::encode(outpoint.txid_internal),
            outpoint.vout
        );
        self.created.insert(
            outpoint,
            StoredUtxo {
                outpoint,
                height: self.height,
                value_sats,
                coinbase,
                script_pubkey,
            },
        );
        Ok(())
    }

    pub fn to_commit(&self, block_hash_internal: [u8; 32]) -> Result<ChainstateBlockCommit> {
        let mut spent_external = Vec::new();
        let mut undo_entries = Vec::new();
        for outpoint in &self.spent {
            if self.created.contains_key(outpoint) {
                continue;
            }
            spent_external.push(*outpoint);
            let utxo = self
                .loaded
                .get(outpoint)
                .ok_or_else(|| anyhow!("cannot build undo for unloaded spent prevout"))?;
            undo_entries.push(UtxoUndoEntry {
                outpoint: *outpoint,
                height: utxo.height,
                value_sats: utxo.value_sats,
                coinbase: utxo.coinbase,
                script_pubkey: utxo.script_pubkey.clone(),
            });
        }
        let created_utxos = self
            .created
            .iter()
            .filter_map(|(outpoint, utxo)| (!self.spent.contains(outpoint)).then_some(utxo.clone()))
            .collect();
        Ok(ChainstateBlockCommit {
            chain: self.chain.clone(),
            height: self.height,
            block_hash_internal,
            spent_external,
            created_utxos,
            undo_entries,
        })
    }
}

fn tuned_options() -> Options {
    let cache = Cache::new_lru_cache(256 << 20);
    let mut block_options = BlockBasedOptions::default();
    block_options.set_block_cache(&cache);
    block_options.set_bloom_filter(10.0, true);
    block_options.set_cache_index_and_filter_blocks(true);

    let mut options = Options::default();
    options.create_if_missing(true);
    options.set_block_based_table_factory(&block_options);
    options.set_write_buffer_size(64 << 20);
    options.set_max_write_buffer_number(4);
    options.set_max_background_jobs(4);
    options
}

fn env_flag(name: &str) -> bool {
    std::env::var(name)
        .map(|value| matches!(value.trim(), "1" | "true" | "TRUE" | "yes" | "YES"))
        .unwrap_or(false)
}

fn put_metadata_batch(batch: &mut WriteBatch, meta: &Metadata) -> Result<()> {
    put_meta(batch, "node_id", &meta.node_id);
    put_meta(batch, "generation_id", &meta.generation_id);
    put_meta(batch, "chain", &meta.chain);
    put_meta(batch, "sync_status", &meta.sync_status);
    put_meta(batch, "chainstate_status", &meta.chainstate_status);
    put_meta(batch, "chainstate_backend", &meta.chainstate_backend);
    put_meta(
        batch,
        "validated_height",
        &meta.validated_height.to_string(),
    );
    put_meta(batch, "validated_hash", &meta.validated_hash);
    put_meta(batch, "header_height", &meta.header_height.to_string());
    put_meta(batch, "header_hash", &meta.header_hash);
    put_meta(
        batch,
        "stored_block_height",
        &meta.stored_block_height.to_string(),
    );
    put_meta(batch, "stored_block_hash", &meta.stored_block_hash);
    put_meta(
        batch,
        "chainstate_utxo_count",
        &meta.chainstate_utxo_count.to_string(),
    );
    put_meta(
        batch,
        "current_blocker",
        &meta
            .current_blocker
            .as_ref()
            .map(serde_json::to_string)
            .transpose()?
            .unwrap_or_default(),
    );
    put_meta(batch, "last_error", &meta.last_error);
    put_meta(batch, "updated_at", &meta.updated_at);
    batch.put(b"meta", serde_json::to_vec(meta)?);
    Ok(())
}

fn put_meta(batch: &mut WriteBatch, name: &str, value: &str) {
    batch.put(codec::metadata_key(name), value.as_bytes());
}

fn decode_utxo(outpoint: &UtxoOutpoint, value: &[u8]) -> Result<StoredUtxo> {
    ensure!(value.len() >= 17, "UTXO value too short");
    let height = u32::from_be_bytes(value[0..4].try_into()?);
    let value_sats = u64::from_be_bytes(value[4..12].try_into()?);
    let coinbase = value[12] == 1;
    let (script_pubkey, consumed) = decode_varbytes(&value[13..])?;
    ensure!(13 + consumed == value.len(), "trailing UTXO value bytes");
    Ok(StoredUtxo {
        outpoint: *outpoint,
        height,
        value_sats,
        coinbase,
        script_pubkey,
    })
}

fn encode_undo_entries(entries: &[UtxoUndoEntry]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&(entries.len() as u32).to_be_bytes());
    for entry in entries {
        out.extend_from_slice(&entry.outpoint.txid_internal);
        out.extend_from_slice(&entry.outpoint.vout.to_be_bytes());
        out.extend_from_slice(&entry.height.to_be_bytes());
        out.extend_from_slice(&entry.value_sats.to_be_bytes());
        out.push(if entry.coinbase { 1 } else { 0 });
        out.extend_from_slice(&codec::varbytes(&entry.script_pubkey));
    }
    out
}

fn decode_undo_entries(value: &[u8]) -> Result<Vec<UtxoUndoEntry>> {
    ensure!(value.len() >= 4, "undo value too short");
    let count = u32::from_be_bytes(value[0..4].try_into()?) as usize;
    let mut offset = 4;
    let mut entries = Vec::with_capacity(count);
    for _ in 0..count {
        ensure!(offset + 49 <= value.len(), "undo entry too short");
        let txid_internal = value[offset..offset + 32].try_into()?;
        offset += 32;
        let vout = u32::from_be_bytes(value[offset..offset + 4].try_into()?);
        offset += 4;
        let height = u32::from_be_bytes(value[offset..offset + 4].try_into()?);
        offset += 4;
        let value_sats = u64::from_be_bytes(value[offset..offset + 8].try_into()?);
        offset += 8;
        let coinbase = value[offset] == 1;
        offset += 1;
        let (script_pubkey, consumed) = decode_varbytes(&value[offset..])?;
        offset += consumed;
        entries.push(UtxoUndoEntry {
            outpoint: UtxoOutpoint::new(txid_internal, vout),
            height,
            value_sats,
            coinbase,
            script_pubkey,
        });
    }
    ensure!(offset == value.len(), "trailing undo value bytes");
    Ok(entries)
}

fn decode_tip(value: &[u8]) -> Result<ChainstateTip> {
    ensure!(value.len() == 36, "tip value must be 36 bytes");
    Ok(ChainstateTip {
        height: u32::from_be_bytes(value[0..4].try_into()?),
        block_hash_internal: value[4..36].try_into()?,
    })
}

fn decode_varbytes(value: &[u8]) -> Result<(Vec<u8>, usize)> {
    ensure!(value.len() >= 4, "varbytes length missing");
    let len = u32::from_be_bytes(value[0..4].try_into()?) as usize;
    ensure!(value.len() >= 4 + len, "varbytes payload truncated");
    Ok((value[4..4 + len].to_vec(), 4 + len))
}

fn display_hash_to_internal(value: &str) -> Result<[u8; 32]> {
    let mut bytes = hex::decode(value)?;
    ensure!(bytes.len() == 32, "expected 32-byte hex value");
    bytes.reverse();
    bytes
        .try_into()
        .map_err(|_| anyhow!("expected 32-byte hex value"))
}

fn display_hash(internal: &[u8; 32]) -> String {
    let mut bytes = *internal;
    bytes.reverse();
    hex::encode(bytes)
}

fn txid_from_byte(byte: u8) -> [u8; 32] {
    [byte; 32]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn open_temp() -> (tempfile::TempDir, Store) {
        let dir = tempfile::tempdir().expect("tempdir");
        let store = Store::open(dir.path()).expect("open store");
        (dir, store)
    }

    fn utxo(byte: u8, vout: u32, height: u32, value: u64) -> StoredUtxo {
        StoredUtxo {
            outpoint: UtxoOutpoint::new([byte; 32], vout),
            height,
            value_sats: value,
            coinbase: false,
            script_pubkey: vec![0x51, byte],
        }
    }

    #[test]
    fn get_many_preserves_order_and_missing_slots() {
        let (_dir, store) = open_temp();
        let first = utxo(1, 0, 1, 11);
        let second = utxo(2, 1, 1, 22);
        store.put_utxo("testnet4", &first).expect("put first");
        store.put_utxo("testnet4", &second).expect("put second");

        let values = store
            .get_many_utxos(
                "testnet4",
                &[
                    UtxoOutpoint::new([9; 32], 0),
                    second.outpoint,
                    first.outpoint,
                    UtxoOutpoint::new([8; 32], 0),
                ],
            )
            .expect("get many");

        assert_eq!(values[0], None);
        assert_eq!(values[1].as_ref().unwrap().value_sats, 22);
        assert_eq!(values[2].as_ref().unwrap().value_sats, 11);
        assert_eq!(values[3], None);
    }

    #[test]
    fn commit_block_writes_tip_undo_utxos_metadata_and_counter() {
        let (_dir, store) = open_temp();
        store.put_metadata(&missing_metadata()).expect("metadata");
        let created = utxo(3, 0, 1, 33);
        let mut timings = ConnectTimings::default();
        let result = store
            .commit_block(
                ChainstateBlockCommit {
                    chain: "testnet4".to_string(),
                    height: 1,
                    block_hash_internal: [7; 32],
                    spent_external: vec![],
                    created_utxos: vec![created.clone()],
                    undo_entries: vec![],
                },
                &mut timings,
            )
            .expect("commit");

        assert_eq!(result.tip.height, 1);
        assert_eq!(result.chainstate_utxo_count, 1);
        assert_eq!(store.chainstate_utxo_count().unwrap(), 1);
        assert_eq!(store.read_tip("testnet4").unwrap().unwrap().height, 1);
        assert_eq!(store.read_undo("testnet4", 1).unwrap(), Vec::new());
        assert_eq!(
            store
                .get_utxo("testnet4", &created.outpoint)
                .unwrap()
                .unwrap()
                .value_sats,
            33
        );
        assert_eq!(store.metadata().unwrap().validated_height, 1);
    }

    #[test]
    fn block_view_resolves_same_block_spends_and_rejects_double_spends() {
        let (_dir, store) = open_temp();
        let outpoint = UtxoOutpoint::new([4; 32], 0);
        let mut view = BlockUtxoView::new(&store, "testnet4", 5, 1, 1);
        view.create(outpoint, 44, vec![0x51], false)
            .expect("create");
        assert_eq!(view.get(&outpoint).unwrap().unwrap().value_sats, 44);
        view.spend(&outpoint).expect("spend");
        assert!(view.spend(&outpoint).is_err());
        let commit = view.to_commit([5; 32]).expect("commit view");
        assert!(commit.created_utxos.is_empty());
        assert!(commit.spent_external.is_empty());
    }

    #[test]
    fn connect_proof_uses_maintained_counter() {
        let dir = tempfile::tempdir().expect("tempdir");
        let proof = seed_connect_proof(dir.path()).expect("proof");
        let store = Store::open(dir.path()).expect("reopen");
        assert_eq!(proof.metadata.validated_height, 2);
        assert_eq!(store.chainstate_utxo_count().unwrap(), 1);
        assert_eq!(store.metadata().unwrap().chainstate_utxo_count, 1);
        assert!(proof.batch_prevout_order_preserved);
        assert!(proof.atomic_commit_exercised);
    }
}
