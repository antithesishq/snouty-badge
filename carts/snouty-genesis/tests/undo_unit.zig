//! `core/undo.zig` unit tests (PLAN.md "M3 Scrub: contract", Track A):
//! the scrubber's ring over the shipped test ROM and over hand-made
//! writes: Left then Right symmetry against full `Keyframe`s, the depth
//! and history arithmetic, truncation on resume, eviction order, losing
//! the history and rebuilding it, the live-on-a-boundary step, `disable`,
//! and `Md.render_still` leaving the state untouched.
//!
//! The tracker is file-level state (one console): every test starts with
//! `undo.init` on its own arena and ends with `undo.disable()` so the
//! other tests run untracked.
const std = @import("std");
const core = @import("core");
const Md = core.Md;
const Pad = core.Pad;
const undo = core.undo;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const prefixes = [_][]const u8{ "", "carts/snouty-genesis/", "../", "../../" };

/// A file under the cart directory, whatever the test's working directory.
pub fn read_any(rel: []const u8, buf: []u8) ?[]u8 {
    for (prefixes) |pre| {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}{s}", .{ pre, rel }) catch continue;
        return std.Io.Dir.cwd().readFile(std.testing.io, path, buf) catch continue;
    }
    return null;
}

var test_rom_buf: [0x10000]u8 = undefined;

pub fn test_rom() ![]u8 {
    return read_any("roms/snouty-test.bin", &test_rom_buf) orelse error.TestRomMissing;
}

/// The test ROM's pad per Genesis frame: `tools/scripts/m1_play.json`
/// (updates of two frames; the Select tap as Genesis A).
pub fn test_pad(frame: u32) u16 {
    const u = frame / 2;
    var p: u16 = 0;
    if (u >= 30 and u <= 59) p |= Pad.right;
    if (u >= 60 and u <= 74) p |= Pad.down | Pad.b;
    if (u >= 80 and u <= 81) p |= Pad.start;
    if (u >= 90 and u <= 94) p |= Pad.c;
    if (u >= 102 and u <= 103) p |= Pad.a;
    if (u >= 105 and u <= 119) p |= Pad.up | Pad.left;
    return p;
}

/// Every `Keyframe` field equal (`std.meta.eql` field by field); prints
/// the ones that differ.
pub fn same_state(what: []const u8, a: *const Md.Keyframe, b: *const Md.Keyframe) !void {
    var ok = true;
    inline for (@typeInfo(Md.Keyframe).@"struct".field_names) |n| {
        if (!std.meta.eql(@field(a.*, n), @field(b.*, n))) {
            std.debug.print("{s}: {s} differs\n", .{ what, n });
            ok = false;
        }
    }
    if (!ok) return error.TestUnexpectedResult;
}

pub const Fixture = struct {
    md: *Md,
    arena: []align(4) u8,
    kf: []Md.Keyframe,
    frame: u32 = 0,

    /// A console on the test ROM, an arena of `slots` slots, `kfs`
    /// keyframe buffers; tracking on from reset.
    pub fn init(rom: []const u8, slots: usize, kfs: usize) !Fixture {
        const a = std.testing.allocator;
        const md = try a.create(Md);
        md.init_in_place(core.RomSource.from_slice(rom));
        const arena = try a.alignedAlloc(u8, .@"4", slots * @sizeOf(undo.Slot));
        const kf = try a.alloc(Md.Keyframe, kfs);
        undo.init(arena);
        undo.reset(md);
        return .{ .md = md, .arena = arena, .kf = kf };
    }

    pub fn deinit(f: *Fixture) void {
        undo.disable();
        const a = std.testing.allocator;
        a.free(f.kf);
        a.free(f.arena);
        a.destroy(f.md);
    }

    /// Step one tracked frame with `pad(frame)`.
    pub fn step(f: *Fixture, pad: *const fn (u32) u16) void {
        f.md.step_frame(pad(f.frame), false);
        undo.record_frame(f.md);
        f.frame += 1;
    }
};

test "undo: small state fits, slot layout" {
    try expectEqual(@as(usize, 68), @sizeOf(undo.Slot));
    try expectEqual(@as(usize, 4), @offsetOf(undo.Slot, "data"));
    std.debug.print("\nundo: @sizeOf(Md.Small) = {d} B, {d} slots per record head\n", .{ @sizeOf(Md.Small), undo.small_slots });
    try expect(@sizeOf(Md.Small) <= 2048);
}

test "undo: Left then Right restores exact keyframes, depth and history" {
    var f = try Fixture.init(try test_rom(), 4000, 8);
    defer f.deinit();
    try expect(!undo.can_step(-1));
    try expect(!undo.can_step(1));
    try expectEqual(@as(u32, 0), undo.history_frames());

    // Keyframes at frames 0, 30, 60, 90, then live at 100.
    var k: usize = 0;
    while (f.frame < 100) {
        if (f.frame % 30 == 0) {
            f.md.snapshot(&f.kf[k]);
            k += 1;
        }
        f.step(test_pad);
    }
    f.md.snapshot(&f.kf[4]);
    try expectEqual(@as(usize, 3), undo.record_count());
    try expectEqual(@as(u32, 100), undo.history_frames());
    try expectEqual(@as(u32, 0), undo.depth_frames());
    try expect(!undo.parked());

    // Left: 10 frames back (the open record), then 30 more each.
    const depths = [_]u32{ 10, 40, 70, 100 };
    for (depths, 0..) |d, i| {
        try expect(undo.step(f.md, -1));
        try expectEqual(d, undo.depth_frames());
        try expect(undo.parked());
        var now: Md.Keyframe = undefined;
        f.md.snapshot(&now);
        try same_state("left", &now, &f.kf[3 - i]);
    }
    try expect(!undo.can_step(-1));
    try expect(!undo.step(f.md, -1));
    // Right back to live, through the same states.
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        try expect(undo.step(f.md, 1));
        var now: Md.Keyframe = undefined;
        f.md.snapshot(&now);
        try same_state("right", &now, &f.kf[1 + i]);
    }
    try expect(!undo.parked());
    try expect(!undo.can_step(1));
    try expectEqual(@as(u32, 100), undo.history_frames());

    // Tracking resumes where it was: the open record still covers 90..100.
    while (f.frame < 115) f.step(test_pad);
    try expectEqual(@as(usize, 3), undo.record_count());
    try expect(undo.step(f.md, -1));
    try expectEqual(@as(u32, 25), undo.depth_frames());
    var now: Md.Keyframe = undefined;
    f.md.snapshot(&now);
    try same_state("after more frames", &now, &f.kf[3]);
    try expect(undo.step(f.md, 1));
}

test "undo: Left from live on a boundary skips the empty open record" {
    var f = try Fixture.init(try test_rom(), 4000, 3);
    defer f.deinit();
    while (f.frame < 90) {
        if (f.frame == 30) f.md.snapshot(&f.kf[0]);
        if (f.frame == 60) f.md.snapshot(&f.kf[1]);
        f.step(test_pad);
    }
    f.md.snapshot(&f.kf[2]);
    try expectEqual(@as(u32, 90), undo.history_frames());
    try expect(undo.step(f.md, -1));
    try expectEqual(@as(u32, 30), undo.depth_frames());
    var now: Md.Keyframe = undefined;
    f.md.snapshot(&now);
    try same_state("one back", &now, &f.kf[1]);
    try expect(undo.step(f.md, -1));
    try expectEqual(@as(u32, 60), undo.depth_frames());
    // Right twice lands on live (the empty record is re-applied in the
    // same step).
    try expect(undo.step(f.md, 1));
    try expectEqual(@as(u32, 30), undo.depth_frames());
    try expect(undo.step(f.md, 1));
    try expect(!undo.parked());
    f.md.snapshot(&now);
    try same_state("live", &now, &f.kf[2]);
}

test "undo: resume while parked truncates the future and chains on" {
    var f = try Fixture.init(try test_rom(), 4000, 4);
    defer f.deinit();
    while (f.frame < 120) {
        if (f.frame == 60) f.md.snapshot(&f.kf[0]);
        f.step(test_pad);
    }
    try expectEqual(@as(usize, 4), undo.record_count());
    // Back to frame 60 (the open record is empty: 2 steps, depth 60).
    try expect(undo.step(f.md, -1));
    try expect(undo.step(f.md, -1));
    try expectEqual(@as(u32, 60), undo.depth_frames());
    const used_before = undo.slots_in_use();
    undo.resume_here(f.md);
    try expect(!undo.parked());
    try expectEqual(@as(usize, 2), undo.record_count());
    try expectEqual(@as(u32, 60), undo.history_frames());
    try expect(undo.slots_in_use() < used_before);
    try expect(!undo.can_step(1));
    // Play on from 60 with a different pad: a new future.
    f.frame = 60;
    const other = struct {
        fn pad(_: u32) u16 {
            return Pad.left | Pad.up;
        }
    }.pad;
    while (f.frame < 100) {
        if (f.frame == 90) f.md.snapshot(&f.kf[1]);
        f.step(other);
    }
    f.md.snapshot(&f.kf[2]);
    try expectEqual(@as(usize, 3), undo.record_count());
    try expectEqual(@as(u32, 100), undo.history_frames());
    // Back: 90 (open record), 60 (the resumed record), 30 (the old one).
    try expect(undo.step(f.md, -1));
    var now: Md.Keyframe = undefined;
    f.md.snapshot(&now);
    try same_state("new 90", &now, &f.kf[1]);
    try expect(undo.step(f.md, -1));
    f.md.snapshot(&now);
    try same_state("resume point 60", &now, &f.kf[0]);
    try expect(undo.step(f.md, -1));
    try expectEqual(@as(u32, 70), undo.depth_frames());
    try expect(undo.step(f.md, 1));
    try expect(undo.step(f.md, 1));
    try expect(undo.step(f.md, 1));
    f.md.snapshot(&now);
    try same_state("new live", &now, &f.kf[2]);
}

test "undo: record_frame while parked forgets the history" {
    var f = try Fixture.init(try test_rom(), 4000, 1);
    defer f.deinit();
    while (f.frame < 70) f.step(test_pad);
    try expect(undo.step(f.md, -1));
    f.step(test_pad);
    try expect(!undo.parked());
    try expectEqual(@as(usize, 0), undo.record_count());
    try expectEqual(@as(u32, 0), undo.history_frames());
}

/// Write one byte into each of `n` work RAM blocks from `first` through
/// the 68000 bus (the hooked path).
fn dirty_blocks(md: *Md, first: u32, n: u32, v: u8) void {
    var b = md.bus_for();
    var i: u32 = 0;
    while (i < n) : (i += 1) b.write8(@intCast(0xFF0000 + ((first + i) % 1024) * 64), v);
}

/// End the open record without stepping the console.
fn boundary() void {
    var i: u32 = 0;
    while (i < undo.frames_per_record) : (i += 1) undo.record_frame(md_for_boundary);
}
var md_for_boundary: *Md = undefined;

test "undo: eviction drops the oldest records first" {
    const s = undo.small_slots;
    // Room for exactly five records of s + 10 slots.
    var f = try Fixture.init(try test_rom(), 5 * (s + 10), 8);
    defer f.deinit();
    md_for_boundary = f.md;
    var r: u32 = 0;
    while (r < 5) : (r += 1) {
        f.md.snapshot(&f.kf[r]);
        dirty_blocks(f.md, r * 10, 10, @intCast(r + 1));
        boundary();
    }
    // The fifth close opened a sixth record whose small slots evicted the
    // oldest.
    try expectEqual(@as(usize, 4), undo.record_count());
    try expectEqual(@as(u32, 4 * 30), undo.history_frames());
    try expectEqual(4 * (s + 10) + s, undo.slots_in_use());
    // Every held record goes back to its keyframe; the oldest is kf[1].
    var k: usize = 5;
    while (k > 1) {
        k -= 1;
        try expect(undo.step(f.md, -1));
        var now: Md.Keyframe = undefined;
        f.md.snapshot(&now);
        try same_state("evict", &now, &f.kf[k]);
    }
    try expect(!undo.can_step(-1));
    while (undo.step(f.md, 1)) {}
    try expect(!undo.parked());
}

test "undo: max_records caps the ring" {
    var f = try Fixture.init(try test_rom(), 200 * (undo.small_slots + 1), 1);
    defer f.deinit();
    md_for_boundary = f.md;
    var r: u32 = 0;
    while (r < undo.max_records + 5) : (r += 1) {
        dirty_blocks(f.md, r, 1, 0x55);
        boundary();
    }
    try expectEqual(@as(usize, undo.max_records), undo.record_count());
    try expectEqual(@as(u32, undo.max_records * 30), undo.history_frames());
    var n: u32 = 0;
    while (undo.step(f.md, -1)) n += 1;
    try expectEqual(@as(u32, undo.max_records), n);
    while (undo.step(f.md, 1)) {}
}

test "undo: an oversized record loses the history until the next boundary" {
    const s = undo.small_slots;
    var f = try Fixture.init(try test_rom(), 2 * s + 20, 2);
    defer f.deinit();
    md_for_boundary = f.md;
    dirty_blocks(f.md, 0, 5, 1);
    boundary();
    try expectEqual(@as(usize, 1), undo.record_count());
    // More blocks than the whole ring: the closed record goes first, then
    // the open one itself.
    dirty_blocks(f.md, 100, 2 * s + 20, 2);
    try expect(undo.lost_history());
    try expectEqual(@as(usize, 0), undo.record_count());
    try expectEqual(@as(u32, 0), undo.history_frames());
    try expectEqual(@as(usize, 0), undo.slots_in_use());
    try expect(!undo.can_step(-1));
    // Nothing is copied while lost.
    dirty_blocks(f.md, 300, 10, 3);
    try expectEqual(@as(usize, 0), undo.slots_in_use());
    // The boundary rebuilds from here.
    boundary();
    try expect(!undo.lost_history());
    try expectEqual(@as(usize, 0), undo.record_count());
    try expectEqual(@as(usize, s), undo.slots_in_use());
    f.md.snapshot(&f.kf[0]);
    dirty_blocks(f.md, 500, 4, 4);
    boundary();
    try expectEqual(@as(usize, 1), undo.record_count());
    try expect(undo.step(f.md, -1));
    var now: Md.Keyframe = undefined;
    f.md.snapshot(&now);
    try same_state("rebuilt", &now, &f.kf[0]);
    try expect(undo.step(f.md, 1));
}

test "undo: every write path is tracked (68000, Z80, VDP port and DMA, SRAM)" {
    var f = try Fixture.init(try test_rom(), 4000, 2);
    defer f.deinit();
    md_for_boundary = f.md;
    const md = f.md;
    // One frame into the record so Left applies just the open record.
    md.snapshot(&f.kf[0]);
    undo.record_frame(md);
    var b = md.bus_for();
    // 68000: work RAM word and byte, Z80 RAM through A00000 (bus held).
    b.write16(0xFF1234, 0xBEEF);
    b.write8(0xE0FFFF, 0x12);
    b.write16(0xA11100, 0x0100);
    b.write8(0xA00123, 0x77);
    // Z80: its RAM and work RAM through the bank window (bank FF8000).
    var zb = md.z80bus_for();
    zb.write(0x1FF0, 0x99);
    md.z80_bank = 0x1FF;
    zb.write(0x8010, 0x42);
    // VDP: a data port VRAM write, a 68000->VRAM DMA from work RAM, a
    // fill and a copy.
    b.write16(0xC00004, 0x8114); // display off, DMA on (reg 1 = 0x14)
    b.write16(0xC00004, 0x8F02); // auto-increment 2
    b.write16(0xC00004, 0x4100);
    b.write16(0xC00004, 0x0000); // VRAM write at 0100
    b.write16(0xC00000, 0xCAFE);
    // DMA 68000 -> VRAM 2000, 0x40 words from FF0000.
    b.write16(0xC00004, 0x9340);
    b.write16(0xC00004, 0x9400);
    b.write16(0xC00004, 0x9500);
    b.write16(0xC00004, 0x9680);
    b.write16(0xC00004, 0x977F);
    b.write16(0xC00004, 0x6000);
    b.write16(0xC00004, 0x0080);
    // Fill 0x100 bytes at 4000 with 0x5A.
    b.write16(0xC00004, 0x9300);
    b.write16(0xC00004, 0x9401);
    b.write16(0xC00004, 0x9780);
    b.write16(0xC00004, 0x4000);
    b.write16(0xC00004, 0x0081);
    b.write16(0xC00000, 0x5A00);
    // Copy 0x80 bytes from 0100 to 6000 with increment 3 (per byte).
    b.write16(0xC00004, 0x8F03);
    b.write16(0xC00004, 0x9380);
    b.write16(0xC00004, 0x9400);
    b.write16(0xC00004, 0x9500);
    b.write16(0xC00004, 0x9601);
    b.write16(0xC00004, 0x97C0);
    b.write16(0xC00004, 0x6000);
    b.write16(0xC00004, 0x00C1);
    // SRAM (none declared by the test ROM: poke a map in).
    md.sram_map = .{ .lo = 0x200000, .hi = 0x203FFF };
    md.sram_active = md.sram_map;
    b.write8(0x200010, 0xAB);
    b.write16(0x203FFE, 0xCDEF);
    const blocks = undo.open_record_blocks();
    try expect(blocks[0] >= 3 and blocks[1] >= 4 and blocks[2] >= 2 and blocks[3] == 2);
    try expect(undo.step(md, -1));
    var now: Md.Keyframe = undefined;
    md.snapshot(&now);
    try same_state("write paths", &now, &f.kf[0]);
    try expect(undo.step(md, 1));
    try expectEqual(@as(u8, 0xAB), md.sram[0x10]);
}

test "undo: disable stops tracking and forgets" {
    var f = try Fixture.init(try test_rom(), 4000, 1);
    defer f.deinit();
    while (f.frame < 40) f.step(test_pad);
    try expect(undo.can_step(-1));
    undo.disable();
    try expect(!undo.can_step(-1));
    try expectEqual(@as(u32, 0), undo.history_frames());
    try expectEqual(@as(usize, 0), undo.slots_in_use());
    dirty_blocks(f.md, 0, 50, 9);
    f.step(test_pad);
    try expectEqual(@as(usize, 0), undo.slots_in_use());
    try expectEqual(@as(usize, 0), undo.open_record_slots());
    // reset turns it back on.
    undo.reset(f.md);
    try expectEqual(@as(usize, undo.small_slots), undo.slots_in_use());
}

const RowCheck = struct {
    rows: u32 = 0,
    in_order: bool = true,
    fn on_line(ctx: *anyopaque, row: u8, _: [*]const u8, _: u16, _: *const [64]u16) void {
        const h: *RowCheck = @ptrCast(@alignCast(ctx));
        if (row != h.rows) h.in_order = false;
        h.rows += 1;
    }
};

test "undo: render_still draws 128 rows and leaves the state as it was" {
    var f = try Fixture.init(try test_rom(), 4000, 2);
    defer f.deinit();
    var h: RowCheck = .{};
    f.md.line_sink = .{ .ctx = &h, .func = &RowCheck.on_line };
    while (f.frame < 75) f.step(test_pad);
    // Mid-frame positions too: a sprite table change pending.
    f.md.vdp.spr_dirty = true;
    f.md.vdp.status = 0x0060;
    f.md.snapshot(&f.kf[0]);
    f.md.render_still();
    try expectEqual(@as(u32, core.out_h), h.rows);
    try expect(h.in_order);
    f.md.snapshot(&f.kf[1]);
    try same_state("render_still", &f.kf[1], &f.kf[0]);
    // Parked too.
    try expect(undo.step(f.md, -1));
    f.md.snapshot(&f.kf[0]);
    h = .{};
    f.md.render_still();
    try expectEqual(@as(u32, core.out_h), h.rows);
    f.md.snapshot(&f.kf[1]);
    try same_state("render_still parked", &f.kf[1], &f.kf[0]);
    try expect(undo.step(f.md, 1));
}
