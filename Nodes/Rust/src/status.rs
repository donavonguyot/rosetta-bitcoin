use anyhow::Result;
use serde::Serialize;
use std::path::Path;

use crate::storage;

#[derive(Serialize)]
pub struct StatusDocument {
    ok: bool,
    node_id: String,
    implementation: &'static str,
    runtime_surface: String,
    runtime_status: String,
    chain: String,
    network: String,
    datadir: String,
    sync_status: String,
    runtime_status_detail: &'static str,
    binary_gate_status: String,
    header_height: i64,
    header_hash: String,
    stored_block_height: i64,
    stored_block_hash: String,
    validated_height: i64,
    validated_hash: String,
    chainstate_backend: String,
    chainstate_backend_path: String,
    chainstate_generation_id: String,
    chainstate_status: String,
    chainstate_utxo_count: i64,
    native_crypto_backend: &'static str,
    native_crypto_available: bool,
    taproot_tweak_backend: &'static str,
    block_gap_count: i64,
    current_blocker: Option<serde_json::Value>,
    last_error: String,
    active_writer_pid: Option<u32>,
    lock_status: String,
    updated_at: String,
}

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
        native_crypto_backend: "rust-secp256k1/libsecp256k1",
        native_crypto_available: true,
        taproot_tweak_backend: "not_implemented",
        block_gap_count: (meta.stored_block_height - meta.validated_height).max(0),
        current_blocker: meta.current_blocker,
        last_error: meta.last_error,
        active_writer_pid,
        lock_status,
        updated_at: meta.updated_at,
    })
}
