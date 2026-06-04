use std::process::Command;

#[test]
fn codec_vectors_pass() {
    let status = Command::new(env!("CARGO_BIN_EXE_rsbitnode"))
        .arg("codec-vectors")
        .status()
        .expect("run codec vectors");
    assert!(status.success());
}

#[test]
fn empty_status_is_not_attempted() {
    let dir = tempfile::tempdir().expect("tempdir");
    let output = Command::new(env!("CARGO_BIN_EXE_rsbitnode"))
        .arg("status")
        .arg("--datadir")
        .arg(dir.path())
        .output()
        .expect("run status");
    assert!(output.status.success());
    let value: serde_json::Value = serde_json::from_slice(&output.stdout).expect("status json");
    assert_eq!(value["implementation"], "RustNode");
    assert_eq!(value["validated_height"], 0);
    assert_eq!(value["binary_gate_status"], "not_attempted");
    assert_eq!(value["chainstate_status"], "missing");
}

#[test]
fn storage_proof_seeds_height_two() {
    let dir = tempfile::tempdir().expect("tempdir");
    let result = dir.path().join("proof.json");
    let output = Command::new(env!("CARGO_BIN_EXE_rsbitnode"))
        .arg("storage-proof")
        .arg("--datadir")
        .arg(dir.path().join("data"))
        .arg("--result-path")
        .arg(&result)
        .output()
        .expect("run storage proof");
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let value: serde_json::Value = serde_json::from_slice(&output.stdout).expect("proof json");
    assert_eq!(value["implementation"], "RustNode");
    assert_eq!(value["validated_height"], 2);
    assert_eq!(value["chainstate_backend"], "rocksdb");
    assert!(result.is_file());
}

#[test]
fn script_corpus_loads_45_rows() {
    let dir = tempfile::tempdir().expect("tempdir");
    let result = dir.path().join("script.json");
    let output = Command::new(env!("CARGO_BIN_EXE_rsbitnode"))
        .arg("script-corpus")
        .arg("--result-path")
        .arg(&result)
        .output()
        .expect("run script corpus");
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let value: serde_json::Value = serde_json::from_slice(&output.stdout).expect("script json");
    assert_eq!(value["fixture_count"], 45);
    assert_eq!(
        value["passed"].as_i64().unwrap() + value["failed"].as_i64().unwrap(),
        45
    );
    assert_eq!(value["not_implemented"], 0);
    assert_eq!(value["verifier"]["delegated"], false);
    assert!(result.is_file());
}
