//! New for Snouty GC: the main menu's PICKUPS page. The 15 non-league
//! pickups' icons (pickups.png, cell = `world.Pickup`) in a grid, a row per
//! roll tier (A 5, B 6, C 4), a coral cursor that wraps both ways, and
//! under it the pickup's name, three lines on what it does and one on who
//! tends to roll it (pickup_text.zig). B goes back to the menu. The cursor
//! is kept while the cart runs (no saves). Drawn like the racer select:
//! solid, 4 px clear of the edges, the 8x8 font without shadow.
const cart = @import("cart-api");
const hud = @import("hud.zig");
const font = @import("font.zig");
const input = @import("input.zig");
const sound = @import("sound.zig");
const sprites = @import("sprites.zig");
const roster_text = @import("roster_text.zig");
const pickup_text = @import("pickup_text.zig");

/// The pickup under the cursor (a `world.Pickup` value, 0..14).
pub var cursor: u8 = 0;

pub const Action = enum { none, back };

/// One frame of input: the arrows move the cursor, B leaves.
pub fn update() Action {
    if (input.pressed(.b)) return .back;
    const dx: i8 = @as(i8, @intFromBool(input.pressed(.right))) - @intFromBool(input.pressed(.left));
    const dy: i8 = @as(i8, @intFromBool(input.pressed(.down))) - @intFromBool(input.pressed(.up));
    if (dx != 0 or dy != 0) {
        const next = pickup_text.move(cursor, dx, dy);
        if (next != cursor) sound.menu_move();
        cursor = next;
    }
    return .none;
}

const bg = cart.DisplayColor.rgb(0x100E16);
const panel = cart.DisplayColor.rgb(0x221E2C);
const ink = cart.DisplayColor.rgb(0xECE8F0);
const rule = cart.DisplayColor.rgb(0x464056);

/// The grid: 18x18 cells (a 1 px frame round the 16x16 icon) 20 px apart,
/// six columns centred.
const pitch: i32 = 20;
const grid_x: i32 = 80 - @divTrunc(pickup_text.cols * pitch - 2, 2);
const grid_y: i32 = 16;
/// The text under it, 9 px a line.
const text_y: i32 = 79;

fn plain(str: []const u8, x: i32, y: i32, color: cart.DisplayColor) void {
    font.draw(str, x, y, .from_color(color), null);
}

/// A 1 px frame.
fn frame_rect(x: i32, y: i32, w: i32, h: i32, color: cart.DisplayColor) void {
    hud.fill_rect(x, y, w, 1, color);
    hud.fill_rect(x, y + h - 1, w, 1, color);
    hud.fill_rect(x, y + 1, 1, h - 2, color);
    hud.fill_rect(x + w - 1, y + 1, 1, h - 2, color);
}

pub fn draw(frame: u32) void {
    _ = frame;
    hud.fill_rect(0, 0, 160, 128, bg);
    plain("PICKUPS", 4, 4, hud.cyan);
    plain("B BACK", 156 - 48, 4, hud.dim);
    for (0..3) |r| {
        const y = grid_y + @as(i32, @intCast(r)) * pitch;
        for (0..pickup_text.row_len[r]) |c| {
            const i: u8 = pickup_text.row_start[r] + @as(u8, @intCast(c));
            const x = grid_x + @as(i32, @intCast(c)) * pitch;
            const sel = i == cursor;
            hud.fill_rect(x + 1, y + 1, 16, 16, panel);
            if (sel) {
                frame_rect(x - 1, y - 1, 20, 20, hud.coral);
                frame_rect(x, y, 18, 18, hud.coral);
            } else frame_rect(x, y, 18, 18, rule);
            sprites.blit_at(&sprites.pickups, i, x + 1, y + 1, .{});
        }
    }
    hud.fill_rect(4, text_y - 3, 152, 1, rule);
    const e = &pickup_text.entries[cursor % pickup_text.count];
    plain(roster_text.pickup_name(@fromBackingInt(cursor)), 4, text_y, ink);
    for (e.lines, 0..) |line, k| plain(line, 4, text_y + 9 + @as(i32, @intCast(k)) * 9, hud.grey);
    plain(e.who, 4, text_y + 36, hud.orange);
}
