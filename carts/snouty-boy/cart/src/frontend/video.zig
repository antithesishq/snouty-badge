//! Line sink: Game Boy scanlines (shades 0..3) into the column-major RGB565
//! framebuffer, with the squeeze/crop line map and the current palette.
//! Owner in M1: track C. SPEC.md section 6.
const cart = @import("cart-api");
const core = @import("core");

pub const Scale = enum { squeeze, crop };

pub var scale: Scale = .squeeze;

/// Row in the badge framebuffer for each Game Boy line, or -1 to skip.
var line_map: [core.screen_h]i16 = undefined;
var shades: [4]cart.Pixel = undefined;

/// DMG green (SPEC.md section 6), lightest first.
pub const palette_dmg = [4]u32{ 0x9BBC0F, 0x8BAC0F, 0x306230, 0x0F380F };

pub fn init() void {
    set_palette(palette_dmg);
    set_scale(scale);
}

pub fn set_palette(p: [4]u32) void {
    for (&shades, p) |*s, rgb| s.* = .from_color(.rgb(rgb));
}

pub fn set_scale(s: Scale) void {
    scale = s;
    for (&line_map, 0..) |*row, ly| {
        row.* = switch (s) {
            // Drop every ninth line: 144 - 16 = 128 rows.
            .squeeze => if (ly % 9 == 8) -1 else @intCast(ly - ly / 9),
            .crop => if (ly < 8 or ly >= 8 + cart.screen_height) -1 else @intCast(ly - 8),
        };
    }
}

pub fn sink() core.LineSink {
    return .{ .ctx = @ptrFromInt(@alignOf(usize)), .func = &on_line };
}

fn on_line(_: *anyopaque, ly: u8, line: *const [core.screen_w]u8) void {
    const row = line_map[ly];
    if (row < 0) return;
    const y: usize = @intCast(row);
    for (line, 0..) |shade, x| {
        cart.framebuffer[x][y] = shades[shade & 3];
    }
}

/// Called once per badge frame after `step_frame`; nothing to do while the
/// sink writes straight into the framebuffer.
pub fn finish_frame() void {}
