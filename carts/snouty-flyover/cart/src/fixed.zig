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

/// Two-octave value noise in 0..255 on integer cell coordinates, deterministic
/// and integer-only. Octave 1 has a lattice point every 16 cells, octave 2
/// every 8 cells at half weight; each is a bilinear blend of hashed lattice
/// values with 8 fractional bits. Result = (2 * o1 + o2) / 3. Periodic in x
/// with period 256 cells (the strip width), so the x wrap has no seam.
pub fn noise2(x: i32, y: i32, seed: u32) u8 {
    const o1 = lattice_bilinear(x, y, 4, seed);
    const o2 = lattice_bilinear(x, y, 3, seed ^ 0xA511_E9B3);
    return @intCast(@divTrunc(2 * o1 + o2, 3));
}

/// Bilinear value noise on a lattice of 2^log2_cell cells, result 0..255.
fn lattice_bilinear(x: i32, y: i32, comptime log2_cell: u5, seed: u32) i32 {
    const x_cells_mask = (256 >> log2_cell) - 1;
    const ix = x >> log2_cell;
    const ix1 = (ix + 1) & x_cells_mask;
    const iy = y >> log2_cell;
    // Fraction within the cell in 1/256.
    const fx = (x & ((1 << log2_cell) - 1)) << (8 - log2_cell);
    const fy = (y & ((1 << log2_cell) - 1)) << (8 - log2_cell);
    const ix0 = ix & x_cells_mask;
    const v00 = lattice(ix0, iy, seed);
    const v10 = lattice(ix1, iy, seed);
    const v01 = lattice(ix0, iy + 1, seed);
    const v11 = lattice(ix1, iy + 1, seed);
    const top = v00 * 256 + (v10 - v00) * fx; // 1/256 units
    const bot = v01 * 256 + (v11 - v01) * fx;
    return (top * 256 + (bot - top) * fy) >> 16;
}

/// Hashed lattice value 0..255.
fn lattice(ix: i32, iy: i32, seed: u32) i32 {
    var h: u32 = @as(u32, @bitCast(ix)) *% 0x9E3779B1 ^ @as(u32, @bitCast(iy)) *% 0x85EBCA77 ^ seed;
    h ^= h >> 15;
    h *%= 0x2C1B3C6D;
    h ^= h >> 12;
    h *%= 0x297A2D39;
    h ^= h >> 15;
    return @intCast(h >> 24);
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
