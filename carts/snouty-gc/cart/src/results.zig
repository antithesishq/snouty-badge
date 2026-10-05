//! Forked from snouty-zero/cart/src/results.zig at f8f6962.
//! The results (SPEC 8.2), two cards. First the winner: full-size
//! portrait, name, car, time, kills and their taunt, and the followed
//! car's own place and best lap under it. Then the field by rank, each row
//! with the racer's half-scale portrait (the 24x16 face band of it: six
//! 24-row portraits do not fit 128 px), name and best lap, finish time,
//! kills and wrecks. CYCLES join in the career (M5). M3: GARBAGE
//! COLLECTION's survivor card (`LAST PROCESS RUNNING`, the winner's full
//! portrait and taunt, the sweeps survived) and its table in collection
//! order (a collected car's rank is its place), each row saying at which
//! sweep the car was freed or that it went out wrecked. Draw only.
const cart = @import("cart-api");
const world = @import("world.zig");
const racers = @import("racers.zig");
const roster_text = @import("roster_text.zig");
const sprites = @import("sprites.zig");
const hud = @import("hud.zig");
const fx = @import("fx.zig");

const panel = cart.DisplayColor.rgb(0x2A2236);

fn car_of_rank(w: *const world.World, r: u8) ?usize {
    for (&w.cars, 0..) |*c, i| {
        if (c.rank == r) return i;
    }
    return null;
}

/// Writes "K<kills> W<wrecks>" into `buf`, returns the used part.
fn tally(buf: *[8]u8, kills: u8, wrecks: u8) []const u8 {
    var n: usize = 0;
    buf[n] = 'K';
    n += 1;
    n += put(buf[n..], kills);
    buf[n] = ' ';
    n += 1;
    buf[n] = 'W';
    n += 1;
    n += put(buf[n..], wrecks);
    return buf[0..n];
}

/// GARBAGE COLLECTION table, line 2: `SURVIVOR`, `SWEEP n` (collected at
/// sweep n), `WRECKED` (collected for a wreck while marked).
fn gc_line(w: *const world.World, i: usize, y: i32) void {
    if (i == w.gc.survivor) return hud.text("SURVIVOR", 42, y, hud.cyan);
    if (fx.freed_sweep[i] == 0) return hud.text("RUNNING", 42, y, hud.grey);
    if (fx.freed_cause[i] == .wreck) return hud.text("WRECKED", 42, y, hud.coral);
    var buf: [8]u8 = "SWEEP   ".*;
    const n = put(buf[6..], fx.freed_sweep[i]);
    hud.text(buf[0 .. 6 + n], 42, y, hud.white);
}

fn put(out: []u8, v: u8) usize {
    if (v >= 10) {
        out[0] = '0' + @as(u8, @min(9, v / 10));
        out[1] = '0' + v % 10;
        return 2;
    }
    out[0] = '0' + @as(u8, v);
    return 1;
}

/// Winner's card.
pub fn draw_winner(w: *const world.World, follow: u8, frame: u32) void {
    if (w.mode == .gc) return draw_survivor(w, follow, frame);
    hud.fill_rect(0, 0, 160, 128, hud.anti_black);
    const wi = car_of_rank(w, 1) orelse follow;
    const win = &w.cars[wi];
    const r = win.racer % racers.count;
    const liv = hud.livery(r);
    hud.centered("WINNER", 4, hud.cyan);
    hud.fill_rect(4, 16, 50, 50, liv);
    sprites.blit_at(&sprites.portraits[r], 0, 5, 17, .{});
    hud.text(racers.roster[r].name, 60, 18, liv);
    hud.text(racers.roster[r].car, 60, 28, hud.white);
    var clock: [7]u8 = undefined;
    if (win.finished) {
        hud.format_clock(&clock, win.finish_tick);
        hud.text(&clock, 60, 40, hud.white);
    }
    var kbuf: [8]u8 = undefined;
    hud.text(tally(&kbuf, win.kills, win.wrecks), 60, 52, hud.grey);
    // The taunt, in quotes, wrapped at 17 characters.
    const taunt = roster_text.roster[r].taunt;
    var q: [24]u8 = undefined;
    q[0] = '"';
    @memcpy(q[1..][0..taunt.len], taunt);
    q[taunt.len + 1] = '"';
    const quoted = q[0 .. taunt.len + 2];
    const k = roster_text.wrap(quoted, 19);
    hud.centered(quoted[0..k], 74, hud.white);
    if (k < quoted.len) hud.centered(quoted[k + 1 ..], 84, hud.white);
    // The followed car's own result.
    const me = &w.cars[follow % world.car_count];
    if (wi != follow) {
        var line: [16]u8 = undefined;
        const name = racers.roster[me.racer % racers.count].name;
        @memcpy(line[0..name.len], name);
        line[name.len] = ' ';
        @memcpy(line[name.len + 1 ..][0..3], hud.rank_text(me.rank));
        hud.centered(line[0 .. name.len + 4], 98, hud.livery(me.racer));
    }
    if (me.best_lap > 0) {
        var best: [16]u8 = "BEST LAP        ".*;
        hud.format_clock(best[9..16], me.best_lap);
        hud.centered(&best, 108, hud.grey);
    }
    if ((frame / 30) % 2 == 0) hud.centered("A", 118, hud.coral);
}

/// The taunt in quotes, wrapped at 19, centred on rows y and y + 9.
fn quote(r: u8, y: i32) void {
    const taunt = roster_text.roster[r].taunt;
    var q: [24]u8 = undefined;
    q[0] = '"';
    @memcpy(q[1..][0..taunt.len], taunt);
    q[taunt.len + 1] = '"';
    const quoted = q[0 .. taunt.len + 2];
    const k = roster_text.wrap(quoted, 19);
    hud.centered(quoted[0..k], y, hud.white);
    if (k < quoted.len) hud.centered(quoted[k + 1 ..], y + 9, hud.white);
}

/// GARBAGE COLLECTION (SPEC 8.2): the last car running, full portrait,
/// `LAST PROCESS RUNNING`, its taunt; the player's own place under it.
fn draw_survivor(w: *const world.World, follow: u8, frame: u32) void {
    hud.fill_rect(0, 0, 160, 128, hud.anti_black);
    const wi: usize = if (w.gc.survivor < world.car_count) w.gc.survivor else car_of_rank(w, 1) orelse follow;
    const win = &w.cars[wi];
    const r = win.racer % racers.count;
    const liv = hud.livery(r);
    hud.centered("LAST PROCESS", 4, hud.cyan);
    hud.centered("RUNNING", 13, if ((frame / 20) % 2 == 0) hud.cyan else hud.white);
    hud.fill_rect(4, 24, 50, 50, liv);
    sprites.blit_at(&sprites.portraits[r], 0, 5, 25, .{});
    hud.text(racers.roster[r].name, 60, 26, liv);
    hud.text(racers.roster[r].car, 60, 36, hud.white);
    var sw: [9]u8 = "SWEEPS   ".*;
    const n = put(sw[7..], w.gc.sweeps);
    hud.text(sw[0 .. 7 + n], 60, 48, hud.grey);
    var kbuf: [8]u8 = undefined;
    hud.text(tally(&kbuf, win.kills, win.wrecks), 60, 60, hud.grey);
    quote(r, 80);
    const me = &w.cars[follow % world.car_count];
    if (wi != follow) {
        var line: [16]u8 = undefined;
        const name = racers.roster[me.racer % racers.count].name;
        @memcpy(line[0..name.len], name);
        line[name.len] = ' ';
        @memcpy(line[name.len + 1 ..][0..3], hud.rank_text(me.rank));
        hud.centered(line[0 .. name.len + 4], 102, hud.livery(me.racer));
    }
    if ((frame / 30) % 2 == 0) hud.centered("A", 116, hud.coral);
}

/// The field by rank.
pub fn draw_table(w: *const world.World, follow: u8, frame: u32) void {
    _ = frame;
    hud.fill_rect(0, 0, 160, 128, hud.anti_black);
    hud.centered("RESULTS", 4, hud.cyan);
    var r: u8 = 1;
    while (r <= world.car_count) : (r += 1) {
        const i = car_of_rank(w, r) orelse continue;
        const c = &w.cars[i];
        const racer = c.racer % racers.count;
        const y: i32 = 14 + @as(i32, r - 1) * 18;
        if (i == follow) hud.fill_rect(4, y - 1, 152, 18, panel);
        var pos: [1]u8 = .{'0' + r};
        hud.text(&pos, 4, y + 4, if (r == 1) hud.cyan else hud.white);
        // Half scale: rows 8..39 of the 48x48 portrait into 24x16.
        sprites.blit_rect(&sprites.portraits[racer], 0, 8, 48, 32, 14, y, 24, 16, .{});
        hud.text(racers.roster[racer].name, 42, y, hud.livery(racer));
        // Line 1 right: the best lap as SS"CC (laps are under a minute).
        if (c.best_lap > 0) {
            var best: [7]u8 = undefined;
            hud.format_clock(&best, c.best_lap);
            hud.text(best[2..], 156 - 5 * 8, y, hud.grey);
        }
        // Line 2: the finish time (or the lap reached), kills and wrecks;
        // GARBAGE COLLECTION: SURVIVOR, or the sweep it was freed at.
        var clock: [7]u8 = undefined;
        if (w.mode == .gc) {
            gc_line(w, i, y + 9);
        } else if (c.finished) {
            hud.format_clock(&clock, c.finish_tick);
            hud.text(&clock, 42, y + 9, hud.white);
        } else {
            var lap: [5]u8 = "LAP 1".*;
            lap[4] = @as(u8, '1') + @min(c.lap, 2);
            hud.text(&lap, 42, y + 9, hud.grey);
        }
        var kbuf: [8]u8 = undefined;
        const t = tally(&kbuf, c.kills, c.wrecks);
        hud.text(t, 156 - @as(i32, @intCast(t.len)) * 8, y + 9, hud.grey);
    }
}
