//! New for Snouty GC (M5): the CIRCUIT's cards between races (SPEC 8.2,
//! 9.1). The standings after each race (the league table with this race's
//! points, and what the race paid the player in CYCLES), the league card
//! when a league's third race is booked (won, on the podium, or out of it
//! and replayed), the unlock card when the next league opens (drawn over
//! that league's own floor by main.zig), and the end card of the SNOUTY
//! GCP. Draw only: career.zig holds the numbers.
const cart = @import("cart-api");
const racers = @import("racers.zig");
const track = @import("track.zig");
const tuning = @import("tuning.zig");
const career = @import("career.zig");
const roster_text = @import("roster_text.zig");
const sprites = @import("sprites.zig");
const hud = @import("hud.zig");

const panel = cart.DisplayColor.rgb(0x2A2236);
const rule = cart.DisplayColor.rgb(0x464056);

/// A line of text built in place (no allocation).
const Line = struct {
    buf: [20]u8 = undefined,
    len: usize = 0,

    fn add(self: *Line, s: []const u8) *Line {
        const n = @min(s.len, self.buf.len - self.len);
        @memcpy(self.buf[self.len..][0..n], s[0..n]);
        self.len += n;
        return self;
    }
    fn num(self: *Line, v: u32) *Line {
        var tmp: [10]u8 = undefined;
        hud.put_uint(&tmp, v, ' ');
        var i: usize = 0;
        while (i + 1 < tmp.len and tmp[i] == ' ') i += 1;
        return self.add(tmp[i..]);
    }
    fn str(self: *const Line) []const u8 {
        return self.buf[0..self.len];
    }
};

fn blink(frame: u32) bool {
    return (frame / 30) % 2 == 0;
}

/// After each CIRCUIT race: the league table (place, livery, name, this
/// race's points, the total) and the player's CYCLES.
pub fn draw_standings(c: *const career.Career, frame: u32) void {
    hud.fill_rect(0, 0, 160, 128, hud.anti_black);
    hud.centered("STANDINGS", 2, hud.cyan);
    const lg = track.leagues[c.league % track.leagues.len];
    var head = Line{};
    _ = head.add(lg.name).add(" ").num(c.race).add("/3");
    hud.centered(head.str(), 11, hud.grey);
    const order = c.standings();
    for (order, 0..) |r, k| {
        const y: i32 = 22 + @as(i32, @intCast(k)) * 10;
        if (r == c.racer) hud.fill_rect(4, y - 1, 152, 10, panel);
        var pos: [1]u8 = .{'1' + @as(u8, @intCast(k))};
        hud.text(&pos, 6, y, if (k < tuning.league_clear) hud.cyan else hud.white);
        hud.fill_rect(18, y, 4, 8, hud.livery(r));
        hud.text(racers.roster[r].name, 26, y, hud.livery(r));
        var gain = Line{};
        _ = gain.add("+").num(c.last.points[r]);
        hud.text(gain.str(), 104, y, hud.green);
        var tot = Line{};
        _ = tot.num(c.points[r]);
        hud.text(tot.str(), 156 - @as(i32, @intCast(tot.len * 8)), y, hud.white);
    }
    hud.fill_rect(4, 84, 152, 1, rule);
    const a = c.last;
    var l1 = Line{};
    _ = l1.add(hud.rank_text(a.place)).add(" +").num(a.place_cycles);
    if (a.kills > 0) _ = l1.add("  ").num(a.kills).add("K +").num(a.kill_cycles);
    hud.text(l1.str(), 4, 88, hud.white);
    var l2 = Line{};
    _ = l2.num(a.chips).add(" CHIPS +").num(a.chip_cycles);
    hud.text(l2.str(), 4, 97, hud.white);
    var l3 = Line{};
    _ = l3.add("+").num(a.total).add(" CYCLES");
    hud.text(l3.str(), 4, 107, hud.yellow);
    var l4 = Line{};
    _ = l4.add("WALLET ").num(c.cycles);
    hud.text(l4.str(), 4, 117, hud.grey);
    if (blink(frame)) hud.text("A", 148, 117, hud.coral);
}

/// The taunt in quotes, wrapped at 19, centred on rows y and y + 9.
fn quote(r: u8, y: i32, color: cart.DisplayColor) void {
    const taunt = roster_text.roster[r].taunt;
    var q = Line{};
    _ = q.add("\"").add(taunt).add("\"");
    const s = q.str();
    const k = roster_text.wrap(s, 19);
    hud.centered(s[0..k], y, color);
    if (k < s.len) hud.centered(s[k + 1 ..], y + 9, color);
}

/// A league's end: the Prix won (the 1500), a podium place (the next
/// league opens), or out of the top 3 (the league again, CYCLES kept);
/// the league champion's portrait and taunt.
pub fn draw_league(c: *const career.Career, frame: u32) void {
    hud.fill_rect(0, 0, 160, 128, hud.anti_black);
    // `close_league` has moved on: the league just closed is the one
    // before, unless it was failed (replayed) or the last.
    const closed = if (c.unlocked) c.league - 1 else c.league;
    var head = Line{};
    _ = head.add(track.leagues[closed % track.leagues.len].name).add(" PRIX");
    hud.centered(head.str(), 3, hud.cyan);
    var res = Line{};
    switch (c.outcome) {
        .won => _ = res.add("PRIX WON!"),
        .cleared => _ = res.add("PODIUM: ").add(hud.rank_text(c.league_place)),
        .failed => _ = res.add(hud.rank_text(c.league_place)).add(": NO PODIUM"),
    }
    hud.centered(res.str(), 13, if (c.outcome == .failed) hud.coral else if (blink(frame)) hud.yellow else hud.white);
    const ch = c.champion;
    hud.fill_rect(54, 24, 52, 52, hud.livery(ch));
    sprites.blit_at(&sprites.portraits[ch], 0, 56, 26, .{});
    var name = Line{};
    _ = name.add("CHAMPION ").add(racers.roster[ch].name);
    hud.centered(name.str(), 79, hud.livery(ch));
    quote(ch, 89, hud.white);
    switch (c.outcome) {
        .won, .cleared => {
            if (c.outcome == .won) hud.centered("+1500 CYCLES", 108, hud.yellow);
            if (c.unlocked) {
                var open = Line{};
                _ = open.add(track.leagues[c.league % track.leagues.len].name).add(" OPENS");
                hud.centered(open.str(), 118, hud.green);
            } else hud.centered("THE FENCE IS NEAR", 118, hud.green);
        },
        .failed => {
            hud.centered("TOP 3 GO ON. AGAIN!", 108, hud.white);
            hud.centered("CYCLES KEPT", 118, hud.grey);
        },
    }
}

/// The next league opens (drawn over its floor, the caller's backdrop).
pub fn draw_unlock(c: *const career.Career, frame: u32) void {
    hud.fill_rect(0, 34, 160, 94, hud.anti_black);
    hud.centered("NEW PRIX UNLOCKED", 38, if (blink(frame)) hud.yellow else hud.white);
    const lg = track.leagues[c.league % track.leagues.len];
    hud.glyph_text(lg.name, 80 - @as(i32, @intCast(lg.name.len * 8)) + 1, 49, 2, false, hud.coral);
    hud.glyph_text(lg.name, 80 - @as(i32, @intCast(lg.name.len * 8)), 48, 2, false, hud.white);
    const first = c.league * track.tracks_per_league;
    for (0..track.tracks_per_league) |k| {
        hud.centered(track.tracks[first + k].name, 70 + @as(i32, @intCast(k)) * 10, hud.cyan);
    }
    hud.centered(if (c.league == 1) "MIND THE VENTS" else "MIND THE SWEEPER", 102, hud.coral);
    if (blink(frame)) hud.centered("A TO THE GARAGE", 118, hud.white);
}

const fence_px: cart.Pixel = .from_color(.rgb(0x2C2A34));
const post_px: cart.Pixel = .from_color(.rgb(0x46424E));

/// The SNOUTY GCP's end (SPEC 8.2): the fence the Hyperscalers put up,
/// the player's portrait, the line, the Prix in numbers.
pub fn draw_end(c: *const career.Career, frame: u32) void {
    hud.fill_rect(0, 0, 160, 128, hud.anti_black);
    // A chain-link fence over the whole card, posts every 40 px: per
    // column, the two diagonals' pixels every 10 rows (x + y and x - y
    // multiples of 10), no per-pixel test (the bench's worst card).
    for (0..160) |x| {
        const col = &cart.framebuffer[x];
        if (x % 40 == 20) {
            @memset(col, post_px);
            continue;
        }
        const m = x % 10;
        var y: usize = (10 - m) % 10;
        while (y < 128) : (y += 10) col[y] = fence_px;
        y = m;
        while (y < 128) : (y += 10) col[y] = fence_px;
    }
    hud.centered("SNOUTY GCP", 3, hud.cyan);
    hud.centered("PRIX COMPLETE", 12, if (blink(frame)) hud.yellow else hud.white);
    const r = c.racer;
    hud.fill_rect(63, 22, 34, 34, hud.livery(r));
    sprites.blit_rect(&sprites.portraits[r], 0, 0, 48, 48, 64, 23, 32, 32, .{});
    const lines = [_][]const u8{ "YOU REACHED THE", "FENCE. THE", "HYPERSCALERS DID", "NOT NOTICE." };
    for (lines, 0..) |l, k| hud.centered(l, 61 + @as(i32, @intCast(k)) * 9, hud.white);
    var s1 = Line{};
    _ = s1.num(c.races).add(" RACES ").num(c.wins).add(" WINS");
    hud.centered(s1.str(), stats_y, hud.grey);
    var s2 = Line{};
    _ = s2.num(c.kills).add(" KILLS ").num(c.cycles).add(" CYC");
    hud.centered(s2.str(), stats_y + 9, hud.grey);
    if (blink(frame)) hud.centered("A", 118, hud.coral);
}
const stats_y: i32 = 101;
