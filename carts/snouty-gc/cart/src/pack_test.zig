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
