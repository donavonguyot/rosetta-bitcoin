use anyhow::{bail, ensure, Context, Result};
use sha2::{Digest, Sha256};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OutPoint {
    pub hash: [u8; 32],
    pub index: u32,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TxIn {
    pub previous_output: OutPoint,
    pub script_sig: Vec<u8>,
    pub sequence: u32,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TxOut {
    pub value: i64,
    pub script_pubkey: Vec<u8>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Transaction {
    pub version: i32,
    pub inputs: Vec<TxIn>,
    pub outputs: Vec<TxOut>,
    pub lock_time: u32,
    pub witness: Vec<Vec<Vec<u8>>>,
}

impl Transaction {
    pub fn is_coinbase(&self) -> bool {
        self.inputs.len() == 1
            && self.inputs[0].previous_output.index == u32::MAX
            && self.inputs[0].previous_output.hash == [0u8; 32]
    }

    pub fn txid(&self) -> String {
        display_hash(&double_sha(&serialize(self, false)))
    }

    pub fn txid_internal(&self) -> [u8; 32] {
        double_sha(&serialize(self, false))
    }
}

pub fn parse_block_transactions(raw: &[u8]) -> Result<Vec<Transaction>> {
    ensure!(raw.len() >= 81, "block too short");
    let (count, mut offset) = read_compact_size(raw, 80)?;
    let mut txs = Vec::with_capacity(count as usize);
    for index in 0..count {
        let (tx, next) =
            deserialize(raw, offset).with_context(|| format!("tx {index} at offset {offset}"))?;
        txs.push(tx);
        offset = next;
    }
    ensure!(
        offset == raw.len(),
        "block parser consumed {} of {} bytes",
        offset,
        raw.len()
    );
    Ok(txs)
}

pub fn deserialize(data: &[u8], mut offset: usize) -> Result<(Transaction, usize)> {
    ensure!(offset + 4 <= data.len(), "truncated tx version");
    let version = i32::from_le_bytes(data[offset..offset + 4].try_into()?);
    offset += 4;
    let witness = offset + 2 <= data.len() && data[offset] == 0x00 && data[offset + 1] == 0x01;
    if witness {
        offset += 2;
    }

    let (input_count, next) = read_compact_size(data, offset)?;
    offset = next;
    let mut inputs = Vec::with_capacity(input_count as usize);
    for _ in 0..input_count {
        ensure!(offset + 36 <= data.len(), "truncated tx input outpoint");
        let mut hash = [0u8; 32];
        hash.copy_from_slice(&data[offset..offset + 32]);
        offset += 32;
        let index = u32::from_le_bytes(data[offset..offset + 4].try_into()?);
        offset += 4;
        let (script_len, next) = read_compact_size(data, offset)?;
        offset = next;
        let script_len = usize::try_from(script_len)?;
        ensure!(
            offset + script_len <= data.len(),
            "truncated tx input script"
        );
        let script_sig = data[offset..offset + script_len].to_vec();
        offset += script_len;
        ensure!(offset + 4 <= data.len(), "truncated tx input sequence");
        let sequence = u32::from_le_bytes(data[offset..offset + 4].try_into()?);
        offset += 4;
        inputs.push(TxIn {
            previous_output: OutPoint { hash, index },
            script_sig,
            sequence,
        });
    }

    let (output_count, next) = read_compact_size(data, offset)?;
    offset = next;
    let mut outputs = Vec::with_capacity(output_count as usize);
    for _ in 0..output_count {
        ensure!(offset + 8 <= data.len(), "truncated tx output value");
        let value = i64::from_le_bytes(data[offset..offset + 8].try_into()?);
        offset += 8;
        let (script_len, next) = read_compact_size(data, offset)?;
        offset = next;
        let script_len = usize::try_from(script_len)?;
        ensure!(
            offset + script_len <= data.len(),
            "truncated tx output script"
        );
        let script_pubkey = data[offset..offset + script_len].to_vec();
        offset += script_len;
        outputs.push(TxOut {
            value,
            script_pubkey,
        });
    }

    let mut witnesses = Vec::new();
    if witness {
        for _ in 0..input_count {
            let (item_count, next) = read_compact_size(data, offset)?;
            offset = next;
            let mut stack = Vec::with_capacity(item_count as usize);
            for _ in 0..item_count {
                let (item_len, next) = read_compact_size(data, offset)?;
                offset = next;
                let item_len = usize::try_from(item_len)?;
                ensure!(offset + item_len <= data.len(), "truncated witness item");
                stack.push(data[offset..offset + item_len].to_vec());
                offset += item_len;
            }
            witnesses.push(stack);
        }
    }

    ensure!(offset + 4 <= data.len(), "truncated tx locktime");
    let lock_time = u32::from_le_bytes(data[offset..offset + 4].try_into()?);
    offset += 4;

    Ok((
        Transaction {
            version,
            inputs,
            outputs,
            lock_time,
            witness: witnesses,
        },
        offset,
    ))
}

pub fn serialize(tx: &Transaction, include_witness: bool) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&(tx.version as u32).to_le_bytes());
    let use_witness = include_witness && !tx.witness.is_empty();
    if use_witness {
        out.extend_from_slice(&[0x00, 0x01]);
    }
    out.extend_from_slice(&compact_size(tx.inputs.len() as u64));
    for input in &tx.inputs {
        out.extend_from_slice(&input.previous_output.hash);
        out.extend_from_slice(&input.previous_output.index.to_le_bytes());
        out.extend_from_slice(&compact_size(input.script_sig.len() as u64));
        out.extend_from_slice(&input.script_sig);
        out.extend_from_slice(&input.sequence.to_le_bytes());
    }
    out.extend_from_slice(&compact_size(tx.outputs.len() as u64));
    for output in &tx.outputs {
        out.extend_from_slice(&(output.value as u64).to_le_bytes());
        out.extend_from_slice(&compact_size(output.script_pubkey.len() as u64));
        out.extend_from_slice(&output.script_pubkey);
    }
    if use_witness {
        for stack in &tx.witness {
            out.extend_from_slice(&compact_size(stack.len() as u64));
            for item in stack {
                out.extend_from_slice(&compact_size(item.len() as u64));
                out.extend_from_slice(item);
            }
        }
    }
    out.extend_from_slice(&tx.lock_time.to_le_bytes());
    out
}

#[allow(dead_code)]
pub fn serialize_txout(output: &TxOut) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&(output.value as u64).to_le_bytes());
    out.extend_from_slice(&compact_size(output.script_pubkey.len() as u64));
    out.extend_from_slice(&output.script_pubkey);
    out
}

#[allow(dead_code)]
pub fn serialize_outpoint(outpoint: &OutPoint) -> Vec<u8> {
    let mut out = outpoint.hash.to_vec();
    out.extend_from_slice(&outpoint.index.to_le_bytes());
    out
}

pub fn read_compact_size(data: &[u8], mut offset: usize) -> Result<(u64, usize)> {
    ensure!(offset < data.len(), "truncated compactsize");
    let first = data[offset];
    offset += 1;
    match first {
        0xfd => {
            ensure!(offset + 2 <= data.len(), "truncated compactsize16");
            Ok((
                u16::from_le_bytes(data[offset..offset + 2].try_into()?) as u64,
                offset + 2,
            ))
        }
        0xfe => {
            ensure!(offset + 4 <= data.len(), "truncated compactsize32");
            Ok((
                u32::from_le_bytes(data[offset..offset + 4].try_into()?) as u64,
                offset + 4,
            ))
        }
        0xff => {
            ensure!(offset + 8 <= data.len(), "truncated compactsize64");
            Ok((
                u64::from_le_bytes(data[offset..offset + 8].try_into()?),
                offset + 8,
            ))
        }
        value => Ok((value as u64, offset)),
    }
}

pub fn compact_size(value: u64) -> Vec<u8> {
    if value < 0xfd {
        vec![value as u8]
    } else if value <= 0xffff {
        let mut out = vec![0xfd];
        out.extend_from_slice(&(value as u16).to_le_bytes());
        out
    } else if value <= 0xffff_ffff {
        let mut out = vec![0xfe];
        out.extend_from_slice(&(value as u32).to_le_bytes());
        out
    } else {
        let mut out = vec![0xff];
        out.extend_from_slice(&value.to_le_bytes());
        out
    }
}

pub fn double_sha(data: &[u8]) -> [u8; 32] {
    let first = Sha256::digest(data);
    let second = Sha256::digest(first);
    second.into()
}

pub fn display_hash(raw_internal: &[u8]) -> String {
    let mut rev = raw_internal.to_vec();
    rev.reverse();
    hex::encode(rev)
}

pub fn parse_display_hash(value: &str) -> Result<[u8; 32]> {
    let mut bytes = hex::decode(value)?;
    ensure!(bytes.len() == 32, "hash is not 32 bytes");
    bytes.reverse();
    Ok(bytes
        .try_into()
        .map_err(|_| anyhow::anyhow!("hash length"))?)
}

#[allow(dead_code)]
pub fn script_pushes(script: &[u8]) -> Result<Vec<Vec<u8>>> {
    let mut offset = 0usize;
    let mut pushes = Vec::new();
    while offset < script.len() {
        let opcode = script[offset];
        offset += 1;
        let len = match opcode {
            0x00 => {
                pushes.push(Vec::new());
                continue;
            }
            0x01..=0x4b => opcode as usize,
            0x4c => {
                ensure!(offset < script.len(), "truncated PUSHDATA1");
                let len = script[offset] as usize;
                offset += 1;
                len
            }
            0x4d => {
                ensure!(offset + 2 <= script.len(), "truncated PUSHDATA2");
                let len = u16::from_le_bytes(script[offset..offset + 2].try_into()?) as usize;
                offset += 2;
                len
            }
            0x4e => {
                ensure!(offset + 4 <= script.len(), "truncated PUSHDATA4");
                let len = u32::from_le_bytes(script[offset..offset + 4].try_into()?) as usize;
                offset += 4;
                len
            }
            _ => bail!("script is not push-only"),
        };
        ensure!(offset + len <= script.len(), "truncated push data");
        pushes.push(script[offset..offset + len].to_vec());
        offset += len;
    }
    Ok(pushes)
}
