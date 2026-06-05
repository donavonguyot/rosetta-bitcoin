use anyhow::{bail, ensure, Context, Result};
use std::collections::BTreeMap;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::sync::mpsc::{self, Receiver};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::tx;

const PROTOCOL_VERSION: i32 = 70016;
const SERVICES: u64 = 1 | 8; // NODE_NETWORK | NODE_WITNESS
const TESTNET4_MAGIC: [u8; 4] = [0x1c, 0x16, 0x3f, 0x28];
const MSG_WITNESS_BLOCK: u32 = (1 << 30) | 2;
const GENESIS_HASH: &str = "00000000da84f2bafbbc53dee25a72ae507ff4914b867c565be350b0da8bf043";

pub struct FetchOptions {
    pub peer: String,
    pub target: u32,
    pub start_height: u32,
    pub prefetch: usize,
}

pub struct P2PBlock {
    pub height: u32,
    pub hash: String,
    pub raw: Vec<u8>,
    pub fetch_ms: i64,
}

pub fn fetch_blocks(opts: FetchOptions) -> Receiver<Result<P2PBlock>> {
    let (sender, receiver) = mpsc::sync_channel(opts.prefetch.max(1).min(64));
    thread::spawn(move || {
        let result = || -> Result<()> {
            let mut client = Client::connect(&opts.peer)?;
            client.handshake()?;
            let hashes = client.headers_through(opts.target)?;
            let prefetch = opts.prefetch.max(1).min(64);
            let mut start = opts.start_height as usize;
            while start <= opts.target as usize {
                let end = (start + prefetch).min(opts.target as usize + 1);
                let fetch_started = Instant::now();
                let blocks = client.request_blocks(&hashes[start..end])?;
                let fetch_ms = (fetch_started.elapsed().as_millis() as i64)
                    / i64::try_from(blocks.len().max(1)).unwrap_or(1);
                for (offset, raw) in blocks.into_iter().enumerate() {
                    let height = (start + offset) as u32;
                    let hash = tx::display_hash(&tx::double_sha(&raw[..80]));
                    if sender
                        .send(Ok(P2PBlock {
                            height,
                            hash,
                            raw,
                            fetch_ms,
                        }))
                        .is_err()
                    {
                        return Ok(());
                    }
                }
                start = end;
            }
            Ok(())
        }();
        if let Err(error) = result {
            let _ = sender.send(Err(error));
        }
    });
    receiver
}

struct Client {
    stream: TcpStream,
}

struct Message {
    command: String,
    payload: Vec<u8>,
}

impl Client {
    fn connect(peer: &str) -> Result<Self> {
        let stream = TcpStream::connect(peer).with_context(|| format!("connect {peer}"))?;
        stream.set_read_timeout(Some(Duration::from_secs(120)))?;
        stream.set_write_timeout(Some(Duration::from_secs(30)))?;
        Ok(Self { stream })
    }

    fn handshake(&mut self) -> Result<()> {
        self.send("version", &version_payload())?;
        let mut seen_version = false;
        let mut seen_verack = false;
        while !seen_version || !seen_verack {
            let message = self.read_message()?;
            match message.command.as_str() {
                "version" => {
                    seen_version = true;
                    self.send("verack", &[])?;
                }
                "verack" => seen_verack = true,
                "ping" => self.send("pong", &message.payload)?,
                _ => {}
            }
        }
        self.send("sendheaders", &[])?;
        Ok(())
    }

    fn headers_through(&mut self, target: u32) -> Result<Vec<[u8; 32]>> {
        let mut hashes = vec![hash_from_display(GENESIS_HASH)?];
        while hashes.len() <= target as usize {
            let locator = *hashes.last().expect("genesis locator exists");
            self.send("getheaders", &getheaders_payload(&locator))?;
            let message = self.read_command("headers")?;
            let headers = parse_headers(&message.payload)?;
            ensure!(
                !headers.is_empty(),
                "peer returned no headers at height {}",
                hashes.len() - 1
            );
            for header in headers {
                if hashes.len() > target as usize {
                    break;
                }
                ensure!(
                    header[4..36] == hashes[hashes.len() - 1],
                    "header prev mismatch at height {}",
                    hashes.len()
                );
                hashes.push(tx::double_sha(&header));
            }
        }
        Ok(hashes)
    }

    fn request_blocks(&mut self, hashes: &[[u8; 32]]) -> Result<Vec<Vec<u8>>> {
        if hashes.is_empty() {
            return Ok(Vec::new());
        }
        self.send("getdata", &getdata_payload(hashes))?;
        let mut pending = BTreeMap::new();
        for (index, hash) in hashes.iter().enumerate() {
            pending.insert(hex::encode(hash), index);
        }
        let mut result = vec![Vec::new(); hashes.len()];
        while !pending.is_empty() {
            let message = self.read_message()?;
            match message.command.as_str() {
                "block" => {
                    ensure!(message.payload.len() >= 80, "short block payload");
                    let hash = hex::encode(tx::double_sha(&message.payload[..80]));
                    if let Some(index) = pending.remove(&hash) {
                        result[index] = message.payload;
                    }
                }
                "notfound" => bail!("peer returned notfound for requested block"),
                "ping" => self.send("pong", &message.payload)?,
                _ => {}
            }
        }
        Ok(result)
    }

    fn read_command(&mut self, command: &str) -> Result<Message> {
        loop {
            let message = self.read_message()?;
            if message.command == command {
                return Ok(message);
            }
            if message.command == "ping" {
                self.send("pong", &message.payload)?;
            }
        }
    }

    fn read_message(&mut self) -> Result<Message> {
        let mut header = [0u8; 24];
        self.stream.read_exact(&mut header)?;
        ensure!(header[0..4] == TESTNET4_MAGIC, "unexpected network magic");
        let command = String::from_utf8_lossy(&header[4..16])
            .trim_end_matches('\0')
            .to_string();
        let length = u32::from_le_bytes(header[16..20].try_into()?) as usize;
        let checksum = &header[20..24];
        let mut payload = vec![0u8; length];
        self.stream.read_exact(&mut payload)?;
        ensure!(
            message_checksum(&payload) == checksum,
            "checksum mismatch for {command}"
        );
        Ok(Message { command, payload })
    }

    fn send(&mut self, command: &str, payload: &[u8]) -> Result<()> {
        let mut frame = Vec::with_capacity(24 + payload.len());
        frame.extend_from_slice(&TESTNET4_MAGIC);
        let mut command_bytes = [0u8; 12];
        command_bytes[..command.len().min(12)]
            .copy_from_slice(&command.as_bytes()[..command.len().min(12)]);
        frame.extend_from_slice(&command_bytes);
        frame.extend_from_slice(&(payload.len() as u32).to_le_bytes());
        frame.extend_from_slice(&message_checksum(payload));
        frame.extend_from_slice(payload);
        self.stream.write_all(&frame)?;
        Ok(())
    }
}

fn version_payload() -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&PROTOCOL_VERSION.to_le_bytes());
    out.extend_from_slice(&SERVICES.to_le_bytes());
    out.extend_from_slice(
        &(SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs() as i64)
            .to_le_bytes(),
    );
    append_net_addr(&mut out);
    append_net_addr(&mut out);
    out.extend_from_slice(
        &(SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos() as u64)
            .to_le_bytes(),
    );
    append_var_bytes(&mut out, b"/rsbitnode:0.1.0/");
    out.extend_from_slice(&0i32.to_le_bytes());
    out.push(0);
    out
}

fn append_net_addr(out: &mut Vec<u8>) {
    out.extend_from_slice(&SERVICES.to_le_bytes());
    out.extend_from_slice(&[0u8; 10]);
    out.extend_from_slice(&[0xff, 0xff, 0, 0, 0, 0]);
    out.extend_from_slice(&0u16.to_be_bytes());
}

fn getheaders_payload(locator: &[u8; 32]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&PROTOCOL_VERSION.to_le_bytes());
    append_varint(&mut out, 1);
    out.extend_from_slice(locator);
    out.extend_from_slice(&[0u8; 32]);
    out
}

fn getdata_payload(hashes: &[[u8; 32]]) -> Vec<u8> {
    let mut out = Vec::new();
    append_varint(&mut out, hashes.len() as u64);
    for hash in hashes {
        out.extend_from_slice(&MSG_WITNESS_BLOCK.to_le_bytes());
        out.extend_from_slice(hash);
    }
    out
}

fn parse_headers(payload: &[u8]) -> Result<Vec<[u8; 80]>> {
    let (count, mut offset) = read_varint(payload, 0)?;
    let mut headers = Vec::with_capacity(count as usize);
    for _ in 0..count {
        ensure!(offset + 80 <= payload.len(), "truncated headers payload");
        let mut header = [0u8; 80];
        header.copy_from_slice(&payload[offset..offset + 80]);
        offset += 80;
        let (tx_count, next) = read_varint(payload, offset)?;
        ensure!(tx_count == 0, "headers message had nonzero tx count");
        offset = next;
        headers.push(header);
    }
    Ok(headers)
}

fn append_var_bytes(out: &mut Vec<u8>, value: &[u8]) {
    append_varint(out, value.len() as u64);
    out.extend_from_slice(value);
}

fn append_varint(out: &mut Vec<u8>, value: u64) {
    match value {
        0..=0xfc => out.push(value as u8),
        0xfd..=0xffff => {
            out.push(0xfd);
            out.extend_from_slice(&(value as u16).to_le_bytes());
        }
        0x1_0000..=0xffff_ffff => {
            out.push(0xfe);
            out.extend_from_slice(&(value as u32).to_le_bytes());
        }
        _ => {
            out.push(0xff);
            out.extend_from_slice(&value.to_le_bytes());
        }
    }
}

fn read_varint(data: &[u8], mut offset: usize) -> Result<(u64, usize)> {
    ensure!(offset < data.len(), "truncated varint");
    let first = data[offset];
    offset += 1;
    match first {
        0xfd => {
            ensure!(offset + 2 <= data.len(), "truncated varint16");
            Ok((
                u16::from_le_bytes(data[offset..offset + 2].try_into()?) as u64,
                offset + 2,
            ))
        }
        0xfe => {
            ensure!(offset + 4 <= data.len(), "truncated varint32");
            Ok((
                u32::from_le_bytes(data[offset..offset + 4].try_into()?) as u64,
                offset + 4,
            ))
        }
        0xff => {
            ensure!(offset + 8 <= data.len(), "truncated varint64");
            Ok((
                u64::from_le_bytes(data[offset..offset + 8].try_into()?),
                offset + 8,
            ))
        }
        _ => Ok((first as u64, offset)),
    }
}

fn message_checksum(payload: &[u8]) -> [u8; 4] {
    tx::double_sha(payload)[..4]
        .try_into()
        .expect("checksum length")
}

fn hash_from_display(value: &str) -> Result<[u8; 32]> {
    let mut raw: [u8; 32] = hex::decode(value)?
        .try_into()
        .map_err(|_| anyhow::anyhow!("hash must be 32 bytes"))?;
    raw.reverse();
    Ok(raw)
}
