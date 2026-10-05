//! Forked from snouty-zero/cart/src/menu.zig at f8f6962.
//! Menus and screens (SPEC 8.1): the splash (Snouty's eyepatched portrait,
//! M1), the title (M3: SNOUTY GC / GARBAGE COLLECTION over the Dumps
//! horizon, the six portraits along the bottom, PRESS START), the main
//! menu (M3: QUICK RACE, GARBAGE COLLECTION, LINK (M4; greyed in the
//! simulator), SOUND)
//! and the vertical list the pause menu uses. Zero's league and track
//! pickers and the Grand Prix standings are gone; the racer select is
//! select.zig. main.zig owns the state machine and draws the live floor
//! behind the title and the menu.
const cart = @import("cart-api");
const hud = @import("hud.zig");
const sprites = @import("sprites.zig");
const racers = @import("racers.zig");

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
    hud.fill_rect(0, 0, 160, 128, hud.anti_black);
}

/// Splash (SPEC 8.1): Snouty's eyepatched portrait at 2x in his livery
/// frame, the title and subtitle under it.
pub fn draw_splash(frame: u32) void {
    clear();
    hud.fill_rect(31, 4, 98, 98, hud.livery(0));
    sprites.blit_cell(&sprites.portraits[0], 0, 32, 5, 96, 96, .{});
    hud.centered(title_str, 104, hud.white);
    hud.text(title_str, 80 - @as(i32, title_str.len) * 4 + 1, 104, hud.white); // bold
    if (frame > 30) hud.centered(subtitle, 115, hud.coral);
}

/// SNOUTY GC at 2x with a coral drop, centred, top row at `y`.
pub fn big_title(y: i32) void {
    const x: i32 = 80 - @as(i32, title_str.len) * 8;
    hud.glyph_text(title_str, x + 2, y + 2, 2, false, hud.coral);
    hud.glyph_text(title_str, x, y, 2, false, hud.white);
}

/// Portrait row (title): six half-scale portraits 25 px apart, a livery
/// stripe under each; the one `lit` (0..5) sits 2 px higher.
const row_x0: i32 = 5;
const row_y: i32 = 96;

/// Title over the live floor (drawn by the caller, the Dumps horizon at
/// the top): the title band, PRESS START blinking, and the six racers'
/// portraits along the bottom, one stepping up at a time.
pub fn draw_title(frame: u32) void {
    hud.fill_rect(0, 34, 160, 56, hud.anti_black);
    big_title(38);
    hud.centered(subtitle, 60, hud.coral);
    if ((frame / 30) % 2 == 0) hud.centered("PRESS START", 76, hud.white);
    const lit: u32 = (frame / 45) % racers.count;
    for (0..racers.count) |k| {
        const x = row_x0 + @as(i32, @intCast(k)) * 25;
        const up: i32 = if (k == lit) 2 else 0;
        hud.fill_rect(x - 1, row_y - 1 - up, 26, 26, hud.anti_black);
        sprites.blit_rect(&sprites.portraits[k], 0, 0, 48, 48, x, row_y - up, 24, 24, .{});
        hud.fill_rect(x, row_y + 25 - up, 24, 2, hud.livery(@intCast(k)));
    }
}

// --- The main menu (SPEC 8.1) -------------------------------------------------------

/// Main menu rows, in order.
pub const Item = enum(u8) { quick, gc, link, sound };
pub const item_count = 4;

const panel = cart.DisplayColor.rgb(0x2A1E34);
const panel_hi = cart.DisplayColor.rgb(0x4A2440);

/// The menu over the live floor: the title at 2x over the horizon, the
/// rows centred on the longest (GARBAGE COLLECTION: 144 px, so no room for
/// a `>` marker) in a panel, the cursor row coral on a highlight bar, LINK
/// greyed when there is no link (the simulator), and a line about the row
/// under the cursor. `link_note` > 0: A was pressed on a greyed LINK, NO
/// LINK IN SIMULATOR flashes in place of its line.
pub fn draw_main(list: *const List, sound_on: bool, link_ok: bool, link_note: u32, frame: u32) void {
    big_title(8);
    const y0: i32 = 36;
    const pitch: i32 = 13;
    cart.rect(.{ .x = 4, .y = y0 - 3, .width = 152, .height = 4 * pitch + 5, .fill_color = panel, .stroke_color = hud.dim });
    const items = [item_count][]const u8{ "QUICK RACE", "GARBAGE COLLECTION", "LINK", if (sound_on) "SOUND: ON" else "SOUND: OFF" };
    const x: i32 = 80 - @as(i32, subtitle.len) * 4;
    for (items, 0..) |item, i| {
        const y = y0 + @as(i32, @intCast(i)) * pitch;
        const sel = i == list.cursor;
        if (sel) hud.fill_rect(6, y - 2, 148, 11, panel_hi);
        const greyed = i == @backingInt(Item.link) and !link_ok;
        const color = if (greyed) hud.dim else if (sel) hud.coral else hud.white;
        hud.text(item, x, y, color);
    }
    _ = frame;
    // What the row under the cursor does.
    const about = switch (@as(Item, @fromBackingInt(@intCast(list.cursor)))) {
        .quick => "3 LAPS, SIX RACERS",
        .gc => "LAST CAR LEFT WINS",
        .link => if (link_ok) "2 BADGES, 1 CABLE" else "NO LINK IN",
        .sound => "A TOGGLES SOUND",
    };
    const note_on = link_note > 0 and (link_note / 6) % 2 == 0;
    const on_link = list.cursor == @backingInt(Item.link);
    const about_color = if (on_link and !link_ok) (if (note_on) hud.coral else hud.grey) else hud.grey;
    hud.fill_rect(4, 92, 152, 32, hud.anti_black);
    hud.centered(about, 96, about_color);
    if (list.cursor == @backingInt(Item.gc)) hud.centered("MARK AND SWEEP", 106, hud.dim);
    if (on_link) hud.centered(if (link_ok) "LINK RACE, LINK GC" else "SIMULATOR", 106, if (link_ok) hud.dim else about_color);
    hud.centered("A SELECT  B BACK", 116, hud.dim);
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
