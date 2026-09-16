//! Byte-oriented node adapter result, shared by all independent crypto lanes.
pub const TweakResult = struct {
    output_xonly: [32]u8,
    parity: u8,
};
