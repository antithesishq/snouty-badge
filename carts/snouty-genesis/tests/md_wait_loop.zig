//! `Md.step_frame` skips whole iterations of a 68000 wait loop
//! (`Md.skip_wait_loop`); these check that every console field ends
//! exactly as stepping each instruction leaves it, for each recognised
//! loop form, across V-int entries and exits. The reference is the frame
//! loop of PLAN.md's contract written out here, calling `step` outside
//! `run_m68k` (where `Md.m68k_share` is 0, so nothing is skipped).
const std = @import("std");
const core = @import("core");
const Md = core.Md;
const vdp = core.vdp;

/// A 16 KB ROM: reset to 0x200, level 6 autovector to 0x300. Main: SR
/// 2000, VDP register 1 = 64 (display, V-int on), then forever: `arm`
/// the flag at FF8000, the wait loop `wait`, count a pass in FF8010.
/// V-int: `fire` the flag, count in D7, RTE.
fn build_rom(buf: *[0x4000]u8, arm: []const u16, wait: []const u16, fire: []const u16) void {
    @memset(buf, 0);
    const put = struct {
        fn f(b: *[0x4000]u8, at: u32, words: []const u16) u32 {
            var a = at;
            for (words) |w| {
                b[a] = @truncate(w >> 8);
                b[a + 1] = @truncate(w);
                a += 2;
            }
            return a;
        }
    }.f;
    _ = put(buf, 0, &.{ 0x00FF, 0xFE00, 0x0000, 0x0200 });
    _ = put(buf, 0x78, &.{ 0x0000, 0x0300 });
    var a = put(buf, 0x200, &.{ 0x46FC, 0x2000, 0x33FC, 0x8164, 0x00C0, 0x0004 });
    const loop = a;
    a = put(buf, a, arm);
    a = put(buf, a, wait);
    a = put(buf, a, &.{ 0x5279, 0x00FF, 0x8010 });
    // BRA.s loop
    const disp: u8 = @truncate(0x100 - (a + 2 - loop));
    _ = put(buf, a, &.{0x6000 | @as(u16, disp)});
    a = put(buf, 0x300, fire);
    _ = put(buf, a, &.{ 0x5287, 0x4E73 });
}

/// `step_frame` as the contract has it, one `step` per instruction.
fn reference_frame(md: *Md) void {
    var b = md.bus_for();
    var line: u32 = 0;
    while (line < vdp.lines_per_frame) : (line += 1) {
        if (line == vdp.vint_line) md.z80_int = true;
        const share = (line + 1) * vdp.m68k_cycles_per_frame / vdp.lines_per_frame - line * vdp.m68k_cycles_per_frame / vdp.lines_per_frame;
        var used: u32 = md.m68k_carry;
        while (used < share) {
            if (md.dma_stall != 0) {
                used += md.dma_stall;
                md.dma_stall = 0;
                continue;
            }
            if (md.cpu.stopped and md.vdp.irq_level() <= md.cpu.mask()) {
                used = share;
                break;
            }
            used += md.cpu.step(&b);
            md.vdp.line_cycles = @truncate(@min(used, 0xFFFF));
        }
        md.m68k_carry = used - share;
        md.z80_int = false;
        md.ym.tick(share);
        md.vdp.end_line();
    }
    md.frame_count +%= 1;
}

var rom_buf: [0x4000]u8 = undefined;

fn check(arm: []const u16, wait: []const u16, fire: []const u16) !void {
    build_rom(&rom_buf, arm, wait, fire);
    const a = try std.testing.allocator.create(Md);
    defer std.testing.allocator.destroy(a);
    const r = try std.testing.allocator.create(Md);
    defer std.testing.allocator.destroy(r);
    const ka = try std.testing.allocator.create(Md.Keyframe);
    defer std.testing.allocator.destroy(ka);
    const kr = try std.testing.allocator.create(Md.Keyframe);
    defer std.testing.allocator.destroy(kr);
    a.init_in_place(core.RomSource.from_slice(&rom_buf));
    r.init_in_place(core.RomSource.from_slice(&rom_buf));
    var f: u32 = 0;
    while (f < 5) : (f += 1) {
        a.step_frame(0, false);
        reference_frame(r);
        a.snapshot(ka);
        r.snapshot(kr);
        if (!std.meta.eql(ka.*, kr.*)) {
            inline for (@typeInfo(Md.Keyframe).@"struct".field_names) |n| {
                if (!std.meta.eql(@field(ka.*, n), @field(kr.*, n))) std.debug.print("frame {d}: {s} differs\n", .{ f, n });
            }
            std.debug.print("cpu a pc {X} cyc {d} d7 {d} / r pc {X} cyc {d} d7 {d}; carry {d} {d}\n", .{ a.cpu.pc, a.cpu.cyc, a.cpu.d[7], r.cpu.pc, r.cpu.cyc, r.cpu.d[7], a.m68k_carry, r.m68k_carry });
            return error.TestUnexpectedResult;
        }
    }
    // The loop ran and V-int got in: D7 counts interrupts, FF8010 passes.
    try std.testing.expect(a.cpu.d[7] >= 4);
}

// Arm and fire for loops that wait while the flag is zero, and the reverse.
const clr = [_]u16{ 0x4239, 0x00FF, 0x8000 };
const st = [_]u16{ 0x50F9, 0x00FF, 0x8000 };
const clr_l = [_]u16{ 0x42B9, 0x00FF, 0x8000 };

test "md: wait loop skip, TST.b abs.l / BEQ.s" {
    try check(&clr, &.{ 0x4A39, 0x00FF, 0x8000, 0x67F8 }, &st);
}

test "md: wait loop skip, TST.w abs.w / BEQ.s" {
    try check(&clr, &.{ 0x4A78, 0x8000, 0x67FA }, &st);
}

test "md: wait loop skip, TST.l abs.l / BEQ.s" {
    try check(&clr_l, &.{ 0x4AB9, 0x00FF, 0x8000, 0x67F8 }, &st);
}

test "md: wait loop skip, TST.b abs.l / BNE.s" {
    try check(&st, &.{ 0x4A39, 0x00FF, 0x8000, 0x66F8 }, &clr);
}

test "md: wait loop skip, BTST #7 abs.w / BEQ.s" {
    try check(&clr, &.{ 0x0838, 0x0007, 0x8000, 0x67F8 }, &st);
}

test "md: wait loop skip, BTST #0 abs.l / BEQ.s" {
    try check(&clr, &.{ 0x0839, 0x0000, 0x00FF, 0x8000, 0x67F6 }, &st);
}

test "md: wait loop skip, BRA.s * with V-int" {
    try check(&clr, &.{0x60FE}, &st);
}

test "md: wait loop skip, MOVE.b abs.l,D0 / BEQ.s" {
    try check(&clr, &.{ 0x1039, 0x00FF, 0x8000, 0x67F8 }, &st);
}

test "md: wait loop skip, MOVE.w abs.w,D3 / BNE.s" {
    try check(&st, &.{ 0x3638, 0x8000, 0x66FA }, &clr);
}

test "md: wait loop skip, MOVE.l abs.l,D5 / BEQ.s" {
    try check(&clr_l, &.{ 0x2A39, 0x00FF, 0x8000, 0x67F8 }, &st);
}
