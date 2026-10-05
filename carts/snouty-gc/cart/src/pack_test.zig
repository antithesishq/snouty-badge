//! M7 track pack host tests (docs/PACKS.md): the format parser, the loader,
//! the fuzzing of truncated and bit-flipped packs, props, crust and the
//! link race on the test pack. New for Snouty GCP. `host_tests.zig` imports
//! this one file, so the pack modules' tests are added here.
const std = @import("std");
const fixed = @import("fixed.zig");
const world = @import("world.zig");
const track = @import("track.zig");
const sim = @import("sim.zig");
const ai = @import("ai.zig");
const racers = @import("racers.zig");
const pack = @import("pack.zig");
const fmt = @import("pack_format.zig");

const World = world.World;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test {
    _ = @import("pack_format.zig");
    _ = @import("pack.zig");
    _ = @import("pack_rows.zig");
    _ = @import("pack_content_test.zig");
}

/// The committed test pack (tools/test_pack/make.py).
pub const test_pack = @embedFile("gen/packs/TEST.GCP");
/// Its tracks: LANDFILL TEST, CRUST LOOP, then the arena TEST SANDBOX.
pub const k_landfill = 0;
pub const k_crust = 1;
pub const k_arena = 2;

fn run_countdown(w: *World) void {
    while (w.phase == .countdown) sim.simulate(w, .{ 0, 0 });
}

/// A race on the loaded pack track with SNOUTY on the autopilot as the
/// human, to the end or `limit` ticks; returns the World.
pub fn autopilot_race(seed: u32, limit: u32) World {
    var w: World = undefined;
    sim.reset(&w, .{ .track = track.pack_base, .seed = seed, .humans = .{ racers.snouty, world.no_human } });
    run_countdown(&w);
    while (w.phase == .racing and w.tick < limit) sim.simulate(&w, .{ ai.drive(&w, racers.snouty).byte(), 0 });
    return w;
}

test "the test pack loads: its tracks and arena run through track.pack_track" {
    defer pack.forget();
    try expectEqual(fmt.Refusal.ok, pack.load_bytes(test_pack, k_landfill));
    try std.testing.expectEqualStrings("LANDFILL TEST", track.pack_track.name);
    try std.testing.expectEqualStrings("TEST DUMPS", track.pack_track.league.name);
    try expectEqual(@as(u8, 3), track.pack_track.laps);
    var w: World = undefined;
    sim.reset(&w, .{ .track = track.pack_base, .seed = 7 });
    try expect(sim.track_of(&w) == &track.pack_track);
    // The same map as the built-in Landfill Loop it was made from.
    const pack_map = track.map_ram;
    track.select(&track.landfill_loop);
    try expect(std.mem.eql(u8, &pack_map, &track.map_ram));
    // The props: seven, one solid; the sheet holds the 4 cells it uses.
    track.select(&track.pack_track);
    try expectEqual(@as(u8, 7), track.prop_n);
    try expectEqual(@as(u8, 6), track.prop_reach);
    try expectEqual(@as(u8, 4), track.pack_track.sheet.?.cells);
    try expect(std.mem.eql(u8, &pack_map, &track.map_ram));
    // The arena.
    try expectEqual(fmt.Refusal.ok, pack.load_bytes(test_pack, k_arena));
    try std.testing.expectEqualStrings("TEST SANDBOX", track.pack_track.name);
    sim.reset(&w, .{ .track = track.pack_base, .mode = .battle, .seed = 7 });
    try expectEqual(@as(u8, 6), track.arena.spawn_n);
    try expect(track.arena.node_n > 0);
    // Past the last track: refused, nothing loaded.
    try expectEqual(fmt.Refusal.damaged, pack.load_bytes(test_pack, 3));
    try expect(pack.loaded == null);
}

test "a pack race with the autopilot finishes its 3 laps; a built-in race after it is unchanged" {
    defer pack.forget();
    var ref: World = undefined;
    sim.reset(&ref, .{ .track = 0, .seed = 99, .humans = .{ racers.snouty, world.no_human } });
    try expectEqual(fmt.Refusal.ok, pack.load_bytes(test_pack, k_landfill));
    for (0..2) |s| {
        const w = autopilot_race(@intCast(0x9AC0 + s), 60 * 300);
        try expectEqual(world.Phase.finished, w.phase);
        try expect(w.cars[racers.snouty].finished);
    }
    // Built-in after pack: the same reset as before the pack.
    var w: World = undefined;
    sim.reset(&w, .{ .track = 0, .seed = 99, .humans = .{ racers.snouty, world.no_human } });
    try expect(sim.worlds_equal(&ref, &w));
    // And the pack track again: select reloads its map and art.
    sim.reset(&w, .{ .track = track.pack_base, .seed = 1 });
    try expect(track.art_league == &track.pack_league);
}

// --- The drive scan (romfs images, tools/test_pack/make.py) ------------------------

const romfs = @import("romfs");
const pack_rows = @import("pack_rows.zig");
const hazards = @import("hazards.zig");
const tuning = @import("tuning.zig");

const drive_test = @embedFile("gen/packs/drive_test.img");
const drive_frag = @embedFile("gen/packs/drive_frag.img");
const drive_empty = @embedFile("gen/packs/drive_empty.img");

fn status_of(name: []const u8) fmt.Refusal {
    for (pack.packs[0..pack.count]) |*p| {
        if (std.mem.eql(u8, p.file_name(), name)) return p.status;
    }
    return .bad_file;
}

test "the drive scan: the test pack is raceable, damaged, foreign and too-new files are refused with their lines" {
    defer pack.forget();
    pack.scan(romfs.Image.truncated_test(drive_test));
    try expectEqual(@as(u8, 4), pack.count); // the .GB file is not listed
    try expectEqual(fmt.Refusal.not_a_pack, status_of("JUNK.GCP"));
    try expectEqual(fmt.Refusal.too_new, status_of("NEWER.GCP"));
    try expect(pack.busy());
    try expectEqual(fmt.Refusal.checking, status_of("TEST.GCP"));
    // The CRCs a few KB a tick: 27.5 KB is 7 ticks a pack.
    var ticks: u32 = 0;
    while (pack.tick()) ticks += 1;
    try expect(ticks >= 2 * 27500 / pack.crc_step);
    try expectEqual(fmt.Refusal.ok, status_of("TEST.GCP"));
    try expectEqual(fmt.Refusal.damaged, status_of("BROKEN.GCP"));
    try std.testing.expectEqualStrings("PACK DAMAGED", status_of("BROKEN.GCP").text());
    // The rows: six built-in tracks, TEST's two, one row per refused file;
    // arenas: The Sandbox and TEST's.
    try expectEqual(@as(u8, 6 + 2 + 3), pack_rows.race_count());
    try expectEqual(@as(u8, 2), pack_rows.arena_count());
    var refused: u32 = 0;
    for (0..pack_rows.race_count()) |i| {
        const r = pack_rows.race_row(@intCast(i));
        if (r == .refused) {
            refused += 1;
            try expect(pack_rows.track_of(r, false) == null);
            try expect(pack_rows.reason(r).len > 0);
        }
    }
    try expectEqual(@as(u32, 3), refused);
    const t = pack_rows.track_of(pack_rows.race_row(6), false).?;
    try std.testing.expectEqualStrings("LANDFILL TEST", t.name);
    try std.testing.expectEqualStrings("TEST SANDBOX", pack_rows.track_of(pack_rows.arena_row(1), true).?.name);
    // A second scan keeps the verdicts (no second CRC).
    pack.scan(romfs.Image.truncated_test(drive_test));
    try expectEqual(fmt.Refusal.ok, status_of("TEST.GCP"));
    try expect(!pack.busy());
    // The link: the rules name the pack by id; another id is not here.
    const pk = pack_rows.link_pick(pack_rows.race_row(7));
    try expectEqual(track.pack_base + 1, pk.track);
    try expect(pack_rows.row_of(false, pk.track, pk.pack) != null);
    try expect(pack_rows.row_of(false, pk.track, pk.pack ^ 1) == null);
    try expect(pack_rows.has_rules(.{ .track = pk.track, .pack = pk.pack }));
    try expect(!pack_rows.has_rules(.{ .track = pk.track, .pack = pk.pack ^ 1 }));
}

test "the drive scan: a pack split over the drive is RECOPY PACK; an empty drive or none lists nothing" {
    defer pack.forget();
    pack.scan(romfs.Image.truncated_test(drive_frag));
    pack.check_all();
    try expectEqual(fmt.Refusal.ok, status_of("FRAG.GCP"));
    // The CRC reads it cluster by cluster; the load needs sections in one run.
    try expectEqual(fmt.Refusal.fragmented, pack.load(0, 0));
    try std.testing.expectEqualStrings("RECOPY PACK", pack.packs[0].status.text());
    try expect(pack.loaded == null);
    pack.scan(romfs.Image.truncated_test(drive_empty));
    try expectEqual(@as(u8, 0), pack.count);
    try expectEqual(@as(u8, 6), pack_rows.race_count());
    pack.scan(romfs.Image.whole(&@as([512]u8, @splat(0))));
    try expectEqual(@as(u8, 0), pack.count);
}

// --- Fuzzing: truncated and bit-flipped packs ---------------------------------

fn put_crc(b: []u8) void {
    std.mem.writeInt(u32, b[48..52], pack.crc_update(0xFFFFFFFF, b[fmt.header_bytes..]) ^ 0xFFFFFFFF, .little);
}

/// A loaded (fuzzed) pack track or arena runs 200 ticks without a fault.
fn run_some(k: u8) void {
    var w: World = undefined;
    const arena = k == k_arena;
    sim.reset(&w, .{ .track = track.pack_base, .seed = 3, .mode = if (arena) .battle else .race, .humans = .{ racers.snouty, world.no_human } });
    var n: u32 = 0;
    while (n < 400) : (n += 1) sim.simulate(&w, .{ ai.drive(&w, racers.snouty).byte(), 0 });
    track.crust_look(&w.hazards);
}

test "fuzz: truncated packs are refused, never a crash" {
    defer pack.forget();
    var n: usize = 0;
    while (n < test_pack.len) : (n += if (n < 512) 1 else 97) {
        for (0..3) |k| try expect(pack.load_bytes(test_pack[0..n], @intCast(k)) != .ok);
    }
    try expectEqual(fmt.Refusal.ok, pack.load_bytes(test_pack, 0));
    // A size field that lies about the file is damage, past the cap too big.
    const big = try std.testing.allocator.alloc(u8, fmt.file_max + 1);
    defer std.testing.allocator.free(big);
    @memset(big, 0);
    @memcpy(big[0..test_pack.len], test_pack);
    try expectEqual(fmt.Refusal.too_big, pack.load_bytes(big, 0));
    try expectEqual(fmt.Refusal.damaged, pack.load_bytes(big[0 .. test_pack.len + 4], 0));
}

test "fuzz: bit flips are refused by the CRC; with the CRC made good they load or are refused, and what loads runs" {
    defer pack.forget();
    const buf = try std.testing.allocator.alloc(u8, test_pack.len);
    defer std.testing.allocator.free(buf);
    var rng = std.Random.DefaultPrng.init(0x6C9A_C4);
    const r = rng.random();
    var crc_refused: u32 = 0;
    var loaded: u32 = 0;
    var refused: u32 = 0;
    for (0..600) |it| {
        @memcpy(buf, test_pack);
        const flips = 1 + r.uintLessThan(u32, 4);
        // Mostly the directory and the small sections, where the checks
        // live; sometimes anywhere.
        const span: usize = if (it % 3 == 0) buf.len else 640;
        for (0..flips) |_| buf[r.uintLessThan(usize, span)] ^= @as(u8, 1) << r.int(u3);
        const k: u8 = @intCast(it % 3);
        const raw = pack.load_bytes(buf, k);
        if (std.mem.eql(u8, buf[fmt.header_bytes..], test_pack[fmt.header_bytes..])) {
            // Only the header changed: its own checks decide.
            if (raw == .ok) run_some(k);
        } else {
            try expect(raw != .ok);
            crc_refused += 1;
        }
        put_crc(buf);
        const fixed_up = pack.load_bytes(buf, k);
        if (fixed_up == .ok) {
            loaded += 1;
            run_some(k);
        } else refused += 1;
    }
    std.debug.print("\npack fuzz: 600 flipped packs, {d} refused by the CRC; with the CRC made good {d} loaded and ran, {d} refused\n", .{ crc_refused, loaded, refused });
    try expect(crc_refused > 300 and refused > 50);
}

test "fuzz: random bytes behind a good magic and directory are refused" {
    defer pack.forget();
    const buf = try std.testing.allocator.alloc(u8, test_pack.len);
    defer std.testing.allocator.free(buf);
    var rng = std.Random.DefaultPrng.init(77);
    for (0..40) |it| {
        @memcpy(buf, test_pack);
        // Keep the header and directory, scramble one section's bytes.
        var d: fmt.Directory = undefined;
        _ = fmt.parse(buf[0..fmt.dir_max], @intCast(buf.len), &d);
        const secs = [_]fmt.Section{ d.tiles, d.horizon, d.tracks[0].map, d.tracks[0].center, d.tracks[2].arena, d.tracks[1].feat, d.attr, d.tracks[0].props };
        const s = secs[it % secs.len];
        rng.random().bytes(buf[s.off..][0..s.len]);
        put_crc(buf);
        const k: u8 = if (it % secs.len == 4) k_arena else if (it % secs.len == 5) k_crust else 0;
        const res = pack.load_bytes(buf, k);
        if (res == .ok) run_some(k);
        // A scrambled stream, map, centerline, arena or attribute table is
        // never taken as good (feat and props may happen to pass: then it
        // ran above).
        if (it % secs.len < 5 or it % secs.len == 6) try expect(res != .ok);
    }
}

// --- Crust and props in the sim --------------------------------------------------

fn park(w: *World, i: usize, x: i32, y: i32, h: fixed.Turn) void {
    const c = &w.cars[i];
    c.x = (x & 1023) << fixed.Q;
    c.y = (y & 1023) << fixed.Q;
    c.vx = 0;
    c.vy = 0;
    c.heading = h;
    c.immune = 0;
    c.progress = sim.nearest_sample(sim.track_of(w), c, c.progress);
}

/// Only car `keep` on the track, a human with no input (it goes straight).
fn quiet_world(keep: u8) World {
    var w: World = undefined;
    sim.reset(&w, .{ .track = track.pack_base, .seed = 5, .combat = false, .humans = .{ keep, world.no_human } });
    run_countdown(&w);
    for (&w.cars, 0..) |*c, i| c.active = i == keep;
    return w;
}

test "breakable crust: a touch cracks it, it breaks `warn` ticks later, a car on it falls, it heals after `period`" {
    defer pack.forget();
    try expectEqual(fmt.Refusal.ok, pack.load_bytes(test_pack, k_crust));
    var w = quiet_world(racers.legacy);
    var k: usize = 0;
    while (track.hazard_specs[k].kind != .crust) k += 1;
    const h = track.hazard_specs[k];
    try expectEqual(@as(u16, 30), h.warn);
    try expectEqual(@as(u16, 120), h.period);
    const mx = @divTrunc(h.x0 + h.x1, 2);
    const my = @divTrunc(h.y0 + h.y1, 2);
    try expectEqual(track.Attr.crust, track.pack_track.attr_at(mx, my));
    // Intact: a car stopped on it is fine, and cracks it.
    park(&w, racers.legacy, mx, my, 49152);
    for (0..h.warn) |_| {
        w.cars[racers.legacy].vx = 0;
        w.cars[racers.legacy].vy = 0;
        sim.simulate(&w, .{ 0, 0 });
        try expectEqual(world.Wreck.none, w.cars[racers.legacy].wreck);
    }
    try expectEqual(world.HazardState.warn, w.hazards[k].state);
    // The look: the map copy shows the cracked tile, the sim does not care.
    track.crust_look(&w.hazards);
    try expectEqual(track.crust_tile + 1, track.pack_track.tile_at(mx, my));
    // It breaks: the car still on it, parked (not crossing), falls.
    var fell = false;
    for (0..4) |_| {
        w.cars[racers.legacy].vx = 0;
        w.cars[racers.legacy].vy = 0;
        sim.simulate(&w, .{ 0, 0 });
        fell = fell or w.cars[racers.legacy].wreck == .fall;
    }
    try expectEqual(world.HazardState.active, w.hazards[k].state);
    try expect(fell);
    try expect(hazards.crust_broken(&w, mx, my));
    try expect(sim.pit_at(&w, &track.pack_track, mx, my));
    track.crust_look(&w.hazards);
    try expectEqual(track.crust_tile + 2, track.pack_track.tile_at(mx, my));
    // The respawn is not on the broken crust.
    var n: u32 = 0;
    while (w.cars[racers.legacy].wreck != .none and n < 600) : (n += 1) sim.simulate(&w, .{ 0, 0 });
    const c = &w.cars[racers.legacy];
    try expect(!sim.pit_at(&w, &track.pack_track, c.x >> fixed.Q, c.y >> fixed.Q));
    // It heals.
    w.cars[racers.legacy].active = false;
    n = 0;
    while (w.hazards[k].state != .idle and n < 400) : (n += 1) sim.simulate(&w, .{ 0, 0 });
    try expectEqual(world.HazardState.idle, w.hazards[k].state);
    try expect(!hazards.crust_broken(&w, mx, my));
    track.crust_look(&w.hazards);
    try expectEqual(track.crust_tile, track.pack_track.tile_at(mx, my));
}

// --- M9.1: crust that bites -----------------------------------------------------

/// The loaded track's first crust region.
fn crust_k() usize {
    var k: usize = 0;
    while (track.hazard_specs[k].kind != .crust) k += 1;
    return k;
}

/// World px of (along, lat) in crust region `h`'s frame (its sample).
fn band_point(h: *const track.HazardSpec, along: i32, lat: i32) [2]i32 {
    const s = track.pack_track.sample(h.sample);
    const sx = fixed.cos(s.tangent);
    const sy = fixed.sin(s.tangent);
    return .{ @as(i32, s.x) + ((sx * along - sy * lat) >> fixed.Q), @as(i32, s.y) + ((sy * along + sx * lat) >> fixed.Q) };
}

/// Car `i` at (along, lat) in the band's frame, heading down the track at
/// `speed` (Q16 px/tick).
fn place(w: *World, i: usize, h: *const track.HazardSpec, along: i32, lat: i32, speed: i32) void {
    const p = band_point(h, along, lat);
    const tangent = track.pack_track.sample(h.sample).tangent;
    park(w, i, p[0], p[1], tangent);
    w.cars[i].vx = fixed.mul(fixed.cos(tangent), speed);
    w.cars[i].vy = fixed.mul(fixed.sin(tangent), speed);
}

/// Car `i` on the centerline `back` samples before the band's, heading
/// along it at `speed`.
fn place_on_line(w: *World, i: usize, h: *const track.HazardSpec, back: u8, speed: i32) void {
    const k = h.sample -% back;
    const s = track.pack_track.sample(k);
    park(w, i, s.x, s.y, s.tangent);
    w.cars[i].progress = k;
    w.cars[i].vx = fixed.mul(fixed.cos(s.tangent), speed);
    w.cars[i].vy = fixed.mul(fixed.sin(s.tangent), speed);
}

/// The car's position along the band's frame, px.
fn along_of(w: *const World, i: usize, h: *const track.HazardSpec) i32 {
    const s = track.pack_track.sample(h.sample);
    const c = &w.cars[i];
    const ox = (((c.x >> fixed.Q) - @as(i32, s.x) + 512) & 1023) - 512;
    const oy = (((c.y >> fixed.Q) - @as(i32, s.y) + 512) & 1023) - 512;
    return (ox * fixed.cos(s.tangent) + oy * fixed.sin(s.tangent)) >> fixed.Q;
}

fn break_now(w: *World, k: usize) void {
    w.hazards[k].state = .active;
    w.hazards[k].timer = 0;
    w.hazards[k].hit = 0;
}

test "crust bites: a car driven onto a broken band falls in; one crossing as it breaks gets across; one in the air flies over" {
    defer pack.forget();
    try expectEqual(fmt.Refusal.ok, pack.load_bytes(test_pack, k_crust));
    const car = racers.legacy;
    var w = quiet_world(car);
    const k = crust_k();
    const h = &track.hazard_specs[k];
    // CRUST LOOP's band spans the road, 24 px deep: no deeper than a car is
    // long, so the old four-corner rule never took a car crossing it.
    try expectEqual(@as(i32, 24), h.x1 - h.x0);
    // Broken; the car (no input: straight on at 2.5 px/tick) drives onto it.
    break_now(&w, k);
    place(&w, car, h, @as(i32, h.along_lo) - 60, 0, 5 << 15);
    var n: u32 = 0;
    while (w.cars[car].wreck == .none and n < 60) : (n += 1) sim.simulate(&w, .{ 0, 0 });
    try expectEqual(world.Wreck.fall, w.cars[car].wreck);
    const c = &w.cars[car];
    try expectEqual(track.Attr.crust, track.pack_track.attr_at(c.x >> fixed.Q, c.y >> fixed.Q));
    // The centre over the hole, not the whole car: it went in at its near edge.
    try expect(along_of(&w, car, h) < @as(i32, h.along_lo) + 8);
    // Cracked and about to break with the car's centre already on it,
    // crossing at 2 px/tick: it gets across.
    w = quiet_world(car);
    w.hazards[k].state = .warn;
    w.hazards[k].timer = h.warn - 3;
    place(&w, car, h, @as(i32, h.along_lo) + 3, 0, 2 << 16);
    n = 0;
    while (along_of(&w, car, h) < @as(i32, h.along_hi) + 16 and n < 60) : (n += 1) {
        sim.simulate(&w, .{ 0, 0 });
        try expectEqual(world.Wreck.none, w.cars[car].wreck);
    }
    try expectEqual(world.HazardState.active, w.hazards[k].state);
    try expect(n < 60);
    // The next car onto it, right behind, goes in.
    place(&w, car, h, @as(i32, h.along_lo) - 30, 0, 5 << 15);
    n = 0;
    while (w.cars[car].wreck == .none and n < 60) : (n += 1) sim.simulate(&w, .{ 0, 0 });
    try expectEqual(world.Wreck.fall, w.cars[car].wreck);
    // Off a ramp's hop over the broken band: no fall, it lands beyond.
    w = quiet_world(car);
    break_now(&w, k);
    place(&w, car, h, @as(i32, h.along_lo) - 20, 0, 5 << 15);
    w.cars[car].hop = 40;
    w.cars[car].air = 40;
    n = 0;
    while (n < 60) : (n += 1) {
        sim.simulate(&w, .{ 0, 0 });
        try expectEqual(world.Wreck.none, w.cars[car].wreck);
    }
    try expect(along_of(&w, car, h) > @as(i32, h.along_hi) + 30);
}

test "the AI's crust sense: it steers round a broken band it can see (a crew blind to crust goes in), and waits for one across the road" {
    defer pack.forget();
    // FOOD COURT (Dead Mall): the ceiling-tile band leaves the balcony side
    // solid.
    const dead_mall = @embedFile("gen/packs/DEADMALL.GCP");
    const car = racers.snouty;
    var blind = ai.crews[car];
    blind.crust_sight = 0;
    for ([_]bool{ true, false }) |sees| {
        try expectEqual(fmt.Refusal.ok, pack.load_bytes(dead_mall, 1));
        var w = quiet_world(car);
        const k = crust_k();
        const h = &track.hazard_specs[k];
        const room = @as(i32, track.pack_track.sample(h.sample).half) - tuning.avoid_margin;
        try expect(h.lat_lo - tuning.ai_crust_clear >= -room); // a way round on the left
        break_now(&w, k);
        place_on_line(&w, car, h, 9, 5 << 15);
        var n: u32 = 0;
        while (w.cars[car].wreck == .none and along_of(&w, car, h) < @as(i32, h.along_hi) + 16 and n < 200) : (n += 1) {
            const in = if (sees) ai.drive(&w, car) else ai.drive_crew(&w, car, &blind);
            sim.simulate(&w, .{ in.byte(), 0 });
        }
        try expectEqual(if (sees) world.Wreck.none else world.Wreck.fall, w.cars[car].wreck);
        try expect(n < 200);
    }
    // CRUST LOOP's band spans the road: the AI slows and gets there as it
    // heals (it cracks it again and gets across), never in.
    try expectEqual(fmt.Refusal.ok, pack.load_bytes(test_pack, k_crust));
    var w = quiet_world(car);
    const k = crust_k();
    const h = &track.hazard_specs[k];
    break_now(&w, k);
    place_on_line(&w, car, h, 11, 5 << 15);
    var slowest: i32 = std.math.maxInt(i32);
    var n: u32 = 0;
    while (along_of(&w, car, h) < @as(i32, h.along_hi) + 16 and n < 600) : (n += 1) {
        sim.simulate(&w, .{ ai.drive(&w, car).byte(), 0 });
        try expectEqual(world.Wreck.none, w.cars[car].wreck);
        slowest = @min(slowest, sim.speed(&w.cars[car]));
    }
    try expect(n < 600);
    try expect(n >= h.period); // it waited for the heal
    try expect(slowest < fixed.one);
}

test "a solid prop is a wall: a car driven into it stops at its edge; decorations are not" {
    defer pack.forget();
    try expectEqual(fmt.Refusal.ok, pack.load_bytes(test_pack, k_landfill));
    var w = quiet_world(racers.kiddie);
    var solid: track.Prop = .{};
    var deco: track.Prop = .{};
    for (0..track.prop_n) |pk| {
        const p = track.prop(pk);
        if (p.radius > 0) solid = p else if (deco.x == 0 and p.y > 150) deco = p;
    }
    try expect(solid.radius == 6);
    const reach: i32 = @as(i32, solid.radius) + tuning.car_radius;
    // From 40 px west, heading east at it.
    park(&w, racers.kiddie, @as(i32, solid.x) - 40, solid.y, 0);
    var min_d: i32 = 1000;
    for (0..60) |_| {
        sim.simulate(&w, .{ 0, 0 });
        const c = &w.cars[racers.kiddie];
        const dx = (c.x >> fixed.Q) - solid.x;
        const dy = (c.y >> fixed.Q) - solid.y;
        min_d = @min(min_d, @as(i32, @intCast(std.math.sqrt(@as(u32, @intCast(dx * dx + dy * dy))))));
    }
    try expect(min_d >= reach - 2);
    // A decoration (a cone off the south edge) does nothing to a car.
    try expect(deco.radius == 0);
}

test "the content packs from a drive image: every track and arena loads" {
    defer pack.forget();
    pack.scan(romfs.Image.truncated_test(@embedFile("gen/packs/drive_packs.img")));
    pack.check_all();
    try expectEqual(@as(u8, 5), pack.count);
    for (pack.packs[0..pack.count], 0..) |*p, i| {
        try expectEqual(fmt.Refusal.ok, p.status);
        for (0..p.track_n + p.arena_n) |k| try expectEqual(fmt.Refusal.ok, pack.load(@intCast(i), @intCast(k)));
    }
    try expectEqual(@as(u8, 6 + 3 + 3 + 3 + 3 + 2), pack_rows.race_count());
    try expectEqual(@as(u8, 6), pack_rows.arena_count());
}
