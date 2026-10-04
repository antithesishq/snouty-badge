//! Scrubber determinism (SPEC.md section 10, PLAN.md "M3 Scrub: contract"
//! Track A): 600 scripted frames of the shipped test ROM (always) and of
//! Miniplanets (skipped when `roms/miniplanets.bin` is absent) with a full
//! `Keyframe` every 30 frames beside the undo records. Walking Left
//! through every record must give exactly each keyframe (and
//! `render_still` must leave each parked state alone), walking Right must
//! give live back; a tracked console and an untracked one stepped alike
//! end equal; resuming from a parked position and replaying the same
//! input gives the same live state, and the new records chain on.
const std = @import("std");
const core = @import("core");
const Md = core.Md;
const Pad = core.Pad;
const undo = core.undo;
const uu = @import("undo_unit.zig");
const golden_mini = @import("golden_mini.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const frames = 600;
const kfs = frames / undo.frames_per_record + 1;

fn mini_pad(frame: u32) u16 {
    return golden_mini.pad_at(frame / 2);
}

const Counter = struct {
    rows: u32 = 0,
    fn on_line(ctx: *anyopaque, _: u8, _: [*]const u8, _: u16, _: *const [64]u16) void {
        const h: *Counter = @ptrCast(@alignCast(ctx));
        h.rows += 1;
    }
};

/// `a` and `b` (two consoles) hold the same state. The 68000's fetch
/// window may point into each console's own work RAM: compared as an
/// offset.
fn same_consoles(a: *const Md, b: *const Md, ka: *Md.Keyframe, kb: *Md.Keyframe) !void {
    a.snapshot(ka);
    b.snapshot(kb);
    const pa = @intFromPtr(ka.cpu.win_ptr);
    const pb = @intFromPtr(kb.cpu.win_ptr);
    const ra = @intFromPtr(&a.work_ram);
    const rb = @intFromPtr(&b.work_ram);
    if (pa -% ra == pb -% rb) kb.cpu.win_ptr = ka.cpu.win_ptr;
    try uu.same_state("tracked vs untracked", ka, kb);
}

fn run(rom: []const u8, pad: *const fn (u32) u16) !void {
    const a = std.testing.allocator;
    const md = try a.create(Md);
    defer a.destroy(md);
    const plain = try a.create(Md);
    defer a.destroy(plain);
    const kf = try a.alloc(Md.Keyframe, kfs + 2);
    defer a.free(kf);
    const arena = try a.alignedAlloc(u8, .@"4", 8 << 20);
    defer a.free(arena);

    md.init_in_place(core.RomSource.from_slice(rom));
    plain.init_in_place(core.RomSource.from_slice(rom));
    var c: Counter = .{};
    md.line_sink = .{ .ctx = &c, .func = &Counter.on_line };
    // Rendering sets the sticky sprite status bits: both consoles render.
    var c2: Counter = .{};
    plain.line_sink = .{ .ctx = &c2, .func = &Counter.on_line };
    undo.init(arena);
    defer undo.disable();
    undo.reset(md);

    var f: u32 = 0;
    while (f < frames) : (f += 1) {
        if (f % undo.frames_per_record == 0) md.snapshot(&kf[f / undo.frames_per_record]);
        md.step_frame(pad(f), f % 2 == 1);
        undo.record_frame(md);
        plain.step_frame(pad(f), f % 2 == 1);
    }
    md.snapshot(&kf[kfs - 1]);
    try expect(!undo.lost_history());
    try expectEqual(@as(usize, kfs - 1), undo.record_count());
    try expectEqual(@as(u32, frames), undo.history_frames());
    try same_consoles(md, plain, &kf[kfs], &kf[kfs + 1]);

    // Left through every record: each parked state is its keyframe, and
    // drawing it changes nothing.
    var k: usize = kfs - 1;
    while (k > 0) {
        k -= 1;
        try expect(undo.step(md, -1));
        try expectEqual(@as(u32, frames) - @as(u32, @intCast(k)) * undo.frames_per_record, undo.depth_frames());
        md.snapshot(&kf[kfs]);
        try uu.same_state("left", &kf[kfs], &kf[k]);
        c = .{};
        md.render_still();
        try expectEqual(@as(u32, core.out_h), c.rows);
        md.snapshot(&kf[kfs]);
        try uu.same_state("render_still", &kf[kfs], &kf[k]);
    }
    try expect(!undo.can_step(-1));
    // Right back to live.
    k = 0;
    while (k < kfs - 1) {
        k += 1;
        try expect(undo.step(md, 1));
        md.snapshot(&kf[kfs]);
        try uu.same_state("right", &kf[kfs], &kf[k]);
    }
    try expect(!undo.parked());
    try same_consoles(md, plain, &kf[kfs], &kf[kfs + 1]);

    // Resume two records back and replay the same input: the same live
    // state, the history whole again, and the new records chain.
    try expect(undo.step(md, -1));
    try expect(undo.step(md, -1));
    try expectEqual(@as(u32, 60), undo.depth_frames());
    undo.resume_here(md);
    try expectEqual(@as(usize, kfs - 3), undo.record_count());
    f = frames - 60;
    while (f < frames) : (f += 1) {
        md.step_frame(pad(f), f % 2 == 1);
        undo.record_frame(md);
    }
    try expectEqual(@as(usize, kfs - 1), undo.record_count());
    try same_consoles(md, plain, &kf[kfs], &kf[kfs + 1]);
    try expect(undo.step(md, -1));
    md.snapshot(&kf[kfs]);
    try uu.same_state("after resume, one back", &kf[kfs], &kf[kfs - 2]);
    try expect(undo.step(md, -1));
    md.snapshot(&kf[kfs]);
    try uu.same_state("after resume, two back", &kf[kfs], &kf[kfs - 3]);
    try expect(undo.step(md, 1));
    try expect(undo.step(md, 1));
    try expect(!undo.parked());
    md.snapshot(&kf[kfs]);
    try uu.same_state("after resume, live", &kf[kfs], &kf[kfs - 1]);
}

var mini_buf: [0x80000]u8 = undefined;

test "determinism: test ROM, 600 frames, every record back and forth" {
    try run(try uu.test_rom(), uu.test_pad);
}

test "determinism: Miniplanets, 600 frames, every record back and forth" {
    const rom = uu.read_any("roms/miniplanets.bin", &mini_buf) orelse return error.SkipZigTest;
    try run(rom, mini_pad);
}

// ---- Fast forward (docs/FAST_FORWARD.md at the root) ----

/// Genesis frames per fast-forward update in the test (`tuning.ff_max_frames`).
const ff_batch = 8;

/// `rom` for `n` frames at 1x (two frames per update, the second rendered,
/// as app.zig paces it) and in fast-forward batches (`ff_batch` frames, only
/// the last rendered), with one pad per batch, `pad` of its first frame:
/// the consoles must agree after every batch. The fast-forward console is
/// tracked by the scrubber; Left through every record afterwards must give
/// the 1x console's state at that record's boundary.
fn ff_matches_1x(rom: []const u8, pad: *const fn (u32) u16, n: u32) !void {
    const a = std.testing.allocator;
    const one = try a.create(Md);
    defer a.destroy(one);
    const ff = try a.create(Md);
    defer a.destroy(ff);
    const n_kf = n / undo.frames_per_record + 1;
    const kf = try a.alloc(Md.Keyframe, n_kf + 2);
    defer a.free(kf);
    const arena = try a.alignedAlloc(u8, .@"4", 8 << 20);
    defer a.free(arena);

    one.init_in_place(core.RomSource.from_slice(rom));
    ff.init_in_place(core.RomSource.from_slice(rom));
    var c1: Counter = .{};
    one.line_sink = .{ .ctx = &c1, .func = &Counter.on_line };
    var c2: Counter = .{};
    ff.line_sink = .{ .ctx = &c2, .func = &Counter.on_line };
    undo.init(arena);
    defer undo.disable();
    undo.reset(ff);
    one.snapshot(&kf[0]);

    var f: u32 = 0;
    var batches: u32 = 0;
    while (f < n) : (f += ff_batch) {
        const p = pad(f);
        for (0..ff_batch) |i| {
            const g = f + @as(u32, @intCast(i));
            one.step_frame(p, g % 2 == 1);
            if ((g + 1) % undo.frames_per_record == 0) one.snapshot(&kf[(g + 1) / undo.frames_per_record]);
            ff.step_frame(p, i == ff_batch - 1);
            undo.record_frame(ff);
        }
        batches += 1;
        one.snapshot(&kf[n_kf]);
        ff.snapshot(&kf[n_kf + 1]);
        same_ff("after a batch", one, ff, &kf[n_kf], &kf[n_kf + 1]) catch |err| {
            std.debug.print("frame {d}: 1x and fast forward differ\n", .{f + ff_batch});
            return err;
        };
    }
    // Fast forward really skipped the pixel work of all but one frame in
    // each batch.
    try expect(c2.rows <= batches * core.out_h);
    try expect(c1.rows > c2.rows);

    // The fast-forwarded history is the 1x one (the newest `max_records`
    // records of it on a long run).
    try expect(!undo.lost_history());
    const held = @min(n, undo.max_records * undo.frames_per_record);
    try expectEqual(held, undo.history_frames());
    var k: usize = n_kf - 1;
    while (k > (n - held) / undo.frames_per_record) {
        k -= 1;
        try expect(undo.step(ff, -1));
        ff.snapshot(&kf[n_kf]);
        try same_ff("fast-forward history", one, ff, &kf[k], &kf[n_kf]);
    }
}

/// `ka` (a snapshot of `a`) and `kb` (of `b`) hold the same console, with
/// two allowances. The 68000's fetch window may point into each console's
/// own work RAM (compared as an offset). The VDP's sprite table cache
/// (`spr_cache`, `spr_band`, `spr_count`) is derived from VRAM and
/// registers 5 and 12 and rebuilt lazily by the first rendered line after
/// a change (`spr_dirty`): the 1x console renders every second frame and
/// fast forward every eighth, so one may hold a rebuilt cache where the
/// other still has the old one marked dirty, and entries past `spr_count`
/// keep whatever a longer list left. Compared only where both are in use
/// (neither dirty): the live entries and the bands. Modifies `ka` and `kb`.
fn same_ff(what: []const u8, a: *const Md, b: *const Md, ka: *Md.Keyframe, kb: *Md.Keyframe) !void {
    const pa = @intFromPtr(ka.cpu.win_ptr);
    const pb = @intFromPtr(kb.cpu.win_ptr);
    if (pa -% @intFromPtr(&a.work_ram) == pb -% @intFromPtr(&b.work_ram)) kb.cpu.win_ptr = ka.cpu.win_ptr;
    const in_use = !ka.vdp.spr_dirty and !kb.vdp.spr_dirty;
    for ([_]*Md.Keyframe{ ka, kb }) |k| {
        const v = &k.vdp;
        if (!in_use) {
            v.spr_dirty = true;
            v.spr_count = 0;
            v.spr_band = @splat(@splat(0));
        }
        @memset(v.spr_cache[v.spr_count..], 0);
    }
    try uu.same_state(what, ka, kb);
}

/// Sonic 1's pad per frame (`tools/scripts/snd_sonic1.json` less the
/// splash): the SEGA logo and the title, Start into Green Hill Zone at
/// frame 928, then running right from 1088 with a jump every 160 frames.
fn sonic_pad(frame: u32) u16 {
    var p: u16 = 0;
    if (frame >= 928 and frame < 934) p |= Pad.start;
    if (frame >= 1088) p |= Pad.right;
    if (frame >= 1088 and frame % 160 < 8) p |= Pad.c;
    return p;
}

var sonic_buf: [0x80000]u8 = undefined;

test "determinism: fast-forward batches equal 1x pacing, test ROM" {
    try ff_matches_1x(try uu.test_rom(), uu.test_pad, frames);
}

test "determinism: fast-forward batches equal 1x pacing, Miniplanets" {
    const rom = uu.read_any("roms/miniplanets.bin", &mini_buf) orelse return error.SkipZigTest;
    try ff_matches_1x(rom, mini_pad, frames);
}

test "determinism: fast-forward batches equal 1x pacing, Sonic 1" {
    // Sprites in play: `~/roms/genesis/sonic1.bin` (local only, never in the
    // repository), skipped when missing.
    const home = std.testing.environ.getPosix("HOME") orelse return error.SkipZigTest;
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/roms/genesis/sonic1.bin", .{home});
    const rom = std.Io.Dir.cwd().readFile(std.testing.io, path, &sonic_buf) catch return error.SkipZigTest;
    try ff_matches_1x(rom, sonic_pad, 2400);
}
