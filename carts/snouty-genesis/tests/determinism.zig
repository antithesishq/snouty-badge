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
