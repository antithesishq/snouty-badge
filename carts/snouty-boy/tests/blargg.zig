//! Blargg CPU tests: run until the serial output says Passed or Failed.
//! Owner in M1: track A. ROMs come from tools/fetch_test_roms.sh.
const std = @import("std");
const core = @import("core");

/// Cart RAM for the consoles below (the MBC tests declare RAM in the header).
var test_ram: [core.Gb.max_cart_ram]u8 = undefined;

const frame_budget = 4000;

fn run_blargg(comptime name: []const u8) !void {
    const rom = @embedFile("roms/" ++ name ++ ".gb");
    // Gb is ~33 KB; keep it off the test thread's stack.
    const gb = try std.testing.allocator.create(core.Gb);
    defer std.testing.allocator.destroy(gb);
    gb.* = core.Gb.init(rom, .dmg, &test_ram);
    var frame: u32 = 0;
    while (frame < frame_budget) : (frame += 1) {
        gb.step_frame(0);
        const text = gb.serial.text();
        if (std.mem.indexOf(u8, text, "Passed") != null) return;
        if (std.mem.indexOf(u8, text, "Failed") != null) {
            // Let the ROM finish printing the failure details.
            var extra: u32 = 0;
            while (extra < 120) : (extra += 1) gb.step_frame(0);
            std.debug.print("\n{s}: FAILED after {d} frames, serial:\n{s}\n", .{ name, frame, gb.serial.text() });
            return error.BlarggFailed;
        }
    }
    std.debug.print("\n{s}: no verdict in {d} frames (PC={X:0>4}), serial:\n{s}\n", .{ name, frame_budget, gb.cpu.pc, gb.serial.text() });
    return error.BlarggTimeout;
}

test "blargg cpu_instrs 01 special" {
    try run_blargg("cpu_instrs_01");
}
test "blargg cpu_instrs 02 interrupts" {
    try run_blargg("cpu_instrs_02");
}
test "blargg cpu_instrs 03 op sp,hl" {
    try run_blargg("cpu_instrs_03");
}
test "blargg cpu_instrs 04 op r,imm" {
    try run_blargg("cpu_instrs_04");
}
test "blargg cpu_instrs 05 op rp" {
    try run_blargg("cpu_instrs_05");
}
test "blargg cpu_instrs 06 ld r,r" {
    try run_blargg("cpu_instrs_06");
}
test "blargg cpu_instrs 07 jr,jp,call,ret,rst" {
    try run_blargg("cpu_instrs_07");
}
test "blargg cpu_instrs 08 misc instrs" {
    try run_blargg("cpu_instrs_08");
}
test "blargg cpu_instrs 09 op r,r" {
    try run_blargg("cpu_instrs_09");
}
test "blargg cpu_instrs 10 bit ops" {
    try run_blargg("cpu_instrs_10");
}
test "blargg cpu_instrs 11 op a,(hl)" {
    try run_blargg("cpu_instrs_11");
}
test "blargg cpu_instrs combined (MBC1)" {
    try run_blargg("cpu_instrs");
}
test "blargg instr_timing" {
    try run_blargg("instr_timing");
}

test "post-boot state matches DMG values" {
    var rom: [0x8000]u8 = @splat(0);
    rom[0x147] = 0x01; // MBC1
    const gb = try std.testing.allocator.create(core.Gb);
    defer std.testing.allocator.destroy(gb);
    gb.* = core.Gb.init(&rom, .dmg, &test_ram);
    const c = gb.cpu;
    try std.testing.expectEqual(@as(u8, 0x01), c.a);
    try std.testing.expectEqual(@as(u8, 0xB0), c.f);
    try std.testing.expectEqual(@as(u8, 0x00), c.b);
    try std.testing.expectEqual(@as(u8, 0x13), c.c);
    try std.testing.expectEqual(@as(u8, 0x00), c.d);
    try std.testing.expectEqual(@as(u8, 0xD8), c.e);
    try std.testing.expectEqual(@as(u8, 0x01), c.h);
    try std.testing.expectEqual(@as(u8, 0x4D), c.l);
    try std.testing.expectEqual(@as(u16, 0xFFFE), c.sp);
    try std.testing.expectEqual(@as(u16, 0x0100), c.pc);

    const expect = [_]struct { u16, u8 }{
        .{ 0xFF00, 0xCF }, .{ 0xFF01, 0x00 }, .{ 0xFF02, 0x7E }, .{ 0xFF04, 0xAB },
        .{ 0xFF05, 0x00 }, .{ 0xFF06, 0x00 }, .{ 0xFF07, 0xF8 }, .{ 0xFF0F, 0xE1 },
        .{ 0xFF10, 0x80 }, .{ 0xFF11, 0xBF }, .{ 0xFF12, 0xF3 }, .{ 0xFF13, 0xFF },
        .{ 0xFF14, 0xBF }, .{ 0xFF16, 0x3F }, .{ 0xFF17, 0x00 }, .{ 0xFF18, 0xFF },
        .{ 0xFF19, 0xBF }, .{ 0xFF1A, 0x7F }, .{ 0xFF1B, 0xFF }, .{ 0xFF1C, 0x9F },
        .{ 0xFF1D, 0xFF }, .{ 0xFF1E, 0xBF }, .{ 0xFF20, 0xFF }, .{ 0xFF21, 0x00 },
        .{ 0xFF22, 0x00 }, .{ 0xFF23, 0xBF }, .{ 0xFF24, 0x77 }, .{ 0xFF25, 0xF3 },
        .{ 0xFF26, 0xF1 }, .{ 0xFF40, 0x91 }, .{ 0xFF42, 0x00 }, .{ 0xFF43, 0x00 },
        .{ 0xFF44, 0x00 }, .{ 0xFF45, 0x00 }, .{ 0xFF46, 0xFF }, .{ 0xFF47, 0xFC },
        .{ 0xFF4A, 0x00 }, .{ 0xFF4B, 0x00 }, .{ 0xFFFF, 0x00 },
        // Unmapped I/O reads as 0xFF.
        .{ 0xFF03, 0xFF },
        .{ 0xFF4C, 0xFF }, .{ 0xFF7F, 0xFF },
    };
    for (expect) |e| {
        const got = gb.read8(e[0]);
        if (got != e[1]) {
            std.debug.print("\n{X:0>4}: got {X:0>2}, want {X:0>2}\n", .{ e[0], got, e[1] });
            return error.TestExpectedEqual;
        }
    }
    // STAT mode bits belong to the PPU; the stored value is the post-boot one.
    // Documented post-boot STAT is 0x85; our PPU starts line 0 in mode 2 (0x86).
    try std.testing.expectEqual(@as(u8, 0x86), gb.io[core.Reg.stat]);
    // Cart RAM is disabled after reset on an MBC1.
    try std.testing.expectEqual(@as(u8, 0xFF), gb.read8(0xA000));
}

test "mbc1 bank switching and 0x20 quirk" {
    // 1 MB ROM: 64 banks, each tagged with its number at offset 0.
    const rom = try std.testing.allocator.alloc(u8, 64 * 0x4000);
    defer std.testing.allocator.free(rom);
    @memset(rom, 0);
    for (0..64) |b| rom[b * 0x4000] = @intCast(b);
    rom[0x147] = 0x03;
    rom[0x149] = 0x02;
    const gb = try std.testing.allocator.create(core.Gb);
    defer std.testing.allocator.destroy(gb);
    gb.* = core.Gb.init(rom, .dmg, &test_ram);
    try std.testing.expectEqual(@as(u8, 1), gb.read8(0x4000));
    gb.write8(0x2000, 0x05);
    try std.testing.expectEqual(@as(u8, 5), gb.read8(0x4000));
    gb.write8(0x2000, 0x00);
    gb.write8(0x4000, 0x01); // upper bits -> bank 0x21
    try std.testing.expectEqual(@as(u8, 0x21), gb.read8(0x4000));
    try std.testing.expectEqual(@as(u8, 0), gb.read8(0x0000));
    gb.write8(0x6000, 0x01); // mode 1 remaps 0x0000 to bank 0x20
    try std.testing.expectEqual(@as(u8, 0x20), gb.read8(0x0000));
    // RAM enable
    gb.write8(0xA000, 0x42);
    try std.testing.expectEqual(@as(u8, 0xFF), gb.read8(0xA000));
    gb.write8(0x0000, 0x0A);
    gb.write8(0xA000, 0x42);
    try std.testing.expectEqual(@as(u8, 0x42), gb.read8(0xA000));
}

test "timer: TIMA at 262144 Hz and overflow irq" {
    var rom: [0x8000]u8 = @splat(0);
    const gb = try std.testing.allocator.create(core.Gb);
    defer std.testing.allocator.destroy(gb);
    gb.* = core.Gb.init(&rom, .dmg, &test_ram);
    gb.write8(0xFF04, 0); // reset DIV
    gb.write8(0xFF06, 0xFE); // TMA
    gb.write8(0xFF05, 0xFE); // TIMA
    gb.write8(0xFF0F, 0);
    gb.write8(0xFF07, 0x05); // enable, 16 T per tick = 4 M
    core.timer.tick(gb, 4);
    try std.testing.expectEqual(@as(u8, 0xFF), gb.read8(0xFF05));
    core.timer.tick(gb, 4);
    try std.testing.expectEqual(@as(u8, 0xFE), gb.read8(0xFF05));
    try std.testing.expect((gb.read8(0xFF0F) & core.Irq.timer) != 0);
}
