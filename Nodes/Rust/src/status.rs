use anyhow::Result;
use serde::Serialize;
use std::path::Path;

use crate::storage;

#[derive(Serialize)]
pub struct StatusDocument {
    pub ok: bool,
    pub node_id: String,
    pub implementation: &'static str,
    pub runtime_surface: String,
    pub utxo_accounting_policy: &'static str,
    pub runtime_status: String,
    pub chain: String,
    pub network: String,
    pub datadir: String,
    pub sync_status: String,
    pub runtime_status_detail: &'static str,
    pub binary_gate_status: String,
    pub header_height: i64,
    pub header_hash: String,
    pub stored_block_height: i64,
    pub stored_block_hash: String,
    pub validated_height: i64,
    pub validated_hash: String,
    pub chainstate_backend: String,
    pub chainstate_backend_path: String,
    pub chainstate_generation_id: String,
    pub chainstate_status: String,
    pub chainstate_utxo_count: i64,
    pub native_crypto_backend: &'static str,
    pub native_crypto_available: bool,
    pub schnorr_backend: &'static str,
    pub taproot_tweak_backend: &'static str,
    pub block_gap_count: i64,
    pub current_blocker: Option<serde_json::Value>,
    pub last_error: String,
    pub active_writer_pid: Option<u32>,
    pub lock_status: String,
    pub updated_at: String,
}

/// Builds status JSON from RocksDB runtime truth in the datadir.
pub fn build(datadir: &Path, runtime_surface: &str) -> Result<StatusDocument> {
    let meta = storage::read_metadata(datadir).unwrap_or_else(|_| storage::missing_metadata());
    let (lock_status, active_writer_pid) = storage::lock_status(datadir);
    let binary_gate_status = if meta.current_blocker.is_some() {
        "failed"
    } else {
        "not_attempted"
    };
    Ok(StatusDocument {
        ok: true,
        node_id: meta.node_id,
        implementation: "RustNode",
        runtime_surface: runtime_surface.to_string(),
        utxo_accounting_policy: "core_spendable_v1",
        runtime_status: if active_writer_pid.is_some() {
            "running"
        } else {
            "not_running"
        }
        .to_string(),
        chain: meta.chain.clone(),
        network: meta.chain,
        datadir: datadir.to_string_lossy().to_string(),
        sync_status: meta.sync_status,
        runtime_status_detail: "scaffold",
        binary_gate_status: binary_gate_status.to_string(),
        header_height: meta.header_height,
        header_hash: meta.header_hash,
        stored_block_height: meta.stored_block_height,
        stored_block_hash: meta.stored_block_hash,
        validated_height: meta.validated_height,
        validated_hash: meta.validated_hash,
        chainstate_backend: meta.chainstate_backend,
        chainstate_backend_path: storage::backend_path(datadir).to_string_lossy().to_string(),
        chainstate_generation_id: meta.generation_id,
        chainstate_status: meta.chainstate_status,
        chainstate_utxo_count: meta.chainstate_utxo_count,
        native_crypto_backend: "rust-secp256k1",
        native_crypto_available: true,
        schnorr_backend: "rust-secp256k1",
        taproot_tweak_backend: "rust-secp256k1",
        block_gap_count: (meta.stored_block_height - meta.validated_height).max(0),
        current_blocker: meta.current_blocker,
        last_error: meta.last_error,
        active_writer_pid,
        lock_status,
        updated_at: meta.updated_at,
    })
}
