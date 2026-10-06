//! Testnet4 consensus parameters (spacing, retarget, BIP94, BIP113, BIP68).
//! Activation heights are data. Connect does not special-case a height of its own.
//! Through height 155069, 105573 of 155070 blocks (68 percent) are minimum-difficulty,
//! which is why a retarget bases on the first block of the period
//! (`zig_consensus_context_host_2026-10-04.json`, test "retarget uses the first block bits").
//! Does not apply the rules. `consensus_context.zig` does.

/// Compact testnet4 proof-of-work ceiling.
/// These values are testnet4 data. A different network does not belong in this file.
/// test "retarget uses the first block bits"
pub const pow_limit_bits: u32 = 0x1d00ffff;
/// 600-second target spacing used by the retarget.
/// These values are testnet4 data. A different network does not belong in this file.
/// test "retarget uses the first block bits"
pub const spacing: u32 = 600;
/// Two weeks, the retarget window that pairs with the 2016-block interval.
/// These values are testnet4 data. A different network does not belong in this file.
/// test "retarget uses the first block bits"
pub const timespan: i64 = 1_209_600;
/// 2016-block retarget spacing on testnet4.
/// These values are testnet4 data. A different network does not belong in this file.
/// test "retarget uses the first block bits"
pub const interval: u32 = 2016;
/// Twenty minutes. A later testnet4 block may use the pow limit.
/// These values are testnet4 data. A different network does not belong in this file.
/// test "retarget uses the first block bits"
pub const min_difficulty_gap: i64 = 1200;
/// BIP94 allowance, 600 seconds, on the first block of a retarget period.
/// These values are testnet4 data. A different network does not belong in this file.
/// test "retarget uses the first block bits"
pub const timewarp: u32 = 600;
/// Height where BIP113 compares locktime to MTP instead of the block timestamp.
/// These values are testnet4 data. A different network does not belong in this file.
/// test "retarget uses the first block bits"
pub const bip113_height: u32 = 1;
/// Height where BIP68 and BIP112 are enforced. Testnet4 data, not a connect branch.
/// These values are testnet4 data. A different network does not belong in this file.
/// test "retarget uses the first block bits"
pub const csv_height: u32 = 1;
/// Locktimes below this are heights. At or above, they are timestamps.
/// These values are testnet4 data. A different network does not belong in this file.
/// test "retarget uses the first block bits"
pub const locktime_threshold: u32 = 500_000_000;

/// testnet4 genesis header fields. Header ingest starts from this block.
/// test "retarget uses the first block bits"
pub const genesis_time: u32 = 1714777860;
/// testnet4 genesis nBits. Header ingest starts from this compact target.
/// These values are testnet4 data. A different network does not belong in this file.
/// test "retarget uses the first block bits"
pub const genesis_bits: u32 = pow_limit_bits;
