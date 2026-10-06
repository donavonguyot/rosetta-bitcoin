//! Byte-oriented tweak result shared by every crypto lane.
//! `output_xonly` and `parity` match across libsecp, own_curve, and the pure verifier.
//! Does not verify a signature.

/// X-only output key and parity from a BIP341 tweak.
/// Parity is 0 or 1. The x-only key is 32 bytes.
/// test "pure taproot tweak edge cases match native backend"
pub const TweakResult = struct {
    output_xonly: [32]u8,
    parity: u8,
};
