//! xorshift32, seeded per game. Gameplay randomness comes only from here
//! (never `cart.rand()`), so a run is reproducible from its seed.
//! The state is `world.w.rng`.
const world = @import("world.zig");

pub const fallback_seed: u32 = 0x2545F491;

/// Seeds the generator. Zero is a fixed point of xorshift, so it is remapped.
pub fn seed(s: u32) void {
    world.w.rng = if (s == 0) fallback_seed else s;
}

pub fn next() u32 {
    var x = world.w.rng;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    world.w.rng = x;
    return x;
}

/// Uniform-ish integer in [lo, hi] inclusive. Requires lo <= hi.
pub fn range(lo: i32, hi: i32) i32 {
    const span: u32 = @intCast(hi - lo + 1);
    const off: i32 = @intCast(next() % span);
    return lo + off;
}
