use anyhow::{anyhow, bail, Result};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use crate::{repo, script_verify, tx};

#[derive(Debug, Deserialize)]
struct Manifest {
    fixture_count: usize,
    fixtures: Vec<FixtureEntry>,
}

#[derive(Debug, Deserialize)]
struct FixtureEntry {
    fixture_id: String,
    expected_result: String,
    files: BTreeMap<String, Vec<String>>,
    #[serde(default)]
    height: Option<i64>,
    #[serde(default)]
    block_hash: String,
    #[serde(default)]
    txid: String,
    #[serde(default)]
    input_index: Option<i64>,
}

#[derive(Serialize)]
pub struct ScriptCorpusReport {
    implementation: &'static str,
    category: &'static str,
    runtime_surface: String,
    captured_at: String,
    commit: String,
    manifest: String,
    fixture_count: usize,
    loaded: usize,
    passed: usize,
    failed: usize,
    not_implemented: usize,
    result: &'static str,
    verifier: Value,
    results: Vec<ScriptFixtureResult>,
}

#[derive(Serialize)]
struct ScriptFixtureResult {
    fixture_id: String,
    height: Option<i64>,
    block_hash: String,
    txid: String,
    input_index: Option<i64>,
    expected_result: String,
    result: String,
    failure: String,
    failure_stage: String,
    failure_type: String,
    loaded_files: usize,
    file_sha256: BTreeMap<String, String>,
}

#[derive(Debug, Deserialize)]
struct PrevoutJson {
    #[serde(default)]
    amount: Option<i64>,
    #[serde(default)]
    amount_sats: Option<i64>,
    #[serde(default)]
    value: Option<i64>,
    #[serde(default)]
    spk: String,
    #[serde(default)]
    script_pubkey: String,
    #[serde(default, rename = "scriptPubKey")]
    script_pubkey2: String,
}

pub fn run(
    manifest_path: Option<&Path>,
    result_path: Option<&Path>,
    fixture_id: Option<&str>,
    runtime_surface: &str,
) -> Result<ScriptCorpusReport> {
    let manifest_path = match manifest_path {
        Some(path) => path.to_path_buf(),
        None => repo::root()?.join("NodeCore/conformance/fixtures/scripts/manifest.json"),
    };
    let base_dir = manifest_path
        .parent()
        .ok_or_else(|| anyhow!("manifest has no parent directory"))?;
    let manifest: Manifest = serde_json::from_slice(&std::fs::read(&manifest_path)?)?;
    let entries = manifest.fixtures;
    if (manifest.fixture_count != 45 || entries.len() != 45) && fixture_id.is_none() {
        bail!(
            "expected 45 script corpus fixtures, manifest says {} and contains {}",
            manifest.fixture_count,
            entries.len()
        );
    }

    let mut results = Vec::new();
    for entry in entries {
        if fixture_id.is_some_and(|wanted| wanted != entry.fixture_id) {
            continue;
        }
        results.push(load_fixture(base_dir, entry));
    }
    if fixture_id.is_some() && results.is_empty() {
        bail!("fixture_id not found in manifest");
    }

    let failed = results.iter().filter(|r| r.result == "failed").count();
    let passed = results.iter().filter(|r| r.result == "passed").count();
    let not_implemented = results
        .iter()
        .filter(|r| r.result == "not_implemented")
        .count();
    let report = ScriptCorpusReport {
        implementation: "RustNode",
        category: "script_corpus",
        runtime_surface: runtime_surface.to_string(),
        captured_at: Utc::now().to_rfc3339(),
        commit: repo::git_commit(),
        manifest: repo::rel(&manifest_path),
        fixture_count: results.len(),
        loaded: results.len().saturating_sub(failed),
        passed,
        failed,
        not_implemented,
        result: if failed == 0 { "passed" } else { "failed" },
        verifier: serde_json::json!({
            "engine": "rust_native",
            "crypto_backend": "rust-secp256k1",
            "source": "Nodes/Rust/src/script_verify.rs",
            "note": "Rust runs an independent native script verifier over the shared NodeCore corpus.",
            "delegated": false
        }),
        results,
    };

    let default_path;
    let path = match result_path {
        Some(path) => path,
        None => {
            default_path = default_result_path();
            default_path.as_path()
        }
    };
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(
        path,
        format!("{}\n", serde_json::to_string_pretty(&report)?),
    )?;
    Ok(report)
}

fn load_fixture(base_dir: &Path, entry: FixtureEntry) -> ScriptFixtureResult {
    let mut loaded_files = 0usize;
    let mut hashes = BTreeMap::new();
    let mut failures = Vec::new();

    if entry.fixture_id.trim().is_empty() {
        failures.push("missing fixture_id".to_string());
    }
    if entry.expected_result.trim().is_empty() {
        failures.push("missing expected_result".to_string());
    }
    if entry.files.is_empty() {
        failures.push("missing files map".to_string());
    }

    for (category, paths) in &entry.files {
        if paths.is_empty() {
            failures.push(format!("{category} has no files"));
        }
        for relative in paths {
            let path = base_dir.join(relative);
            match std::fs::read(&path) {
                Ok(bytes) => {
                    loaded_files += 1;
                    hashes.insert(relative.clone(), hex::encode(Sha256::digest(bytes)));
                }
                Err(err) => failures.push(format!("{relative}: {err}")),
            }
        }
    }

    if !entry.files.contains_key("tx") {
        failures.push("missing tx fixture file category".to_string());
    }
    if !entry.files.contains_key("meta") {
        failures.push("missing meta fixture file category".to_string());
    }
    let verify_failure = if failures.is_empty() {
        verify_fixture(base_dir, &entry)
            .err()
            .map(|err| err.to_string())
    } else {
        None
    };
    if let Some(failure) = verify_failure {
        failures.push(failure);
    }
    let failed = !failures.is_empty();
    ScriptFixtureResult {
        fixture_id: entry.fixture_id,
        height: entry.height,
        block_hash: entry.block_hash,
        txid: entry.txid,
        input_index: entry.input_index,
        expected_result: entry.expected_result,
        result: if failed { "failed" } else { "passed" }.to_string(),
        failure: if failed {
            failures.join("; ")
        } else {
            String::new()
        },
        failure_stage: if failed {
            "verify".to_string()
        } else {
            String::new()
        },
        failure_type: if failed {
            "anyhow".to_string()
        } else {
            String::new()
        },
        loaded_files,
        file_sha256: hashes,
    }
}

fn verify_fixture(base_dir: &Path, entry: &FixtureEntry) -> Result<()> {
    if entry.expected_result != "valid" {
        bail!("unsupported expected result: {}", entry.expected_result);
    }
    let tx_path = first_path(base_dir, entry, "tx")
        .ok_or_else(|| anyhow!("fixture has no transaction file"))?;
    let raw = read_hex(&tx_path)?;
    let (transaction, consumed) = tx::deserialize(&raw, 0)?;
    if consumed != raw.len() {
        bail!(
            "transaction parser consumed {consumed} of {} bytes",
            raw.len()
        );
    }
    let prevouts = align_prevouts(base_dir, entry, &transaction)?;
    let input_index = entry.input_index.unwrap_or(0) as usize;
    if input_index >= prevouts.len() {
        bail!("fixture input_index has no matching prevout");
    }
    let target = prevouts[input_index].clone();
    script_verify::verify_transaction_input(
        &transaction,
        input_index,
        &script_verify::VerifyInputOptions {
            script_pubkey: target.script_pubkey,
            amount: target.amount,
            spent_prevouts: prevouts,
        },
    )
}

fn align_prevouts(
    base_dir: &Path,
    entry: &FixtureEntry,
    transaction: &tx::Transaction,
) -> Result<Vec<script_verify::SpentPrevout>> {
    let mut prevouts = load_prevouts(base_dir, entry)?;
    if prevouts.len() == transaction.inputs.len() {
        return Ok(prevouts);
    }
    let input_index = entry.input_index.unwrap_or(0) as usize;
    let target = prevouts
        .get(input_index)
        .cloned()
        .or_else(|| prevouts.first().cloned())
        .ok_or_else(|| anyhow!("fixture has no prevout records"))?;
    while prevouts.len() < transaction.inputs.len() {
        prevouts.push(script_verify::SpentPrevout {
            amount: 0,
            script_pubkey: Vec::new(),
        });
    }
    prevouts[input_index] = target;
    Ok(prevouts)
}

fn load_prevouts(
    base_dir: &Path,
    entry: &FixtureEntry,
) -> Result<Vec<script_verify::SpentPrevout>> {
    let Some(path) = first_path(base_dir, entry, "prevouts") else {
        let spk_path = first_path(base_dir, entry, "prev_spk")
            .ok_or_else(|| anyhow!("fixture has no prevouts or prev_spk file"))?;
        return Ok(vec![script_verify::SpentPrevout {
            amount: 0,
            script_pubkey: read_hex(&spk_path)?,
        }]);
    };
    let parsed: Vec<PrevoutJson> = serde_json::from_slice(&std::fs::read(path)?)?;
    parsed
        .into_iter()
        .map(|prevout| {
            let amount = prevout
                .amount_sats
                .or(prevout.amount)
                .or(prevout.value)
                .ok_or_else(|| anyhow!("prevout missing amount"))?;
            let script_hex = [prevout.spk, prevout.script_pubkey, prevout.script_pubkey2]
                .into_iter()
                .find(|value| !value.is_empty())
                .ok_or_else(|| anyhow!("prevout missing script_pubkey"))?;
            Ok(script_verify::SpentPrevout {
                amount,
                script_pubkey: hex::decode(script_hex)?,
            })
        })
        .collect()
}

fn first_path(base_dir: &Path, entry: &FixtureEntry, category: &str) -> Option<PathBuf> {
    entry
        .files
        .get(category)
        .and_then(|paths| paths.first())
        .map(|path| base_dir.join(path))
}

fn read_hex(path: &Path) -> Result<Vec<u8>> {
    let text = std::fs::read_to_string(path)?;
    Ok(hex::decode(text.split_whitespace().collect::<String>())?)
}

fn default_result_path() -> PathBuf {
    repo::root()
        .unwrap_or_else(|_| PathBuf::from("."))
        .join(format!(
            "NodeCore/conformance/results/rust_script_corpus_{}.json",
            Utc::now().format("%F")
        ))
}
