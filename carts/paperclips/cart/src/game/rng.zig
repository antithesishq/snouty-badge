//! The SPEC section 5 RNG that replaces `Math.random()` in the port and in
//! the oracle: xorshift64*, 53-bit result in [0, 1).

pub const Rng = struct {
    x: u64,

    pub fn init(seed: u64) Rng {
        return .{ .x = if (seed == 0) 0x9E3779B97F4A7C15 else seed };
    }

    pub fn next(r: *Rng) f64 {
        var x = r.x;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        r.x = x;
        const v = x *% 0x2545F4914F6CDD1D;
        return @as(f64, @floatFromInt(v >> 11)) * (1.0 / 9007199254740992.0);
    }
};
