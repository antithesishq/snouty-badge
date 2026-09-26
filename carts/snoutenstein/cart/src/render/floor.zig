//! Ceiling (y 0..51) and floor (y 52..103) colour tables: flat per-row
//! fills, darker toward the horizon (SPEC.md section 5). Built at comptime.
const cart = @import("cart-api");

pub const half_h = 52;

/// Server-room ceiling: cool grey-violet, brightest at the top row.
const ceil_near = [3]comptime_int{ 0x4A, 0x44, 0x5C };
const ceil_far = [3]comptime_int{ 0x0E, 0x0C, 0x14 };
/// Floor: dark teal-grey, brightest at the bottom row.
const floor_near = [3]comptime_int{ 0x3A, 0x46, 0x44 };
const floor_far = [3]comptime_int{ 0x0C, 0x0E, 0x0E };

/// Colour used for columns whose ray passes the range cap: the darkest
/// shade, matching the horizon rows of both tables so fog blends in.
pub const fog: cart.Pixel = mix(ceil_far, floor_far, 1, 2);

/// `ceiling[y]` for y 0..51 (row 0 at the top of the screen).
pub const ceiling: [half_h]cart.Pixel = ramp(ceil_near, ceil_far);
/// `floor[y - 52]` for y 52..103 (row 0 at the horizon).
pub const floor: [half_h]cart.Pixel = blk: {
    const r = ramp(floor_near, floor_far);
    var out: [half_h]cart.Pixel = undefined;
    for (0..half_h) |i| out[i] = r[half_h - 1 - i];
    break :blk out;
};

/// Row 0 = `near` colour, row 51 = `far`. The row's distance on a flat
/// plane is ~ 1 / (rows to horizon), so interpolate on that, not linearly.
fn ramp(comptime near: [3]comptime_int, comptime far: [3]comptime_int) [half_h]cart.Pixel {
    @setEvalBranchQuota(10000);
    var out: [half_h]cart.Pixel = undefined;
    for (0..half_h) |i| {
        // rows from the horizon: 52 (edge of the screen) .. 1 (horizon)
        const rows: comptime_float = @floatFromInt(half_h - i);
        // brightness 1 at the screen edge, falls off like distance 52/rows,
        // softened so the horizon is not a hard black band.
        const t: comptime_float = @sqrt(rows / @as(comptime_float, half_h));
        var c: [3]u32 = undefined;
        for (0..3) |k| {
            const v: comptime_float = @as(comptime_float, far[k]) + (@as(comptime_float, near[k]) - @as(comptime_float, far[k])) * t;
            c[k] = @intFromFloat(@round(v));
        }
        out[i] = .from_color(.rgb((c[0] << 16) | (c[1] << 8) | c[2]));
    }
    return out;
}

fn mix(comptime a: [3]comptime_int, comptime b: [3]comptime_int, comptime wa: comptime_int, comptime wb: comptime_int) cart.Pixel {
    var c: [3]u32 = undefined;
    for (0..3) |k| c[k] = (a[k] * wa + b[k] * wb) / (wa + wb);
    return .from_color(.rgb((c[0] << 16) | (c[1] << 8) | c[2]));
}

/// The same tables as pixel pairs (rows 2k and 2k+1 in one word), so the
/// fills below store 32 bits at a time. Column starts are 256-byte aligned
/// (128 rows x 2 bytes), so even rows are word-aligned.
const ceiling_pairs: [half_h / 2]u32 = pairs(ceiling);
const floor_pairs: [half_h / 2]u32 = pairs(floor);

fn pairs(comptime t: [half_h]cart.Pixel) [half_h / 2]u32 {
    var out: [half_h / 2]u32 = undefined;
    for (0..half_h / 2) |k| out[k] = @as(u32, t[2 * k].bits) | (@as(u32, t[2 * k + 1].bits) << 16);
    return out;
}

/// Fills `col[0..top]` with the ceiling and `col[bottom..104]` with the
/// floor; `top <= 52 <= bottom`. Word stores through a volatile pointer:
/// the upstream compiler-rt memcpy in ReleaseSmall copies bytewise, and
/// volatile stops LLVM from turning the loop back into a memcpy call.
pub inline fn fill(col: *align(4) [cart.screen_height]cart.Pixel, top: usize, bottom: usize) void {
    const words: [*]volatile u32 = @ptrCast(col);
    var k: usize = 0;
    while (k < top / 2) : (k += 1) words[k] = ceiling_pairs[k];
    if (top & 1 != 0) col[top - 1] = ceiling[top - 1];
    var y = bottom;
    if (y & 1 != 0) {
        col[y] = floor[y - half_h];
        y += 1;
    }
    k = (y - half_h) / 2;
    while (k < half_h / 2) : (k += 1) words[half_h / 2 + k] = floor_pairs[k];
}
