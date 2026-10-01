//! Scrubber determinism (SPEC.md section 10, PLAN.md "M3 Scrub: contract"
//! Track A): 600 frames of the shipped raycast ROM under the m1 play
//! script (looped, tests/undo_unit.zig `PlayPads`).
//!
//! 1. Replay: a full `Lynx` copy every 30 frames; for every k, restore
//!    copy k, step the same 30 frames, and the result equals copy k + 1
//!    (RAM byte for byte, `Lynx.Small` field by field, the first
//!    difference named). The console is a function of its state and the
//!    pads, so a restored state is a true keyframe.
//! 2. Undo: the same run tracked; walking Left through every record gives
//!    exactly each copy (and `refresh_display` leaves each parked state
//!    alone), walking Right gives live back; a tracked console and an
//!    untracked one stepped alike end equal; resuming two records back and
//!    replaying the same pads gives the same live state, and the new
//!    records chain on.
const std = @import("std");
const core = @import("core");
const Lynx = core.Lynx;
const undo = core.undo;
const uu = @import("undo_unit.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const frames = 600;
/// 30-frame records as SPEC 10 wrote them (the cart uses 60; set below).
const per = 30;
const kfs = frames / per + 1;

fn same_consoles(what: []const u8, a: *const Lynx, b: *const Lynx, sa: *uu.State, sb: *uu.State) !void {
    uu.snapshot(a, sa);
    uu.snapshot(b, sb);
    try uu.same_state(what, sa, sb);
}

test "determinism: raycast, a restored copy steps to the next copy (600 frames)" {
    undo.frames_per_record = per;
    const a = std.testing.allocator;
    const pads = try uu.PlayPads.init();
    const copies = try a.alloc(Lynx, kfs);
    defer a.free(copies);
    const l = try a.create(Lynx);
    defer a.destroy(l);
    const st = try a.alloc(uu.State, 2);
    defer a.free(st);

    l.init_in_place(try uu.raycast());
    var f: u32 = 0;
    while (f < frames) : (f += 1) {
        if (f % per == 0) copies[f / per] = l.*;
        l.step_frame(pads.at(f));
    }
    copies[kfs - 1] = l.*;

    var k: usize = 0;
    while (k + 1 < kfs) : (k += 1) {
        l.* = copies[k];
        var i: u32 = 0;
        while (i < per) : (i += 1) l.step_frame(pads.at(@intCast(k * per + i)));
        var buf: [32]u8 = undefined;
        const what = try std.fmt.bufPrint(&buf, "copy {d} + 30", .{k});
        try same_consoles(what, l, &copies[k + 1], &st[0], &st[1]);
    }
}

test "determinism: raycast, every record back and forth, resume (600 frames)" {
    undo.frames_per_record = per;
    const a = std.testing.allocator;
    const pads = try uu.PlayPads.init();
    const l = try a.create(Lynx);
    defer a.destroy(l);
    const plain = try a.create(Lynx);
    defer a.destroy(plain);
    const kf = try a.alloc(uu.State, kfs + 2);
    defer a.free(kf);
    const arena = try a.alignedAlloc(u8, .@"4", 8 << 20);
    defer a.free(arena);

    const cart = try uu.raycast();
    l.init_in_place(cart);
    plain.init_in_place(cart);
    undo.init(arena);
    defer undo.disable();
    undo.reset(l);

    var f: u32 = 0;
    while (f < frames) : (f += 1) {
        if (f % per == 0) uu.snapshot(l, &kf[f / per]);
        l.step_frame(pads.at(f));
        undo.record_frame(l);
        plain.step_frame(pads.at(f));
    }
    uu.snapshot(l, &kf[kfs - 1]);
    try expect(!undo.lost_history());
    try expectEqual(@as(usize, kfs - 1), undo.record_count());
    try expectEqual(@as(u32, frames), undo.history_frames());
    try same_consoles("tracked vs untracked", l, plain, &kf[kfs], &kf[kfs + 1]);

    // Left through every record: each parked state is its copy, and
    // refreshing the picture changes nothing.
    var k: usize = kfs - 1;
    while (k > 0) {
        k -= 1;
        try expect(undo.step(l, -1));
        try expectEqual(@as(u32, frames) - @as(u32, @intCast(k)) * per, undo.depth_frames());
        uu.snapshot(l, &kf[kfs]);
        try uu.same_state("left", &kf[kfs], &kf[k]);
        l.refresh_display();
        uu.snapshot(l, &kf[kfs]);
        try uu.same_state("refresh_display", &kf[kfs], &kf[k]);
    }
    try expect(!undo.can_step(-1));
    // Right back to live.
    k = 0;
    while (k < kfs - 1) {
        k += 1;
        try expect(undo.step(l, 1));
        uu.snapshot(l, &kf[kfs]);
        try uu.same_state("right", &kf[kfs], &kf[k]);
    }
    try expect(!undo.parked());
    try same_consoles("back at live vs untracked", l, plain, &kf[kfs], &kf[kfs + 1]);

    // Resume two records back and replay the same pads: the same live
    // state, the history whole again, and the new records chain.
    try expect(undo.step(l, -1));
    try expect(undo.step(l, -1));
    try expectEqual(@as(u32, 2 * per), undo.depth_frames());
    undo.resume_here(l);
    try expectEqual(@as(usize, kfs - 3), undo.record_count());
    f = frames - 2 * per;
    while (f < frames) : (f += 1) {
        l.step_frame(pads.at(f));
        undo.record_frame(l);
    }
    try expectEqual(@as(usize, kfs - 1), undo.record_count());
    try same_consoles("after resume vs untracked", l, plain, &kf[kfs], &kf[kfs + 1]);
    try expect(undo.step(l, -1));
    uu.snapshot(l, &kf[kfs]);
    try uu.same_state("after resume, one back", &kf[kfs], &kf[kfs - 2]);
    try expect(undo.step(l, -1));
    uu.snapshot(l, &kf[kfs]);
    try uu.same_state("after resume, two back", &kf[kfs], &kf[kfs - 3]);
    try expect(undo.step(l, 1));
    try expect(undo.step(l, 1));
    try expect(!undo.parked());
    uu.snapshot(l, &kf[kfs]);
    try uu.same_state("after resume, live", &kf[kfs], &kf[kfs - 1]);
}
