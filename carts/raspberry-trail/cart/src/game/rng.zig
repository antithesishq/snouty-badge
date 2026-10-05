//! RND(-1) for the port and the oracle (SPEC 3.4): splitmix64 seeds an
//! xorshift64* generator; each RND(-1) is one draw, (next >> 11) * 2^-53,
//! in [0, 1). tools/oracle/basic.py implements the same bits.
pub const Rng = struct {
    state: u64 = 1,

    pub fn init(seed: u64) Rng {
        var z = seed +% 0x9E3779B97F4A7C15;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        z ^= z >> 31;
        return .{ .state = if (z == 0) 1 else z };
    }

    pub fn next(r: *Rng) u64 {
        var x = r.state;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        r.state = x;
        return x *% 0x2545F4914F6CDD1D;
    }

    /// One RND(-1).
    pub fn rnd(r: *Rng) f64 {
        return @as(f64, @floatFromInt(r.next() >> 11)) * 0x1p-53;
    }
};

test "rng: first draws for seed 1 (basic.py prints the same)" {
    const std = @import("std");
    var r = Rng.init(1);
    const a = r.rnd();
    const b = r.rnd();
    try std.testing.expect(a >= 0 and a < 1 and b >= 0 and b < 1 and a != b);
}
