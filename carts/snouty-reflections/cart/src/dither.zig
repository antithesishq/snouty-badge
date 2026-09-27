//! Quantisation of linear f32 RGB to RGB565 `Pixel` (PLAN.md "Quantisation").
//!
//! Both modes are the same arithmetic, `floor(c * max + th)` per channel,
//! and differ only in the threshold table: mode `none` uses the constant
//! 1e-4, `bayer_temporal` uses `(B + 0.5) / 16` from a 4x4 Bayer matrix
//! whose x index is shifted by 2 on odd frames. `begin_frame` picks the
//! 16-entry table for the frame, so `quantise` has no branch: one table
//! load, three multiplies and three adds, three float-to-int conversions, the
//! bit packing and (at the caller) one 16-bit store.
//!
//! No clamp is needed: the input is saturated to [0, 1] and the largest
//! threshold is 31/32 < 1, so `c * 31 + th < 32` and `c * 63 + th < 64`.
//!
//! No gamma table: the output is linear, as the reference (tools/
//! reference.py) expects in mode `none`.
const cart = @import("cart-api");
const math = @import("math.zig");

pub const Mode = enum(u32) { bayer_temporal = 0, none = 1 };

pub var mode: Mode = .bayer_temporal;

pub fn next_mode() void {
    mode = if (mode == .bayer_temporal) .none else .bayer_temporal;
    select_table();
}

/// Called once per frame before any quantise() call.
pub fn begin_frame(frame: u32) void {
    parity = frame & 1;
    select_table();
}

/// Frame parity stored by begin_frame (0 even, 1 odd).
var parity: u32 = 0;

/// Threshold table for the current frame and mode, indexed by
/// `(y & 3) * 4 + (x & 3)`.
var table: *const [16]f32 = &bayer_tables[0];

fn select_table() void {
    table = switch (mode) {
        .bayer_temporal => &bayer_tables[parity],
        .none => &none_table,
    };
}

const bayer4 = [4][4]u8{
    .{ 0, 8, 2, 10 },
    .{ 12, 4, 14, 6 },
    .{ 3, 11, 1, 9 },
    .{ 15, 7, 13, 5 },
};

/// [parity][(y & 3) * 4 + (x & 3)] = (B[y & 3][(x + 2 * parity) & 3] + 0.5) / 16.
const bayer_tables: [2][16]f32 = blk: {
    var t: [2][16]f32 = undefined;
    for (0..2) |p| {
        for (0..4) |y| {
            for (0..4) |x| {
                const b: f32 = @floatFromInt(bayer4[y][(x + 2 * p) & 3]);
                t[p][y * 4 + x] = (b + 0.5) / 16.0;
            }
        }
    }
    break :blk t;
};

const none_table: [16]f32 = @splat(1e-4);

/// Quantise linear RGB in [0, 1] (already saturated) for screen pixel (x, y).
pub inline fn quantise(x: u32, y: u32, rgb: math.Vec3) cart.Pixel {
    const th = table[((y & 3) << 2) | (x & 3)];
    const scale: math.Vec3 = .{ 31.0, 63.0, 31.0 };
    // Separate mul and add (not @mulAdd): VMUL+VADD are 1 cycle each on the
    // M33, VFMA is 3, and wasm would lower fma to a libcall.
    const q = rgb * scale + @as(math.Vec3, @splat(th));
    // Non-negative, so truncation is floor.
    const r: u16 = @intFromFloat(q[0]);
    const g: u16 = @intFromFloat(q[1]);
    const b: u16 = @intFromFloat(q[2]);
    // DisplayColor layout: r bits 0..4, g 5..10, b 11..15.
    const bits: u16 = r | (g << 5) | (b << 11);
    return cart.Pixel.from_color(@bitCast(bits));
}
