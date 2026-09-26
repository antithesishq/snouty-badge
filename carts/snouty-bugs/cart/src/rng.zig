//! xorshift32, seeded per game. Gameplay randomness comes only from here
//! (never `cart.rand()`), so a run is reproducible from its seed.

const fallback_seed: u32 = 0x2545F491;

var state: u32 = fallback_seed;

/// Seeds the generator. Zero is a fixed point of xorshift, so it is remapped.
pub fn seed(s: u32) void {
    state = if (s == 0) fallback_seed else s;
}

pub fn next() u32 {
    var x = state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    state = x;
    return x;
}

/// Uniform-ish integer in [lo, hi] inclusive. Requires lo <= hi.
pub fn range(lo: i32, hi: i32) i32 {
    const span: u32 = @intCast(hi - lo + 1);
    const off: i32 = @intCast(next() % span);
    return lo + off;
}
