//! Forked from snouty-zero/cart/src/menu.zig at f8f6962.
//! Menus and screens (SPEC 8.1): the splash (Snouty's eyepatched portrait,
//! M1), the title, and the vertical list the pause menu uses. Zero's
//! league and track pickers and the Grand Prix standings are gone; the
//! racer select is select.zig, M3 the real title and attract. main.zig
//! owns the state machine.
const cart = @import("cart-api");
const hud = @import("hud.zig");
const sprites = @import("sprites.zig");

pub const title_str = "SNOUTY GC";
pub const subtitle = "GARBAGE COLLECTION";

/// Vertical list cursor.
pub const List = struct {
    cursor: u8 = 0,
    count: u8,

    pub fn up(self: *List) void {
        self.cursor = if (self.cursor == 0) self.count - 1 else self.cursor - 1;
    }
    pub fn down(self: *List) void {
        self.cursor = if (self.cursor + 1 >= self.count) 0 else self.cursor + 1;
    }
};

pub fn clear() void {
    cart.rect(.{ .x = 0, .y = 0, .width = 160, .height = 128, .fill_color = hud.anti_black });
}

/// Splash (SPEC 8.1): Snouty's eyepatched portrait at 2x in his livery
/// frame, the title and subtitle under it.
pub fn draw_splash(frame: u32) void {
    clear();
    cart.rect(.{ .x = 31, .y = 4, .width = 98, .height = 98, .fill_color = hud.livery(0) });
    sprites.blit_cell(&sprites.portraits[0], 0, 32, 5, 96, 96, .{});
    hud.centered(title_str, 104, hud.white);
    hud.text(title_str, 80 - @as(i32, title_str.len) * 4 + 1, 104, hud.white); // bold
    if (frame > 30) hud.centered(subtitle, 115, hud.coral);
}

/// Title over the live floor (drawn by the caller): title, subtitle, Press Start.
pub fn draw_title(frame: u32) void {
    cart.rect(.{ .x = 0, .y = 36, .width = 160, .height = 56, .fill_color = hud.anti_black });
    hud.centered(title_str, 44, hud.white);
    hud.text(title_str, 80 - @as(i32, title_str.len) * 4 + 1, 44, hud.white); // bold
    hud.centered(subtitle, 60, hud.coral);
    if ((frame / 30) % 2 == 0) hud.centered("PRESS START", 78, hud.cyan);
}

/// A titled list with the cursor row in coral and a `>` marker. The marker
/// and the items are centred as one block on the longest item (Zero M5.2),
/// never left of x 44.
pub fn draw_list(title: []const u8, items: []const []const u8, list: *const List, y0: i32) void {
    hud.centered(title, y0, hud.cyan);
    var longest: usize = 0;
    for (items) |item| longest = @max(longest, item.len);
    const x: i32 = @min(44, 80 - @as(i32, @intCast(longest * 4)) + 6);
    for (items, 0..) |item, i| {
        const y = y0 + 16 + @as(i32, @intCast(i)) * 12;
        const selected = i == list.cursor;
        if (selected) hud.text(">", x - 12, y, hud.coral);
        hud.text(item, x, y, if (selected) hud.coral else hud.white);
    }
}
