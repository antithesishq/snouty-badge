//! Party deathmatch HUD (M8, PLAN.md "Look" and "Results"): the rank line
//! in the status bar, the one-line kill feed, the hold-Select scoreboard
//! and the results table. Everything reads a `*const state.Match`, the
//! slot this badge shows (`me`) and the lobby's names by slot (`names`;
//! empty or short = "P1".."P16"). Colours and ordering: slots.zig.
const cart = @import("cart-api");
const state = @import("../state.zig");
const hud = @import("hud.zig");
const slots = @import("slots.zig");

const Match = state.Match;
const max_players = state.max_players;
const fmt = hud.fmt;
const bar_y = hud.bar_y;

/// The kill feed shows the latest death this long (ticks, 2 s).
pub const feed_ticks: u32 = 120;
/// Table rows are 8 px (the font's height plus a gap) when they fit, else
/// 7 px (glyphs touching, every other row on a stripe): 16 rows of 7 fit
/// under two header lines.
pub const row_h: i32 = 7;

fn row_height(n: i32, y0: i32) i32 {
    return if (y0 + 8 * n <= 128) 8 else row_h;
}

// ---------------------------------------------------------------- rank line

/// The status bar's right block (x 96..159, where M7 drew YOU/THEM):
/// "#3/12" and your frags (in your colour), then the leader's frags
/// ("TOP n"; "2ND n" when you lead) in FFA, or the team totals in their
/// colours with your team underlined.
pub fn draw_rank(m: *const Match, me: usize) void {
    cart.rect(.{ .x = 96, .y = bar_y, .width = 64, .height = hud.bar_h, .fill_color = hud.anti_black });
    var buf: [8]u8 = undefined;
    const rank = slots.rank_of(m, me);
    cart.text(.{ .str = fmt(&buf, "#{d}/{d}", .{ rank, slots.present_count(m) }), .x = 96, .y = bar_y + 3, .text_color = hud.anti_white });
    hud.text_right(hud.signed(&buf, m.frags[me]), 159, bar_y + 3, slots.slot_color(m, me));

    const y2 = bar_y + 13;
    if (m.teams == 0) {
        // The best score among the others: the leader's, or the runner-up's
        // when you lead.
        var best: ?i16 = null;
        for (0..max_players) |i| {
            if (i == me or !m.is_present(i)) continue;
            if (best == null or m.frags[i] > best.?) best = m.frags[i];
        }
        const b = best orelse return;
        const lead = b < m.frags[me] or (b == m.frags[me] and rank == 1);
        cart.text(.{ .str = if (lead) "2ND" else "TOP", .x = 96, .y = y2, .text_color = hud.grey });
        hud.text_right(hud.signed(&buf, b), 159, y2, hud.anti_white);
        return;
    }
    const n: i32 = @min(m.teams, state.max_teams);
    const cell: i32 = @divTrunc(64, n);
    for (0..@intCast(n)) |t| {
        const x0: i32 = 96 + cell * @as(i32, @intCast(t));
        const c = slots.team_color(t);
        // Four 16 px cells cannot hold two 8 px digits apart: 3x5 digits.
        if (n > 2) small_signed(m.team_frags[t], x0 + cell - 2, y2, c) else hud.text_right(hud.signed(&buf, m.team_frags[t]), x0 + cell - 1, y2, c);
        if (m.team[me] == t) cart.rect(.{ .x = x0 + 1, .y = y2 + 8, .width = @intCast(cell - 2), .height = 1, .fill_color = c });
    }
}

/// `v` (clamped to -99..99) in the 3x5 digits, right edge at `x1`, top
/// at `y` (7 px tall with the Anti-black margin), a 2 px minus if negative.
fn small_signed(v: i16, x1: i32, y: i32, c: cart.DisplayColor) void {
    const mag: u8 = @intCast(@min(@abs(v), 99));
    const w = slots.small_width(mag) + 2;
    const x = x1 + 1 - w;
    const px: cart.Pixel = .from_color(c);
    slots.small_number_flat(mag, x, y, px, .from_color(hud.anti_black));
    if (v < 0) cart.rect(.{ .x = x - 2, .y = y + 3, .width = 2, .height = 1, .fill_color = c });
}

// ---------------------------------------------------------------- kill feed

/// The latest death as one line at the top of the view for `feed_ticks`:
/// "FRAGGED P7" (you did it), "P7 FRAGGED YOU", "P7 FRAGGED P3",
/// "P3 SELF-FRAG", "BUGS GOT P3", and "SELF-FRAG -1" / "EATEN BY BUGS"
/// for you. Names in their slot colours. `tick` = the World's tick.
pub fn draw_kill_feed(m: *const Match, me: usize, names: []const []const u8, tick: u32) void {
    if (m.kill_tick == state.no_shot or tick -% m.kill_tick >= feed_ticks) return;
    if (m.victim >= max_players) return;
    const v: usize = m.victim;
    const k: usize = m.killer;
    const by_player = k < max_players;
    var line: Line = .{};
    if (v == me) {
        if (k == me) {
            line.add("SELF-FRAG -1", hud.coral);
        } else if (by_player) {
            line.name(m, names, k);
            line.add(" FRAGGED YOU", hud.coral);
        } else {
            line.add("EATEN BY BUGS", hud.coral);
        }
    } else if (k == me) {
        line.add("FRAGGED ", hud.green);
        line.name(m, names, v);
    } else if (k == v) {
        line.name(m, names, v);
        line.add(" SELF-FRAG", hud.grey);
    } else if (by_player) {
        line.name(m, names, k);
        line.add(" FRAGGED ", hud.grey);
        line.name(m, names, v);
    } else {
        line.add("BUGS GOT ", hud.grey);
        line.name(m, names, v);
    }
    cart.rect(.{ .x = 0, .y = 0, .width = 160, .height = 10, .fill_color = hud.anti_black });
    line.draw(1);
}

/// One line of coloured pieces, centred, at most 20 characters.
const Line = struct {
    str: [20]u8 = undefined,
    len: usize = 0,
    ends: [4]usize = undefined,
    colors: [4]cart.DisplayColor = undefined,
    n: usize = 0,

    fn add(l: *Line, s: []const u8, c: cart.DisplayColor) void {
        if (l.n == l.ends.len) return;
        const take = @min(s.len, l.str.len - l.len);
        @memcpy(l.str[l.len..][0..take], s[0..take]);
        l.len += take;
        l.ends[l.n] = l.len;
        l.colors[l.n] = c;
        l.n += 1;
    }

    /// A slot's name, cut to 5 characters so "NAME FRAGGED NAME" fits.
    fn name(l: *Line, m: *const Match, names: []const []const u8, slot: usize) void {
        var buf: [4]u8 = undefined;
        const s = slots.name(names, slot, &buf);
        l.add(s[0..@min(s.len, 5)], slots.slot_color(m, slot));
    }

    fn draw(l: *const Line, y: i32) void {
        var x: i32 = 80 - @as(i32, @intCast(l.len * 4));
        var start: usize = 0;
        for (l.ends[0..l.n], l.colors[0..l.n]) |end, c| {
            cart.text(.{ .str = l.str[start..end], .x = x, .y = y, .text_color = c });
            x += @intCast((end - start) * 8);
            start = end;
        }
    }
};

// ---------------------------------------------------------------- tables

/// Hold Select in a match: every present player, best first (grouped by
/// team, best team first, in team modes), over the view and the bar.
/// Line 1: "FRAGS TO n" (FFA) or the team totals; line 2: the column
/// labels; then 7 px rows: place, colour swatch, name (bots in steel),
/// frags, deaths, accuracy. Your row is highlighted.
pub fn draw_scoreboard(m: *const Match, me: usize, names: []const []const u8) void {
    const n: i32 = slots.present_count(m);
    cart.rect(.{ .x = 0, .y = 0, .width = 160, .height = @intCast(@min(128, 16 + n * row_height(n, 16))), .fill_color = hud.anti_black });
    if (m.teams != 0) {
        draw_team_totals(m, me, 0);
    } else {
        var buf: [16]u8 = undefined;
        hud.centered(fmt(&buf, "FRAGS TO {d}", .{m.frag_limit}), 0, hud.iris);
    }
    draw_labels(8);
    _ = draw_rows(m, me, names, 16);
}

/// The results' table under the lead's title line: in team modes the team
/// totals first, then the column labels and the rows as the scoreboard.
/// Starts at `y0` (8 leaves the top line for the title); with 16 players
/// in a team mode the labels give way so the rows fit. Returns the y
/// under the last row (room left for "PRESS A" when it is <= 120).
pub fn draw_results_table(m: *const Match, me: usize, names: []const []const u8, y0: i32) i32 {
    const n: i32 = slots.present_count(m);
    var y = y0;
    if (m.teams != 0) {
        draw_team_totals(m, me, y);
        y += 8;
    }
    if (y + 8 + n * row_h <= 128) {
        draw_labels(y);
        y += 8;
    }
    return draw_rows(m, me, names, y);
}

/// The team totals across the line, best team first, each in its colour:
/// "RED 12  BLUE 9" (2 teams) or "R 12 B 9 G 4 G 7" (4 teams); your
/// team underlined.
fn draw_team_totals(m: *const Match, me: usize, y: i32) void {
    var order: [state.max_teams]u8 = undefined;
    const nt = slots.sorted_teams(m, &order);
    if (nt == 0) return;
    const cell: i32 = @divTrunc(160, nt);
    var buf: [8]u8 = undefined;
    for (order[0..nt], 0..) |t, i| {
        const x0: i32 = cell * @as(i32, @intCast(i));
        const c = slots.team_color(t);
        const label = if (nt <= 2) slots.team_names[t] else slots.team_names[t][0..1];
        cart.text(.{ .str = label, .x = x0 + 2, .y = y, .text_color = c });
        hud.text_right(hud.signed(&buf, m.team_frags[t]), x0 + cell - 4, y, c);
        if (m.team[me] == t) cart.rect(.{ .x = x0 + 2, .y = y + 7, .width = @intCast(cell - 6), .height = 1, .fill_color = c });
    }
}

// Column right edges (x of the last pixel) and the name's left edge.
const col_place: i32 = 15;
const col_swatch: i32 = 18;
const col_name: i32 = 25;
const col_frags: i32 = 100;
const col_deaths: i32 = 127;
const col_acc: i32 = 159;

fn draw_labels(y: i32) void {
    cart.text(.{ .str = "PLAYER", .x = col_name, .y = y, .text_color = hud.steel });
    hud.text_right("FRG", col_frags, y, hud.steel);
    hud.text_right("DTH", col_deaths, y, hud.steel);
    hud.text_right("ACC", col_acc, y, hud.steel);
}

fn draw_rows(m: *const Match, me: usize, names: []const []const u8, y0: i32) i32 {
    var order: [max_players]u8 = undefined;
    const n = slots.sorted(m, &order);
    const rh = row_height(n, y0);
    var y = y0;
    var buf: [8]u8 = undefined;
    var nbuf: [4]u8 = undefined;
    for (order[0..n], 0..) |slot, row| {
        if (y + row_h > 128) break;
        const mine = slot == me;
        // Every other row on a dark stripe: the 7 px rows touch.
        if (mine or row % 2 == 1) cart.rect(.{ .x = 0, .y = y, .width = 160, .height = @intCast(rh), .fill_color = if (mine) hud.steel else hud.trough });
        const ink = if (mine) hud.anti_white else hud.grey;
        // Place by frags among everyone (ties share it); in team modes the
        // rows go by team, so the swatch says it all.
        if (m.teams == 0) hud.text_right(fmt(&buf, "{d}", .{slots.rank_of(m, slot)}), col_place, y, ink);
        cart.rect(.{ .x = col_swatch, .y = y + 1, .width = 5, .height = 5, .fill_color = slots.slot_color(m, slot) });
        const name_ink = if (mine) hud.anti_white else if (m.is_bot(slot)) hud.steel else hud.anti_white;
        cart.text(.{ .str = slots.name(names, slot, &nbuf), .x = col_name, .y = y, .text_color = name_ink });
        hud.text_right(hud.signed(&buf, m.frags[slot]), col_frags, y, hud.anti_white);
        hud.text_right(fmt(&buf, "{d}", .{m.deaths[slot]}), col_deaths, y, ink);
        hud.text_right(fmt(&buf, "{d}%", .{accuracy(m, slot)}), col_acc, y, ink);
        y += rh;
    }
    return y;
}

/// Shots that hit a player, in percent of shots fired.
pub fn accuracy(m: *const Match, slot: usize) u32 {
    if (m.shots[slot] == 0) return 0;
    return @as(u32, m.hits[slot]) * 100 / m.shots[slot];
}
