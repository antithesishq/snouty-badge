//! Pixel helpers on the column-major framebuffer (cart.framebuffer[x][y]),
//! all clipped to the screen, plus the 5x7 label font and the OS 8x8
//! font scaled up for the note name.
const cart = @import("cart-api");
const font5 = @import("gen/font5x7.zig");
const font8 = @import("gen/font8.zig");

pub const W: i32 = 160;
pub const H: i32 = 128;
pub const Color = cart.DisplayColor;

pub fn rgb(v: u32) Color {
    return Color.rgb(v);
}

/// Linear mix of two 0xRRGGBB colours, t in 0..256.
pub fn mix(a: u32, b: u32, t: i32) Color {
    const tt: u32 = @intCast(@min(@max(t, 0), 256));
    var out: u32 = 0;
    inline for (.{ 16, 8, 0 }) |sh| {
        const ca = (a >> sh) & 0xFF;
        const cb = (b >> sh) & 0xFF;
        out |= ((ca * (256 - tt) + cb * tt) >> 8) << sh;
    }
    return rgb(out);
}

pub fn clear(c: Color) void {
    const p = cart.Pixel.from_color(c);
    for (cart.framebuffer) |*col| @memset(col, p);
}

pub inline fn set(x: i32, y: i32, c: Color) void {
    if (x < 0 or y < 0 or x >= W or y >= H) return;
    cart.framebuffer[@intCast(x)][@intCast(y)] = cart.Pixel.from_color(c);
}

pub fn fill(x: i32, y: i32, w: i32, h: i32, c: Color) void {
    const x0 = @max(x, 0);
    const y0 = @max(y, 0);
    const x1 = @min(x + w, W);
    const y1 = @min(y + h, H);
    if (x0 >= x1 or y0 >= y1) return;
    const p = cart.Pixel.from_color(c);
    var xx = x0;
    while (xx < x1) : (xx += 1) @memset(cart.framebuffer[@intCast(xx)][@intCast(y0)..@intCast(y1)], p);
}

pub fn hline(x: i32, y: i32, w: i32, c: Color) void {
    fill(x, y, w, 1, c);
}

pub fn vline(x: i32, y: i32, h: i32, c: Color) void {
    fill(x, y, 1, h, c);
}

pub fn frame(x: i32, y: i32, w: i32, h: i32, c: Color) void {
    hline(x, y, w, c);
    hline(x, y + h - 1, w, c);
    vline(x, y, h, c);
    vline(x + w - 1, y, h, c);
}

pub fn line(x0: i32, y0: i32, x1: i32, y1: i32, c: Color) void {
    var x = x0;
    var y = y0;
    const dx: i32 = @intCast(@abs(x1 - x0));
    const dy: i32 = -@as(i32, @intCast(@abs(y1 - y0)));
    const sx: i32 = if (x0 < x1) 1 else -1;
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err = dx + dy;
    while (true) {
        set(x, y, c);
        if (x == x1 and y == y1) break;
        const e2 = 2 * err;
        if (e2 >= dy) {
            err += dy;
            x += sx;
        }
        if (e2 <= dx) {
            err += dx;
            y += sy;
        }
    }
}

/// Filled ellipse centred at (cx, cy).
pub fn ellipse(cx: i32, cy: i32, rx: i32, ry: i32, c: Color) void {
    if (rx <= 0 or ry <= 0) return;
    var dy: i32 = -ry;
    while (dy <= ry) : (dy += 1) {
        // Half-width at this row: rx * sqrt(1 - (dy/ry)^2), integer.
        const rem = ry * ry - dy * dy;
        var hw: i32 = 0;
        while ((hw + 1) * (hw + 1) * ry * ry <= rem * rx * rx) hw += 1;
        hline(cx - hw, cy + dy, 2 * hw + 1, c);
    }
}

// ---- Text ----

pub const cell_w: i32 = 6;

/// 5x7 text, top-left at (x, y); returns the x after the last glyph.
pub fn text(s: []const u8, x: i32, y: i32, c: Color) i32 {
    var cx = x;
    for (s) |ch| {
        const cols = glyph5(ch);
        for (cols, 0..) |bits, i| {
            var b = bits;
            var yy: i32 = 0;
            while (b != 0) : (yy += 1) {
                if (b & 1 != 0) set(cx + @as(i32, @intCast(i)), y + yy, c);
                b >>= 1;
            }
        }
        cx += cell_w;
    }
    return cx;
}

pub fn text_width(s: []const u8) i32 {
    if (s.len == 0) return 0;
    return @as(i32, @intCast(s.len)) * cell_w - 1;
}

fn glyph5(ch: u8) *const [5]u8 {
    const unknown = &[5]u8{ 0x7F, 0x41, 0x41, 0x41, 0x7F };
    if (ch < font5.first or ch - font5.first >= font5.count) return unknown;
    return &font5.columns[ch - font5.first];
}

/// The OS 8x8 font at `scale`x, top-left at (x, y).
pub fn text_big(s: []const u8, x: i32, y: i32, scale: i32, c: Color) void {
    var cx = x;
    for (s) |ch| {
        if (ch >= font8.first and ch <= font8.last) {
            const g = font8.glyphs[ch - font8.first];
            for (g, 0..) |row, r| {
                var col: i32 = 0;
                while (col < 8) : (col += 1) {
                    if ((row >> @intCast(7 - col)) & 1 != 0)
                        fill(cx + col * scale, y + @as(i32, @intCast(r)) * scale, scale, scale, c);
                }
            }
        }
        cx += 8 * scale;
    }
}
