const crypto_mod = @import("crypto.zig");

pub const crypto = crypto_mod;

pub fn secp256k1Available() bool {
    return crypto.available();
}
