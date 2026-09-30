//! STUB (Track B, M4): stand-in for Track A's progressive path tracer with
//! exactly the PLAN.md M4 "Fixed interfaces" (plus `run_passes`, which the
//! debug_pt_run export needs; see the report). It traces nothing: begin()
//! stores the real-time frame in the arena, each "column" of a pass just
//! bumps that column's sample count, and display() redraws the stored frame
//! through dither.quantise with odd-count columns at half brightness, so
//! the pass front is visible as a sweeping band. The integrator replaces
//! this file with Track A's.
const cart = @import("cart-api");
const trace = @import("trace.zig");
const camera = @import("camera.zig");
const dither = @import("dither.zig");
const arena = @import("arena.zig");
const math = @import("math.zig");

pub const max_passes: u32 = 256; // knob
pub const slice_us: u32 = 36_000; // knob: tracing time per update
pub const wasm_columns_per_update: u32 = 40; // knob

const w = camera.width;
const h = camera.height;

/// The stored real-time frame, RGB565, x * height + y (the stub arena is
/// half size: two pixels per word).
fn pixels() *[w * h]u16 {
    return @ptrCast(&arena.words);
}

var is_active: bool = false;
/// Samples per column (PLAN.md "Accumulator": n_col).
var n_col: [w]u32 = @splat(0);
/// Next column to trace.
var cursor: u32 = 0;

/// Seed from the framebuffer the real-time tracer has just drawn for `view`.
pub fn begin(view: trace.View) void {
    _ = view;
    for (0..w) |x| {
        for (0..h) |y| pixels()[x * h + y] = @bitCast(cart.framebuffer[x][y].to_color());
    }
    n_col = @splat(0);
    cursor = 0;
    arena.owner = .pt;
    is_active = true;
}

fn column() void {
    n_col[cursor] += 1;
    cursor += 1;
    if (cursor == w) cursor = 0;
}

/// Whole columns until the deadline, at least one; on wasm exactly
/// wasm_columns_per_update. Nothing once done().
pub fn step(deadline_us: u64) void {
    if (!is_active or done()) return;
    if (cart.is_wasm) {
        var i: u32 = 0;
        while (i < wasm_columns_per_update and !done()) : (i += 1) column();
        return;
    }
    while (true) {
        column();
        if (done() or cart.micros_since_boot() >= deadline_us) break;
    }
}

/// Run until passes() has grown by n (or done()). Synchronous, for the
/// debug_pt_run export.
pub fn run_passes(n: u32) void {
    if (!is_active) return;
    const target = passes() +| n;
    while (passes() < target and !done()) column();
}

pub fn display() void {
    for (0..w) |x| {
        const k: f32 = if (n_col[x] & 1 == 1) 0.5 else 1.0;
        for (0..h) |y| {
            const c: cart.DisplayColor = @bitCast(pixels()[x * h + y]);
            const rgb = math.vec3(
                @as(f32, @floatFromInt(c.r)) / 31.0 * k,
                @as(f32, @floatFromInt(c.g)) / 63.0 * k,
                @as(f32, @floatFromInt(c.b)) / 31.0 * k,
            );
            cart.framebuffer[x][y] = dither.quantise(@intCast(x), @intCast(y), rgb);
        }
    }
}

pub fn release() void {
    if (!is_active) return;
    is_active = false;
    arena.owner = .realtime;
}

pub fn active() bool {
    return is_active;
}

/// Completed passes (the minimum over columns: the last column's count).
pub fn passes() u32 {
    return n_col[w - 1];
}

pub fn done() bool {
    return passes() >= max_passes;
}
