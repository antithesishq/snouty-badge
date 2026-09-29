//! CGB memory map, speed switch and DMA unit tests (SPEC.md 19.6), plus the
//! Mooneye ROMs that cover them. Owner in M6: track A.
const std = @import("std");
const core = @import("core");
const Gb = core.Gb;

const expectEqual = std.testing.expectEqual;

var test_ram: [Gb.max_cart_ram]u8 = undefined;

/// A 32 KB ROM of zeros (NOPs) with the given cartridge type and RAM code.
fn blank_rom(cart: u8, ram: u8) [0x8000]u8 {
    var rom: [0x8000]u8 = @splat(0);
    rom[0x143] = 0x80;
    rom[0x147] = cart;
    rom[0x149] = ram;
    return rom;
}

fn new_gb(rom: []const u8, model: core.Model) !*Gb {
    // Gb is ~60 KB; keep it off the test thread's stack.
    const gb = try std.testing.allocator.create(Gb);
    gb.* = Gb.init(rom, model, &test_ram);
    return gb;
}

test "cgb post-boot registers" {
    const rom = blank_rom(0, 0);
    const gb = try new_gb(&rom, .cgb);
    defer std.testing.allocator.destroy(gb);
    const c = gb.cpu;
    try expectEqual(@as(u8, 0x11), c.a);
    try expectEqual(@as(u8, 0x80), c.f);
    try expectEqual(@as(u8, 0xFF), c.d);
    try expectEqual(@as(u8, 0x56), c.e);
    try expectEqual(@as(u8, 0x0D), c.l);
    const want = [_]struct { u16, u8 }{
        .{ 0xFF02, 0x7F }, .{ 0xFF46, 0x00 }, .{ 0xFF4D, 0x7E }, .{ 0xFF4F, 0xFE },
        .{ 0xFF51, 0xFF }, .{ 0xFF55, 0xFF }, .{ 0xFF56, 0x3E }, .{ 0xFF70, 0xF8 },
        .{ 0xFF72, 0x00 }, .{ 0xFF73, 0x00 }, .{ 0xFF74, 0x00 }, .{ 0xFF75, 0x8F },
        .{ 0xFF76, 0x00 }, .{ 0xFF77, 0x00 }, .{ 0xFF4C, 0xFF }, .{ 0xFF7F, 0xFF },
    };
    for (want) |e| {
        const got = gb.read8(e[0]);
        if (got != e[1]) {
            std.debug.print("\n{X:0>4}: got {X:0>2}, want {X:0>2}\n", .{ e[0], got, e[1] });
            return error.TestExpectedEqual;
        }
    }
    // SC bit 1 (fast serial clock) is writable on a CGB, stuck at 1 on a DMG.
    gb.write8(0xFF02, 0x00);
    try expectEqual(@as(u8, 0x7C), gb.read8(0xFF02));
    gb.write8(0xFF02, 0x02);
    try expectEqual(@as(u8, 0x7E), gb.read8(0xFF02));
}

test "cgb registers read 0xFF and ignore writes on a dmg" {
    const rom = blank_rom(0, 0);
    const gb = try new_gb(&rom, .dmg);
    defer std.testing.allocator.destroy(gb);
    const regs = [_]u16{ 0xFF4D, 0xFF4F, 0xFF51, 0xFF52, 0xFF53, 0xFF54, 0xFF55, 0xFF56, 0xFF68, 0xFF69, 0xFF6A, 0xFF6B, 0xFF6C, 0xFF70, 0xFF72, 0xFF73, 0xFF74, 0xFF75, 0xFF76, 0xFF77 };
    const io_before = gb.io;
    gb.wram[0x1000] = 0x5A;
    for (regs) |r| gb.write8(r, 0x01);
    for (regs) |r| try expectEqual(@as(u8, 0xFF), gb.read8(r));
    try std.testing.expectEqualSlices(u8, &io_before, &gb.io);
    gb.write8(0xFF02, 0x00);
    try expectEqual(@as(u8, 0x7E), gb.read8(0xFF02));
    try expectEqual(@as(u16, 0), gb.banks.vram_off);
    try expectEqual(@as(u16, 0x1000), gb.banks.wram_off);
    try expectEqual(@as(u8, 0x5A), gb.read8(0xD000));
    // STOP with the KEY1 arm bit "written" stays a HALT on a DMG.
    gb.cpu.pc = 0xC000;
    gb.wram[0] = 0x10;
    _ = core.cpu.step(gb);
    try expectEqual(@as(u2, 2), gb.dot_shift);
    try expect(gb.cpu.halted);
}

fn expect(ok: bool) !void {
    try std.testing.expect(ok);
}

test "cgb VBK switches VRAM banks" {
    const rom = blank_rom(0, 0);
    const gb = try new_gb(&rom, .cgb);
    defer std.testing.allocator.destroy(gb);
    gb.write8(0x8010, 0x11);
    gb.write8(0xFF4F, 0xFF); // only bit 0 counts
    try expectEqual(@as(u8, 0xFF), gb.read8(0xFF4F));
    try expectEqual(@as(u8, 0x00), gb.read8(0x8010));
    gb.write8(0x8010, 0x22);
    gb.write8(0x9FFF, 0x33);
    try expectEqual(@as(u8, 0x22), gb.vram[0x2010]);
    try expectEqual(@as(u8, 0x33), gb.vram[0x3FFF]);
    gb.write8(0xFF4F, 0x00);
    try expectEqual(@as(u8, 0xFE), gb.read8(0xFF4F));
    try expectEqual(@as(u8, 0x11), gb.read8(0x8010));
}

test "cgb SVBK switches D000, bank 0 means 1, echo follows" {
    const rom = blank_rom(0, 0);
    const gb = try new_gb(&rom, .cgb);
    defer std.testing.allocator.destroy(gb);
    for (1..8) |b| {
        gb.write8(0xFF70, @intCast(b));
        gb.write8(0xD123, @intCast(0xA0 + b));
    }
    for (1..8) |b| try expectEqual(@as(u8, @intCast(0xA0 + b)), gb.wram[b * 0x1000 + 0x123]);
    gb.write8(0xFF70, 0);
    try expectEqual(@as(u8, 0xF8), gb.read8(0xFF70));
    try expectEqual(@as(u8, 0xA1), gb.read8(0xD123));
    gb.write8(0xFF70, 0x0D); // bits 3+ ignored: bank 5
    try expectEqual(@as(u8, 0xFD), gb.read8(0xFF70));
    try expectEqual(@as(u8, 0xA5), gb.read8(0xD123));
    try expectEqual(@as(u8, 0xA5), gb.read8(0xF123)); // echo of D000
    gb.write8(0xF124, 0x77);
    try expectEqual(@as(u8, 0x77), gb.wram[5 * 0x1000 + 0x124]);
    // C000 and its echo are always bank 0.
    gb.write8(0xC010, 0x99);
    try expectEqual(@as(u8, 0x99), gb.read8(0xE010));
    try expectEqual(@as(u8, 0x99), gb.wram[0x10]);
}

/// ROM whose code at 0x100 arms KEY1 and executes STOP, then spins.
fn stop_rom() [0x8000]u8 {
    var rom = blank_rom(0, 0);
    const code = [_]u8{
        0x3E, 0x01, // LD A,1
        0xE0, 0x4D, // LDH (KEY1),A
        0x10, 0x00, // STOP
        0x18, 0xFE, // JR -2
    };
    @memcpy(rom[0x100..][0..code.len], &code);
    return rom;
}

test "cgb KEY1 + STOP switches to double speed and back" {
    const rom = stop_rom();
    const gb = try new_gb(&rom, .cgb);
    defer std.testing.allocator.destroy(gb);
    _ = core.cpu.step(gb);
    _ = core.cpu.step(gb);
    try expectEqual(@as(u8, 0x7F), gb.read8(0xFF4D)); // armed
    _ = core.cpu.step(gb); // STOP
    try expectEqual(@as(u2, 1), gb.dot_shift);
    try expectEqual(@as(u8, 0xFE), gb.read8(0xFF4D)); // double speed, disarmed
    try expectEqual(@as(u16, 2050), gb.stall_m);
    try expect(!gb.cpu.halted);
    try expectEqual(@as(u16, 0x106), gb.cpu.pc);
    try expectEqual(@as(u8, 0), gb.read8(0xFF04)); // STOP resets DIV

    // Arm again and STOP: back to normal speed.
    gb.stall_m = 0;
    gb.write8(0xFF4D, 1);
    gb.cpu.pc = 0x104;
    _ = core.cpu.step(gb);
    try expectEqual(@as(u2, 2), gb.dot_shift);
    try expectEqual(@as(u8, 0x7E), gb.read8(0xFF4D));
    // Unarmed STOP halts as before.
    gb.cpu.pc = 0x104;
    _ = core.cpu.step(gb);
    try expectEqual(@as(u2, 2), gb.dot_shift);
    try expect(gb.cpu.halted);
}

test "cgb double speed: a PPU line takes twice the M-cycles, timer runs at CPU rate" {
    const rom = blank_rom(0, 0);
    const gb = try new_gb(&rom, .cgb);
    defer std.testing.allocator.destroy(gb);
    try expectEqual(@as(u8, 0), gb.read8(0xFF44));
    gb.tick(114); // one 456-dot line at normal speed
    try expectEqual(@as(u8, 1), gb.read8(0xFF44));

    gb.write8(0xFF4D, 1);
    gb.cpu.pc = 0xC000;
    gb.wram[0] = 0x10; // STOP
    _ = core.cpu.step(gb);
    try expectEqual(@as(u2, 1), gb.dot_shift);
    gb.stall_m = 0;
    gb.write8(0xFF04, 0);
    const dots0 = gb.frame_dots;
    gb.tick(114);
    try expectEqual(@as(u8, 1), gb.read8(0xFF44));
    try expectEqual(dots0 + 228, gb.frame_dots);
    gb.tick(114);
    try expectEqual(@as(u8, 2), gb.read8(0xFF44));
    // DIV advances once per 64 M-cycles at either speed.
    try expectEqual(@as(u8, 3), gb.read8(0xFF04));

    // The switch pause runs through the frame loop at the new speed.
    const rom2 = stop_rom();
    const gb2 = try new_gb(&rom2, .cgb);
    defer std.testing.allocator.destroy(gb2);
    gb2.step_frame(0);
    try expectEqual(@as(u2, 1), gb2.dot_shift);
    try expectEqual(@as(u16, 0), gb2.stall_m);
    try expectEqual(@as(u8, 0xFE), gb2.read8(0xFF4D));
}

fn fill_pattern(gb: *Gb, base: u16, n: usize) void {
    for (0..n) |i| gb.write8(base + @as(u16, @intCast(i)), @truncate(i * 7 + 3));
}

test "cgb GDMA copies at once, masks addresses, stalls 8 M-cycles per block" {
    const rom = blank_rom(0, 0);
    const gb = try new_gb(&rom, .cgb);
    defer std.testing.allocator.destroy(gb);
    fill_pattern(gb, 0xC000, 0x100);
    gb.write8(0xFF51, 0xC0);
    gb.write8(0xFF52, 0x0F); // low 4 bits ignored: 0xC000
    gb.write8(0xFF53, 0xE1); // top 3 bits ignored: 0x01xx
    gb.write8(0xFF54, 0x2F); // -> 0x8120
    try expectEqual(@as(u8, 0xFF), gb.read8(0xFF51)); // write-only
    gb.write8(0xFF55, 0x01); // 2 blocks = 32 bytes
    try std.testing.expectEqualSlices(u8, gb.wram[0..32], gb.vram[0x120..0x140]);
    try expectEqual(@as(u8, 0), gb.vram[0x140]);
    try expectEqual(@as(u8, 0), gb.vram[0x11F]);
    try expectEqual(@as(u16, 16), gb.stall_m);
    try expectEqual(@as(u8, 0xFF), gb.read8(0xFF55));

    // Addresses continue where the transfer stopped; VBK picks the bank.
    gb.stall_m = 0;
    gb.write8(0xFF4F, 1);
    gb.write8(0xFF55, 0x00); // 1 block
    try std.testing.expectEqualSlices(u8, gb.wram[32..48], gb.vram[0x2140..0x2150]);
    try expectEqual(@as(u16, 8), gb.stall_m);

    // Double speed: the same 32 dots per block are 16 M-cycles.
    gb.stall_m = 0;
    gb.dot_shift = 1;
    gb.write8(0xFF55, 0x03); // 4 blocks
    try expectEqual(@as(u16, 64), gb.stall_m);

    // 0x7F = 128 blocks = 2 KB; the destination wraps inside the bank.
    gb.stall_m = 0;
    gb.dot_shift = 2;
    gb.write8(0xFF53, 0x1F);
    gb.write8(0xFF54, 0xF0);
    gb.write8(0xFF55, 0x01);
    // The source continues at 0xC070 after the 112 bytes above.
    try expectEqual(gb.wram[0x70], gb.vram[0x3FF0]);
    try expectEqual(gb.wram[0x80], gb.vram[0x2000]);
}

test "cgb HBlank DMA copies 16 bytes per HBlank, reads back and cancels" {
    const rom = blank_rom(0, 0);
    const gb = try new_gb(&rom, .cgb);
    defer std.testing.allocator.destroy(gb);
    fill_pattern(gb, 0xC000, 0x100);
    gb.write8(0xFF51, 0xC0);
    gb.write8(0xFF52, 0x00);
    gb.write8(0xFF53, 0x00);
    gb.write8(0xFF54, 0x00);
    gb.write8(0xFF55, 0x83); // 4 blocks, HBlank mode, LCD on
    try expectEqual(@as(u8, 0x03), gb.read8(0xFF55));
    try expectEqual(@as(u8, 0), gb.vram[0]); // nothing yet
    try expectEqual(@as(u16, 0), gb.stall_m);
    core.mmu.hdma_hblank(gb);
    try std.testing.expectEqualSlices(u8, gb.wram[0..16], gb.vram[0..16]);
    try expectEqual(@as(u8, 0), gb.vram[16]);
    try expectEqual(@as(u8, 0x02), gb.read8(0xFF55));
    try expectEqual(@as(u16, 8), gb.stall_m);
    core.mmu.hdma_hblank(gb);
    try std.testing.expectEqualSlices(u8, gb.wram[0..32], gb.vram[0..32]);
    try expectEqual(@as(u8, 0x01), gb.read8(0xFF55));
    // Cancel: bit 7 set, the blocks left minus one.
    gb.write8(0xFF55, 0x00);
    try expectEqual(@as(u8, 0x81), gb.read8(0xFF55));
    core.mmu.hdma_hblank(gb);
    try expectEqual(@as(u8, 0), gb.vram[32]);
    try expectEqual(@as(u16, 16), gb.stall_m);

    // Restart and run to the end: reads 0xFF, further HBlanks copy nothing.
    gb.write8(0xFF55, 0x81); // 2 blocks, continuing at 0xC020 -> 0x8020
    core.mmu.hdma_hblank(gb);
    core.mmu.hdma_hblank(gb);
    try std.testing.expectEqualSlices(u8, gb.wram[0..64], gb.vram[0..64]);
    try expectEqual(@as(u8, 0xFF), gb.read8(0xFF55));
    core.mmu.hdma_hblank(gb);
    try expectEqual(@as(u8, 0), gb.vram[64]);
    try expectEqual(@as(u16, 32), gb.stall_m);
}

test "cgb HBlank DMA started with the LCD off copies one block at once" {
    const rom = blank_rom(0, 0);
    const gb = try new_gb(&rom, .cgb);
    defer std.testing.allocator.destroy(gb);
    fill_pattern(gb, 0xC000, 0x40);
    gb.write8(0xFF40, 0x00); // LCD off
    gb.write8(0xFF51, 0xC0);
    gb.write8(0xFF52, 0x00);
    gb.write8(0xFF53, 0x00);
    gb.write8(0xFF54, 0x00);
    gb.write8(0xFF55, 0x81);
    try std.testing.expectEqualSlices(u8, gb.wram[0..16], gb.vram[0..16]);
    try expectEqual(@as(u8, 0), gb.vram[16]);
    try expectEqual(@as(u8, 0x00), gb.read8(0xFF55));
}

test "mbc5 32 KB cart RAM: four banks, wrap, disable" {
    var rom = blank_rom(0x1B, 3);
    try expectEqual(@as(usize, 0x8000), core.mmu.cart_ram_len(&rom));
    rom[0x149] = 4;
    try expectEqual(@as(usize, 0x8000), core.mmu.cart_ram_len(&rom));
    rom[0x149] = 5;
    try expectEqual(@as(usize, 0x8000), core.mmu.cart_ram_len(&rom));
    rom[0x149] = 2;
    try expectEqual(@as(usize, 0x2000), core.mmu.cart_ram_len(&rom));
    rom[0x149] = 3;
    const gb = try new_gb(&rom, .cgb);
    defer std.testing.allocator.destroy(gb);
    try expectEqual(@as(u8, 0xFF), gb.read8(0xA000)); // disabled after reset
    gb.write8(0x0000, 0x0A);
    for (0..4) |b| {
        gb.write8(0x4000, @intCast(b));
        gb.write8(0xA000, @intCast(0x10 + b));
        gb.write8(0xBFFF, @intCast(0x20 + b));
    }
    for (0..4) |b| {
        try expectEqual(@as(u8, @intCast(0x10 + b)), gb.cart_ram[b * 0x2000]);
        try expectEqual(@as(u8, @intCast(0x20 + b)), gb.cart_ram[b * 0x2000 + 0x1FFF]);
        gb.write8(0x4000, @intCast(b));
        try expectEqual(@as(u8, @intCast(0x10 + b)), gb.read8(0xA000));
    }
    gb.write8(0x4000, 6); // banks past the RAM size wrap modulo 4
    try expectEqual(@as(u8, 0x12), gb.read8(0xA000));
    gb.write8(0x0000, 0x00);
    try expectEqual(@as(u8, 0xFF), gb.read8(0xA000));
}

test "mbc5 8 KB cart RAM ignores the bank number" {
    const rom = blank_rom(0x1A, 2);
    const gb = try new_gb(&rom, .cgb);
    defer std.testing.allocator.destroy(gb);
    gb.write8(0x0000, 0x0A);
    gb.write8(0xA010, 0x42);
    gb.write8(0x4000, 3);
    try expectEqual(@as(u8, 0x42), gb.read8(0xA010));
}

test "mbc1 32 KB cart RAM banks in mode 1" {
    const rom = blank_rom(0x03, 3);
    const gb = try new_gb(&rom, .dmg);
    defer std.testing.allocator.destroy(gb);
    gb.write8(0x0000, 0x0A);
    gb.write8(0x6000, 0x01);
    gb.write8(0x4000, 2);
    gb.write8(0xA000, 0x55);
    try expectEqual(@as(u8, 0x55), gb.cart_ram[0x4000]);
    gb.write8(0x6000, 0x00); // mode 0: always bank 0
    try expectEqual(@as(u8, 0x00), gb.read8(0xA000));
}

// ---- Mooneye Test Suite (tools/fetch_test_roms.sh) ----
//
// The suite's CGB tests (misc/boot_regs-cgb, misc/boot_hwio-C,
// misc/bits/unused_hwio-C) are DMG-flagged ROMs checking a CGB running a
// DMG cart in compatibility mode (KEY1, SVBK, BCPD read 0xFF, DMG-cart boot
// registers), which SPEC.md 19.1 leaves out, so they are not run. The MBC
// tests below cover the cart RAM and ROM banking these changes touch.

/// Run a Mooneye ROM until it reports: pass is `LD B,B` with B C D E H L =
/// 3 5 8 13 21 34, fail the same with all six 0x42. The ROM spins after
/// reporting, so the registers are checked once per frame.
fn run_mooneye(comptime name: []const u8, model: core.Model) !void {
    const rom = @embedFile("roms/mooneye-" ++ name ++ ".gb");
    const gb = try new_gb(rom, model);
    defer std.testing.allocator.destroy(gb);
    var frame: u32 = 0;
    while (frame < 600) : (frame += 1) {
        gb.step_frame(0);
        const c = gb.cpu;
        const regs = [6]u8{ c.b, c.c, c.d, c.e, c.h, c.l };
        if (std.mem.eql(u8, &regs, &.{ 3, 5, 8, 13, 21, 34 })) return;
        if (std.mem.eql(u8, &regs, &.{ 0x42, 0x42, 0x42, 0x42, 0x42, 0x42 })) {
            std.debug.print("\nmooneye {s} ({t}): FAILED at PC={X:0>4} A={X:0>2}\n", .{ name, model, c.pc, c.a });
            return error.MooneyeFailed;
        }
    }
    std.debug.print("\nmooneye {s} ({t}): no verdict (PC={X:0>4})\n", .{ name, model, gb.cpu.pc });
    return error.MooneyeTimeout;
}

test "mooneye mbc1 ram_64kb" {
    try run_mooneye("ram_64kb", .dmg);
}
test "mooneye mbc1 ram_256kb" {
    try run_mooneye("ram_256kb", .dmg);
}
test "mooneye mbc5 rom_512kb" {
    try run_mooneye("rom_512kb", .cgb);
}
test "mooneye mbc5 rom_1Mb" {
    try run_mooneye("rom_1Mb", .cgb);
}
test "mooneye mbc5 rom_2Mb" {
    try run_mooneye("rom_2Mb", .cgb);
}
