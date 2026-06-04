use anyhow::Result;
use secp256k1::{ecdsa, schnorr, Message, PublicKey, Secp256k1, XOnlyPublicKey};
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
    #[serde(default)]
    pubkey_hex: String,
    #[serde(default)]
    xonly_pubkey_hex: String,
    #[serde(default)]
    msg_hash_hex: String,
    #[serde(default)]
    signature_hex: String,
    #[serde(default)]
    merkle_root_hex: String,
    #[serde(default)]
    expected_output_xonly_hex: String,
    #[serde(default)]
    expected_parity: Option<i32>,
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
    result: String,
    failure: String,
}

pub fn run(path: Option<&Path>) -> Result<CryptoReport> {
    let fixture_path = path.map(Path::to_path_buf).unwrap_or(default_fixture()?);
    let fixture: CryptoFixture = serde_json::from_slice(&std::fs::read(&fixture_path)?)?;
    let results = fixture
        .vectors
        .into_iter()
        .map(run_vector)
        .collect::<Vec<_>>();
    let failed = results
        .iter()
        .filter(|result| result.result != result.expected)
        .count();

    Ok(CryptoReport {
        implementation: "RustNode",
        category: "native_crypto_v1",
        fixture_path: repo::rel(&fixture_path),
        version: fixture.version,
        target_backend: fixture.target_backend,
        backend: "rust-secp256k1",
        backend_available: fixture.status == "active",
        result: if failed == 0 { "passed" } else { "failed" },
        vector_count: results.len(),
        results,
    })
}

fn run_vector(vector: CryptoVector) -> CryptoVectorResult {
    let actual = match vector.operation.as_str() {
        "verify_ecdsa" => verify_ecdsa_vector(&vector),
        "verify_schnorr" => verify_schnorr_vector(&vector),
        "taproot_tweak_xonly" => taproot_tweak_vector(&vector),
        other => Err(format!("unsupported operation {other}")),
    };
    let (result, failure) = match actual {
        Ok(result) => (result, String::new()),
        Err(failure) => ("malformed_input".to_string(), failure),
    };
    CryptoVectorResult {
        id: vector.id,
        operation: vector.operation,
        expected: vector.expected,
        result,
        failure,
    }
}

fn verify_ecdsa_vector(vector: &CryptoVector) -> std::result::Result<String, String> {
    let pubkey =
        PublicKey::from_slice(&hex::decode(&vector.pubkey_hex).map_err(|e| e.to_string())?)
            .map_err(|e| e.to_string())?;
    let msg =
        Message::from_digest_slice(&hex32(&vector.msg_hash_hex)?).map_err(|e| e.to_string())?;
    let mut sig =
        ecdsa::Signature::from_der(&hex::decode(&vector.signature_hex).map_err(|e| e.to_string())?)
            .map_err(|e| e.to_string())?;
    let secp = Secp256k1::verification_only();
    let valid = secp.verify_ecdsa(&msg, &sig, &pubkey).is_ok() || {
        sig.normalize_s();
        secp.verify_ecdsa(&msg, &sig, &pubkey).is_ok()
    };
    Ok(if valid { "valid" } else { "consensus_invalid" }.to_string())
}

fn verify_schnorr_vector(vector: &CryptoVector) -> std::result::Result<String, String> {
    let pubkey =
        XOnlyPublicKey::from_slice(&hex32(&vector.xonly_pubkey_hex)?).map_err(|e| e.to_string())?;
    let sig = schnorr::Signature::from_slice(
        &hex::decode(&vector.signature_hex).map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;
    let msg =
        Message::from_digest_slice(&hex32(&vector.msg_hash_hex)?).map_err(|e| e.to_string())?;
    let valid = Secp256k1::verification_only()
        .verify_schnorr(&sig, &msg, &pubkey)
        .is_ok();
    Ok(if valid { "valid" } else { "consensus_invalid" }.to_string())
}

fn taproot_tweak_vector(vector: &CryptoVector) -> std::result::Result<String, String> {
    let internal =
        XOnlyPublicKey::from_slice(&hex32(&vector.xonly_pubkey_hex)?).map_err(|e| e.to_string())?;
    let tweak = tap_tweak_hash(
        &hex32(&vector.xonly_pubkey_hex)?,
        &hex::decode(&vector.merkle_root_hex).map_err(|e| e.to_string())?,
    );
    let scalar = secp256k1::Scalar::from_be_bytes(tweak).map_err(|e| format!("{e:?}"))?;
    let secp = Secp256k1::verification_only();
    let (output, parity) = internal
        .add_tweak(&secp, &scalar)
        .map_err(|e| e.to_string())?;
    let output_hex = output.to_string();
    let expected_parity = vector.expected_parity.unwrap_or(-1) == i32::from(parity.to_u8());
    Ok(
        if output_hex == vector.expected_output_xonly_hex && expected_parity {
            "valid"
        } else {
            "consensus_invalid"
        }
        .to_string(),
    )
}

fn hex32(value: &str) -> std::result::Result<[u8; 32], String> {
    let bytes = hex::decode(value).map_err(|e| e.to_string())?;
    if bytes.len() != 32 {
        return Err("expected 32-byte value".to_string());
    }
    bytes
        .try_into()
        .map_err(|_| "expected 32-byte value".to_string())
}

fn tap_tweak_hash(internal: &[u8; 32], merkle_root: &[u8]) -> [u8; 32] {
    use sha2::{Digest, Sha256};
    let tag = Sha256::digest(b"TapTweak");
    let mut engine = Sha256::new();
    engine.update(tag);
    engine.update(tag);
    engine.update(internal);
    engine.update(merkle_root);
    engine.finalize().into()
}

fn default_fixture() -> Result<PathBuf> {
    Ok(repo::root()?.join("NodeCore/conformance/fixtures/native_crypto_v1_vectors.json"))
}
