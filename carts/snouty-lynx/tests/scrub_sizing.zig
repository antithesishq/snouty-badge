//! Scrubber sizing (print only; PLAN.md "M3 Scrub: contract" Track A,
//! docs/SCRUB.md): the slots each undo record takes (the `Lynx.Small` head
//! plus one per 64-byte RAM block first written in its 30 frames), measured
//! through the real store over a large arena, and the history the badge's
//! candidate arenas would hold with those records:
//!
//! - raycast (shipped): 1800 frames under the m1 play script, looped.
//! - Hard Drivin' (`~/roms/lynx/hard_drivin.lnx`, local, skipped when
//!   absent): 1800 badge updates of the M1 drive script (A at 600 and 800,
//!   Up from 900): title, menus, then driving.
//! - Blue Lightning (`~/roms/lynx/blue_lightning.lnx`, local, skipped when
//!   absent): 1500 frames of attract after the splash.
//!
//! Nothing about the commercial ROMs is asserted beyond "ran", and nothing
//! derived from them is committed: the numbers go into docs/SCRUB.md by
//! hand.
const std = @import("std");
const core = @import("core");
const Lynx = core.Lynx;
const undo = core.undo;
const runner = @import("runner.zig");
const files = @import("testfiles.zig");
const uu = @import("undo_unit.zig");
const expect = std.testing.expect;

const per = undo.frames_per_record;
/// Kept below the frontend's guard (PLAN.md: 1 KB between the arena and
/// the stack limit).
const stack_guard = 1024;

const Arena = struct { name: []const u8, bytes: u32 };
/// Free RAM between `__bss_end__` and `__stack_limit__` per build (PLAN.md
/// "M3 Scrub: contract", Memory): the arena is that minus the guard.
const arenas = [_]Arena{
    .{ .name = "ReleaseFast as built (M2)", .bytes = 40_632 },
    .{ .name = "ReleaseFast, exec un-inlined (est.)", .bytes = 88_000 },
    .{ .name = "ReleaseSmall", .bytes = 120_296 },
    .{ .name = "XIP", .bytes = 190_000 },
};

const max_recs = 128;

const Sizes = struct {
    /// Slots of each 30-frame record, and its RAM blocks as a bit set.
    slots: [max_recs]u32 = undefined,
    sets: [max_recs][undo.ram_blocks / 64]u64 = undefined,
    n: usize = 0,
    frames: u32 = 0,
    lost: u32 = 0,
};

var lynx: Lynx = undefined;
var arena_buf: [4 << 20]u8 align(4) = undefined;
var ids: [undo.ram_blocks]u16 = undefined;

/// Step `l` through `pads` (null = splash, not stepped) tracked over a
/// large arena, recording the open record's slots and blocks at every
/// boundary.
fn measure(l: *Lynx, pads: []const ?u16) *const Sizes {
    const s = &sizes;
    s.* = .{};
    undo.init(&arena_buf);
    defer undo.disable();
    undo.reset(l);
    var open: u32 = 0;
    for (pads) |p| {
        const pad = p orelse continue;
        l.step_frame(pad);
        s.frames += 1;
        open += 1;
        if (open == per) {
            open = 0;
            if (undo.lost_history()) s.lost += 1;
            if (s.n == sample_record) print_blocks(l);
            if (s.n < max_recs) {
                s.slots[s.n] = @intCast(undo.open_record_slots());
                const n = @min(ids.len, undo.open_record_blocks(&ids));
                s.sets[s.n] = @splat(0);
                for (ids[0..n]) |b| s.sets[s.n][b >> 6] |= @as(u64, 1) << @intCast(b & 63);
                s.n += 1;
            }
        }
        undo.record_frame(l);
    }
    return s;
}
var sizes: Sizes = .{};

/// The record whose RAM blocks are printed as address ranges.
const sample_record = 40;

/// The open record's RAM blocks as address ranges, with Suzy's VIDBAS and
/// COLLBAS and the displayed DISPADR (which buffers the record holds).
fn print_blocks(l: *const Lynx) void {
    const n = @min(ids.len, undo.open_record_blocks(&ids));
    std.mem.sort(u16, ids[0..n], {}, std.sort.asc(u16));
    std.debug.print("\nsizing: record {d}: VIDBAS ${X:0>4} COLLBAS ${X:0>4} DISPADR ${X:0>4}; {d} blocks:", .{ sample_record, l.suzy.regs[core.suzy.reg.vidbas], l.suzy.regs[core.suzy.reg.collbas], l.mikey.dispadr_latched, n });
    var i: usize = 0;
    while (i < n) {
        var j = i;
        while (j + 1 < n and ids[j + 1] == ids[j] + 1) j += 1;
        std.debug.print(" ${X:0>4}-${X:0>4}", .{ @as(u32, ids[i]) * 64, @as(u32, ids[j]) * 64 + 63 });
        i = j + 1;
    }
    std.debug.print("\n", .{});
}

/// Closed records a ring of `cap` slots holds beside record `r` (full,
/// open), newest first, capped at `max_records` and at the records that
/// exist before `r`.
fn held_at(slots: []const u32, r: usize, cap: u32) u32 {
    var used: u32 = slots[r];
    if (used > cap) return 0;
    var n: u32 = 0;
    while (n < undo.max_records and n < r) : (n += 1) {
        const next = slots[r - 1 - n];
        if (used + next > cap) break;
        used += next;
    }
    return n;
}

/// Slots of records `k` times as long (k consecutive 30-frame records
/// merged: the union of their blocks plus one head), into `out`.
fn merged(s: *const Sizes, k: usize, out: []u32) []u32 {
    var m: usize = 0;
    var r: usize = 0;
    while (r + k <= s.n) : (r += k) {
        var u: [undo.ram_blocks / 64]u64 = @splat(0);
        for (s.sets[r .. r + k]) |set| {
            for (&u, set) |*x, y| x.* |= y;
        }
        var c: u32 = undo.small_slots;
        for (u) |x| c += @popCount(x);
        out[m] = c;
        m += 1;
    }
    return out[0..m];
}

fn report(name: []const u8, s: *const Sizes) void {
    if (s.n == 0) return;
    var lo: u32 = std.math.maxInt(u32);
    var hi: u32 = 0;
    var sum: u64 = 0;
    // The first record holds the game's start-up (the loader filling RAM):
    // reported, not counted in the steady sizes.
    const from: usize = if (s.n > 1) 1 else 0;
    for (s.slots[from..s.n]) |x| {
        lo = @min(lo, x);
        hi = @max(hi, x);
        sum += x;
    }
    const mean: u32 = @intCast(sum / (s.n - from));
    std.debug.print("sizing: {s}: {d} frames, {d} records, {d} lost boundaries; record 0 {d} slots; records 1..: min {d} mean {d} max {d} slots (mean {d} B, {d} RAM blocks)\n", .{ name, s.frames, s.n, s.lost, s.slots[0], lo, mean, hi, mean * @sizeOf(undo.Slot), mean - undo.small_slots });
    std.debug.print("sizing: {s}: slots per record:", .{name});
    for (s.slots[0..s.n]) |x| std.debug.print(" {d}", .{x});
    std.debug.print("\n", .{});
    history(name, s.slots[0..s.n], 1);
    // The same run with longer records (what frames_per_record = 60 or 120
    // would give: a game that redraws its buffers every frame writes the
    // same blocks in 60 frames as in 30).
    var buf: [max_recs]u32 = undefined;
    history(name, merged(s, 2, &buf), 2);
    history(name, merged(s, 4, &buf), 4);
}

/// History over the second half of the run (steady play): the least and
/// the mean a ring holds, in seconds (each closed record is `k` * 0.5 s;
/// the open record adds up to that much more).
fn history(name: []const u8, slots: []const u32, k: u32) void {
    const r0 = slots.len / 2;
    if (r0 == 0) return;
    for (arenas) |a| {
        const cap: u32 = (a.bytes - stack_guard) / @sizeOf(undo.Slot);
        var min_h: u32 = std.math.maxInt(u32);
        var sum_h: u32 = 0;
        var capped = false;
        var r = r0;
        while (r < slots.len) : (r += 1) {
            const h = held_at(slots, r, cap);
            if (h == r or h == undo.max_records) capped = true;
            min_h = @min(min_h, h);
            sum_h += h;
        }
        const cnt: u32 = @intCast(slots.len - r0);
        const min10 = min_h * k * 5; // tenths of a second
        const mean10 = sum_h * k * 5 / cnt;
        std.debug.print("sizing: {s}: {d:>3}-frame records: {s:<36} {d:>7} B -> {d:>5} slots: min {d:>2} records = {d}.{d} s, mean {d}.{d} s{s}\n", .{ name, k * per, a.name, a.bytes, cap, min_h, min10 / 10, min10 % 10, mean10 / 10, mean10 % 10, if (capped) " (capped by the run or max_records)" else "" });
    }
}

var pads_buf: [4096]?u16 = undefined;

/// The stepped pads of `controls` through the runner's frontend model.
fn frontend_pads(controls: []const u16) []?u16 {
    var fe: runner.Frontend = .{};
    for (controls, 0..) |c, i| pads_buf[i] = fe.update(c);
    return pads_buf[0..controls.len];
}

test "sizing: raycast, 1800 frames under the m1 script looped" {
    const pads = try uu.PlayPads.init();
    var i: u32 = 0;
    while (i < 1800) : (i += 1) pads_buf[i] = pads.at(i);
    lynx.init_in_place(try uu.raycast());
    const s = measure(&lynx, pads_buf[0..1800]);
    report("raycast", s);
    try expect(s.n == 60);
    try expect(s.lost == 0);
}

var file_buf: [512 * 1024 + 64]u8 = undefined;

fn local_cart(rel: []const u8) ?core.Cart {
    const file = files.read_home_file(rel, &file_buf) orelse return null;
    return switch (runner.cart_from_file(file)) {
        .ok => |c| c,
        .refused => null,
    };
}

test "sizing: Hard Drivin' (local), the M1 drive script, 1800 updates" {
    const cart = local_cart("roms/lynx/hard_drivin.lnx") orelse return error.SkipZigTest;
    var ctl: [1800]u16 = @splat(0);
    for (600..602) |u| ctl[u] = runner.Btn.a;
    for (800..802) |u| ctl[u] = runner.Btn.a;
    for (900..1800) |u| ctl[u] = runner.Btn.up;
    lynx.init_in_place(cart);
    const s = measure(&lynx, frontend_pads(&ctl));
    report("Hard Drivin'", s);
    try expect(s.n > 0);
}

test "sizing: Blue Lightning (local), 1500 frames of attract" {
    const cart = local_cart("roms/lynx/blue_lightning.lnx") orelse return error.SkipZigTest;
    var ctl: [1500 + runner.splash_frames]u16 = @splat(0);
    lynx.init_in_place(cart);
    const s = measure(&lynx, frontend_pads(&ctl));
    report("Blue Lightning", s);
    try expect(s.n > 0);
}
