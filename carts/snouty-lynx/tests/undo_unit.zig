//! `core/undo.zig` unit tests (PLAN.md "M3 Scrub: contract", Track A),
//! ported from Snouty Genesis's: Left then Right against full state copies
//! on the shipped raycast ROM, the depth and history arithmetic, the
//! live-on-a-boundary step, truncation on resume, eviction order, the
//! `max_records` cap, losing the history and rebuilding it, every RAM
//! write path, `touch_range` wrapping at 64 KB, `disable`, the `Small`
//! round trip and `refresh_display` leaving the state alone.
//!
//! The tracker is file-level state (one console): every test starts with
//! `undo.init` on its own arena and ends with `undo.disable()` so the
//! other tests run untracked. Also the shared helpers of determinism.zig
//! and scrub_sizing.zig (`State`, `same_state`, the raycast pad sequence).
const std = @import("std");
const core = @import("core");
const runner = @import("runner.zig");
const files = @import("testfiles.zig");
const Lynx = core.Lynx;
const Pad = core.Pad;
const undo = core.undo;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

/// A console's whole state for comparisons: RAM and `Lynx.Small`.
pub const State = struct {
    ram: [0x10000]u8,
    small: Lynx.Small,
};

pub fn snapshot(l: *const Lynx, out: *State) void {
    out.ram = l.ram;
    l.save_small(&out.small);
}

/// Equal RAM (the first differing address printed) and every `Small`
/// field equal (`std.meta.eql`; a differing struct field also names its
/// first differing member).
pub fn same_state(what: []const u8, a: *const State, b: *const State) !void {
    var ok = true;
    for (a.ram, b.ram, 0..) |x, y, i| {
        if (x != y) {
            std.debug.print("{s}: ram[${X:0>4}] differs ({X:0>2} vs {X:0>2})\n", .{ what, i, x, y });
            ok = false;
            break;
        }
    }
    inline for (@typeInfo(Lynx.Small).@"struct".field_names) |n| {
        const fa = @field(a.small, n);
        const fb = @field(b.small, n);
        if (!std.meta.eql(fa, fb)) {
            ok = false;
            const T = @TypeOf(fa);
            if (@typeInfo(T) == .@"struct") {
                inline for (@typeInfo(T).@"struct".field_names) |m| {
                    if (!std.meta.eql(@field(fa, m), @field(fb, m))) std.debug.print("{s}: {s}.{s} differs\n", .{ what, n, m });
                }
            } else std.debug.print("{s}: {s} differs\n", .{ what, n });
        }
    }
    if (!ok) return error.TestUnexpectedResult;
}

var rom_buf: [0x10000]u8 = undefined;
var script_buf: [0x1000]u8 = undefined;

/// The shipped ROM as a `Cart` (the file buffer is a static).
pub fn raycast() !core.Cart {
    const file = files.read_cart_file("roms/raycast.lnx", &rom_buf) orelse return error.RaycastMissing;
    return switch (runner.cart_from_file(file)) {
        .ok => |c| c,
        .refused => error.RaycastRefused,
    };
}

/// The pad words of the stepped frames of `tools/scripts/m1_play.json`
/// (300 updates through the runner's frontend model: the splash skipped
/// at 40, then 260 frames of moves and turns), looped: frame f gets
/// `seq[f % len]`. The splash-skipping A is suppressed, so the loop seam
/// presses nothing.
pub const PlayPads = struct {
    seq: [300]u16 = undefined,
    len: usize = 0,

    pub fn init() !PlayPads {
        var p: PlayPads = .{};
        const json = files.read_cart_file("tools/scripts/m1_play.json", &script_buf) orelse return error.FileNotFound;
        var ctl: [300]u16 = undefined;
        try runner.parse_script(std.testing.allocator, json, &ctl);
        var fe: runner.Frontend = .{};
        for (ctl) |c| if (fe.update(c)) |pad| {
            p.seq[p.len] = pad;
            p.len += 1;
        };
        return p;
    }

    pub fn at(p: *const PlayPads, frame: u32) u16 {
        return p.seq[frame % p.len];
    }
};

pub const Fixture = struct {
    l: *Lynx,
    arena: []align(4) u8,
    st: []State,
    pads: PlayPads,
    frame: u32 = 0,

    /// raycast booted, an arena of `slots` slots, `states` state buffers;
    /// tracking on from reset.
    pub fn init(slots: usize, states: usize) !Fixture {
        const a = std.testing.allocator;
        const l = try a.create(Lynx);
        errdefer a.destroy(l);
        l.init_in_place(try raycast());
        const arena = try a.alignedAlloc(u8, .@"4", slots * @sizeOf(undo.Slot));
        errdefer a.free(arena);
        const st = try a.alloc(State, states);
        undo.init(arena);
        undo.reset(l);
        return .{ .l = l, .arena = arena, .st = st, .pads = try PlayPads.init() };
    }

    pub fn deinit(f: *Fixture) void {
        undo.disable();
        const a = std.testing.allocator;
        a.free(f.st);
        a.free(f.arena);
        a.destroy(f.l);
    }

    /// Step one tracked frame with the play script's pad.
    pub fn step(f: *Fixture) void {
        f.stepp(f.pads.at(f.frame));
    }

    pub fn stepp(f: *Fixture, pad: u16) void {
        f.l.step_frame(pad);
        undo.record_frame(f.l);
        f.frame += 1;
    }

    pub fn snap(f: *Fixture, i: usize) void {
        snapshot(f.l, &f.st[i]);
    }

    /// The live state equals `st[i]`.
    pub fn same(f: *Fixture, what: []const u8, i: usize) !void {
        var now: State = undefined;
        snapshot(f.l, &now);
        try same_state(what, &now, &f.st[i]);
    }
};

/// Room for this many slots covers any raycast record (RAM is 1024 blocks).
const big = 4000;

test "undo: slot layout, small state size" {
    try expectEqual(@as(usize, 68), @sizeOf(undo.Slot));
    try expectEqual(@as(usize, 4), @offsetOf(undo.Slot, "data"));
    std.debug.print("\nundo: @sizeOf(Lynx.Small) = {d} B, {d} slots per record head\n", .{ @sizeOf(Lynx.Small), undo.small_slots });
    try expect(@sizeOf(Lynx.Small) <= 1024);
}

test "undo: Left then Right restores exact states, depth and history" {
    var f = try Fixture.init(big, 5);
    defer f.deinit();
    try expect(!undo.can_step(-1));
    try expect(!undo.can_step(1));
    try expectEqual(@as(u32, 0), undo.history_frames());

    // States at frames 0, 30, 60, 90, then live at 100.
    var k: usize = 0;
    while (f.frame < 100) {
        if (f.frame % 30 == 0) {
            f.snap(k);
            k += 1;
        }
        f.step();
    }
    f.snap(4);
    try expectEqual(@as(usize, 3), undo.record_count());
    try expectEqual(@as(u32, 100), undo.history_frames());
    try expectEqual(@as(u32, 0), undo.depth_frames());
    try expect(!undo.parked());

    // Left: 10 frames back (the open record), then 30 more each.
    const depths = [_]u32{ 10, 40, 70, 100 };
    for (depths, 0..) |d, i| {
        try expect(undo.step(f.l, -1));
        try expectEqual(d, undo.depth_frames());
        try expect(undo.parked());
        try f.same("left", 3 - i);
    }
    try expect(!undo.can_step(-1));
    try expect(!undo.step(f.l, -1));
    // Right back to live, through the same states.
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        try expect(undo.step(f.l, 1));
        try f.same("right", 1 + i);
    }
    try expect(!undo.parked());
    try expect(!undo.can_step(1));
    try expectEqual(@as(u32, 100), undo.history_frames());

    // Tracking resumes where it was: the open record still covers 90..100.
    while (f.frame < 115) f.step();
    try expectEqual(@as(usize, 3), undo.record_count());
    try expect(undo.step(f.l, -1));
    try expectEqual(@as(u32, 25), undo.depth_frames());
    try f.same("after more frames", 3);
    try expect(undo.step(f.l, 1));
}

test "undo: Left from live on a boundary skips the empty open record" {
    var f = try Fixture.init(big, 3);
    defer f.deinit();
    while (f.frame < 90) {
        if (f.frame == 30) f.snap(0);
        if (f.frame == 60) f.snap(1);
        f.step();
    }
    f.snap(2);
    try expectEqual(@as(u32, 90), undo.history_frames());
    try expect(undo.step(f.l, -1));
    try expectEqual(@as(u32, 30), undo.depth_frames());
    try f.same("one back", 1);
    try expect(undo.step(f.l, -1));
    try expectEqual(@as(u32, 60), undo.depth_frames());
    try f.same("two back", 0);
    // Right twice lands on live (the empty record is re-applied in the
    // same step).
    try expect(undo.step(f.l, 1));
    try expectEqual(@as(u32, 30), undo.depth_frames());
    try expect(undo.step(f.l, 1));
    try expect(!undo.parked());
    try f.same("live", 2);
}

test "undo: resume while parked truncates the future and chains on" {
    var f = try Fixture.init(big, 4);
    defer f.deinit();
    while (f.frame < 120) {
        if (f.frame == 60) f.snap(0);
        f.step();
    }
    try expectEqual(@as(usize, 4), undo.record_count());
    // Back to frame 60 (the open record is empty: 2 steps, depth 60).
    try expect(undo.step(f.l, -1));
    try expect(undo.step(f.l, -1));
    try expectEqual(@as(u32, 60), undo.depth_frames());
    const used_before = undo.slots_in_use();
    undo.resume_here(f.l);
    try expect(!undo.parked());
    try expectEqual(@as(usize, 2), undo.record_count());
    try expectEqual(@as(u32, 60), undo.history_frames());
    try expect(undo.slots_in_use() < used_before);
    try expect(!undo.can_step(1));
    // Play on from 60 with a different pad: a new future.
    f.frame = 60;
    while (f.frame < 100) {
        if (f.frame == 90) f.snap(1);
        f.stepp(Pad.left | Pad.up);
    }
    f.snap(2);
    try expectEqual(@as(usize, 3), undo.record_count());
    try expectEqual(@as(u32, 100), undo.history_frames());
    // Back: 90 (open record), 60 (the resumed record), 30 (the old one).
    try expect(undo.step(f.l, -1));
    try f.same("new 90", 1);
    try expect(undo.step(f.l, -1));
    try f.same("resume point 60", 0);
    try expect(undo.step(f.l, -1));
    try expectEqual(@as(u32, 70), undo.depth_frames());
    try expect(undo.step(f.l, 1));
    try expect(undo.step(f.l, 1));
    try expect(undo.step(f.l, 1));
    try f.same("new live", 2);
}

test "undo: record_frame while parked forgets the history" {
    var f = try Fixture.init(big, 1);
    defer f.deinit();
    while (f.frame < 70) f.step();
    try expect(undo.step(f.l, -1));
    f.step();
    try expect(!undo.parked());
    try expectEqual(@as(usize, 0), undo.record_count());
    try expectEqual(@as(u32, 0), undo.history_frames());
}

/// Write one byte into each of `n` RAM blocks from `first` through the
/// CPU's bus (the hooked path), below Suzy space (blocks 0..1007).
fn dirty_blocks(l: *Lynx, first: u32, n: u32, v: u8) void {
    var i: u32 = 0;
    while (i < n) : (i += 1) l.write(@intCast(((first + i) % 1008) * 64 + 17), v);
}

/// End the open record without stepping the console.
fn boundary(l: *Lynx) void {
    var i: u32 = 0;
    while (i < undo.frames_per_record) : (i += 1) undo.record_frame(l);
}

test "undo: eviction drops the oldest records first" {
    const s = undo.small_slots;
    // Room for exactly five records of s + 10 slots.
    var f = try Fixture.init(5 * (s + 10), 8);
    defer f.deinit();
    var r: u32 = 0;
    while (r < 5) : (r += 1) {
        f.snap(r);
        dirty_blocks(f.l, r * 10, 10, @intCast(r + 1));
        boundary(f.l);
    }
    // The fifth close opened a sixth record whose small slots evicted the
    // oldest.
    try expectEqual(@as(usize, 4), undo.record_count());
    try expectEqual(@as(u32, 4 * 30), undo.history_frames());
    try expectEqual(4 * (s + 10) + s, undo.slots_in_use());
    // Every held record goes back to its state; the oldest is st[1].
    var k: usize = 5;
    while (k > 1) {
        k -= 1;
        try expect(undo.step(f.l, -1));
        try f.same("evict", k);
    }
    try expect(!undo.can_step(-1));
    while (undo.step(f.l, 1)) {}
    try expect(!undo.parked());
}

test "undo: max_records caps the ring" {
    var f = try Fixture.init(200 * (undo.small_slots + 1), 1);
    defer f.deinit();
    var r: u32 = 0;
    while (r < undo.max_records + 5) : (r += 1) {
        dirty_blocks(f.l, r, 1, 0x55);
        boundary(f.l);
    }
    try expectEqual(@as(usize, undo.max_records), undo.record_count());
    try expectEqual(@as(u32, undo.max_records * 30), undo.history_frames());
    var n: u32 = 0;
    while (undo.step(f.l, -1)) n += 1;
    try expectEqual(@as(u32, undo.max_records), n);
    while (undo.step(f.l, 1)) {}
}

test "undo: an oversized record loses the history until the next boundary" {
    const s = undo.small_slots;
    var f = try Fixture.init(2 * s + 20, 2);
    defer f.deinit();
    dirty_blocks(f.l, 0, 5, 1);
    boundary(f.l);
    try expectEqual(@as(usize, 1), undo.record_count());
    // More blocks than the whole ring: the closed record goes first, then
    // the open one itself.
    dirty_blocks(f.l, 100, 2 * s + 20, 2);
    try expect(undo.lost_history());
    try expectEqual(@as(usize, 0), undo.record_count());
    try expectEqual(@as(u32, 0), undo.history_frames());
    try expectEqual(@as(usize, 0), undo.slots_in_use());
    try expect(!undo.can_step(-1));
    // Nothing is copied while lost.
    dirty_blocks(f.l, 300, 10, 3);
    try expectEqual(@as(usize, 0), undo.slots_in_use());
    // The boundary rebuilds from here.
    boundary(f.l);
    try expect(!undo.lost_history());
    try expectEqual(@as(usize, 0), undo.record_count());
    try expectEqual(@as(usize, s), undo.slots_in_use());
    f.snap(0);
    dirty_blocks(f.l, 500, 4, 4);
    boundary(f.l);
    try expectEqual(@as(usize, 1), undo.record_count());
    try expect(undo.step(f.l, -1));
    try f.same("rebuilt", 0);
    try expect(undo.step(f.l, 1));
}

test "undo: every RAM write path is tracked (bus fast path, $FFF8, under ROM and vectors, overlays off, decrypt range)" {
    var f = try Fixture.init(big, 1);
    defer f.deinit();
    const l = f.l;
    // One frame into the record so Left applies just the open record.
    f.snap(0);
    undo.record_frame(l);
    const mapctl = l.mapctl;
    l.write(0x1234, 0xA5); // RAM fast path
    l.write(0xFFF8, 0x11); // always RAM
    l.write(0xFE10, 0x22); // ROM space: the RAM underneath
    l.write(0xFFFE, 0x33); // vector space: the RAM underneath
    l.write(0xFFF9, 0x03); // MAPCTL: Suzy and Mikey off
    l.write(0xFC10, 0x44); // RAM under Suzy
    l.write(0xFD80, 0x55); // RAM under Mikey
    l.write(0xFFF9, mapctl);
    // What the $FE4A trap and Suzy's spans use.
    undo.touch_range(0x8000, 0x100);
    @memset(l.ram[0x8000..0x8100], 0x66);
    undo.touch_short(0x9FF0, 80);
    @memset(l.ram[0x9FF0..0xA040], 0x77);
    undo.touch(0xB000);
    l.ram[0xB000] = 0x88;
    // Blocks: $1234, $FFC0 ($FFF8 and $FFFE), $FE00, $FC00, $FD80,
    // $8000-$80FF (4), $9FF0-$A03F (2: $9FC0 and $A000), $B000.
    try expectEqual(undo.small_slots + 1 + 1 + 1 + 1 + 1 + 4 + 2 + 1, undo.open_record_slots());
    try expect(undo.step(l, -1));
    try f.same("write paths", 0);
    try expect(undo.step(l, 1));
    try expectEqual(@as(u8, 0x44), l.ram[0xFC10]);
    try expectEqual(@as(u8, 0x88), l.ram[0xB000]);
}

test "undo: touch_range and touch_short wrap at 64 KB" {
    var f = try Fixture.init(big, 1);
    defer f.deinit();
    const l = f.l;
    f.snap(0);
    undo.record_frame(l);
    // $FFC0..$003F: blocks 1023 and 0.
    undo.touch_range(0xFFC0, 0x80);
    try expectEqual(undo.small_slots + 2, undo.open_record_slots());
    @memset(l.ram[0xFFC0..], 0x99);
    @memset(l.ram[0..0x40], 0x99);
    // A short run across the seam: $FFF0..$0030 (no new blocks), then
    // $0070..$00BF (blocks 1 and 2).
    undo.touch_short(0xFFF0, 0x40);
    try expectEqual(undo.small_slots + 2, undo.open_record_slots());
    undo.touch_short(0x0070, 0x50);
    try expectEqual(undo.small_slots + 4, undo.open_record_slots());
    // The whole of RAM at once (the reboot trap).
    undo.touch_range(0, 0x10000);
    try expectEqual(undo.small_slots + undo.ram_blocks, undo.open_record_slots());
    @memset(&l.ram, 0xAB);
    try expect(undo.step(l, -1));
    try f.same("wrap", 0);
    try expect(undo.step(l, 1));
    try expectEqual(@as(u8, 0xAB), l.ram[0x4321]);
}

test "undo: disable stops tracking and forgets" {
    var f = try Fixture.init(big, 1);
    defer f.deinit();
    while (f.frame < 40) f.step();
    try expect(undo.can_step(-1));
    undo.disable();
    try expect(!undo.can_step(-1));
    try expectEqual(@as(u32, 0), undo.history_frames());
    try expectEqual(@as(usize, 0), undo.slots_in_use());
    dirty_blocks(f.l, 0, 50, 9);
    f.step();
    try expectEqual(@as(usize, 0), undo.slots_in_use());
    try expectEqual(@as(usize, 0), undo.open_record_slots());
    // reset turns it back on.
    undo.reset(f.l);
    try expectEqual(@as(usize, undo.small_slots), undo.slots_in_use());
}

test "undo: Small round trip keeps cart, display and idle_sleep" {
    var f = try Fixture.init(big, 2);
    defer f.deinit();
    const l = f.l;
    while (f.frame < 45) f.step();
    var k: Lynx.Small = undefined;
    l.save_small(&k);
    f.snap(0);
    const cart = l.cart;
    // Diverge, then flip the kept fields.
    while (f.frame < 75) f.step();
    const display = l.display;
    l.idle_sleep = true;
    l.load_small(&k);
    try expect(l.idle_sleep);
    try expect(std.meta.eql(cart, l.cart));
    try expect(std.meta.eql(display, l.display));
    l.ram = f.st[0].ram;
    try f.same("load_small", 0);
    // save_small zeroes padding: two saves of one state give equal bytes.
    var k2: Lynx.Small = undefined;
    @memset(std.mem.asBytes(&k2), 0xEE);
    l.save_small(&k2);
    try expect(std.mem.eql(u8, std.mem.asBytes(&k), std.mem.asBytes(&k2)));
    l.idle_sleep = false;
}

test "undo: refresh_display shows the parked frame and changes nothing else" {
    var f = try Fixture.init(big, 2);
    defer f.deinit();
    const l = f.l;
    while (f.frame < 75) {
        if (f.frame == 60) f.snap(0);
        f.step();
    }
    f.snap(1);
    l.refresh_display();
    try f.same("refresh live", 1);
    try expect(undo.step(l, -1));
    try f.same("parked", 0);
    // step() already refreshed: the picture is the frame at DISPADR.
    const a: usize = l.mikey.dispadr_latched & 0xFFFC;
    try expect(std.mem.eql(u8, &l.display.pixels, l.ram[a..][0..core.frame_bytes]));
    l.refresh_display();
    try f.same("refresh parked", 0);
    try expect(undo.step(l, 1));
    try f.same("live again", 1);
}
