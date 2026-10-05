//! Forked from snouty-zero/cart/src/menu.zig at f8f6962.
//! Menus and screens (SPEC 8.1): the splash (Snouty's eyepatched portrait,
//! M1), the title (M3: SNOUTY GCP / GARBAGE COLLECTION / PRIX over the
//! Dumps horizon, the six portraits along the bottom, PRESS START), the main
//! menu (M3: QUICK RACE, GARBAGE COLLECTION, M6 BATTLE, M5 CIRCUIT, PICKUPS
//! (pickup_page.zig), LINK (M4; greyed in the simulator), SOUND)
//! and the vertical list the pause menu uses. Zero's league and track
//! pickers and the Grand Prix standings are gone; the racer select is
//! select.zig. main.zig owns the state machine and draws the live floor
//! behind the title and the menu.
const cart = @import("cart-api");
const hud = @import("hud.zig");
const sprites = @import("sprites.zig");
const racers = @import("racers.zig");
const menu_text = @import("menu_text.zig");

/// The game is Snouty GCP, short for Snouty Garbage Collection Prix. The
/// title lockup is SNOUTY small and GCP big (`lockup`): SNOUTY GCP at 2x
/// is the whole 160 px.
pub const title_str = "SNOUTY GCP";
pub const subtitle = "GARBAGE COLLECTION";
pub const subtitle_2 = "PRIX";
const hero = "GCP";
const small = "SNOUTY";

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
/// frame, the title and the two subtitle lines under it.
pub fn draw_splash(frame: u32) void {
    clear();
    hud.fill_rect(31, 1, 98, 98, hud.livery(0));
    sprites.blit_cell(&sprites.portraits[0], 0, 32, 2, 96, 96, .{});
    hud.centered(title_str, 101, hud.white);
    hud.text(title_str, 80 - @as(i32, title_str.len) * 4 + 1, 101, hud.white); // bold
    if (frame > 30) {
        hud.centered(subtitle, 110, hud.coral);
        hud.centered(subtitle_2, 119, hud.coral);
    }
}

/// The title lockup, centred, top row at `y`: SNOUTY at 1x sitting on the
/// baseline of GCP at `scale`x, each white with a coral drop. The glyphs
/// use 7 of their 8 columns, so the ink is 47 + 6 + 23 * scale px wide.
/// `plate`: an Anti-Black plate behind SNOUTY (over the live floor, where
/// 1x text alone gets lost in the scenery).
pub fn lockup(y: i32, scale: i32, plate: bool) void {
    const gap: i32 = 6;
    const small_w: i32 = @as(i32, small.len) * 8 - 1;
    const x: i32 = 80 - @divTrunc(small_w + gap + 23 * scale, 2);
    const sy = y + 8 * scale - 8;
    if (plate) hud.fill_rect(x - 2, sy - 2, small_w + 5, 12, hud.anti_black);
    hud.glyph_text(small, x + 1, sy + 1, 1, false, hud.coral);
    hud.glyph_text(small, x, sy, 1, false, hud.white);
    const hx = x + small_w + gap;
    hud.glyph_text(hero, hx + scale, y + scale, scale, false, hud.coral);
    hud.glyph_text(hero, hx, y, scale, false, hud.white);
}

/// The lockup with GCP at 2x and the plate (the LINK lobby; the main menu
/// draws it at `menu_text.layout.title_y`), top row at `y`.
pub fn big_title(y: i32) void {
    lockup(y, 2, true);
}

/// Portrait row (title): six half-scale portraits 25 px apart, a livery
/// stripe under each; the one `lit` (0..5) sits 2 px higher.
const row_x0: i32 = 5;
const row_y: i32 = 96;

/// Title over the live floor (drawn by the caller, the Dumps horizon at
/// the top): the title band, PRESS START blinking with `A  QUICK RACE`
/// in its off half, and the six racers' portraits along the bottom, one
/// stepping up at a time.
pub fn draw_title(frame: u32) void {
    hud.fill_rect(0, 30, 160, 64, hud.anti_black);
    lockup(33, 3, false);
    hud.centered(subtitle, 63, hud.coral);
    hud.centered(subtitle_2, 72, hud.coral);
    // PRESS START blinks; in its off half the A shortcut (L40) shows.
    if ((frame / 30) % 2 == 0) hud.centered("PRESS START", 84, hud.white) else hud.centered(menu_text.title_a, 84, hud.grey);
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

/// Main menu rows, in order (SPEC 8.1; M6 BATTLE after GARBAGE
/// COLLECTION, SPEC 8.3: `menu_text.layout`'s 7 rows).
pub const Item = enum(u8) { quick, gc, battle, circuit, pickups, link, sound };
pub const item_count = 7;

const panel = cart.DisplayColor.rgb(0x2A1E34);
const panel_hi = cart.DisplayColor.rgb(0x4A2440);
const lay = menu_text.layout;

comptime {
    if (item_count > lay.max_rows) @compileError("main menu: more rows than menu_text.layout fits");
}

/// The menu over the live floor: the title lockup over the horizon, the
/// rows centred on the longest (GARBAGE COLLECTION: 144 px, so no room for
/// a `>` marker) in a panel, the cursor row coral on a highlight bar, LINK
/// greyed when there is no link (the simulator), and a bar along the
/// bottom with a line about the row under the cursor over the footer
/// (`menu_text.layout` has the numbers). `link_note` > 0: A was pressed on
/// a greyed LINK, its line flashes coral.
pub fn draw_main(list: *const List, sound_on: bool, link_ok: bool, link_note: u32, frame: u32) void {
    _ = frame;
    lockup(lay.title_y, 2, true);
    var labels: [lay.max_rows][]const u8 = undefined;
    var n: usize = 0;
    var cursor_row: usize = 0;
    var link_row: usize = 0;
    for (0..item_count) |i| {
        const it: Item = @fromBackingInt(@intCast(i));
        if (i == list.cursor) cursor_row = n;
        if (it == .link) link_row = n;
        labels[n] = switch (it) {
            .quick => "QUICK RACE",
            .gc => "GARBAGE COLLECTION",
            .battle => "BATTLE",
            .circuit => "CIRCUIT",
            .pickups => "PICKUPS",
            .link => "LINK",
            .sound => if (sound_on) "SOUND: ON" else "SOUND: OFF",
        };
        n += 1;
    }
    const rows: i32 = @intCast(n);
    const py = lay.panel_y(rows);
    cart.rect(.{ .x = 4, .y = py, .width = 152, .height = @intCast(lay.panel_h(rows)), .fill_color = panel, .stroke_color = hud.dim });
    const x: i32 = 80 - @as(i32, subtitle.len) * 4;
    for (labels[0..n], 0..) |item, i| {
        const y = lay.row_y(rows, @intCast(i));
        const sel = i == cursor_row;
        if (sel) hud.fill_rect(6, y - lay.bar_above, 148, lay.highlight_h, panel_hi);
        const greyed = i == link_row and !link_ok;
        const color = if (greyed) hud.dim else if (sel) hud.coral else hud.white;
        hud.text(item, x, y, color);
    }
    // What the row under the cursor does, over the footer.
    const about = switch (@as(Item, @fromBackingInt(@intCast(list.cursor)))) {
        .quick => menu_text.quick,
        .gc => menu_text.gc,
        .battle => menu_text.battle,
        .circuit => menu_text.circuit,
        .pickups => menu_text.pickups,
        .link => if (link_ok) menu_text.link else menu_text.no_link,
        .sound => menu_text.sound,
    };
    const note_on = link_note > 0 and (link_note / 6) % 2 == 0;
    const on_link = list.cursor == @backingInt(Item.link);
    const about_color = if (on_link and !link_ok and note_on) hud.coral else hud.grey;
    hud.fill_rect(4, lay.bar_y, 152, 128 - lay.bar_y, hud.anti_black);
    hud.centered(about, lay.hint_y, about_color);
    hud.centered(menu_text.footer, lay.footer_y, hud.dim);
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
