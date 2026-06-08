use anyhow::{anyhow, bail, ensure, Result};
use chrono::Utc;
use secp256k1::ffi::CPtr;
use secp256k1::{ffi, schnorr, Secp256k1, XOnlyPublicKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};

use crate::{crypto_vectors, repo, script_corpus};

const BACKEND: &str = "rust-secp256k1";
const SUITE_VERSION: &str = "2026-06-07";

#[derive(Serialize)]
pub struct CapabilityArtifact {
    schema: &'static str,
    category: &'static str,
    port: &'static str,
    captured_at: String,
    suites: Vec<Suite>,
    contracts: Vec<Contract>,
    results: Vec<CapabilityResult>,
}

#[derive(Serialize)]
struct Suite {
    suite_id: &'static str,
    suite_version: &'static str,
    suite_hash: String,
    case_total: usize,
    provenance: Vec<&'static str>,
    does_not_prove: &'static str,
}

#[derive(Serialize)]
struct Contract {
    port: &'static str,
    contract_id: &'static str,
    capability: &'static str,
    status: &'static str,
    scope: &'static str,
    backend: &'static str,
    evidence_kind: &'static str,
    evidence_path: String,
    command_key: &'static str,
    suite_id: &'static str,
    suite_version: &'static str,
    suite_hash: String,
    case_passed: usize,
    case_total: usize,
    provenance: Vec<&'static str>,
    does_not_prove: &'static str,
    blocking_for: Vec<&'static str>,
}

#[derive(Serialize)]
struct CapabilityResult {
    suite_id: &'static str,
    result: &'static str,
    case_passed: usize,
    case_total: usize,
    notes: String,
}

#[derive(Deserialize)]
struct BlockProbeManifest {
    fixtures: Vec<BlockProbeFixture>,
}

#[derive(Deserialize)]
struct BlockProbeFixture {
    backend_path: String,
    fixture_id: String,
    required_observation: String,
}

struct SuiteOutcome {
    passed: usize,
    total: usize,
    result: &'static str,
    notes: String,
}

pub fn run_crypto_vectors(result_path: Option<&Path>) -> Result<CapabilityArtifact> {
    let root = repo::root()?;
    let bip340_path = root.join("Nodes/Shared/testing/fixtures/bip340/test-vectors.csv");
    let native_path = root.join("Nodes/Shared/conformance/fixtures/native_crypto_v1_vectors.json");
    let equivalence_path = root.join("Nodes/Shared/testing/fixtures/crypto_backend_equivalence_v1.json");

    let bip340 = run_bip340_vectors(&bip340_path)?;
    let native = crypto_vectors::run(Some(&native_path))?;
    let native_passed = native.passed_count();
    let native_total = native.vector_count();
    let equivalence_passed = bip340.passed + native_passed;
    let equivalence_total = bip340.total + native_total;
    let equivalence_result = if bip340.result == "pass" && native.result() == "passed" {
        "pass"
    } else {
        "fail"
    };

    let bip340_hash = sha256_file(&bip340_path)?;
    let equivalence_hash = sha256_file(&equivalence_path)?;
    let artifact = CapabilityArtifact {
        schema: "port.test_capability_contract.v1",
        category: "test_capability_contracts",
        port: "rust",
        captured_at: Utc::now().to_rfc3339(),
        suites: vec![
            Suite {
                suite_id: "bitcoin.bip340_schnorr_vectors",
                suite_version: SUITE_VERSION,
                suite_hash: bip340_hash.clone(),
                case_total: bip340.total,
                provenance: vec!["bip_standard_vector"],
                does_not_prove: "BIP340 verification vectors do not prove ECDSA, Taproot tweak handling, block connect usage, or every secp256k1 implementation behavior.",
            },
            Suite {
                suite_id: "rb.crypto_backend_equivalence_v1",
                suite_version: SUITE_VERSION,
                suite_hash: equivalence_hash.clone(),
                case_total: equivalence_total,
                provenance: vec!["bip_standard_vector", "proof_derived"],
                does_not_prove: "Backend equivalence vectors do not prove every libsecp256k1 internal test, every consensus path, or block-connect usage.",
            },
        ],
        contracts: vec![
            Contract {
                port: "rust",
                contract_id: "rust.crypto_bip340_vectors",
                capability: "crypto_bip340_vectors",
                status: bip340.result,
                scope: "host",
                backend: BACKEND,
                evidence_kind: "suite",
                evidence_path: repo::rel(&bip340_path),
                command_key: "test_crypto_vectors",
                suite_id: "bitcoin.bip340_schnorr_vectors",
                suite_version: SUITE_VERSION,
                suite_hash: bip340_hash,
                case_passed: bip340.passed,
                case_total: bip340.total,
                provenance: vec!["bip_standard_vector"],
                does_not_prove: "BIP340 verification vectors do not prove ECDSA, Taproot tweak handling, block connect usage, or every secp256k1 implementation behavior.",
                blocking_for: vec!["pure_crypto_experiment"],
            },
            Contract {
                port: "rust",
                contract_id: "rust.crypto_libsecp256k1_equivalence",
                capability: "crypto_libsecp256k1_equivalence",
                status: equivalence_result,
                scope: "host",
                backend: BACKEND,
                evidence_kind: "suite",
                evidence_path: repo::rel(&equivalence_path),
                command_key: "test_crypto_vectors",
                suite_id: "rb.crypto_backend_equivalence_v1",
                suite_version: SUITE_VERSION,
                suite_hash: equivalence_hash,
                case_passed: equivalence_passed,
                case_total: equivalence_total,
                provenance: vec!["bip_standard_vector", "proof_derived"],
                does_not_prove: "Backend equivalence vectors do not prove every libsecp256k1 internal test, every consensus path, or block-connect usage.",
                blocking_for: vec!["pure_crypto_experiment"],
            },
        ],
        results: vec![
            CapabilityResult {
                suite_id: "bitcoin.bip340_schnorr_vectors",
                result: bip340.result,
                case_passed: bip340.passed,
                case_total: bip340.total,
                notes: bip340.notes,
            },
            CapabilityResult {
                suite_id: "rb.crypto_backend_equivalence_v1",
                result: equivalence_result,
                case_passed: equivalence_passed,
                case_total: equivalence_total,
                notes: format!(
                    "BIP340 {}/{} plus native crypto vectors {}/{}",
                    bip340.passed, bip340.total, native_passed, native_total
                ),
            },
        ],
    };
    write_artifact(result_path, "rust_crypto_vectors", &artifact)?;
    Ok(artifact)
}

pub fn run_block_connect_backend(result_path: Option<&Path>) -> Result<CapabilityArtifact> {
    let root = repo::root()?;
    let manifest_path = root.join("Nodes/Shared/testing/fixtures/block_connect_backend_probe_v1.json");
    let manifest: BlockProbeManifest = serde_json::from_slice(&std::fs::read(&manifest_path)?)?;
    ensure!(
        manifest.fixtures.len() == 2,
        "block-connect backend probe must define exactly two fixtures"
    );

    let mut passed = 0usize;
    let mut notes = Vec::new();
    for fixture in &manifest.fixtures {
        let tmp = temp_probe_path(&fixture.fixture_id);
        let report = script_corpus::run(None, Some(&tmp), Some(&fixture.fixture_id), "host")?;
        let observed_backend = report.native_crypto_backend() == BACKEND
            && report.verifier_crypto_backend() == Some(BACKEND);
        if report.result() == "passed" && report.passed() == report.fixture_count() && observed_backend {
            passed += 1;
        }
        let _ = std::fs::remove_file(&tmp);
        notes.push(format!(
            "{}:{} result={} backend_observed={} requirement={}",
            fixture.backend_path,
            fixture.fixture_id,
            report.result(),
            observed_backend,
            fixture.required_observation
        ));
    }

    let total = manifest.fixtures.len();
    let status = if passed == total { "pass" } else { "fail" };
    let suite_hash = sha256_file(&manifest_path)?;
    let artifact = CapabilityArtifact {
        schema: "port.test_capability_contract.v1",
        category: "test_capability_contracts",
        port: "rust",
        captured_at: Utc::now().to_rfc3339(),
        suites: vec![Suite {
            suite_id: "rb.block_connect_backend_probe_v1",
            suite_version: SUITE_VERSION,
            suite_hash: suite_hash.clone(),
            case_total: total,
            provenance: vec!["rb_live_chain_regression", "proof_derived"],
            does_not_prove: "Bounded backend probe does not prove long-sync safety, tip maintenance, or every future script template.",
        }],
        contracts: vec![Contract {
            port: "rust",
            contract_id: "rust.block_connect_with_backend",
            capability: "block_connect_with_backend",
            status,
            scope: "host",
            backend: BACKEND,
            evidence_kind: "suite",
            evidence_path: repo::rel(&manifest_path),
            command_key: "test_block_connect_backend",
            suite_id: "rb.block_connect_backend_probe_v1",
            suite_version: SUITE_VERSION,
            suite_hash,
            case_passed: passed,
            case_total: total,
            provenance: vec!["rb_live_chain_regression", "proof_derived"],
            does_not_prove: "Bounded backend probe does not prove long-sync safety, tip maintenance, or every future script template.",
            blocking_for: vec!["pure_crypto_experiment"],
        }],
        results: vec![CapabilityResult {
            suite_id: "rb.block_connect_backend_probe_v1",
            result: status,
            case_passed: passed,
            case_total: total,
            notes: notes.join("; "),
        }],
    };
    write_artifact(result_path, "rust_block_connect_backend", &artifact)?;
    Ok(artifact)
}

fn run_bip340_vectors(path: &Path) -> Result<SuiteOutcome> {
    let content = std::fs::read_to_string(path)?;
    let mut passed = 0usize;
    let mut total = 0usize;
    let mut failures = Vec::new();
    for (line_index, line) in content.lines().enumerate() {
        if line_index == 0 || line.trim().is_empty() {
            continue;
        }
        total += 1;
        let columns = line.split(',').collect::<Vec<_>>();
        ensure!(columns.len() >= 7, "malformed BIP340 CSV row {}", line_index + 1);
        let expected = match columns[6].trim() {
            "TRUE" => true,
            "FALSE" => false,
            other => bail!("unexpected BIP340 expected value {other}"),
        };
        let actual = verify_bip340(columns[2].trim(), columns[4].trim(), columns[5].trim());
        if actual == expected {
            passed += 1;
        } else {
            failures.push(columns[0].to_string());
        }
    }
    Ok(SuiteOutcome {
        passed,
        total,
        result: if passed == total { "pass" } else { "fail" },
        notes: if failures.is_empty() {
            "all BIP340 vectors matched expected verification result".to_string()
        } else {
            format!("mismatched BIP340 vector indexes: {}", failures.join(","))
        },
    })
}

fn verify_bip340(pubkey_hex: &str, msg_hex: &str, signature_hex: &str) -> bool {
    let Ok(pubkey_bytes) = hex::decode(pubkey_hex) else {
        return false;
    };
    let Ok(signature_bytes) = hex::decode(signature_hex) else {
        return false;
    };
    let Ok(message) = hex::decode(msg_hex) else {
        return false;
    };
    let Ok(pubkey) = XOnlyPublicKey::from_slice(&pubkey_bytes) else {
        return false;
    };
    let Ok(signature) = schnorr::Signature::from_slice(&signature_bytes) else {
        return false;
    };
    let secp = Secp256k1::verification_only();
    unsafe {
        ffi::secp256k1_schnorrsig_verify(
            secp.ctx().as_ptr(),
            signature.as_c_ptr(),
            message.as_ptr(),
            message.len(),
            pubkey.as_c_ptr(),
        ) == 1
    }
}

fn temp_probe_path(fixture_id: &str) -> PathBuf {
    let safe = fixture_id.replace(['.', '/'], "_");
    std::env::temp_dir().join(format!("rsbitnode_{safe}_probe.json"))
}

fn write_artifact<T: Serialize>(path: Option<&Path>, prefix: &str, artifact: &T) -> Result<()> {
    let path = match path {
        Some(path) => path.to_path_buf(),
        None => default_result_path(prefix)?,
    };
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(path, format!("{}\n", serde_json::to_string_pretty(artifact)?))?;
    Ok(())
}

fn default_result_path(prefix: &str) -> Result<PathBuf> {
    Ok(repo::root()?.join(format!(
        "Nodes/Shared/testing/results/{}_{}.json",
        prefix,
        Utc::now().format("%Y-%m-%d")
    )))
}

fn sha256_file(path: &Path) -> Result<String> {
    let bytes = std::fs::read(path).map_err(|err| anyhow!("{}: {err}", path.display()))?;
    Ok(hex::encode(Sha256::digest(bytes)))
}
