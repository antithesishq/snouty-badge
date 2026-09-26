//! Line sink: Game Boy scanlines (shades 0..3) into the column-major RGB565
//! framebuffer, with the squeeze/crop line map and the current palette.
//! Owner in M1: track C. SPEC.md section 6.
//!
//! The hot path is `on_line`, called by the PPU once per visible line (144
//! per frame). The framebuffer is `[160][128]Pixel`, i.e. column-major: one
//! Game Boy line is 160 halfword stores 256 bytes apart. The row's first
//! pixel address is computed once per line and the loop only adds the
//! column stride, so there is no per-pixel bounds check or 2D index math.
const cart = @import("cart-api");
const core = @import("core");

pub const Scale = enum { squeeze, crop };

pub var scale: Scale = .squeeze;

const gb_h = core.screen_h;
const gb_w = core.screen_w;
const fb_h = cart.screen_height;
const fb_w = cart.screen_width;

comptime {
    if (gb_w != fb_w) @compileError("horizontal mapping is 1:1");
    if (fb_h > 0xFF) @compileError("rows must fit in u8");
}

/// Line map entry meaning "this Game Boy line is not drawn".
const skip: u8 = 0xFF;

/// Row in the badge framebuffer for each Game Boy line, or `skip`.
const LineMap = [gb_h]u8;

fn build_line_map(s: Scale) LineMap {
    var map: LineMap = undefined;
    for (&map, 0..) |*row, ly| {
        row.* = switch (s) {
            // Drop every ninth line (ly % 9 == 8): 144 - 16 = 128 rows.
            .squeeze => if (ly % 9 == 8) skip else @intCast(ly - ly / 9),
            // Lines 8..135 to rows 0..127.
            .crop => if (ly < 8 or ly >= 8 + fb_h) skip else @intCast(ly - 8),
        };
    }
    return map;
}

/// Checks a map covers every framebuffer row exactly once, in order.
fn check_line_map(comptime s: Scale, map: LineMap) void {
    var next_row: usize = 0;
    for (map, 0..) |row, ly| {
        const expect_skip = switch (s) {
            .squeeze => ly % 9 == 8,
            .crop => ly < 8 or ly > 135,
        };
        if (expect_skip != (row == skip)) @compileError("line map skips the wrong lines");
        if (row == skip) continue;
        if (row != next_row) @compileError("line map rows are not contiguous");
        next_row += 1;
    }
    if (next_row != fb_h) @compileError("line map does not fill the screen");
}

const line_maps = blk: {
    @setEvalBranchQuota(10_000);
    const sq = build_line_map(.squeeze);
    const cr = build_line_map(.crop);
    check_line_map(.squeeze, sq);
    check_line_map(.crop, cr);
    // Spot checks against SPEC.md section 6.
    if (sq[0] != 0 or sq[7] != 7 or sq[8] != skip or sq[9] != 8 or sq[142] != 127 or sq[143] != skip)
        @compileError("squeeze spot check");
    if (cr[7] != skip or cr[8] != 0 or cr[135] != 127 or cr[136] != skip)
        @compileError("crop spot check");
    break :blk [_]LineMap{ sq, cr };
};

var line_map: *const LineMap = &line_maps[@backingInt(Scale.squeeze)];

// ---- Palettes (SPEC.md section 6), lightest shade first ----

pub const Palette = struct {
    name: []const u8,
    rgb: [4]u32,
};

pub const palettes = [_]Palette{
    // The original DMG screen.
    .{ .name = "DMG", .rgb = .{ 0x9BBC0F, 0x8BAC0F, 0x306230, 0x0F380F } },
    // Game Boy Pocket: grey-olive LCD.
    .{ .name = "Pocket", .rgb = .{ 0xC4CFA1, 0x8B956D, 0x4D533C, 0x1F1F1F } },
    // Crisp black on white.
    .{ .name = "Light", .rgb = .{ 0xFFFFFF, 0xAAAAAA, 0x555555, 0x000000 } },
    // Antithesis-ish: cream, coral, plum, near-black aubergine (the cream,
    // coral and black are snouty-bugs' brand colors).
    .{ .name = "Snouty", .rgb = .{ 0xF4EFDF, 0xF18271, 0x6B2A5E, 0x16031B } },
};

/// Every palette converted to `Pixel` once, at compile time (the wasm
/// byte swap is comptime-known).
const pixel_tables = blk: {
    var t: [palettes.len][4]cart.Pixel = undefined;
    for (&t, palettes) |*dst, p| {
        for (dst, p.rgb) |*px, rgb| px.* = .from_color(.rgb(rgb));
    }
    break :blk t;
};

pub var palette_index: usize = 0;
var shades: *const [4]cart.Pixel = &pixel_tables[0];
/// The current palette indexed by the raw shade byte: entry i is
/// `shades[i & 3]`. 512 bytes of RAM buy one instruction per pixel (the
/// store loop is ldrb, ldrh, strh with no masking), and a core that ever
/// emits a byte above 3 still cannot index out of bounds.
var lut: [256]cart.Pixel = @splat(.{ .bits = 0 });

/// Lines the core emitted since the last `finish_frame` (drawn or skipped).
var lines_this_frame: u32 = 0;
/// Lines emitted during the last completed frame (144 with the LCD on).
pub var last_frame_lines: u32 = 0;

pub fn init() void {
    set_palette_index(palette_index);
    set_scale(scale);
}

/// Select palette `i` (wraps, so `set_palette_index(palette_index + 1)`
/// cycles). Takes effect from the next line.
pub fn set_palette_index(i: usize) void {
    palette_index = i % palettes.len;
    shades = &pixel_tables[palette_index];
    for (&lut, 0..) |*px, b| px.* = shades[b & 3];
}

pub fn next_palette() void {
    set_palette_index(palette_index + 1);
}

pub fn palette_name() []const u8 {
    return palettes[palette_index].name;
}

pub fn set_scale(s: Scale) void {
    scale = s;
    line_map = &line_maps[@backingInt(s)];
}

pub fn sink() core.LineSink {
    return .{ .ctx = @ptrFromInt(@alignOf(usize)), .func = &on_line };
}

fn on_line(_: *anyopaque, ly: u8, line: *const [gb_w]u8) void {
    lines_this_frame += 1;
    if (ly >= gb_h) return;
    const row = line_map[ly];
    if (row == skip) return;
    store_line(row, line);
}

/// One Game Boy line to framebuffer row `row`: 160 halfword stores with a
/// stride of `fb_h` pixels (256 bytes). Unrolled by 8 so the stores use
/// immediate offsets; on Cortex-M33 ReleaseFast this is 3 instructions per
/// pixel (ldrb shade, ldrh lut[shade], strh [col, #k*256]).
inline fn store_line(row: u8, line: *const [gb_w]u8) void {
    var dst: [*]cart.Pixel = @as([*]cart.Pixel, @ptrCast(cart.framebuffer)) + row;
    var x: usize = 0;
    while (x < gb_w) : (x += 8) {
        inline for (0..8) |k| {
            dst[k * fb_h] = lut[line[x + k]];
        }
        dst += 8 * fb_h;
    }
}

/// Fill the whole screen with one shade of the current palette.
pub fn blank(shade: u2) void {
    const px: u16 = shades[shade].bits;
    const fb: *[fb_w * fb_h / 2]u32 = @ptrCast(cart.framebuffer);
    @memset(fb, @as(u32, px) << 16 | px);
}

/// Called once per badge frame after `step_frame`. With the LCD off the core
/// emits no lines, and the (not copied forward) back buffer still holds an
/// old frame, so blank it to shade 0 as a real DMG shows a blank screen.
pub fn finish_frame() void {
    if (lines_this_frame == 0) blank(0);
    last_frame_lines = lines_this_frame;
    lines_this_frame = 0;
}

/// Shade `s` of the current palette as a `DisplayColor`, for overlays drawn
/// with the cart API (menu, splash) so they follow the palette.
pub fn shade_color(s: u2) cart.DisplayColor {
    return .rgb(palettes[palette_index].rgb[s]);
}

/// Recolor a frozen frame in place: every pixel equal to shade k of palette
/// `old` becomes shade k of palette `new`. Other pixels (overlay text) stay.
/// Used by the menu when the palette changes while the core is paused; costs
/// one pass over the 20,480 pixels, only on a key press.
pub fn remap_palette(old: usize, new: usize) void {
    const from = &pixel_tables[old % palettes.len];
    const to = &pixel_tables[new % palettes.len];
    const fb: *[fb_w * fb_h]cart.Pixel = @ptrCast(cart.framebuffer);
    for (fb) |*px| {
        const b = px.bits;
        if (b == from[0].bits) {
            px.* = to[0];
        } else if (b == from[1].bits) {
            px.* = to[1];
        } else if (b == from[2].bits) {
            px.* = to[2];
        } else if (b == from[3].bits) {
            px.* = to[3];
        }
    }
}
