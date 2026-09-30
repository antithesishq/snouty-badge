//! Scrubber sizing (print only, like `golden-mini`): Miniplanets through
//! `golden_mini.pad_at` for 1200 Genesis frames (600 badge updates: boot,
//! title, the menus, the level load, then play), one undo record per 30
//! frames through the real store, printing each record's slots (the
//! `Md.Small` head plus one per block first written, by region) and a
//! per-scene summary with the history a ring of `ring_slots` holds (SPEC.md
//! 10.1's table redone). Skips when the ROM is absent.
const std = @import("std");
const core = @import("core");
const Md = core.Md;
const undo = core.undo;
const uu = @import("undo_unit.zig");
const golden_mini = @import("golden_mini.zig");

const frames = 1200;
const records = frames / undo.frames_per_record;
/// About what the badge's RAM window leaves for the arena after M3.
const ring_slots = 1560;

const Scene = struct { name: []const u8, from: u32, to: u32 };
/// Record ranges (inclusive) by what the screen shows (from the printed
/// sizes): the boot with the Z80 driver upload, the title, the load after
/// the first Start (update 100 = frame 200), the menu, the level load
/// after the second (frame 260, the load lands in record 9), then play.
const scenes = [_]Scene{
    .{ .name = "boot", .from = 0, .to = 1 },
    .{ .name = "title", .from = 2, .to = 6 },
    .{ .name = "menu load", .from = 7, .to = 7 },
    .{ .name = "menu", .from = 8, .to = 8 },
    .{ .name = "level load", .from = 9, .to = 9 },
    .{ .name = "play", .from = 10, .to = records - 1 },
};

var mini_buf: [0x80000]u8 = undefined;

test "scrub-sizing: Miniplanets record sizes per scene" {
    const rom = uu.read_any("roms/miniplanets.bin", &mini_buf) orelse return error.SkipZigTest;
    const a = std.testing.allocator;
    const md = try a.create(Md);
    defer a.destroy(md);
    const arena = try a.alignedAlloc(u8, .@"4", 16 << 20);
    defer a.free(arena);
    md.init_in_place(core.RomSource.from_slice(rom));
    undo.init(arena);
    defer undo.disable();
    undo.reset(md);

    var slots: [records]u32 = undefined;
    var blocks: [records][4]u32 = undefined;
    var f: u32 = 0;
    while (f < frames) : (f += 1) {
        md.step_frame(golden_mini.pad_at(f / 2), f % 2 == 1);
        if ((f + 1) % undo.frames_per_record == 0) {
            const r = f / undo.frames_per_record;
            slots[r] = @intCast(undo.open_record_slots());
            blocks[r] = undo.open_record_blocks();
        }
        undo.record_frame(md);
    }
    std.debug.print("\nscrub-sizing: Miniplanets, {d} frames, {d}-slot head (Md.Small {d} B), records of {d} frames\n", .{ frames, undo.small_slots, @sizeOf(Md.Small), undo.frames_per_record });
    for (slots, blocks, 0..) |s, b, r| {
        std.debug.print("scrub-sizing: record {d:>2} frames {d:>4}-{d:>4}: {d:>4} slots ({d:>5} B), RAM {d:>3} VRAM {d:>4} Z80 {d:>3} SRAM {d}\n", .{ r, r * 30, r * 30 + 29, s, s * @sizeOf(undo.Slot), b[0], b[1], b[2], b[3] });
    }
    // Scene means; the play mean stands in for the open record's size.
    var means: [scenes.len]u32 = undefined;
    for (scenes, &means) |sc, *m| {
        var sum: u32 = 0;
        var r = sc.from;
        while (r <= sc.to) : (r += 1) sum += slots[r];
        m.* = sum / (sc.to - sc.from + 1);
    }
    const open = means[scenes.len - 1];
    for (scenes, means) |sc, mean| {
        var lo: u32 = std.math.maxInt(u32);
        var hi: u32 = 0;
        var r = sc.from;
        while (r <= sc.to) : (r += 1) {
            lo = @min(lo, slots[r]);
            hi = @max(hi, slots[r]);
        }
        // Closed records of this size a full ring holds beside a play-sized
        // open record (capped at max_records); the open one adds up to 0.5 s.
        const held = @min(@as(u32, undo.max_records), (ring_slots - open) / mean);
        std.debug.print("scrub-sizing: {s:<10} records {d:>2}-{d:>2}: {d}-{d} slots, mean {d} ({d} B); a {d}-slot ring holds {d} = {d}.{d} s back\n", .{ sc.name, sc.from, sc.to, lo, hi, mean, mean * @sizeOf(undo.Slot), ring_slots, held, held / 2, (held % 2) * 5 });
    }
}
