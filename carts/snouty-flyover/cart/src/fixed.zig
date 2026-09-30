//! Q16.16 fixed point, value noise and a small rng (PLAN.md "Fixed interfaces").
//! Everything in this cart is integer so wasm, badge-bench and the badge
//! produce identical frames.

/// Fraction bits of the Q16.16 format used for world coordinates.
pub const Q = 16;
pub const one: i32 = 1 << Q;

/// (a * b) >> 16 through i64, no overflow for |a|,|b| < 2^31.
pub inline fn mul(a: i32, b: i32) i32 {
    return @intCast((@as(i64, a) * @as(i64, b)) >> Q);
}

/// Two-octave value noise in 0..255 on integer cell coordinates.
/// Stub: Track B replaces it with the real interpolated noise.
pub fn noise2(x: i32, y: i32, seed: u32) u8 {
    var h: u32 = @as(u32, @bitCast(x)) *% 0x9E3779B1 ^ @as(u32, @bitCast(y)) *% 0x85EBCA77 ^ seed;
    h ^= h >> 15;
    h *%= 0x2C1B3C6D;
    h ^= h >> 12;
    return @truncate(h >> 24);
}

/// xorshift32; never seed with 0.
pub const Rng = struct {
    s: u32,
    pub fn next(self: *Rng) u32 {
        var x = self.s;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.s = x;
        return x;
    }
};
