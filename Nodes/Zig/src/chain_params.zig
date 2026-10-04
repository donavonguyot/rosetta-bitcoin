//! Testnet4 consensus parameters. Deployment heights are data for the shared
//! context checks. They are not a reason to special-case a block height in connect.

pub const pow_limit_bits: u32 = 0x1d00ffff;
pub const spacing: u32 = 600;
pub const timespan: i64 = 1_209_600;
pub const interval: u32 = 2016;
pub const min_difficulty_gap: i64 = 1200;
pub const timewarp: u32 = 600;
pub const bip113_height: u32 = 1;
pub const csv_height: u32 = 1;
pub const locktime_threshold: u32 = 500_000_000;

/// testnet4 genesis header fields. Header ingest starts from this block.
pub const genesis_time: u32 = 1714777860;
pub const genesis_bits: u32 = pow_limit_bits;
