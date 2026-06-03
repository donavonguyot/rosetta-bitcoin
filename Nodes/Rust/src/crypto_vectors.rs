use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

use crate::repo;

#[derive(Deserialize)]
struct CryptoFixture {
    version: u32,
    target_backend: String,
    status: String,
    vectors: Vec<CryptoVector>,
}

#[derive(Deserialize)]
struct CryptoVector {
    id: String,
    operation: String,
    expected: String,
}

#[derive(Serialize)]
pub struct CryptoReport {
    implementation: &'static str,
    category: &'static str,
    fixture_path: String,
    version: u32,
    target_backend: String,
    backend: &'static str,
    backend_available: bool,
    result: &'static str,
    vector_count: usize,
    results: Vec<CryptoVectorResult>,
}

#[derive(Serialize)]
struct CryptoVectorResult {
    id: String,
    operation: String,
    expected: String,
    result: &'static str,
    failure: &'static str,
}

pub fn run(path: Option<&Path>) -> Result<CryptoReport> {
    let fixture_path = path.map(Path::to_path_buf).unwrap_or(default_fixture()?);
    let fixture: CryptoFixture = serde_json::from_slice(&std::fs::read(&fixture_path)?)?;
    let results = fixture
        .vectors
        .into_iter()
        .map(|vector| CryptoVectorResult {
            id: vector.id,
            operation: vector.operation,
            expected: vector.expected,
            result: "not_implemented",
            failure: "Rust native crypto vector runner is scaffolded; independent vector verification is not implemented in this milestone.",
        })
        .collect::<Vec<_>>();

    Ok(CryptoReport {
        implementation: "RustNode",
        category: "native_crypto_v1",
        fixture_path: repo::rel(&fixture_path),
        version: fixture.version,
        target_backend: fixture.target_backend,
        backend: "rust-secp256k1/libsecp256k1",
        backend_available: fixture.status == "active",
        result: "not_implemented",
        vector_count: results.len(),
        results,
    })
}

fn default_fixture() -> Result<PathBuf> {
    Ok(repo::root()?.join("NodeCore/conformance/fixtures/native_crypto_v1_vectors.json"))
}
