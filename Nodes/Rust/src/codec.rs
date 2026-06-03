use anyhow::{anyhow, bail, Result};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

use crate::repo;

#[derive(Debug, Deserialize)]
struct CodecFixture {
    chain: String,
    txid_internal_hex: String,
    block_hash_internal_hex: String,
    script_pubkey_hex: String,
    utxo: UtxoFixture,
    undo: UndoFixture,
    tip: TipFixture,
    block_index: BlockIndexFixture,
    header: HeaderFixture,
    metadata: MetadataFixture,
}

#[derive(Debug, Deserialize)]
struct UtxoFixture {
    height: u32,
    vout: u32,
    value_sats: u64,
    coinbase: bool,
    key_hex: String,
    value_hex: String,
}

#[derive(Debug, Deserialize)]
struct UndoFixture {
    height: u32,
    key_hex: String,
    value_hex: String,
}

#[derive(Debug, Deserialize)]
struct TipFixture {
    height: u32,
    key_hex: String,
    value_hex: String,
}

#[derive(Debug, Deserialize)]
struct BlockIndexFixture {
    height: u32,
    file_number: u32,
    file_offset: u32,
    block_size: u32,
    key_hex: String,
    value_hex: String,
}

#[derive(Debug, Deserialize)]
struct HeaderFixture {
    height: u32,
    serialized_header_hex: String,
    key_hex: String,
    value_hex: String,
}

#[derive(Debug, Deserialize)]
struct MetadataFixture {
    name: String,
    value: String,
    key_hex: String,
    value_hex: String,
}

#[derive(Serialize)]
pub struct VectorReport {
    implementation: &'static str,
    category: &'static str,
    fixture_path: String,
    result: String,
    passed: usize,
    failed: usize,
    results: Vec<VectorResult>,
}

#[derive(Serialize)]
struct VectorResult {
    name: String,
    result: String,
    failure: String,
}

pub fn run_vectors(path: Option<&Path>) -> Result<VectorReport> {
    let fixture_path = path.map(Path::to_path_buf).unwrap_or(default_fixture()?);
    let fixture: CodecFixture = serde_json::from_slice(&std::fs::read(&fixture_path)?)?;
    let txid = decode_fixed_32(&fixture.txid_internal_hex)?;
    let block_hash = decode_fixed_32(&fixture.block_hash_internal_hex)?;
    let script = hex::decode(&fixture.script_pubkey_hex)?;

    let checks = vec![
        check(
            "utxo.key",
            utxo_key(&fixture.chain, &txid, fixture.utxo.vout),
            &fixture.utxo.key_hex,
        ),
        check(
            "utxo.value",
            utxo_value(
                fixture.utxo.height,
                fixture.utxo.value_sats,
                fixture.utxo.coinbase,
                &script,
            ),
            &fixture.utxo.value_hex,
        ),
        check(
            "undo.key",
            height_key(b'd', &fixture.chain, fixture.undo.height),
            &fixture.undo.key_hex,
        ),
        check(
            "undo.value",
            undo_value(
                &txid,
                fixture.utxo.vout,
                fixture.utxo.height,
                fixture.utxo.value_sats,
                fixture.utxo.coinbase,
                &script,
            ),
            &fixture.undo.value_hex,
        ),
        check(
            "tip.key",
            chain_key(b't', &fixture.chain),
            &fixture.tip.key_hex,
        ),
        check(
            "tip.value",
            tip_value(fixture.tip.height, &block_hash),
            &fixture.tip.value_hex,
        ),
        check(
            "block_index.key",
            height_key(b'b', &fixture.chain, fixture.block_index.height),
            &fixture.block_index.key_hex,
        ),
        check(
            "block_index.value",
            block_index_value(
                &block_hash,
                fixture.block_index.file_number,
                fixture.block_index.file_offset,
                fixture.block_index.block_size,
            ),
            &fixture.block_index.value_hex,
        ),
        check(
            "header.key",
            height_key(b'h', &fixture.chain, fixture.header.height),
            &fixture.header.key_hex,
        ),
        check(
            "header.value",
            varbytes(&hex::decode(&fixture.header.serialized_header_hex)?),
            &fixture.header.value_hex,
        ),
        check(
            "metadata.key",
            metadata_key(&fixture.metadata.name),
            &fixture.metadata.key_hex,
        ),
        check(
            "metadata.value",
            fixture.metadata.value.as_bytes().to_vec(),
            &fixture.metadata.value_hex,
        ),
    ];

    let failed = checks.iter().filter(|r| r.result != "passed").count();
    Ok(VectorReport {
        implementation: "RustNode",
        category: "chainstate_codec_v2",
        fixture_path: repo::rel(&fixture_path),
        result: if failed == 0 { "passed" } else { "failed" }.to_string(),
        passed: checks.len() - failed,
        failed,
        results: checks,
    })
}

fn default_fixture() -> Result<PathBuf> {
    Ok(repo::root()?.join("NodeCore/conformance/fixtures/chainstate_codec_v2_vectors.json"))
}

fn check(name: &str, actual: Vec<u8>, expected_hex: &str) -> VectorResult {
    let actual_hex = hex::encode(actual);
    if actual_hex == expected_hex {
        VectorResult {
            name: name.to_string(),
            result: "passed".to_string(),
            failure: String::new(),
        }
    } else {
        VectorResult {
            name: name.to_string(),
            result: "failed".to_string(),
            failure: format!("expected {expected_hex}, got {actual_hex}"),
        }
    }
}

pub fn chain_key(prefix: u8, chain: &str) -> Vec<u8> {
    let mut out = vec![prefix, chain.len() as u8];
    out.extend_from_slice(chain.as_bytes());
    out
}

pub fn height_key(prefix: u8, chain: &str, height: u32) -> Vec<u8> {
    let mut out = chain_key(prefix, chain);
    out.extend_from_slice(&height.to_be_bytes());
    out
}

pub fn metadata_key(name: &str) -> Vec<u8> {
    let mut out = vec![b'm', name.len() as u8];
    out.extend_from_slice(name.as_bytes());
    out
}

pub fn utxo_key(chain: &str, txid_internal: &[u8; 32], vout: u32) -> Vec<u8> {
    let mut out = chain_key(b'u', chain);
    out.extend_from_slice(txid_internal);
    out.extend_from_slice(&vout.to_be_bytes());
    out
}

pub fn utxo_value(height: u32, value_sats: u64, coinbase: bool, script_pubkey: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&height.to_be_bytes());
    out.extend_from_slice(&value_sats.to_be_bytes());
    out.push(if coinbase { 1 } else { 0 });
    out.extend_from_slice(&varbytes(script_pubkey));
    out
}

pub fn undo_value(
    txid_internal: &[u8; 32],
    vout: u32,
    height: u32,
    value_sats: u64,
    coinbase: bool,
    script_pubkey: &[u8],
) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&1u32.to_be_bytes());
    out.extend_from_slice(txid_internal);
    out.extend_from_slice(&vout.to_be_bytes());
    out.extend_from_slice(&height.to_be_bytes());
    out.extend_from_slice(&value_sats.to_be_bytes());
    out.push(if coinbase { 1 } else { 0 });
    out.extend_from_slice(&varbytes(script_pubkey));
    out
}

pub fn tip_value(height: u32, block_hash_internal: &[u8; 32]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&height.to_be_bytes());
    out.extend_from_slice(block_hash_internal);
    out
}

pub fn block_index_value(
    block_hash_internal: &[u8; 32],
    file_number: u32,
    file_offset: u32,
    block_size: u32,
) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(block_hash_internal);
    out.extend_from_slice(&file_number.to_be_bytes());
    out.extend_from_slice(&file_offset.to_be_bytes());
    out.extend_from_slice(&block_size.to_be_bytes());
    out
}

pub fn varbytes(bytes: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&(bytes.len() as u32).to_be_bytes());
    out.extend_from_slice(bytes);
    out
}

fn decode_fixed_32(hex_text: &str) -> Result<[u8; 32]> {
    let bytes = hex::decode(hex_text)?;
    if bytes.len() != 32 {
        bail!("expected 32 bytes, got {}", bytes.len());
    }
    bytes
        .try_into()
        .map_err(|_| anyhow!("failed to decode fixed bytes"))
}
