use anyhow::{anyhow, bail, ensure, Context, Result};
use base64::Engine;
use chrono::Utc;
use serde::Serialize;
use serde_json::Value;
use std::cmp::Ordering;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering as AtomicOrdering};
use std::thread;
use std::time::Duration;

use crate::{storage, tx};

#[derive(Clone, Debug)]
#[allow(dead_code)]
pub struct BlockInfo {
    pub hash: String,
    pub hash_internal: [u8; 32],
    pub prev_hash: String,
    pub merkle_root: String,
    pub tx_count: usize,
}

#[derive(Serialize)]
pub struct SyncSummary {
    implementation: &'static str,
    runtime_surface: String,
    peer_mode: &'static str,
    peer: String,
    target_height: u32,
    header_height: u32,
    stored_block_height: u32,
    validated_height: i64,
    sync_status: String,
    current_blocker: Option<Value>,
    binary_gate_status: &'static str,
    started_at: String,
    updated_at: String,
    blocks_fetched: u32,
}

pub struct SyncOptions<'a> {
    pub datadir: &'a Path,
    pub target: u32,
    pub rpc_url: &'a str,
    pub rpc_user: &'a str,
    pub rpc_password: &'a str,
    pub progress: u32,
    pub runtime_surface: &'a str,
}

pub struct Client {
    url: String,
    user: String,
    password: String,
    counter: AtomicU64,
    agent: ureq::Agent,
}

impl Client {
    pub fn new(url: &str, user: &str, password: &str) -> Self {
        Self {
            url: url.to_string(),
            user: user.to_string(),
            password: password.to_string(),
            counter: AtomicU64::new(0),
            agent: ureq::AgentBuilder::new().build(),
        }
    }

    pub fn block_hash(&self, height: u32) -> Result<String> {
        self.call("getblockhash", serde_json::json!([height]))
    }

    pub fn raw_block(&self, hash: &str) -> Result<Vec<u8>> {
        let hex_block: String = self.call("getblock", serde_json::json!([hash, 0]))?;
        Ok(hex::decode(hex_block)?)
    }

    fn call<T: serde::de::DeserializeOwned>(&self, method: &str, params: Value) -> Result<T> {
        let auth = base64::engine::general_purpose::STANDARD
            .encode(format!("{}:{}", self.user, self.password));
        let attempts = rpc_attempts();
        for attempt in 0..attempts {
            let id = self.counter.fetch_add(1, AtomicOrdering::SeqCst) + 1;
            let payload = serde_json::json!({
                "jsonrpc": "1.0",
                "id": id,
                "method": method,
                "params": params,
            });
            let response = match self
                .agent
                .post(&self.url)
                .set("Content-Type", "application/json")
                .set("Authorization", &format!("Basic {auth}"))
                .send_json(payload)
            {
                Ok(response) => response,
                Err(error) if attempt + 1 < attempts => {
                    retry_pause(attempt);
                    let _ = error;
                    continue;
                }
                Err(error) => {
                    return Err(anyhow!(error))
                        .with_context(|| format!("rpc {method} request failed"));
                }
            };
            if !(200..300).contains(&response.status()) {
                bail!("rpc {method} returned HTTP {}", response.status());
            }
            let envelope: Value = match response.into_json() {
                Ok(envelope) => envelope,
                Err(error) if attempt + 1 < attempts => {
                    retry_pause(attempt);
                    let _ = error;
                    continue;
                }
                Err(error) => {
                    return Err(anyhow!(error))
                        .with_context(|| format!("rpc {method} response parse failed"));
                }
            };
            if !envelope.get("error").unwrap_or(&Value::Null).is_null() {
                bail!("rpc {method} error: {}", envelope["error"]);
            }
            return serde_json::from_value(envelope["result"].clone()).map_err(Into::into);
        }
        unreachable!("rpc attempts loop always returns")
    }
}

fn rpc_attempts() -> usize {
    std::env::var("RSBITNODE_RPC_RETRIES")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(10)
        .clamp(1, 20)
}

fn retry_pause(attempt: usize) {
    let delay_ms = 100u64.saturating_mul(1u64 << attempt.min(4));
    thread::sleep(Duration::from_millis(delay_ms));
}

pub fn run(opts: SyncOptions<'_>) -> Result<SyncSummary> {
    let progress = opts.progress.max(1);
    let client = Client::new(opts.rpc_url, opts.rpc_user, opts.rpc_password);
    let store = storage::Store::open(opts.datadir)?;
    let started = Utc::now().to_rfc3339();
    let mut prev = String::new();
    let mut stored_hash = String::new();
    for height in 0..=opts.target {
        let hash = client.block_hash(height)?;
        let raw = client.raw_block(&hash)?;
        let info = validate_block(
            &raw,
            Some(&hash),
            if height == 0 { None } else { Some(&prev) },
        )
        .with_context(|| format!("height {height}"))?;
        store.record_block(height, &info.hash, &raw)?;
        prev = info.hash.clone();
        stored_hash = info.hash.clone();
        if height % progress == 0 || height == opts.target {
            store.put_metadata(&metadata_after_store(
                store.metadata().ok(),
                height,
                &stored_hash,
                &started,
            ))?;
            println!(
                "rsbitnode-sync height={} hash={} txs={}",
                height, info.hash, info.tx_count
            );
        }
    }
    let meta = metadata_after_store(store.metadata().ok(), opts.target, &stored_hash, &started);
    store.put_metadata(&meta)?;
    Ok(SyncSummary {
        implementation: "RustNode",
        runtime_surface: opts.runtime_surface.to_string(),
        peer_mode: "local_reference_rpc",
        peer: opts.rpc_url.to_string(),
        target_height: opts.target,
        header_height: opts.target,
        stored_block_height: opts.target,
        validated_height: meta.validated_height,
        sync_status: meta.sync_status,
        current_blocker: meta.current_blocker,
        binary_gate_status: "not_attempted",
        started_at: started,
        updated_at: Utc::now().to_rfc3339(),
        blocks_fetched: opts.target + 1,
    })
}

pub fn validate_block(
    raw: &[u8],
    expected_hash: Option<&str>,
    expected_prev: Option<&str>,
) -> Result<BlockInfo> {
    let (info, _) = decode_block(raw, expected_hash, expected_prev)?;
    Ok(info)
}

pub fn decode_block(
    raw: &[u8],
    expected_hash: Option<&str>,
    expected_prev: Option<&str>,
) -> Result<(BlockInfo, Vec<tx::Transaction>)> {
    ensure!(raw.len() >= 81, "block too short");
    let header = &raw[..80];
    let hash_internal = tx::double_sha(header);
    let hash = tx::display_hash(&hash_internal);
    if let Some(expected) = expected_hash {
        ensure!(
            hash == expected,
            "block hash mismatch: got {hash} want {expected}"
        );
    }
    let bits = u32::from_le_bytes(header[72..76].try_into()?);
    ensure!(
        check_pow(&hash_internal, bits),
        "proof of work target not satisfied at {hash}"
    );
    let prev = tx::display_hash(&header[4..36]);
    if let Some(expected) = expected_prev {
        let prev_internal = hex::encode(&header[4..36]);
        ensure!(
            prev == expected || prev_internal == expected,
            "prev hash mismatch: got {prev} want {expected}"
        );
    }
    let txs = tx::parse_block_transactions(raw)?;
    let txids = txs
        .iter()
        .map(tx::Transaction::txid_internal)
        .collect::<Vec<_>>();
    let merkle = merkle_root(&txids);
    ensure!(merkle == header[36..68], "merkle root mismatch at {hash}");
    Ok((
        BlockInfo {
            hash,
            hash_internal,
            prev_hash: prev,
            merkle_root: tx::display_hash(&merkle),
            tx_count: txs.len(),
        },
        txs,
    ))
}

pub fn metadata_after_store(
    existing: Option<storage::Metadata>,
    height: u32,
    hash: &str,
    _started: &str,
) -> storage::Metadata {
    let mut meta = existing.unwrap_or_else(storage::missing_metadata);
    meta.node_id = "rsbitnode-local-reference-sync".to_string();
    meta.generation_id = "rust-reference-sync".to_string();
    meta.chain = "testnet4".to_string();
    meta.chainstate_backend = "rocksdb".to_string();
    meta.chainstate_status = "usable".to_string();
    meta.header_height = height as i64;
    meta.header_hash = hash.to_string();
    meta.stored_block_height = height as i64;
    meta.stored_block_hash = hash.to_string();
    meta.current_blocker = None;
    meta.last_error.clear();
    meta.sync_status = if meta.validated_height >= height as i64 {
        "blocks_current".to_string()
    } else {
        "blocks_syncing".to_string()
    };
    if height == 0 && meta.validated_hash.is_empty() {
        meta.sync_status = "blocks_current".to_string();
    }
    meta
}

pub fn merkle_root(txids: &[[u8; 32]]) -> [u8; 32] {
    if txids.is_empty() {
        return [0u8; 32];
    }
    let mut level = txids.to_vec();
    while level.len() > 1 {
        let mut next = Vec::with_capacity(level.len().div_ceil(2));
        for pair in level.chunks(2) {
            let left = pair[0];
            let right = if pair.len() == 2 { pair[1] } else { pair[0] };
            let mut data = Vec::with_capacity(64);
            data.extend_from_slice(&left);
            data.extend_from_slice(&right);
            next.push(tx::double_sha(&data));
        }
        level = next;
    }
    level[0]
}

fn check_pow(hash_internal: &[u8; 32], bits: u32) -> bool {
    let Some(target) = compact_to_u256(bits) else {
        return false;
    };
    let mut be = *hash_internal;
    be.reverse();
    compare_u256(&be, &target) != Ordering::Greater
}

fn compact_to_u256(bits: u32) -> Option<[u8; 32]> {
    if bits & 0x0080_0000 != 0 {
        return None;
    }
    let size = (bits >> 24) as usize;
    let word = bits & 0x007f_ffff;
    if word == 0 || size > 32 {
        return None;
    }
    let mut target = [0u8; 32];
    let word_bytes = [(word >> 16) as u8, (word >> 8) as u8, word as u8];
    if size <= 3 {
        let shifted = word >> (8 * (3 - size));
        let bytes = shifted.to_be_bytes();
        target[32 - size..].copy_from_slice(&bytes[4 - size..]);
    } else {
        let start = 32 - size;
        target[start..start + 3].copy_from_slice(&word_bytes);
    }
    Some(target)
}

fn compare_u256(left: &[u8; 32], right: &[u8; 32]) -> Ordering {
    for (a, b) in left.iter().zip(right) {
        match a.cmp(b) {
            Ordering::Equal => continue,
            other => return other,
        }
    }
    Ordering::Equal
}

pub fn default_result_path(name: &str) -> Result<std::path::PathBuf> {
    Ok(crate::repo::root()?.join(format!(
        "NodeCore/conformance/results/rust_{name}_{}.json",
        Utc::now().format("%F")
    )))
}

pub fn rpc_defaults(docker: bool) -> (&'static str, &'static str, &'static str) {
    let url = if docker {
        "http://host.docker.internal:48332"
    } else {
        "http://127.0.0.1:48332"
    };
    (url, "rosetta", "rosetta-dev-only")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compact_target_rejects_negative() {
        assert!(compact_to_u256(0x1d00ffff).is_some());
        assert!(compact_to_u256(0x1d80ffff).is_none());
    }

    #[test]
    fn merkle_duplicates_last_txid() {
        let a = [1u8; 32];
        let root = merkle_root(&[a]);
        assert_eq!(root, a);
    }
}
