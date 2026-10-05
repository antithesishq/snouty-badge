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
        return unit(v >> 11);
    }

    /// k * 2^-53 for k < 2^53, built from its bits: exact (k has at most
    /// 53 significant bits), the same value as the int-to-float conversion
    /// and multiply, without two soft-float calls on the badge.
    pub fn unit(k: u64) f64 {
        if (k == 0) return 0;
        const hi: u32 = @truncate(k >> 32);
        const lz: u32 = if (hi != 0) @clz(hi) else 32 + @as(u32, @clz(@as(u32, @truncate(k))));
        const p: u32 = 63 - lz; // position of the leading 1, 0..52
        const m = (k << @intCast(52 - p)) & ((1 << 52) - 1);
        return @bitCast((@as(u64, 970 + p) << 52) | m);
    }
};
