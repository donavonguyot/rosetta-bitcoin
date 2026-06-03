use anyhow::{anyhow, bail, Result};
use chrono::Utc;
use rocksdb::{Options, DB};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

pub const MARKER_NAME: &str = ".rsbitnode_native_storage";
pub const LOCK_NAME: &str = ".rsbitnode.lock";
pub const BACKEND_DIR: &str = "chainstate-rocksdb";

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Metadata {
    pub node_id: String,
    pub generation_id: String,
    pub chain: String,
    pub sync_status: String,
    pub chainstate_status: String,
    pub chainstate_backend: String,
    pub validated_height: i64,
    pub validated_hash: String,
    pub header_height: i64,
    pub header_hash: String,
    pub stored_block_height: i64,
    pub stored_block_hash: String,
    pub chainstate_utxo_count: i64,
    pub current_blocker: Option<serde_json::Value>,
    pub last_error: String,
    pub updated_at: String,
}

pub struct Store {
    db: DB,
}

impl Store {
    pub fn open(datadir: &Path) -> Result<Self> {
        reject_forbidden_sqlite(datadir)?;
        std::fs::create_dir_all(datadir)?;
        std::fs::write(datadir.join(MARKER_NAME), b"rsbitnode native storage\n")?;
        let mut options = Options::default();
        options.create_if_missing(true);
        let db = DB::open(&options, backend_path(datadir))?;
        Ok(Self { db })
    }

    pub fn put_metadata(&self, meta: &Metadata) -> Result<()> {
        let mut meta = meta.clone();
        meta.updated_at = Utc::now().to_rfc3339();
        self.db.put(b"meta", serde_json::to_vec(&meta)?)?;
        Ok(())
    }

    pub fn metadata(&self) -> Result<Metadata> {
        let Some(bytes) = self.db.get(b"meta")? else {
            bail!("metadata missing");
        };
        Ok(serde_json::from_slice(&bytes)?)
    }

    pub fn put_raw(&self, key: &[u8], value: &[u8]) -> Result<()> {
        self.db.put(key, value)?;
        Ok(())
    }
}

pub fn read_metadata(datadir: &Path) -> Result<Metadata> {
    Store::open(datadir)?.metadata()
}

pub fn backend_path(datadir: &Path) -> PathBuf {
    datadir.join(BACKEND_DIR)
}

pub fn lock_path(datadir: &Path) -> PathBuf {
    datadir.join(LOCK_NAME)
}

pub fn local_sqlite_absent(datadir: &Path) -> bool {
    !has_forbidden_sqlite(datadir)
}

pub fn reject_forbidden_sqlite(datadir: &Path) -> Result<()> {
    if has_forbidden_sqlite(datadir) {
        bail!("native datadir contains forbidden SQLite artifact");
    }
    Ok(())
}

fn has_forbidden_sqlite(datadir: &Path) -> bool {
    let Ok(entries) = std::fs::read_dir(datadir) else {
        return false;
    };
    entries.flatten().any(|entry| {
        let path = entry.path();
        if !path.is_file() {
            return false;
        }
        let name = path
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or_default();
        name.ends_with(".db") || name.ends_with(".sqlite") || name.ends_with(".sqlite3")
    })
}

pub fn seed_two_block_proof(datadir: &Path) -> Result<Metadata> {
    let store = Store::open(datadir)?;
    let meta = Metadata {
        node_id: "rsbitnode-native-storage".to_string(),
        generation_id: "rust-proof-generation".to_string(),
        chain: "testnet4".to_string(),
        sync_status: "blocks_current".to_string(),
        chainstate_status: "usable".to_string(),
        chainstate_backend: "rocksdb".to_string(),
        validated_height: 2,
        validated_hash: "000000001fed1a914651afc36574003c5300cac5df738c3976f28d54f7096253"
            .to_string(),
        header_height: 2,
        header_hash: "000000001fed1a914651afc36574003c5300cac5df738c3976f28d54f7096253".to_string(),
        stored_block_height: 2,
        stored_block_hash: "000000001fed1a914651afc36574003c5300cac5df738c3976f28d54f7096253"
            .to_string(),
        chainstate_utxo_count: 1,
        current_blocker: None,
        last_error: String::new(),
        updated_at: Utc::now().to_rfc3339(),
    };
    store.put_metadata(&meta)?;
    store.put_raw(
        b"block:1",
        b"0000000012982b6d5f621229286b880e909984df669c2afabb102ce311b13f28",
    )?;
    store.put_raw(b"block:2", meta.validated_hash.as_bytes())?;
    store.put_raw(b"utxo:02:0", b"4999990000:51")?;
    Ok(meta)
}

pub fn lock_status(datadir: &Path) -> (String, Option<u32>) {
    let path = lock_path(datadir);
    let Ok(data) = std::fs::read_to_string(path) else {
        return ("unlocked".to_string(), None);
    };
    let pid = data
        .lines()
        .find_map(|line| line.strip_prefix("pid="))
        .and_then(|value| value.parse::<u32>().ok());
    ("locked".to_string(), pid)
}

pub fn missing_metadata() -> Metadata {
    Metadata {
        node_id: "rsbitnode-uninitialized".to_string(),
        generation_id: String::new(),
        chain: "testnet4".to_string(),
        sync_status: "starting".to_string(),
        chainstate_status: "missing".to_string(),
        chainstate_backend: "rocksdb".to_string(),
        validated_height: 0,
        validated_hash: String::new(),
        header_height: 0,
        header_hash: String::new(),
        stored_block_height: 0,
        stored_block_hash: String::new(),
        chainstate_utxo_count: 0,
        current_blocker: None,
        last_error: String::new(),
        updated_at: Utc::now().to_rfc3339(),
    }
}

pub fn ensure_parent(path: &Path) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| anyhow!("result path has no parent"))?;
    std::fs::create_dir_all(parent)?;
    Ok(())
}
