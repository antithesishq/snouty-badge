//! Party deathmatch look (M8, PLAN.md "Look"): the 16 slot colours and
//! the team colours, the name a slot goes by, the frag ranking, and a
//! 3x5 digit font for the numbers over the rivals' heads. Shared by
//! sprites.zig (the rival shirt remap) and scoreboard.zig (HUD, tables).
const cart = @import("cart-api");
const state = @import("../state.zig");

/// A shirt colour: `lit` for the lit cloth, `shade` for its folds (the
/// rival sheet's Coral and dark red are remapped to these at blit time).
pub const Shirt = struct { lit: u24, shade: u24 };

/// Slot colours in slot order. The first four are the most distinct, also
/// for red-green colour blindness (orange-pink, blue, yellow, white differ
/// in hue on the blue-yellow axis and in lightness); later ones fill the
/// hue wheel and lean on the head number to tell them apart. All are
/// bright enough to read on the dark walls (`walls.png` is mostly
/// #17121e..#6d6a86) and the teal-grey floor, and none is the Snouty
/// purple of the fur. Slot 0 is the M7 rival's Coral exactly.
pub const shirts = [state.max_players]Shirt{
    .{ .lit = 0xF18271, .shade = 0x91322F }, // 1 Coral (the M7 rival)
    .{ .lit = 0x56B4E9, .shade = 0x2A5C80 }, // 2 sky blue
    .{ .lit = 0xE6C229, .shade = 0x99622F }, // 3 gold
    .{ .lit = 0xFCFBF9, .shade = 0x958D9D }, // 4 white
    .{ .lit = 0x8FD14F, .shade = 0x3C8A2E }, // 5 lime
    .{ .lit = 0x3D6BFF, .shade = 0x1E3480 }, // 6 blue
    .{ .lit = 0xFF8FC8, .shade = 0x9C4A72 }, // 7 pink
    .{ .lit = 0x3FB8AF, .shade = 0x1F6460 }, // 8 teal
    .{ .lit = 0xEE453C, .shade = 0x7A1E1A }, // 9 red
    .{ .lit = 0xFF8C1A, .shade = 0x99500A }, // 10 orange
    .{ .lit = 0xA8F0D0, .shade = 0x4E8A70 }, // 11 mint
    .{ .lit = 0xB07438, .shade = 0x60391F }, // 12 brown
    .{ .lit = 0x3CA02E, .shade = 0x24552A }, // 13 green
    .{ .lit = 0xF0C37C, .shade = 0xA0703A }, // 14 peach
    .{ .lit = 0xB4B428, .shade = 0x5E5E14 }, // 15 olive
    .{ .lit = 0xE8189A, .shade = 0x780C50 }, // 16 magenta
};

/// Team colours as indices into `shirts`: RED, BLUE, YELLOW, GREEN (2-team
/// matches use the first two; four distinct initials for the 4-team
/// totals). Red and green also differ in lightness.
pub const team_shirt = [state.max_teams]u8{ 8, 1, 2, 4 };
pub const team_names = [state.max_teams][]const u8{ "RED", "BLUE", "YELLOW", "GREEN" };

/// The `shirts` index `slot` wears: its own in FFA, its team's otherwise.
pub fn shirt_of(m: *const state.Match, slot: usize) u8 {
    if (m.teams == 0) return @intCast(slot);
    return team_shirt[@min(m.team[slot], state.max_teams - 1)];
}

pub fn color(i: u8) cart.DisplayColor {
    return .rgb(shirts[i].lit);
}

pub fn slot_color(m: *const state.Match, slot: usize) cart.DisplayColor {
    return color(shirt_of(m, slot));
}

pub fn team_color(team: usize) cart.DisplayColor {
    return color(team_shirt[team]);
}

/// The longest name the HUD shows (8 px a character).
pub const name_len = 6;

/// What `slot` goes by: `names[slot]` (cut to `name_len`) when the lobby
/// gave one, else "P1".."P16".
pub fn name(names: []const []const u8, slot: usize, buf: *[4]u8) []const u8 {
    if (slot < names.len and names[slot].len > 0) return names[slot][0..@min(names[slot].len, name_len)];
    const n = slot + 1;
    buf[0] = 'P';
    if (n < 10) {
        buf[1] = '0' + @as(u8, @intCast(n));
        return buf[0..2];
    }
    buf[1] = '1';
    buf[2] = '0' + @as(u8, @intCast(n - 10));
    return buf[0..3];
}

pub fn present_count(m: *const state.Match) u8 {
    return @popCount(m.present);
}

/// `slot`'s place by frags: 1 + the present players with more (ties
/// share a place, as "#2 #2 #4").
pub fn rank_of(m: *const state.Match, slot: usize) u8 {
    var r: u8 = 1;
    for (0..state.max_players) |i| {
        if (m.is_present(i) and m.frags[i] > m.frags[slot]) r += 1;
    }
    return r;
}

/// Ordering for tables: in team modes by team score then team, then
/// frags (more first), deaths (fewer first), slot.
fn before(m: *const state.Match, a: u8, b: u8) bool {
    if (m.teams != 0 and m.team[a] != m.team[b]) {
        const fa = m.team_frags[m.team[a]];
        const fb = m.team_frags[m.team[b]];
        if (fa != fb) return fa > fb;
        return m.team[a] < m.team[b];
    }
    if (m.frags[a] != m.frags[b]) return m.frags[a] > m.frags[b];
    if (m.deaths[a] != m.deaths[b]) return m.deaths[a] < m.deaths[b];
    return a < b;
}

/// The present slots in table order into `out`; returns how many.
pub fn sorted(m: *const state.Match, out: *[state.max_players]u8) u8 {
    var n: u8 = 0;
    for (0..state.max_players) |i| {
        if (!m.is_present(i)) continue;
        const s: u8 = @intCast(i);
        var j = n;
        while (j > 0 and before(m, s, out[j - 1])) : (j -= 1) out[j] = out[j - 1];
        out[j] = s;
        n += 1;
    }
    return n;
}

/// Team indices by score (more first, then lower team) into `out`; returns
/// `m.teams` (0 in FFA).
pub fn sorted_teams(m: *const state.Match, out: *[state.max_teams]u8) u8 {
    const n: u8 = @min(m.teams, state.max_teams);
    for (0..n) |i| {
        const t: u8 = @intCast(i);
        var j: usize = i;
        while (j > 0 and m.team_frags[t] > m.team_frags[out[j - 1]]) : (j -= 1) out[j] = out[j - 1];
        out[j] = t;
    }
    return n;
}

// ---------------------------------------------------------------- 3x5 digits

/// Rows top to bottom, bit 2 = left column.
const digits = [10][5]u3{
    .{ 7, 5, 5, 5, 7 }, .{ 2, 6, 2, 2, 7 }, .{ 7, 1, 7, 4, 7 }, .{ 7, 1, 3, 1, 7 }, .{ 5, 5, 7, 1, 1 },
    .{ 7, 4, 7, 1, 7 }, .{ 7, 4, 7, 5, 7 }, .{ 7, 1, 1, 2, 2 }, .{ 7, 5, 7, 5, 7 }, .{ 7, 5, 7, 1, 7 },
};

/// Width in pixels of `n` (1..99) in the small font, without the box.
pub fn small_width(n: u8) i32 {
    return if (n >= 10) 7 else 3;
}

/// `n` (0..99) in 3x5 digits at (x, y), each pixel only where
/// `visible(column)` says so (the sprite depth test), on an Anti-black
/// box with a 1 px margin: the whole tag is `small_width(n) + 2` by 7.
pub fn small_number(n: u8, x: i32, y: i32, fg: cart.Pixel, bg: cart.Pixel, ctx: anytype, comptime visible: fn (@TypeOf(ctx), usize) bool) void {
    const w = small_width(n) + 2;
    const ds: [2]u8 = .{ n / 10 % 10, n % 10 };
    const nd: usize = if (n >= 10) 2 else 1;
    const first: usize = 2 - nd;
    var cx: i32 = 0;
    while (cx < w) : (cx += 1) {
        const sx = x + cx;
        if (sx < 0 or sx >= cart.screen_width) continue;
        const xi: usize = @intCast(sx);
        if (!visible(ctx, xi)) continue;
        // Which digit column (or the gap / margin) this is.
        const inner = cx - 1;
        var bits: ?struct { d: u8, c: u2 } = null;
        if (inner >= 0 and inner < w - 2) {
            const k: usize = @intCast(@divTrunc(inner, 4));
            const c = @mod(inner, 4);
            if (c < 3) bits = .{ .d = ds[first + k], .c = @intCast(c) };
        }
        var cy: i32 = 0;
        while (cy < 7) : (cy += 1) {
            const sy = y + cy;
            if (sy < 0 or sy >= cart.screen_height) continue;
            var on = false;
            if (bits) |b| {
                if (cy >= 1 and cy <= 5) {
                    const row = digits[b.d][@intCast(cy - 1)];
                    on = (row >> (2 - b.c)) & 1 == 1;
                }
            }
            cart.framebuffer[xi][@intCast(sy)] = if (on) fg else bg;
        }
    }
}

fn always(_: void, _: usize) bool {
    return true;
}

/// `small_number` with no depth test (HUD use).
pub fn small_number_flat(n: u8, x: i32, y: i32, fg: cart.Pixel, bg: cart.Pixel) void {
    small_number(n, x, y, fg, bg, {}, always);
}
