//! The deathmatch motion tracker's memory (M9.3, PLAN.md; drawn by
//! `render/tracker.zig`). Render-only: it reads the Match once per stepped
//! tick and never writes it, so the World, its hash and the lockstep are
//! untouched. Pure Zig (no cart API).
//!
//! A living rival that moved or fired in the last `loud_ticks` is loud. A
//! pulse grows from the viewer to `range` cells once every `period` ticks;
//! when it passes a loud rival, the rival's blip is placed where it stands
//! and stays there (in the world) until the next pulse finds it again.
const std = @import("std");
const state = @import("state.zig");
const fixed = @import("fixed.zig");
const Fixed = fixed.Fixed;

const max = state.max_players;

/// Ticks of quiet before a rival drops off the tracker (2 s).
pub const loud_ticks: u32 = 120;
/// One pulse a second.
pub const period: u32 = 60;
/// Cells from the centre to the rim (1 px a cell on screen).
pub const range: i32 = 11;
/// Blips are placed only this far out so they stay inside the rim.
const reach: Fixed = fixed.from_int(range) - fixed.half;
const never: u32 = 0xFFFF_FFFF;

pub const Blip = struct {
    x: Fixed,
    y: Fixed,
    /// The tick the pulse found it.
    tick: u32,
};

pub const Memory = struct {
    last_x: [max]Fixed = @splat(0),
    last_y: [max]Fixed = @splat(0),
    last_shots: [max]u16 = @splat(0),
    /// The latest tick each slot moved or fired (`never`: not yet).
    loud_at: [max]u32 = @splat(never),
    blips: [max]?Blip = @splat(null),
    /// The tick `tick` last ran on (`never` right after `reset`).
    seen: u32 = never,

    pub fn reset(r: *Memory) void {
        r.* = .{};
    }

    /// Once per stepped tick (`now` = `GameState.tick`), viewed from slot `me`.
    pub fn tick(r: *Memory, m: *const state.Match, me: usize, now: u32) void {
        const first = r.seen == never;
        if (!first and now == r.seen) return;
        // Pulse ticks in (seen, now]; everything when this is the first
        // tick or a whole period went by.
        const all = first or now -% r.seen >= period;
        const p = &m.players[me];
        for (0..max) |i| {
            if (m.present >> @intCast(i) & 1 == 0) continue;
            const o = &m.players[i];
            if (!first and (o.x != r.last_x[i] or o.y != r.last_y[i] or m.shots[i] != r.last_shots[i])) r.loud_at[i] = now;
            r.last_x[i] = o.x;
            r.last_y[i] = o.y;
            r.last_shots[i] = m.shots[i];
            if (i == me or m.dead[i] > 0) continue;
            if (r.loud_at[i] == never or now -% r.loud_at[i] >= loud_ticks) continue;
            const hit = pulse_tick(o.x - p.x, o.y - p.y) orelse continue;
            // The latest tick <= now whose phase is `hit`.
            const h = now -% ((now % period + period - hit) % period);
            if (all or h -% r.seen -% 1 < now -% r.seen) r.blips[i] = .{ .x = o.x, .y = o.y, .tick = h };
        }
        r.seen = now;
    }
};

/// The phase (0..period-1) at which the pulse reaches a rival at offset
/// (dx, dy) cells, or null beyond `reach`.
pub fn pulse_tick(dx: Fixed, dy: Fixed) ?u32 {
    const d2: u64 = @intCast(@as(i64, dx) * dx + @as(i64, dy) * dy);
    if (d2 >= @as(u64, @intCast(reach)) * @as(u64, @intCast(reach))) return null;
    const d: u64 = std.math.sqrt(d2); // 16.16
    const range_fx: u64 = @intCast(fixed.from_int(range));
    // ceil(d * period / range), at most period - 1 inside `reach`.
    return @intCast(@min((d * period + range_fx - 1) / range_fx, period - 1));
}

/// A world position relative to the viewer at (px, py) facing `a`, as
/// tracker pixels from the centre: right and up (forward), rounded.
pub fn to_screen(x: Fixed, y: Fixed, px: Fixed, py: Fixed, a: fixed.Angle) [2]i32 {
    const rx: i64 = x - px;
    const ry: i64 = y - py;
    const c: i64 = fixed.cos(a);
    const s: i64 = fixed.sin(a);
    const fwd = (rx * c + ry * s) >> 16;
    const right = (ry * c - rx * s) >> 16;
    return .{ @intCast((right + fixed.half) >> 16), @intCast((fwd + fixed.half) >> 16) };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn two_players() state.Match {
    var m: state.Match = std.mem.zeroes(state.Match);
    m.present = 0b11;
    m.players[0] = .{ .x = fixed.from_int(10), .y = fixed.from_int(10), .angle = 0 };
    m.players[1] = .{ .x = fixed.from_int(15), .y = fixed.from_int(10), .angle = 0 };
    return m;
}

fn run(r: *Memory, m: *state.Match, from: u32, to: u32, move: bool) void {
    var t = from;
    while (t < to) : (t += 1) {
        if (move) m.players[1].y +%= fixed.from_float(0.01);
        r.tick(m, 0, t);
    }
}

test "a still rival never shows; a moving one shows where the pulse found it" {
    var m = two_players();
    var r: Memory = .{};
    run(&r, &m, 0, 300, false);
    try testing.expect(r.blips[1] == null);
    // Five cells out: the pulse reaches it at phase ceil(5 * 60 / 11) = 28.
    try testing.expectEqual(@as(?u32, 28), pulse_tick(fixed.from_int(5), 0));
    run(&r, &m, 300, 360, true);
    const b = r.blips[1].?;
    try testing.expectEqual(@as(u32, 328), b.tick);
    try testing.expect(b.y > fixed.from_int(10));
    // The blip stays put until the next pulse.
    const y_found = b.y;
    run(&r, &m, 360, 387, true);
    try testing.expectEqual(y_found, r.blips[1].?.y);
    run(&r, &m, 387, 389, true);
    try testing.expectEqual(@as(u32, 388), r.blips[1].?.tick);
    try testing.expect(r.blips[1].?.y > y_found);
}

test "quiet for 2 s drops off; firing makes noise; out of range and the dead never show" {
    var m = two_players();
    var r: Memory = .{};
    run(&r, &m, 0, 61, true);
    try testing.expect(r.blips[1] != null);
    const last = r.blips[1].?.tick;
    // Stops: still found while loud, then no new detections.
    run(&r, &m, 61, 400, false);
    try testing.expect(r.blips[1].?.tick <= 60 + loud_ticks + period);
    try testing.expect(r.blips[1].?.tick >= last);
    const stale = r.blips[1].?.tick;
    m.shots[1] += 1;
    run(&r, &m, 400, 461, false);
    try testing.expect(r.blips[1].?.tick > stale);
    // Out of range.
    var far = two_players();
    far.players[1].x = fixed.from_int(10 + range);
    var r2: Memory = .{};
    run(&r2, &far, 0, 200, true);
    try testing.expect(r2.blips[1] == null);
    // Dead.
    var dead = two_players();
    dead.dead[1] = 100;
    var r3: Memory = .{};
    run(&r3, &dead, 0, 200, true);
    try testing.expect(r3.blips[1] == null);
}

test "skipped ticks still catch the pulse" {
    var m = two_players();
    var r: Memory = .{};
    run(&r, &m, 0, 10, true);
    // Jump over phase 28 in one step.
    m.players[1].y +%= fixed.from_float(0.01);
    r.tick(&m, 0, 40);
    try testing.expectEqual(@as(u32, 28), r.blips[1].?.tick);
}

test "to_screen: up is forward, right is right" {
    const p = fixed.from_int(10);
    // Facing east (+x): a rival east is straight up, one south is right.
    try testing.expectEqual([2]i32{ 0, 5 }, to_screen(fixed.from_int(15), p, p, p, 0));
    try testing.expectEqual([2]i32{ 3, 0 }, to_screen(p, fixed.from_int(13), p, p, 0));
    // Facing south (+y): the rival east is now on the left.
    try testing.expectEqual([2]i32{ -5, 0 }, to_screen(fixed.from_int(15), p, p, p, fixed.angle_quarter));
}
