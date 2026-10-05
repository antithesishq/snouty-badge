//! GARBAGE COLLECTION, mark and sweep (SPEC 8.2, M3), and the attract
//! demo's scripted KERNEL PANIC. New for Snouty GC.
//!
//! Sweep points are the sector 2 line (sample 170) and the start line, as
//! the race leader passes them. At each one the MARKED car is COLLECTED
//! (it leaves the race) and then the new last car is marked; the first
//! sweep only marks. The marked car passes the mark on by landing a weapon
//! hit on another car (a tag; rams do not count), once it has carried the
//! mark `tuning.gc_tag_grace` ticks; a wreck while marked is an immediate
//! collection. The last car running wins. With six cars that is five
//! collections, so the leader sees about three laps.
//!
//! Part of `sim.simulate`, so pure in the World: no cart API, no clock, no
//! floats, no globals.
const std = @import("std");
const fixed = @import("fixed.zig");
const tuning = @import("tuning.zig");
const world = @import("world.zig");
const sim = @import("sim.zig");
const weapons = @import("weapons.zig");
const pickups = @import("pickups.zig");

const World = world.World;
const no_car = world.no_car;

/// Fine progress (`sim.fine_progress`) of sweep point `k`: sample 170 of
/// lap k / 2 for even k, the start of lap (k + 1) / 2 for odd k.
pub fn sweep_at(k: u8) i32 {
    const lap: i32 = (@as(i32, k) + 1) >> 1;
    return if (k % 2 == 0) lap * 65536 + 170 * 256 else lap * 65536;
}

/// Cars still in the race.
pub fn active_count(w: *const World) u8 {
    var n: u8 = 0;
    for (&w.cars) |*c| n += @intFromBool(c.active);
    return n;
}

/// One racing tick, after the ranks: run the sweeps the leader has passed.
pub fn update(w: *World) void {
    if (w.mode != .gc or w.phase != .racing) return;
    w.gc.mark_ticks +|= 1;
    while (w.gc.survivor == no_car) {
        var lead: i32 = std.math.minInt(i32);
        for (&w.cars) |*c| {
            if (c.active) lead = @max(lead, sim.fine_progress(w, c));
        }
        if (lead < sweep_at(w.gc.sweeps)) break;
        w.gc.sweeps +%= 1;
        sweep(w);
    }
}

/// A sweep point: collect the marked car, then mark the last one.
fn sweep(w: *World) void {
    if (w.gc.marked != no_car) collect(w, w.gc.marked, .sweep);
    if (w.gc.survivor != no_car or active_count(w) < 2) return;
    // The last car running by rank (the ranks of this tick are current).
    var last: u8 = no_car;
    var worst: u8 = 0;
    for (&w.cars, 0..) |*c, i| {
        if (!c.active or c.rank <= worst) continue;
        worst = c.rank;
        last = @intCast(i);
    }
    if (last == no_car) return;
    mark(w, last, no_car, .sweep);
}

fn mark(w: *World, i: u8, by: u8, cause: world.GcCause) void {
    w.gc.marked = i;
    w.gc.mark_ticks = 0;
    const c = &w.cars[i];
    weapons.emit(w, .mark, i, by, @backingInt(cause), c.x, c.y);
}

/// A weapon hit landed by `attacker` on `victim` (`sim.damage`, not rams):
/// the marked car tags the mark onto its victim.
pub fn on_hit(w: *World, attacker: u8, victim: usize) void {
    if (w.mode != .gc or attacker == no_car or attacker != w.gc.marked or victim == attacker) return;
    if (w.gc.mark_ticks < tuning.gc_tag_grace or !w.cars[victim].active) return;
    mark(w, @intCast(victim), attacker, .tag);
}

/// A wreck (`sim.wreck`): the marked car is collected at once.
pub fn on_wreck(w: *World, i: usize) void {
    if (w.mode == .gc and w.gc.marked == i and w.cars[i].active) collect(w, @intCast(i), .wreck);
}

/// Take car `i` out of the race: its rank is its final place (the number
/// of cars that were still running), it leaves every pool's reach
/// (`active = false`), and the last car left wins.
fn collect(w: *World, i: u8, cause: world.GcCause) void {
    const c = &w.cars[i];
    const place = active_count(w);
    pickups.on_wreck(w, i);
    c.rank = place;
    c.active = false;
    c.lock = no_car;
    c.aim = no_car;
    w.gc.collected |= @as(u8, 1) << @intCast(i);
    if (w.gc.marked == i) w.gc.marked = no_car;
    weapons.emit(w, .collect, i, place, @backingInt(cause), c.x, c.y);
    if (active_count(w) != 1) return;
    for (&w.cars, 0..) |*s, j| {
        if (!s.active) continue;
        w.gc.survivor = @intCast(j);
        w.gc.marked = no_car;
        s.rank = 1;
        if (!s.finished) {
            s.finished = true;
            s.finish_tick = w.tick;
        }
    }
}

/// Attract (SPEC 8.2): when the leader is `tuning.attract_panic_sample`
/// samples into lap 2, a KERNEL PANIC packet is launched at it on the
/// centerline `tuning.attract_panic_behind` samples behind it, as fired by
/// the best-placed car behind it still racing (a `use` event from that car,
/// so the feed reads like a real one). Handing that car the pickup instead
/// left the packet a lap of strung-out field to cross, and the leader was
/// often wrecked before it arrived. Called each racing tick.
pub fn script(w: *World) void {
    if (w.mode != .attract or w.scripted or w.phase != .racing) return;
    var lead: i32 = std.math.minInt(i32);
    var leader: u8 = no_car;
    for (&w.cars, 0..) |*c, i| {
        if (!c.active) continue;
        const p = sim.fine_progress(w, c);
        if (p > lead) {
            lead = p;
            leader = @intCast(i);
        }
    }
    if (lead < 65536 + tuning.attract_panic_sample * 256) return;
    const l = &w.cars[leader];
    if (l.wreck != .none or l.finished) return;
    var from: u8 = no_car;
    var best: u8 = 255;
    for (&w.cars, 0..) |*c, i| {
        if (i == leader or !c.active or c.wreck != .none or c.finished or c.rank >= best) continue;
        best = c.rank;
        from = @intCast(i);
    }
    if (from == no_car) return;
    const seg = l.progress -% tuning.attract_panic_behind;
    const s = sim.track_of(w).sample(seg);
    const slot = weapons.proj_slot(w);
    slot.* = .{
        .x = @as(i32, s.x) << fixed.Q,
        .y = @as(i32, s.y) << fixed.Q,
        .kind = .panic,
        .owner = from,
        .target = leader,
        .seg = seg +% 1,
        .ttl = 0,
    };
    weapons.emit(w, .use, from, @backingInt(world.Pickup.kernel_panic), leader, slot.x, slot.y);
    w.scripted = true;
}

test "sweep points: sector 2 of lap 0, the line of lap 1, sector 2 of lap 1, ..." {
    try std.testing.expectEqual(@as(i32, 170 * 256), sweep_at(0));
    try std.testing.expectEqual(@as(i32, 65536), sweep_at(1));
    try std.testing.expectEqual(@as(i32, 65536 + 170 * 256), sweep_at(2));
    try std.testing.expectEqual(@as(i32, 3 * 65536), sweep_at(5));
    _ = fixed;
}
