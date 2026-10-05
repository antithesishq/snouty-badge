//! Host tests for M3 Track A (content and mode simulation): the hazards
//! (vent, Sweeper) and service bays on the real tracks, the AI's hazard
//! sense, every track's combat soak, GARBAGE COLLECTION (mark, tag, sweep,
//! collection, the survivor) and its soak, the attract script, and
//! determinism with all of it on.
const std = @import("std");
const fixed = @import("fixed.zig");
const tuning = @import("tuning.zig");
const track = @import("track.zig");
const world = @import("world.zig");
const racers = @import("racers.zig");
const sim = @import("sim.zig");
const ai = @import("ai.zig");
const weapons = @import("weapons.zig");
const pickups = @import("pickups.zig");
const hazards = @import("hazards.zig");
const gc_mode = @import("gc_mode.zig");

const World = world.World;
const Car = world.Car;
const Input = world.Input;
const no_car = world.no_car;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

/// Print the soaks' per-race summaries.
const report = false;

fn track_index(t: *const track.Track) u8 {
    for (track.tracks, 0..) |x, k| {
        if (x == t) return @intCast(k);
    }
    unreachable;
}

fn run_countdown(w: *World) void {
    while (w.phase == .countdown) sim.simulate(w, .{ 0, 0 });
}

/// Event counts since `seq` (a render-style cursor).
const Tally = struct {
    seq: u16 = 0,
    blasts: u32 = 0,
    hazard_hits: [world.car_count]u32 = @splat(0),
    hazard_dmg: u32 = 0,
    marks: u32 = 0,
    tags: u32 = 0,
    collects: u32 = 0,
    collect_wrecks: u32 = 0,
    last_collect: world.Event = .{},
    last_mark: world.Event = .{},

    fn scan(self: *Tally, w: *const World) void {
        while (self.seq != w.event_seq) : (self.seq +%= 1) {
            const e = w.events[self.seq % world.event_count];
            switch (e.kind) {
                .blast => self.blasts += 1,
                .hazard_hit => {
                    self.hazard_hits[e.b % world.car_count] += 1;
                    self.hazard_dmg += e.c;
                },
                .mark => {
                    self.marks += 1;
                    if (e.c == @backingInt(world.GcCause.tag)) self.tags += 1;
                    self.last_mark = e;
                },
                .collect => {
                    self.collects += 1;
                    if (e.c == @backingInt(world.GcCause.wreck)) self.collect_wrecks += 1;
                    self.last_collect = e;
                },
                else => {},
            }
        }
    }
};

/// A world on track `t` with every car parked out of the way (inactive)
/// but `keep`, racing.
fn arena(t: *const track.Track, keep: []const u8, combat: bool) World {
    var w: World = undefined;
    sim.reset(&w, .{ .track = track_index(t), .seed = 5, .combat = combat });
    run_countdown(&w);
    for (&w.cars, 0..) |*c, i| {
        c.active = std.mem.indexOfScalar(u8, keep, @intCast(i)) != null;
    }
    return w;
}

/// Park car `c` at world px (x, y), heading `h`, stopped.
fn park(w: *World, c: *Car, x: i32, y: i32, h: fixed.Turn) void {
    c.x = (x & 1023) << fixed.Q;
    c.y = (y & 1023) << fixed.Q;
    c.vx = 0;
    c.vy = 0;
    c.heading = h;
    c.immune = 0;
    c.progress = sim.nearest_sample(sim.track_of(w), c, c.progress);
    var best: u8 = 0;
    var best_d: i32 = std.math.maxInt(i32);
    const t = sim.track_of(w);
    for (0..256) |k| {
        const s = t.sample(k);
        const dx = @as(i32, s.x) - x;
        const dy = @as(i32, s.y) - y;
        if (dx * dx + dy * dy < best_d) {
            best_d = dx * dx + dy * dy;
            best = @intCast(k);
        }
    }
    c.progress = best;
}

/// The first hazard of `kind` on the selected track.
fn first(kind: world.HazardKind) usize {
    for (track.hazard_specs[0..track.hazard_n], 0..) |*h, k| {
        if (h.kind == kind) return k;
    }
    unreachable;
}

// --- Hazards ------------------------------------------------------------------

test "every track: well formed hazards, crate rows, a service bay, a hazard" {
    for (track.tracks) |t| {
        track.select(t);
        try expect(track.hazard_n >= 1 and track.hazard_n <= world.hazard_max);
        try expect(track.crate_n >= 6);
        try expectEqual(@as(usize, 0), t.feat.len % track.hazard_record);
        for (track.hazard_specs[0..track.hazard_n]) |*h| {
            try expect(h.kind == .blast or h.kind == .mover);
            try expect(h.len > 2 * 40 and @as(i64, h.ux) * h.ux + @as(i64, h.uy) * h.uy > 65000 * 65000);
            if (h.kind == .mover) try expect(h.travel + h.warn < h.period / 2);
            if (h.kind == .blast) try expect(h.on + h.warn < h.period);
            // The middle of the hazard's line is on the road.
            const mx = h.x0 + @divTrunc(h.x1 - h.x0, 2);
            const my = h.y0 + @divTrunc(h.y1 - h.y0, 2);
            const a = t.attr_at(mx, my);
            try expect(a != .off and a != .wall);
        }
        var bay = false;
        for (track.map_ram) |v| bay = bay or @as(track.Attr, @fromBackingInt(t.attr[v])) == .bay;
        try expect(bay);
        try expect(t.laps == tuning.laps);
    }
}

test "a vent hits a car in its lane once a firing: damage, a shove along the lane, events" {
    var w = arena(&track.salt_pan_sprint, &.{racers.snouty}, true);
    const k = first(.blast);
    const h = &track.hazard_specs[k];
    const c = &w.cars[racers.snouty];
    // Halfway across the lane, facing along the road (across the lane).
    const px = h.x0 + @divTrunc(h.x1 - h.x0, 2);
    const py = h.y0 + @divTrunc(h.y1 - h.y0, 2);
    var tl = Tally{ .seq = w.event_seq };
    // Ten ticks before it fires.
    w.hazards[k].timer = h.period - h.on - 10;
    var hit_tick: u32 = 0;
    for (0..60) |n| {
        park(&w, c, px, py, fixed.atan2(h.ux, -h.uy));
        const armor = c.armor;
        sim.simulate(&w, .{ 0, 0 });
        if (c.armor < armor) {
            try expectEqual(@as(u32, 0), hit_tick);
            hit_tick = @intCast(n + 1);
            try expectEqual(armor - h.damage, c.armor);
            // Shoved along the lane (away from the mouth).
            try expect(fixed.mul(c.vx, h.ux) + fixed.mul(c.vy, h.uy) > (h.push >> 1));
        }
        if (n == 8) try expectEqual(world.HazardState.warn, w.hazards[k].state);
    }
    try expectEqual(@as(u32, 10), hit_tick);
    tl.scan(&w);
    try expectEqual(@as(u32, 1), tl.blasts);
    try expectEqual(@as(u32, 1), tl.hazard_hits[racers.snouty]);
    try expectEqual(@as(u32, 20), tl.hazard_dmg);
    // Out of the lane, airborne, or wrecked: nothing.
    w.hazards[k].timer = h.period - h.on - 1;
    c.armor = c.armor_max;
    park(&w, c, px + @divTrunc(h.uy * 30, 65536), py - @divTrunc(h.ux * 30, 65536), 0);
    for (0..10) |_| sim.simulate(&w, .{ 0, 0 });
    try expectEqual(c.armor_max, c.armor);
    w.hazards[k].timer = h.period - h.on - 1;
    park(&w, c, px, py, 0);
    c.hop = 30;
    sim.simulate(&w, .{ 0, 0 });
    sim.simulate(&w, .{ 0, 0 });
    try expectEqual(c.armor_max, c.armor);
}

test "the Sweeper: idle it is harmless; crossing, it hits once, shoves and pushes the car out of its body" {
    var w = arena(&track.monitor_dunes, &.{racers.legacy}, true);
    const k = first(.mover);
    const h = &track.hazard_specs[k];
    const c = &w.cars[racers.legacy];
    const mid_x = h.x0 + @divTrunc(h.x1 - h.x0, 2);
    const mid_y = h.y0 + @divTrunc(h.y1 - h.y0, 2);
    // Idle: parked at end A, the car on the road is untouched.
    w.hazards[k].timer = 0;
    park(&w, c, mid_x, mid_y, 0);
    for (0..20) |_| {
        c.vx = 0;
        c.vy = 0;
        sim.simulate(&w, .{ 0, 0 });
    }
    try expectEqual(c.armor_max, c.armor);
    // Crossing: start the leg so the body reaches the road's middle.
    var tl = Tally{ .seq = w.event_seq };
    const half = h.period / 2;
    w.hazards[k].timer = half - h.travel - 1;
    var hits: u32 = 0;
    var shoved = false;
    for (0..h.travel) |_| {
        // The car stalled on the path's middle (braking): the body runs into
        // it, hits it once and shoves it.
        const armor = c.armor;
        const x0 = c.x;
        const y0 = c.y;
        sim.simulate(&w, .{ (Input{ .down = true }).byte(), 0 });
        if (c.armor < armor) {
            hits += 1;
            shoved = c.x != x0 or c.y != y0;
            // Pushed out to the body's edge (or as far as the walls allow).
            const hz = &w.hazards[k];
            const dx = ((c.x - hz.x) >> fixed.Q);
            const dy = ((c.y - hz.y) >> fixed.Q);
            try expect(dx * dx + dy * dy >= (h.size + tuning.car_radius - 2) * (h.size + tuning.car_radius - 2));
        }
    }
    tl.scan(&w);
    try expectEqual(@as(u32, 1), hits);
    try expectEqual(h.damage, c.armor_max - c.armor);
    try expectEqual(@as(u32, 1), tl.blasts);
    try expectEqual(@as(u32, 1), tl.hazard_hits[racers.legacy]);
    try expect(shoved);
}

test "a service bay repairs 1 armor every 4 ticks; off the bay nothing" {
    var w = arena(&track.landfill_loop, &.{racers.snouty}, true);
    const t = sim.track_of(&w);
    const c = &w.cars[racers.snouty];
    // A bay tile.
    var bx: i32 = -1;
    var by: i32 = -1;
    outer: for (0..128) |ty| for (0..128) |tx| {
        if (t.attr_at(@intCast(tx * 8 + 4), @intCast(ty * 8 + 4)) == .bay) {
            bx = @intCast(tx * 8 + 4);
            by = @intCast(ty * 8 + 4);
            break :outer;
        }
    };
    try expect(bx >= 0);
    c.armor = 50;
    for (0..40) |_| {
        park(&w, c, bx, by, 0);
        sim.simulate(&w, .{ (Input{ .down = true }).byte(), 0 });
    }
    try expect(c.on_bay);
    try expectEqual(@as(u8, 60), c.armor);
    // Full armor stays full.
    c.armor = c.armor_max;
    for (0..8) |_| {
        park(&w, c, bx, by, 0);
        sim.simulate(&w, .{ 0, 0 });
    }
    try expectEqual(c.armor_max, c.armor);
}

/// One car alone on a track with a vent, driven by its crew from up the
/// road at full speed, the vent timed so that a car keeping its speed
/// arrives 10 ticks into a firing: hazard hits taken.
fn vent_run(racer: u8, back: u8) u32 {
    var w = arena(&track.salt_pan_sprint, &.{racer}, true);
    const k = first(.blast);
    const h = &track.hazard_specs[k];
    const c = &w.cars[racer];
    const px = h.x0 + @divTrunc(h.x1 - h.x0, 2);
    const py = h.y0 + @divTrunc(h.y1 - h.y0, 2);
    const s0 = blk: {
        park(&w, c, px, py, 0);
        break :blk c.progress;
    };
    const s = sim.track_of(&w).sample(s0 -% back);
    park(&w, c, s.x, s.y, s.tangent);
    const top = sim.top_of(c);
    c.vx = fixed.mul(fixed.cos(s.tangent), top);
    c.vy = fixed.mul(fixed.sin(s.tangent), top);
    const dx = s.x - px;
    const dy = s.y - py;
    const dist: i32 = @as(i32, @intCast(fixed.isqrt(@intCast(dx * dx + dy * dy)))) - h.size - tuning.hazard_reach;
    const eta: u16 = @intCast(@divTrunc(dist << fixed.Q, top));
    w.hazards[k].timer = h.period - h.on - (eta - 10);
    var tl = Tally{ .seq = w.event_seq };
    for (0..240) |_| {
        sim.simulate(&w, .{ 0, 0 });
        tl.scan(&w);
    }
    // It got past the vent.
    const gap: i8 = @bitCast(c.progress -% s0);
    std.testing.expect(gap > 4) catch unreachable;
    return tl.hazard_hits[racer];
}

test "AI hazard sense: a crew waits for a firing vent, KIDDIE drives into it" {
    if (report) for ([_]u8{ 12, 10, 8, 6 }) |back| {
        std.debug.print("\nvent_run back {d}: SYSADMIN {d} SNOUTY {d} KIDDIE {d}", .{ back, vent_run(racers.sysadmin, back), vent_run(racers.snouty, back), vent_run(racers.kiddie, back) });
    };
    for ([_]u8{ 12, 10, 8 }) |back| {
        try expectEqual(@as(u32, 0), vent_run(racers.sysadmin, back));
        try expectEqual(@as(u32, 0), vent_run(racers.snouty, back));
        try expectEqual(@as(u32, 1), vent_run(racers.kiddie, back));
    }
}

// --- Soaks on every track -------------------------------------------------------

const Soak = struct {
    ticks: u32 = 0,
    finished: bool = false,
    max_stuck: u32 = 0,
    max_projs: usize = 0,
    max_drops: usize = 0,
    wrecks: u32 = 0,
    falls: u32 = 0,
    hazard_hits: u32 = 0,
    kiddie_hits: u32 = 0,
    blasts: u32 = 0,
    collects: u32 = 0,
    tags: u32 = 0,
    survivors: u32 = 0,
};

/// An AI-only race (human slot empty) with combat and pickups on, run until
/// every car is done (finished, or collected in GC) or the limit.
fn soak(t: u8, seed: u32, mode: world.Mode, limit: u32, out: ?*World) Soak {
    var w: World = undefined;
    sim.reset(&w, .{ .track = t, .seed = seed, .mode = mode });
    var r: Soak = .{};
    var tl = Tally{ .seq = w.event_seq };
    var best: [world.car_count]i32 = @splat(std.math.minInt(i32));
    var since: [world.car_count]u32 = @splat(0);
    var was: [world.car_count]world.Wreck = @splat(.none);
    run_countdown(&w);
    while (r.ticks < limit) : (r.ticks += 1) {
        sim.simulate(&w, .{ 0, 0 });
        tl.scan(&w);
        r.max_projs = @max(r.max_projs, weapons.projs_live(&w));
        r.max_drops = @max(r.max_drops, weapons.drops_live(&w));
        var done = true;
        for (&w.cars, 0..) |*c, i| {
            if (c.wreck != .none and was[i] == .none) {
                if (c.wreck == .fall) r.falls += 1 else r.wrecks += 1;
            }
            was[i] = c.wreck;
            if (c.finished or !c.active) continue;
            done = false;
            const p = sim.fine_progress(&w, c);
            if (p > best[i]) {
                best[i] = p;
                since[i] = 0;
            } else {
                since[i] += 1;
                r.max_stuck = @max(r.max_stuck, since[i]);
            }
        }
        if (done or (mode == .gc and w.phase == .finished)) {
            r.finished = true;
            break;
        }
    }
    for (tl.hazard_hits) |n| r.hazard_hits += n;
    r.kiddie_hits = tl.hazard_hits[racers.kiddie];
    r.blasts = tl.blasts;
    r.collects = tl.collects;
    r.tags = tl.tags;
    if (out) |o| o.* = w;
    return r;
}

test "every track: seeded 6-AI combat races all finish, nobody stuck, pools within caps" {
    for (0..track.tracks.len) |t| {
        var tot: Soak = .{};
        var max_ticks: u32 = 0;
        for (0..4) |s| {
            const r = soak(@intCast(t), @intCast(0xC0DE_0000 + s * 104729 + t * 7), .race, 60 * 300, null);
            try expect(r.finished);
            try expect(r.max_stuck <= 600);
            try expect(r.max_projs <= world.proj_count and r.max_drops <= world.drop_count);
            tot.wrecks += r.wrecks;
            tot.falls += r.falls;
            tot.hazard_hits += r.hazard_hits;
            tot.kiddie_hits += r.kiddie_hits;
            tot.max_stuck = @max(tot.max_stuck, r.max_stuck);
            max_ticks = @max(max_ticks, r.ticks);
        }
        if (report) std.debug.print("\nsoak {s}: max {d} ticks, wrecks {d}, falls {d}, hazard hits {d} (KIDDIE {d}), stuck max {d}", .{ track.tracks[t].name, max_ticks, tot.wrecks, tot.falls, tot.hazard_hits, tot.kiddie_hits, tot.max_stuck });
    }
}

// --- GARBAGE COLLECTION -------------------------------------------------------------

test "GC: the first sweep marks the last car, the next collects it and marks again" {
    var w: World = undefined;
    sim.reset(&w, .{ .track = 0, .seed = 77, .mode = .gc, .combat = false });
    run_countdown(&w);
    var tl = Tally{ .seq = w.event_seq };
    var ticks: u32 = 0;
    while (w.gc.sweeps == 0 and ticks < 3000) : (ticks += 1) sim.simulate(&w, .{ 0, 0 });
    tl.scan(&w);
    try expectEqual(@as(u8, 1), w.gc.sweeps);
    try expect(w.gc.marked != no_car);
    try expectEqual(@as(u8, 6), w.cars[w.gc.marked].rank);
    try expectEqual(@as(u32, 1), tl.marks);
    try expectEqual(no_car, tl.last_mark.b);
    const first_marked = w.gc.marked;
    // Combat off: nobody tags; the next sweep (the line) collects it.
    while (w.gc.sweeps == 1 and ticks < 6000) : (ticks += 1) sim.simulate(&w, .{ 0, 0 });
    tl.scan(&w);
    try expectEqual(@as(u32, 1), tl.collects);
    try expectEqual(first_marked, tl.last_collect.a);
    try expectEqual(@as(u8, 6), tl.last_collect.b);
    const out = &w.cars[first_marked];
    try expect(!out.active);
    try expectEqual(@as(u8, 6), out.rank);
    try expect(w.gc.collected == @as(u8, 1) << @intCast(first_marked));
    try expect(w.gc.marked != no_car and w.gc.marked != first_marked);
    try expectEqual(@as(u8, 5), w.cars[w.gc.marked].rank);
    // A collected car stays out: no lap counting, never drawn into ranks.
    const lap = out.lap;
    for (0..300) |_| sim.simulate(&w, .{ 0, 0 });
    try expectEqual(lap, out.lap);
    try expectEqual(@as(u8, 6), out.rank);
    for (w.cars) |c| {
        if (c.active) try expect(c.rank >= 1 and c.rank <= 5);
    }
}

test "GC: a weapon hit by the marked car passes the mark on, after the grace; a ram does not" {
    var w = arena(&track.landfill_loop, &.{ racers.snouty, racers.kiddie, racers.legacy }, true);
    w.mode = .gc;
    const s = sim.track_of(&w).sample(30);
    const m = &w.cars[racers.snouty];
    const v = &w.cars[racers.kiddie];
    park(&w, m, s.x, s.y, s.tangent);
    park(&w, v, @as(i32, s.x) + ((fixed.cos(s.tangent) * 60) >> fixed.Q), @as(i32, s.y) + ((fixed.sin(s.tangent) * 60) >> fixed.Q), s.tangent);
    w.gc.marked = racers.snouty;
    w.gc.mark_ticks = 0;
    // Within the grace, a hit does not tag.
    sim.damage(&w, racers.kiddie, racers.snouty, 4);
    try expectEqual(racers.snouty, w.gc.marked);
    w.gc.mark_ticks = tuning.gc_tag_grace;
    var tl = Tally{ .seq = w.event_seq };
    sim.damage(&w, racers.kiddie, racers.snouty, 4);
    tl.scan(&w);
    try expectEqual(racers.kiddie, w.gc.marked);
    try expectEqual(@as(u16, 0), w.gc.mark_ticks);
    try expectEqual(@as(u32, 1), tl.tags);
    try expectEqual(racers.snouty, tl.last_mark.b);
    // A hit by an unmarked car does nothing; a ram by the marked one neither.
    w.gc.mark_ticks = tuning.gc_tag_grace;
    sim.damage(&w, racers.legacy, racers.snouty, 4);
    try expectEqual(racers.kiddie, w.gc.marked);
    const l = &w.cars[racers.legacy];
    v.x = m.x;
    v.y = m.y;
    l.x = v.x + (16 << fixed.Q);
    l.y = v.y;
    v.vx = 2 << fixed.Q;
    v.vy = 0;
    l.vx = -(2 << fixed.Q);
    l.vy = 0;
    v.hop = 0;
    l.hop = 0;
    const armor = l.armor;
    sim.collide_all(&w);
    try expect(l.armor < armor);
    try expectEqual(racers.kiddie, w.gc.marked);
}

test "GC: a wreck while marked is an immediate collection; the last car running wins" {
    var w: World = undefined;
    sim.reset(&w, .{ .track = 0, .seed = 3, .mode = .gc, .combat = false });
    run_countdown(&w);
    for (0..100) |_| sim.simulate(&w, .{ 0, 0 });
    var tl = Tally{ .seq = w.event_seq };
    w.gc.marked = racers.botnet;
    sim.wreck(&w, racers.botnet, .fall);
    tl.scan(&w);
    try expect(!w.cars[racers.botnet].active);
    try expectEqual(@as(u8, 6), w.cars[racers.botnet].rank);
    try expectEqual(no_car, w.gc.marked);
    try expectEqual(@as(u32, 1), tl.collect_wrecks);
    // Collect down to one: the survivor wins and the race ends.
    for ([_]u8{ racers.kiddie, racers.legacy, racers.rootkit, racers.sysadmin }, 0..) |r, n| {
        w.gc.marked = r;
        sim.wreck(&w, r, .fall);
        try expectEqual(@as(u8, @intCast(5 - n)), w.cars[r].rank);
    }
    try expectEqual(racers.snouty, w.gc.survivor);
    sim.simulate(&w, .{ 0, 0 });
    try expectEqual(world.Phase.finished, w.phase);
    const c = &w.cars[racers.snouty];
    try expect(c.finished and c.active);
    try expectEqual(@as(u8, 1), c.rank);
    var places: u8 = 0;
    for (w.cars) |x| places |= @as(u8, 1) << @intCast(x.rank - 1);
    try expectEqual(@as(u8, 0x3F), places);
}

test "GC soak: 20 seeded races over every track each end with exactly one car" {
    var total_ticks: u32 = 0;
    for (0..20) |k| {
        const t: u8 = @intCast(k % track.tracks.len);
        var w: World = undefined;
        const r = soak(t, @intCast(0x6C00_0000 + k * 31337), .gc, 60 * 300, &w);
        try expect(r.finished);
        try expectEqual(world.Phase.finished, w.phase);
        try expect(w.gc.survivor != no_car);
        try expectEqual(@as(u8, 1), gc_mode.active_count(&w));
        try expectEqual(@as(u32, 5), r.collects);
        try expect(r.max_stuck <= 600);
        try expect(r.max_projs <= world.proj_count and r.max_drops <= world.drop_count);
        var places: u8 = 0;
        for (w.cars) |c| places |= @as(u8, 1) << @intCast(c.rank - 1);
        try expectEqual(@as(u8, 0x3F), places);
        total_ticks += r.ticks;
        if (report) std.debug.print("\ngc soak {d:2} {s}: {d} ticks, survivor {s}, sweeps {d}, tags {d}, wrecks {d}", .{ k, track.tracks[t].name, r.ticks, racers.roster[w.gc.survivor].name, w.gc.sweeps, r.tags, r.wrecks });
    }
    if (report) std.debug.print("\ngc soak mean {d} ticks\n", .{total_ticks / 20});
}

test "GC with a human: the race ends only when one car is left" {
    var w: World = undefined;
    sim.reset(&w, .{ .track = 3, .seed = 9, .mode = .gc, .humans = .{ racers.snouty, no_car } });
    run_countdown(&w);
    var ticks: u32 = 0;
    while (w.phase == .racing and ticks < 60 * 300) : (ticks += 1) {
        sim.simulate(&w, .{ ai.drive(&w, racers.snouty).byte(), 0 });
    }
    try expectEqual(world.Phase.finished, w.phase);
    try expectEqual(@as(u8, 1), gc_mode.active_count(&w));
    // Laps never finished anyone but the survivor.
    for (w.cars, 0..) |c, i| try expectEqual(i == w.gc.survivor, c.finished);
}

// --- Attract -----------------------------------------------------------------------------

test "attract: a KERNEL PANIC is launched at the leader in lap 2 and freezes it" {
    var hits: u32 = 0;
    for (0..6) |s| {
        var w: World = undefined;
        sim.reset(&w, .{ .track = @intCast(s), .seed = @intCast(1000 + s), .mode = .attract });
        run_countdown(&w);
        var ticks: u32 = 0;
        var tl = Tally{ .seq = w.event_seq };
        var seq = w.event_seq;
        var use: ?world.Event = null;
        while (ticks < 60 * 90 and !w.scripted) : (ticks += 1) {
            sim.simulate(&w, .{ 0, 0 });
            while (seq != w.event_seq) : (seq +%= 1) {
                const e = w.events[seq % world.event_count];
                if (e.kind == .use and e.b == @backingInt(world.Pickup.kernel_panic)) use = e;
            }
        }
        tl.scan(&w);
        try expect(w.scripted);
        // In lap 2 (the leader's), fired "by" a car behind it at it.
        const e = use orelse return error.TestUnexpectedResult;
        const leader = e.c;
        try expectEqual(@as(u8, 1), w.cars[leader].lap);
        try expectEqual(@as(u8, 1), w.cars[leader].rank);
        try expect(e.a != leader and w.cars[e.a].rank > 1);
        var panicked = false;
        var n: u32 = 0;
        while (n < 300 and !panicked) : (n += 1) {
            sim.simulate(&w, .{ 0, 0 });
            panicked = w.cars[leader].frozen_by == .panic;
        }
        if (report) std.debug.print("\nattract {d}: launched at tick {d}, the leader frozen {} after {d}", .{ s, ticks, panicked, n });
        if (panicked) hits += 1;
    }
    // A leader wrecked or airborne at the wrong moment can dodge it.
    try expect(hits >= 5);
}

test "a KERNEL PANIC packet more than half a lap behind its target runs on to it" {
    var w = arena(&track.landfill_loop, &.{ racers.snouty, racers.legacy }, true);
    const t = &w.cars[racers.legacy];
    const user = &w.cars[racers.snouty];
    const s0 = sim.track_of(&w).sample(20);
    park(&w, user, s0.x, s0.y, s0.tangent);
    const s1 = sim.track_of(&w).sample(180);
    park(&w, t, s1.x, s1.y, s1.tangent);
    user.lap = 1;
    t.lap = 1;
    sim.update_ranks(&w);
    user.pickup = .kernel_panic;
    var n: u32 = 0;
    while (n < 900 and t.frozen_by != .panic) : (n += 1) {
        t.vx = 0;
        t.vy = 0;
        user.vx = 0;
        user.vy = 0;
        sim.simulate(&w, .{ (Input{ .b = n == 0, .down = true }).byte(), 0 });
    }
    try expectEqual(world.Freeze.panic, t.frozen_by);
    // 160 samples of about 14 px at twice the top speed: well under 900.
    try expect(n < 600);
}

// --- Determinism ------------------------------------------------------------------------

test "determinism with hazards and GC: the same seeded race twice, and two worlds interleaved" {
    var a: World = undefined;
    var b: World = undefined;
    _ = soak(4, 0xBEEF, .gc, 4000, &a);
    _ = soak(4, 0xBEEF, .gc, 4000, &b);
    try expect(sim.worlds_equal(&a, &b));
    try expect(a.gc.sweeps > 0);
    var x: World = undefined;
    var y: World = undefined;
    sim.reset(&x, .{ .track = 1, .seed = 21, .humans = .{ racers.botnet, racers.snouty }, .mode = .gc });
    sim.reset(&y, .{ .track = 1, .seed = 21, .humans = .{ racers.botnet, racers.snouty }, .mode = .gc });
    var r = fixed.Rng{ .s = 99 };
    var held = [2]u8{ 0, 0 };
    for (0..3000) |_| {
        for (&held) |*hh| {
            if (r.below(10) == 0) hh.* = @truncate(r.next());
        }
        sim.simulate(&x, held);
        sim.simulate(&y, held);
    }
    try expect(sim.worlds_equal(&x, &y));
}

test "the SNOUTY autopilot as the human in a full combat race on every track finishes" {
    for (0..track.tracks.len) |t| {
        var wr: [4]u32 = @splat(0);
        var finish: u32 = 0;
        var rank_sum: u32 = 0;
        for (0..3) |s| {
            var w: World = undefined;
            sim.reset(&w, .{ .track = @intCast(t), .seed = @intCast(0xA770 + s * 17 + t), .humans = .{ racers.snouty, no_car } });
            run_countdown(&w);
            var was = world.Wreck.none;
            var ticks: u32 = 0;
            while (w.phase == .racing and ticks < 60 * 300) : (ticks += 1) {
                sim.simulate(&w, .{ ai.drive(&w, racers.snouty).byte(), 0 });
                const c = &w.cars[racers.snouty];
                if (c.wreck != .none and was == .none) {
                    wr[@backingInt(c.wreck)] += 1;
                    if (report) std.debug.print("\n  {s} seed {d}: wreck {s} at sample {d} tick {d}", .{ track.tracks[t].name, s, @tagName(c.wreck), c.progress, w.tick });
                }
                was = c.wreck;
            }
            try expectEqual(world.Phase.finished, w.phase);
            finish = @max(finish, w.cars[racers.snouty].finish_tick);
            rank_sum += w.cars[racers.snouty].rank;
        }
        if (report) std.debug.print("\nhuman autopilot {s}: worst finish {d} ticks, falls {d}, armor wrecks {d}, ZERO-DAY {d}, mean rank x3 {d}", .{ track.tracks[t].name, finish, wr[1], wr[2], wr[3], rank_sum });
    }
}
