//! Menus and screens (SPEC 8): splash, title, the main menu, league and
//! track pickers, the pause menu, Grand Prix standings and the champion
//! screen. Draw helpers plus a small vertical-list cursor; main.zig owns
//! the state machine.
const cart = @import("cart-api");
const gfx = @import("gfx");
const hud = @import("hud.zig");
const sprites = @import("sprites.zig");
const track = @import("track.zig");

pub const title_str = "SNOUTY ZERO";
pub const subtitle_str = "ECUMENOPOLIS GRAND PRIX";

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

const head_pal = sprites.sheet_palette(gfx.snouty_head);

pub fn clear() void {
    cart.rect(.{ .x = 0, .y = 0, .width = 160, .height = 128, .fill_color = hud.anti_black });
}

/// Splash: Snouty's head large, the title under it.
pub fn draw_splash(frame: u32) void {
    clear();
    sprites.blit_scaled(gfx.snouty_head, 12, 8, 0, 80, 64, 1024, &head_pal, .{});
    hud.centered(title_str, 80, hud.white);
    if (frame > 30) hud.centered(subtitle_str, 96, hud.coral);
}

/// Title over the live attract floor (drawn by the caller): title, subtitle, Press Start.
pub fn draw_title(frame: u32) void {
    cart.rect(.{ .x = 0, .y = 40, .width = 160, .height = 44, .fill_color = hud.anti_black });
    hud.text(title_str, 80 - 11 * 8, 46, hud.white);
    hud.text(title_str, 80 - 11 * 8 + 1, 46, hud.white); // bold
    hud.centered(subtitle_str, 62, hud.coral);
    if ((frame / 30) % 2 == 0) hud.centered("PRESS START", 74, hud.cyan);
}

/// A titled list with the cursor row in coral and a `>` marker.
pub fn draw_list(title: []const u8, items: []const []const u8, list: *const List, y0: i32) void {
    hud.centered(title, y0, hud.cyan);
    for (items, 0..) |item, i| {
        const y = y0 + 16 + @as(i32, @intCast(i)) * 12;
        const selected = i == list.cursor;
        if (selected) hud.text(">", 32, y, hud.coral);
        hud.text(item, 44, y, if (selected) hud.coral else hud.white);
    }
}

pub fn league_names() [track.leagues.len][]const u8 {
    var out: [track.leagues.len][]const u8 = undefined;
    for (track.leagues, 0..) |l, i| out[i] = l.name;
    return out;
}

/// Grand Prix standings: five rows, points, the champion line at the end.
pub const Standings = struct {
    points: [5]u16 = @splat(0),
    /// Per-track ranks of the player (for the summary).
    race: u8 = 0,
};

pub const points_for_rank = [6]u16{ 0, 9, 6, 4, 3, 2 };
pub const names = [5][]const u8{ "SNOUTY", "ARGMAX", "DROPOUT", "BACKPROP", "OVERFIT" };

fn put_uint(out: []u8, v: u32) void {
    var n = v;
    var i = out.len;
    while (i > 0) {
        i -= 1;
        out[i] = @intCast('0' + n % 10);
        n /= 10;
        if (n == 0) break;
    }
}

/// Standings sorted by points, the player's row in cyan. `final` adds the champion line.
pub fn draw_standings(st: *const Standings, league: []const u8, final: bool, frame: u32) void {
    clear();
    hud.centered(if (final) "GRAND PRIX RESULT" else "STANDINGS", 8, hud.cyan);
    hud.centered(league, 20, hud.coral);
    var order = [5]u8{ 0, 1, 2, 3, 4 };
    // Insertion sort by points, stable.
    var i: usize = 1;
    while (i < 5) : (i += 1) {
        const k = order[i];
        var j = i;
        while (j > 0 and st.points[order[j - 1]] < st.points[k]) : (j -= 1) order[j] = order[j - 1];
        order[j] = k;
    }
    for (order, 0..) |who, row| {
        const y = 36 + @as(i32, @intCast(row)) * 12;
        const color = if (who == 0) hud.cyan else hud.white;
        var pos: [2]u8 = "1.".*;
        pos[0] = @intCast('1' + row);
        hud.text(&pos, 20, y, color);
        hud.text(names[who], 40, y, color);
        var pts: [3]u8 = "  0".*;
        put_uint(&pts, st.points[who]);
        hud.text(&pts, 116, y, color);
        if (who >= 1) cart.rect(.{ .x = 136, .y = y + 1, .width = 6, .height = 6, .fill_color = .rgb(sprites.livery_rgb[who - 1]) });
    }
    if (final) {
        const champion = order[0];
        hud.centered(if (champion == 0) "SNOUTY IS CHAMPION" else "RETRAIN AND RETRY", 100, if (champion == 0) hud.cyan else hud.coral);
    }
    if ((frame / 30) % 2 == 0) hud.centered("PRESS START", 114, hud.coral);
}
