use anyhow::{anyhow, bail, Result};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use crate::repo;

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
    runtime_surface: &'static str,
    captured_at: String,
    commit: String,
    manifest: String,
    fixture_count: usize,
    loaded: usize,
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
    loaded_files: usize,
    file_sha256: BTreeMap<String, String>,
}

pub fn run(
    manifest_path: Option<&Path>,
    result_path: Option<&Path>,
    fixture_id: Option<&str>,
) -> Result<ScriptCorpusReport> {
    let root = repo::root()?;
    let manifest_path = manifest_path
        .map(Path::to_path_buf)
        .unwrap_or_else(|| root.join("NodeCore/conformance/fixtures/scripts/manifest.json"));
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
    let not_implemented = results
        .iter()
        .filter(|r| r.result == "not_implemented")
        .count();
    let report = ScriptCorpusReport {
        implementation: "RustNode",
        category: "script_corpus",
        runtime_surface: "host",
        captured_at: Utc::now().to_rfc3339(),
        commit: repo::git_commit(),
        manifest: repo::rel(&manifest_path),
        fixture_count: results.len(),
        loaded: results.len().saturating_sub(failed),
        failed,
        not_implemented,
        result: if failed == 0 {
            "not_implemented"
        } else {
            "failed"
        },
        verifier: serde_json::json!({
            "engine": "rust_loader_only",
            "note": "Rust loads and hashes all fixture files; independent script verification is not implemented in this milestone.",
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
    let failed = !failures.is_empty();
    ScriptFixtureResult {
        fixture_id: entry.fixture_id,
        height: entry.height,
        block_hash: entry.block_hash,
        txid: entry.txid,
        input_index: entry.input_index,
        expected_result: entry.expected_result,
        result: if failed { "failed" } else { "not_implemented" }.to_string(),
        failure: if failed {
            failures.join("; ")
        } else {
            "fixture loaded; Rust independent script verifier not implemented".to_string()
        },
        loaded_files,
        file_sha256: hashes,
    }
}

fn default_result_path() -> PathBuf {
    repo::root()
        .unwrap_or_else(|_| PathBuf::from("."))
        .join(format!(
            "NodeCore/conformance/results/rust_script_corpus_{}.json",
            Utc::now().format("%F")
        ))
}
