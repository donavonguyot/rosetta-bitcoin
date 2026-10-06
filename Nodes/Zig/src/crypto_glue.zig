//! Re-exports the compiled verifier as `crypto`.
//! One binary has one backend. The others are not constructed.
//! Verification is public-data and variable-time
//! (`zig_own_curve_kernel_campaign_host_2026-10-04.json`).
//! Does not implement field arithmetic.

const crypto_mod = @import("crypto.zig");

/// The `crypto.zig` module, re-exported so callers have one name.
/// The re-export and `crypto.zig` are the same verifier.
/// test "native secp256k1 extrakeys and schnorr backend is available"
pub const crypto = crypto_mod;

/// True when the selected backend can verify. Gates record this, they do not probe libsecp themselves.
/// The re-export and `crypto.zig` are the same verifier.
/// test "native secp256k1 extrakeys and schnorr backend is available"
pub fn secp256k1Available() bool {
    return crypto.available();
}
