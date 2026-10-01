//! Golden run of the shipped test ROM (SPEC.md section 16, PLAN.md M1
//! Track C): `roms/snouty-test.bin` for `frames` Genesis frames under
//! `tools/scripts/m1_play.json`, rendering every second frame as the badge
//! does (60/30), hashing each rendered frame's 128 badge rows (160 tagged
//! indices plus the CRAM each row was emitted with) and recording the
//! `tone()` sequence.
//!
//! The script is the preview/badge-bench one: `[{ "from": t, "to": t,
//! "hold": [...] }]` in badge updates (two Genesis frames each), `to`
//! inclusive, badge button names mapped as the frontend maps them (SPEC.md
//! section 5): B = B, A = C, START, the d-pad, and SELECT held for less
//! than the menu hold = Genesis A for 4 frames from the update after its
//! release (frontend/input.zig's tap).
//!
//! `golden_hashes` / `golden_tone_hash` start empty: the test then PRINTS
//! the hashes, and integration fills the tables after an eyeball and an ear
//! check. With the other M1 tracks stubbed the frames are backdrop only.
//! Also: two runs from reset give the same hashes (determinism), and a
//! snapshot/restore mid-run reproduces the same later frame.
//!
//! The ROM and the script are read at run time (outside this module's
//! directory, so `@embedFile` cannot reach them); the tests skip if the
//! ROM is absent.
const std = @import("std");
const core = @import("core");
const Md = core.Md;
const Pad = core.Pad;

/// Genesis frames in the golden run (150 badge updates).
const frames = 300;
/// Genesis frames per update (60/30); the second of each pair renders.
const per_update = 2;
/// Frames (1-based count of frames stepped, always a rendered one) whose
/// hash is checked: boot (display on about frame 12), the sprite moving
/// right, moving down fast, after the Start reset, C held, the A tap (PSG
/// muted), up-left, idle at the end.
const checkpoints = [_]u32{ 20, 80, 140, 170, 186, 206, 230, 300 };
/// Hashes at `checkpoints` from the reviewed run (empty: print only).
const golden_hashes = [_]u64{
    0x47D4BB45A56859D8, // frame 20: display just on, backdrop blue, PSG only
    0xB84A549DDF672C51, // frame 80: Right held, sprite moving
    0x38DCDECF549DF3DC, // frame 140: Down+B done, sprite low right
    0x10739FD1D602DE48, // frame 170: Start re-centred the sprite
    0xF10A37C41544CE94, // frame 186: badge A (Genesis C) held
    0x6FC6BB307FC883E7, // frame 206: after the Select tap (Genesis A muted the PSG)
    0x21AF403195CA431B, // frame 230: Up+Left moving
    0x856E31A5493A6DE7, // frame 300: end of the script
};
/// Hash of the `tone()` change list over the run (0: print only).
const golden_tone_hash: u64 = 0x036397CFD28EAF56; // 11 changes: PSG 220 Hz at 18, FM 440/659 toggling every 30 from 19

/// Updates a Select tap sends Genesis A for (input.zig: tap_frames 4).
const tap_updates = 2;

const Hasher = struct {
    rows: u32 = 0,
    next_row: u32 = 0,
    in_order: bool = true,
    hash: u64 = 0,

    fn on_line(ctx: *anyopaque, row: u8, line: [*]const u8, width: u16, cram: *const [64]u16) void {
        const h: *Hasher = @ptrCast(@alignCast(ctx));
        if (row != h.next_row) h.in_order = false;
        h.next_row = @as(u32, row) + 1;
        h.rows += 1;
        var w = std.hash.Wyhash.init(h.hash);
        w.update(&.{row});
        w.update(line[0..width]);
        w.update(std.mem.sliceAsBytes(cram));
        h.hash = w.final();
    }

    fn sink(h: *Hasher) core.LineSink {
        return .{ .ctx = h, .func = &on_line };
    }

    fn start_frame(h: *Hasher) void {
        h.* = .{};
    }
};

/// Tried in order; the test binary's working directory depends on how the
/// build runs it.
const prefixes = [_][]const u8{ "", "carts/snouty-genesis/", "../", "../../" };

fn read_any(rel: []const u8, buf: []u8) ?[]u8 {
    for (prefixes) |pre| {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}{s}", .{ pre, rel }) catch continue;
        return std.Io.Dir.cwd().readFile(std.testing.io, path, buf) catch continue;
    }
    return null;
}

const Hold = struct { from: u32, to: u32, hold: []const []const u8 };

fn button(name: []const u8) !u16 {
    const map = [_]struct { []const u8, u16 }{
        .{ "UP", Pad.up },       .{ "DOWN", Pad.down }, .{ "LEFT", Pad.left },
        .{ "RIGHT", Pad.right }, .{ "B", Pad.b },       .{ "A", Pad.c },
        .{ "START", Pad.start },
    };
    for (map) |m| if (std.mem.eql(u8, m[0], name)) return m[1];
    return error.UnknownButton;
}

const updates = frames / per_update;

/// Pad word per badge update from the script.
fn script_pads(json: []const u8, pads: *[updates]u16) !void {
    const parsed = try std.json.parseFromSlice([]const Hold, std.testing.allocator, json, .{});
    defer parsed.deinit();
    @memset(pads, 0);
    for (parsed.value) |h| {
        var bits: u16 = 0;
        var select = false;
        for (h.hold) |name| {
            if (std.mem.eql(u8, name, "SELECT")) select = true else bits |= try button(name);
        }
        var u = h.from;
        while (u <= h.to and u < updates) : (u += 1) pads[u] |= bits;
        // A short Select hold is a tap: Genesis A after the release.
        if (select and h.to - h.from + 1 < 15) {
            u = h.to + 1;
            while (u <= h.to + tap_updates and u < updates) : (u += 1) pads[u] |= Pad.a;
        }
    }
}

var rom_buf: [0x80000]u8 = undefined;
var script_buf: [0x4000]u8 = undefined;

const Run = struct {
    hashes: [checkpoints.len]u64 = undefined,
    /// Hash of every rendered frame, by update.
    all: [updates]u64 = undefined,
    tone_hash: u64 = 0,
    tone_changes: u32 = 0,
};

fn load(pads: *[updates]u16) !?[]u8 {
    const rom = read_any("roms/snouty-test.bin", &rom_buf) orelse return null;
    const json = read_any("tools/scripts/m1_play.json", &script_buf) orelse return error.FileNotFound;
    try script_pads(json, pads);
    return rom;
}

/// Step updates `from..to` of the script, hashing each rendered frame into
/// `run.all` and the tone changes into `run.tone_hash`.
fn play(md: *Md, h: *Hasher, pads: *const [updates]u16, from: u32, to: u32, run: *Run, print_tones: bool) !void {
    var last: ?core.Tone = md.tone();
    var u = from;
    while (u < to) : (u += 1) {
        h.start_frame();
        var f: u32 = 0;
        while (f < per_update) : (f += 1) {
            md.step_frame(pads[u], f == per_update - 1);
            const t = md.tone();
            if (!std.meta.eql(t, last)) {
                last = t;
                run.tone_changes += 1;
                var w = std.hash.Wyhash.init(run.tone_hash);
                const rec = [_]u32{ md.frame_count, if (t) |x| x.hz else 0, if (t) |x| x.level else 0xFF };
                w.update(std.mem.sliceAsBytes(&rec));
                run.tone_hash = w.final();
                if (print_tones) {
                    if (t) |x| std.debug.print("  tone at frame {d}: {d} Hz level {d}\n", .{ md.frame_count, x.hz, x.level }) else std.debug.print("  tone at frame {d}: off\n", .{md.frame_count});
                }
            }
        }
        try std.testing.expectEqual(@as(u32, core.out_h), h.rows);
        try std.testing.expect(h.in_order);
        var w = std.hash.Wyhash.init(h.hash);
        w.update(std.mem.sliceAsBytes(&md.vdp.cram));
        run.all[u] = w.final();
    }
}

fn pick_checkpoints(run: *Run) void {
    for (checkpoints, 0..) |c, i| run.hashes[i] = run.all[c / per_update - 1];
}

test "golden: snouty-test.bin scripted run, frame hashes and tone sequence" {
    var pads: [updates]u16 = undefined;
    const rom = (try load(&pads)) orelse return error.SkipZigTest;
    const md = try std.testing.allocator.create(Md);
    defer std.testing.allocator.destroy(md);
    md.init_in_place(core.RomSource.from_slice(rom));
    var h: Hasher = .{};
    md.line_sink = h.sink();

    var run: Run = .{};
    const print = golden_hashes.len == 0 or golden_tone_hash == 0;
    if (print) std.debug.print("\ngolden: snouty-test.bin, {d} frames, tone changes:\n", .{frames});
    try play(md, &h, &pads, 0, updates, &run, print);
    pick_checkpoints(&run);

    if (print) {
        std.debug.print("golden: frame hashes (fill `golden_hashes` after review):\n", .{});
        for (checkpoints, run.hashes) |c, g| std.debug.print("  frame {d}: 0x{X:0>16}\n", .{ c, g });
        std.debug.print("golden: {d} tone changes, tone hash 0x{X:0>16}\n", .{ run.tone_changes, run.tone_hash });
        std.debug.print("golden: 68000 pc {X:0>6} sr {X:0>4}, z80 pc {X:0>4}, vdp line {d}\n", .{ md.cpu.pc, md.cpu.sr, md.z80.pc, md.vdp.line });
    }
    if (golden_hashes.len != 0) {
        for (golden_hashes, run.hashes, checkpoints) |e, g, c| {
            if (e != g) std.debug.print("golden: frame {d}: got 0x{X:0>16}, want 0x{X:0>16}\n", .{ c, g, e });
        }
        try std.testing.expectEqualSlices(u64, &golden_hashes, &run.hashes);
    }
    if (golden_tone_hash != 0) try std.testing.expectEqual(golden_tone_hash, run.tone_hash);
}

test "golden: two runs from reset are identical (determinism)" {
    var pads: [updates]u16 = undefined;
    const rom = (try load(&pads)) orelse return error.SkipZigTest;
    const md = try std.testing.allocator.create(Md);
    defer std.testing.allocator.destroy(md);
    var h: Hasher = .{};

    var a: Run = .{};
    md.init_in_place(core.RomSource.from_slice(rom));
    md.line_sink = h.sink();
    try play(md, &h, &pads, 0, updates, &a, false);

    var b: Run = .{};
    md.reset();
    try play(md, &h, &pads, 0, updates, &b, false);

    try std.testing.expectEqualSlices(u64, &a.all, &b.all);
    try std.testing.expectEqual(a.tone_hash, b.tone_hash);
}

test "golden: snapshot and restore mid-run reproduce the later frames" {
    var pads: [updates]u16 = undefined;
    const rom = (try load(&pads)) orelse return error.SkipZigTest;
    const md = try std.testing.allocator.create(Md);
    defer std.testing.allocator.destroy(md);
    const k = try std.testing.allocator.create(Md.Keyframe);
    defer std.testing.allocator.destroy(k);
    var h: Hasher = .{};
    md.init_in_place(core.RomSource.from_slice(rom));
    md.line_sink = h.sink();

    // Snapshot in the middle of the Right hold, run on, restore, run again.
    const mid = 45;
    var before: Run = .{};
    try play(md, &h, &pads, 0, mid, &before, false);
    md.snapshot(k);
    var a: Run = .{};
    try play(md, &h, &pads, mid, updates, &a, false);
    const end_frame = md.frame_count;

    var b: Run = .{};
    md.restore(k);
    try std.testing.expectEqual(@as(u32, mid * per_update), md.frame_count);
    try play(md, &h, &pads, mid, updates, &b, false);
    try std.testing.expectEqual(end_frame, md.frame_count);
    try std.testing.expectEqualSlices(u64, a.all[mid..], b.all[mid..]);
    try std.testing.expectEqual(a.tone_hash, b.tone_hash);
}
