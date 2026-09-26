//! Snouty vs. the Bugs: M0 scaffold. Shows a title card so the build,
//! simulator shim and preview harness can be verified before gameplay lands.
//! See SPEC.md for the game and CLAUDE.md for the toolchain.
const cart = @import("cart-api");
const gfx = @import("gfx");

comptime {
    cart.export_start_code();
}

const anti_black = cart.DisplayColor.rgb(0x16031B);
const anti_white = cart.DisplayColor.rgb(0xFCFBF9);
const coral = cart.DisplayColor.rgb(0xF18271);

var tick_total: u32 = 0;

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    cart.set_double_buffer_mode(.{ .clear_full_frame = anti_black });
}

pub fn update() void {
    draw_centered_text("SNOUTY", 40, anti_white);
    draw_centered_text("vs. THE BUGS", 52, coral);
    if ((tick_total / 30) % 2 == 0) draw_centered_text("PRESS A", 96, anti_white);
    const c = read_controls();
    if (c.a) draw_centered_text("A!", 112, coral);
    // Exercise the asset pipeline: the 8x8 placeholder marker.
    draw_cell(gfx.hud, 0, 76, 72);
    tick_total +%= 1;
    if (cart.is_wasm) present_wasm();
}

/// Button state. Upstream's platform_wasm.zig exposes `controls` but never
/// fills it from the simulator, which writes its button word (same bit
/// layout as cart.Controls) to linear address 0x04; read that directly on
/// wasm. Hardware gets the OS-maintained cart.controls.
pub fn read_controls() cart.Controls {
    if (cart.is_wasm) return @bitCast(@as(*const volatile u16, @ptrFromInt(0x04)).*);
    return cart.controls.*;
}

fn draw_centered_text(comptime str: []const u8, y: i32, color: cart.DisplayColor) void {
    const x = (cart.screen_width - str.len * cart.font_width) / 2;
    cart.text(.{ .str = str, .x = x, .y = y, .text_color = color });
}

/// Draws cell `index` of a horizontal strip of square cells (side = height)
/// with its top-left at (pos_x, pos_y), skipping palette index 0 (transparent)
/// and clipping to the screen. Copied from snouty-badge; the game will
/// generalise this to non-square cells (see SPEC.md "Rendering").
fn draw_cell(comptime sprite: type, index: u32, pos_x: i32, pos_y: i32) void {
    const cell: usize = sprite.height;
    const src_x: usize = index * cell;
    const col_begin: usize = @intCast(@max(0, -pos_x));
    const col_end: usize = @intCast(@max(0, @min(cell, @as(i32, cart.screen_width) - pos_x)));
    const row_begin: usize = @intCast(@max(0, -pos_y));
    const row_end: usize = @intCast(@max(0, @min(cell, @as(i32, cart.screen_height) - pos_y)));
    if (col_begin >= col_end or row_begin >= row_end) return;
    const dst_y0: usize = @intCast(pos_y + @as(i32, @intCast(row_begin)));
    var col = col_begin;
    while (col < col_end) : (col += 1) {
        const dst_x: usize = @intCast(pos_x + @as(i32, @intCast(col)));
        const column = cart.framebuffer[dst_x][dst_y0..];
        for (row_begin..row_end, 0..) |row, dy| {
            const idx = sprite.indices.get(row * sprite.width + src_x + col);
            if (idx == 0) continue;
            column[dy] = .from_color(sprite.colors[idx]);
        }
    }
}

/// Simulator shim, copied from snouty-badge (see its CLAUDE.md for the full
/// story): upstream's wasm platform never presents, and the web simulator
/// reads a legacy framebuffer at 0x20 with red and blue swapped relative to
/// DisplayColor. Hardware builds compile none of this.
const sim_swap_rb = true;

fn present_wasm() void {
    const sim_framebuffer: *cart.Framebuffer = @ptrFromInt(0x20);
    if (sim_swap_rb) {
        for (cart.framebuffer, sim_framebuffer) |*src_column, *dst_column| {
            for (src_column, dst_column) |src, *dst| {
                const c = src.to_color();
                dst.* = .from_color(.{ .r = c.b, .g = c.g, .b = c.r });
            }
        }
    } else {
        sim_framebuffer.* = cart.framebuffer.*;
    }
}
