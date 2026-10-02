//! Bus, ROM checks and frame-loop plumbing (SPEC.md sections 3, 9, 11;
//! PLAN.md M1 Track C): the 68000 map and its mirrors, the version
//! register, the 3-button pad's TH protocol, BUSREQ/RESET and open bus on
//! the Z80 side, cartridge SRAM, ROM reads past the end, big-endian word
//! assembly, the interrupt plumbing, the load-time refusals and the line
//! table. Built on synthetic ROMs, so they hold with the other tracks'
//! subsystems stubbed.
const std = @import("std");
const core = @import("core");
const Md = core.Md;
const Pad = core.Pad;
const rom = core.rom;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

/// A 1 KB ROM: SSP FFFE00, PC 000200, "SEGA GENESIS" at 0x100, the word
/// at 0x200 `60FE` (bra.s *), everything else 0.
fn make_rom(buf: []u8) void {
    @memset(buf, 0);
    std.mem.writeInt(u32, buf[0..4], 0x00FFFE00, .big);
    std.mem.writeInt(u32, buf[4..8], 0x00000200, .big);
    @memcpy(buf[0x100..][0..16], "SEGA GENESIS    ");
    buf[0x200] = 0x60;
    buf[0x201] = 0xFE;
}

/// Declare SRAM at `start..end` with kind byte `kind` (F8 = odd bytes).
fn declare_sram(buf: []u8, kind: u8, start: u32, end: u32) void {
    buf[0x1B0] = 'R';
    buf[0x1B1] = 'A';
    buf[0x1B2] = kind;
    buf[0x1B3] = 0x20;
    std.mem.writeInt(u32, buf[0x1B4..][0..4], start, .big);
    std.mem.writeInt(u32, buf[0x1B8..][0..4], end, .big);
}

fn new_md(data: []const u8) !*Md {
    const md = try std.testing.allocator.create(Md);
    md.init_in_place(core.RomSource.from_slice(data));
    return md;
}

var rom_buf: [0x400]u8 = undefined;

test "bus: work RAM at FF0000 is mirrored from E00000, words big-endian" {
    make_rom(&rom_buf);
    const md = try new_md(&rom_buf);
    defer std.testing.allocator.destroy(md);
    var b = md.bus_for();
    b.write16(0xFF0010, 0x1234);
    try expectEqual(@as(u8, 0x12), md.work_ram[0x10]);
    try expectEqual(@as(u8, 0x34), md.work_ram[0x11]);
    try expectEqual(@as(u16, 0x1234), b.read16(0xE00010));
    try expectEqual(@as(u16, 0x1234), b.read16(0xF30010));
    try expectEqual(@as(u8, 0x34), b.read8(0xEF0011));
    b.write8(0xE5FFFF, 0xAB);
    try expectEqual(@as(u8, 0xAB), b.read8(0xFFFFFF));
    try expectEqual(@as(u16, 0x00AB), b.read16(0xFFFFFE));
}

test "bus: ROM reads, big-endian words, open bus past the end" {
    make_rom(&rom_buf);
    const md = try new_md(&rom_buf);
    defer std.testing.allocator.destroy(md);
    var b = md.bus_for();
    try expectEqual(@as(u16, 0x00FF), b.read16(0));
    try expectEqual(@as(u16, 0xFE00), b.read16(2));
    try expectEqual(@as(u16, 0x60FE), b.read16(0x200));
    try expectEqual(@as(u8, 0xFE), b.read8(0x201));
    try expectEqual(@as(u8, 'S'), b.read8(0x100));
    // Past the 1 KB ROM, and up to the end of the cartridge area.
    try expectEqual(@as(u8, 0xFF), b.read8(0x400));
    try expectEqual(@as(u16, 0xFFFF), b.read16(0x400));
    try expectEqual(@as(u16, 0xFFFF), b.read16(0x3FFFFE));
    // Writes to ROM are dropped.
    b.write16(0x200, 0);
    try expectEqual(@as(u16, 0x60FE), b.read16(0x200));
    // Unmapped space reads open bus.
    try expectEqual(@as(u16, 0xFFFF), b.read16(0x800000));
    try expectEqual(@as(u8, 0xFF), b.read8(0xA14000));
}

test "bus: reset takes SSP and PC from the vectors" {
    make_rom(&rom_buf);
    const md = try new_md(&rom_buf);
    defer std.testing.allocator.destroy(md);
    try expectEqual(@as(u32, 0x00FFFE00), md.cpu.a[7]);
    try expectEqual(@as(u32, 0x200), md.cpu.pc);
    // Power-on arbiter: Z80 held in reset, bus not requested.
    try expect(md.arbiter.z80_reset);
    try expect(!md.arbiter.busreq);
}

test "bus: version register reads A0 (overseas, NTSC, no TMSS)" {
    make_rom(&rom_buf);
    const md = try new_md(&rom_buf);
    defer std.testing.allocator.destroy(md);
    var b = md.bus_for();
    try expectEqual(@as(u8, 0xA0), b.read8(0xA10001));
    try expectEqual(@as(u8, 0xA0), b.read8(0xA10000));
    try expectEqual(@as(u16, 0xA0A0), b.read16(0xA10000));
}

test "bus: 3-button pad TH select protocol on port 1" {
    make_rom(&rom_buf);
    const md = try new_md(&rom_buf);
    defer std.testing.allocator.destroy(md);
    var b = md.bus_for();
    md.pad = Pad.up | Pad.right | Pad.b | Pad.a | Pad.start;

    // TH as input (control 0): pulled high, `1 TH C B R L D U` active low.
    // Pressed U, R, B: bits 0, 3, 4 low.
    try expectEqual(@as(u8, 0x40 | 0x26), b.read8(0xA10003));

    // TH as output, driven high then low (the usual read sequence).
    b.write8(0xA10009, 0x40);
    try expectEqual(@as(u8, 0x40), b.read8(0xA10009));
    b.write8(0xA10003, 0x40);
    try expectEqual(@as(u8, 0x40 | 0x26), b.read8(0xA10003));
    b.write8(0xA10003, 0x00);
    // TH low: `St A 0 0 D U`: U, A, Start pressed, bits 2-3 always low.
    try expectEqual(@as(u8, 0x02), b.read8(0xA10003));

    // Word access: control and data through the word at the even address.
    b.write16(0xA10002, 0x0040);
    try expectEqual(@as(u16, 0x6666), b.read16(0xA10002));

    // Nothing pressed.
    md.pad = 0;
    try expectEqual(@as(u8, 0x7F), b.read8(0xA10003));
    b.write8(0xA10003, 0x00);
    try expectEqual(@as(u8, 0x33), b.read8(0xA10003));

    // Port 2 has no device: all inputs high.
    try expectEqual(@as(u8, 0x7F), b.read8(0xA10005));
    b.write8(0xA1000B, 0x40);
    b.write8(0xA10005, 0x00);
    try expectEqual(@as(u8, 0x3F), b.read8(0xA10005));
    // Byte writes at even I/O addresses are ignored.
    b.write8(0xA10008, 0x7F);
    try expectEqual(@as(u8, 0x40), md.io.ctrl[0]);
}

test "bus: pad lines for every button in both TH phases" {
    const bus = core.bus;
    try expectEqual(@as(u8, 0x7F), bus.pad_lines(0, true));
    try expectEqual(@as(u8, 0x33), bus.pad_lines(0, false));
    try expectEqual(@as(u8, 0x40 | 0x3E), bus.pad_lines(Pad.up, true));
    try expectEqual(@as(u8, 0x40 | 0x3D), bus.pad_lines(Pad.down, true));
    try expectEqual(@as(u8, 0x40 | 0x3B), bus.pad_lines(Pad.left, true));
    try expectEqual(@as(u8, 0x40 | 0x37), bus.pad_lines(Pad.right, true));
    try expectEqual(@as(u8, 0x40 | 0x2F), bus.pad_lines(Pad.b, true));
    try expectEqual(@as(u8, 0x40 | 0x1F), bus.pad_lines(Pad.c, true));
    // A and Start only in the TH low phase; left/right/B/C only in the high.
    try expectEqual(@as(u8, 0x7F), bus.pad_lines(Pad.a | Pad.start, true));
    try expectEqual(@as(u8, 0x23), bus.pad_lines(Pad.a, false));
    try expectEqual(@as(u8, 0x13), bus.pad_lines(Pad.start, false));
    try expectEqual(@as(u8, 0x33), bus.pad_lines(Pad.left | Pad.right | Pad.b | Pad.c, false));
    try expectEqual(@as(u8, 0x30), bus.pad_lines(Pad.up | Pad.down, false));
}

test "bus: BUSREQ grants the Z80 side, open bus otherwise" {
    make_rom(&rom_buf);
    const md = try new_md(&rom_buf);
    defer std.testing.allocator.destroy(md);
    var b = md.bus_for();
    md.z80_ram[0] = 0x5A;
    // Not requested: bit 0 / bit 8 reads 1 (the Z80 has its bus), the Z80
    // area reads FF and ignores writes.
    try expectEqual(@as(u8, 1), b.read8(0xA11100) & 1);
    try expectEqual(@as(u16, 0x100), b.read16(0xA11100) & 0x100);
    if (core.tunables.z80_enabled) {
        try expectEqual(@as(u8, 0xFF), b.read8(0xA00000));
        b.write8(0xA00001, 0x77);
        try expectEqual(@as(u8, 0), md.z80_ram[1]);
    }
    // Request (word write, bit 8): granted at once.
    b.write16(0xA11100, 0x0100);
    try expect(md.arbiter.busreq);
    try expectEqual(@as(u8, 0), b.read8(0xA11100) & 1);
    try expectEqual(@as(u16, 0), b.read16(0xA11100) & 0x100);
    try expectEqual(@as(u8, 0x5A), b.read8(0xA00000));
    b.write8(0xA00001, 0x77);
    try expectEqual(@as(u8, 0x77), md.z80_ram[1]);
    // Word access: the byte in both halves; a word write stores the high byte.
    try expectEqual(@as(u16, 0x5A5A), b.read16(0xA00000));
    b.write16(0xA00002, 0x1234);
    try expectEqual(@as(u8, 0x12), md.z80_ram[2]);
    // Z80 RAM mirror at A02000; the bank window at A08000 is unreachable.
    try expectEqual(@as(u8, 0x5A), b.read8(0xA02000));
    try expectEqual(@as(u8, 0xFF), b.read8(0xA08000));
    // Release (byte write, bit 0).
    b.write8(0xA11100, 0x00);
    try expect(!md.arbiter.busreq);
    try expectEqual(@as(u8, 1), b.read8(0xA11100) & 1);
}

test "bus: A11200 RESET holds and releases the Z80" {
    make_rom(&rom_buf);
    const md = try new_md(&rom_buf);
    defer std.testing.allocator.destroy(md);
    var b = md.bus_for();
    b.write16(0xA11200, 0x0100);
    try expect(!md.arbiter.z80_reset);
    md.z80.pc = 0x1234;
    b.write16(0xA11200, 0x0000);
    try expect(md.arbiter.z80_reset);
    try expectEqual(@as(u16, 0), md.z80.pc);
    b.write8(0xA11200, 0x01);
    try expect(!md.arbiter.z80_reset);
    // Byte writes at the odd address do nothing.
    b.write8(0xA11201, 0x00);
    try expect(!md.arbiter.z80_reset);
}

test "bus: the Z80 runs only when released from reset and not held by BUSREQ" {
    make_rom(&rom_buf);
    const md = try new_md(&rom_buf);
    defer std.testing.allocator.destroy(md);
    var b = md.bus_for();
    // Load `ld a,5A ; ld (1000),a ; jr $` the way a game does: request the
    // bus, copy through A00000, release the reset and the bus.
    const prog = [_]u8{ 0x3E, 0x5A, 0x32, 0x00, 0x10, 0x18, 0xFE };
    b.write16(0xA11100, 0x0100);
    b.write16(0xA11200, 0x0100);
    for (prog, 0..) |v, i| b.write8(@intCast(0xA00000 + i), v);
    b.write16(0xA11200, 0x0000);
    md.step_frame(0, false);
    try expectEqual(@as(u8, 0), md.z80_ram[0x1000]); // held in reset
    b.write16(0xA11200, 0x0100);
    md.step_frame(0, false);
    if (core.tunables.z80_enabled) try expectEqual(@as(u8, 0), md.z80_ram[0x1000]); // held by BUSREQ
    b.write16(0xA11100, 0x0000);
    md.step_frame(0, false);
    if (core.tunables.z80_enabled) {
        try expectEqual(@as(u8, 0x5A), md.z80_ram[0x1000]);
        try expectEqual(@as(u16, 5), md.z80.pc);
    }
    // INT is asserted for line 224 only.
    try expect(!md.z80_int);
}

test "bus: VDP ports and mirrors, PSG writes at C00011" {
    make_rom(&rom_buf);
    const md = try new_md(&rom_buf);
    defer std.testing.allocator.destroy(md);
    var b = md.bus_for();
    // Status at C00004 and its mirrors (C00006, and every 32 bytes). The
    // status word is computed on read (`status` holds the sticky bits only);
    // in the reset state a read has no side effect, so reads compare equal.
    const st = md.vdp.read_status();
    try expectEqual(st, b.read16(0xC00004));
    try expectEqual(st, b.read16(0xC00006));
    try expectEqual(st, b.read16(0xC00024));
    try expectEqual(@as(u8, @truncate(st >> 8)), b.read8(0xC00004));
    try expectEqual(@as(u8, @truncate(st)), b.read8(0xC00005));
    // HV counter: V in the high byte (C00008), H in the low (C00009).
    const hv = md.vdp.hv_counter();
    try expectEqual(hv, b.read16(0xC00008));
    try expectEqual(hv, b.read16(0xC0000E));
    try expectEqual(@as(u8, @truncate(hv >> 8)), b.read8(0xC00008));
    // PSG: the test ROM's tone 0 setup (tools/testrom/README.md).
    for ([_]u8{ 0x9F, 0xBF, 0xDF, 0xFF, 0x8C, 0x1F, 0x94 }) |v| b.write8(0xC00011, v);
    try expectEqual(@as(u16, 0x1FC), md.psg.tone[0]);
    try expectEqual(@as(u4, 4), md.psg.atten[0]);
    try expectEqual(@as(u4, 15), md.psg.atten[1]);
    // Mirrors C00013/15/17 and a word write (low byte) reach it too.
    b.write8(0xC00013, 0x9A);
    try expectEqual(@as(u4, 10), md.psg.atten[0]);
    b.write16(0xC00010, 0x0092);
    try expectEqual(@as(u4, 2), md.psg.atten[0]);
    // The even byte of the PSG word is not the PSG.
    b.write8(0xC00010, 0x9F);
    try expectEqual(@as(u4, 2), md.psg.atten[0]);
    try expectEqual(@as(u8, 0xFF), b.read8(0xC00011));
}

test "bus: SRAM in the declared range, visible from reset when past the ROM" {
    make_rom(&rom_buf);
    declare_sram(&rom_buf, 0xF8, 0x200001, 0x203FFF);
    const md = try new_md(&rom_buf);
    defer std.testing.allocator.destroy(md);
    var b = md.bus_for();
    try expect(md.sram_map.present());
    try expectEqual(@as(u32, 0x200000), md.sram_active.lo);
    try expectEqual(@as(u32, 0x203FFF), md.sram_active.hi);
    b.write8(0x200001, 0x42);
    try expectEqual(@as(u8, 0x42), b.read8(0x200001));
    b.write16(0x203FFE, 0xBEEF);
    try expectEqual(@as(u16, 0xBEEF), b.read16(0x203FFE));
    try expectEqual(@as(u8, 0x42), md.sram[1]);
    // Outside the range: ROM (open bus past its end) as before.
    try expectEqual(@as(u8, 0xFF), b.read8(0x204000));
    try expectEqual(@as(u16, 0x60FE), b.read16(0x200));
    // A130F1 = 0 hides it, 1 shows it again (contents kept).
    b.write8(0xA130F1, 0);
    try expectEqual(@as(u8, 0xFF), b.read8(0x200001));
    b.write8(0xA130F1, 1);
    try expectEqual(@as(u8, 0x42), b.read8(0x200001));
    // Keyframes carry it.
    const k = try std.testing.allocator.create(Md.Keyframe);
    defer std.testing.allocator.destroy(k);
    md.snapshot(k);
    b.write8(0x200001, 0);
    md.restore(k);
    try expectEqual(@as(u8, 0x42), b.read8(0x200001));
}

test "bus: SRAM declarations that are absent, EEPROM or oversized" {
    make_rom(&rom_buf);
    {
        const md = try new_md(&rom_buf);
        defer std.testing.allocator.destroy(md);
        try expect(!md.sram_map.present());
        var b = md.bus_for();
        b.write8(0x200001, 0x42);
        try expectEqual(@as(u8, 0xFF), b.read8(0x200001));
    }
    // Serial EEPROM (0x1B3 = 40): not emulated, no SRAM.
    declare_sram(&rom_buf, 0xE8, 0x200001, 0x200001);
    rom_buf[0x1B3] = 0x40;
    {
        const md = try new_md(&rom_buf);
        defer std.testing.allocator.destroy(md);
        try expect(!md.sram_map.present());
    }
    // 64 KB declared: clipped to 16 KB.
    declare_sram(&rom_buf, 0xA0, 0x200000, 0x20FFFF);
    {
        const md = try new_md(&rom_buf);
        defer std.testing.allocator.destroy(md);
        try expectEqual(@as(u32, 0x203FFF), md.sram_map.hi);
    }
}

test "bus: SRAM over a ROM that reaches it stays hidden until A130F1" {
    var big = try std.testing.allocator.alloc(u8, 0x200400);
    defer std.testing.allocator.free(big);
    make_rom(big[0..0x400]);
    @memset(big[0x400..], 0x11);
    declare_sram(big, 0xF8, 0x200001, 0x203FFF);
    const md = try new_md(big);
    defer std.testing.allocator.destroy(md);
    var b = md.bus_for();
    try expect(md.sram_map.present());
    try expect(!md.sram_active.present());
    try expectEqual(@as(u8, 0x11), b.read8(0x200001));
    b.write8(0xA130F1, 1);
    b.write8(0x200001, 0x42);
    try expectEqual(@as(u8, 0x42), b.read8(0x200001));
}

test "bus: interrupt level and acknowledge go to the VDP" {
    make_rom(&rom_buf);
    const md = try new_md(&rom_buf);
    defer std.testing.allocator.destroy(md);
    var b = md.bus_for();
    // Interrupts are masked by register 0 bit 4 (H-int) and register 1
    // bit 5 (V-int); the test ROM's values.
    md.vdp.write_reg(0, 0x14);
    md.vdp.write_reg(1, 0x64);
    try expectEqual(@as(u3, 0), b.irq_level());
    md.vdp.hint_pending = true;
    try expectEqual(@as(u3, 4), b.irq_level());
    md.vdp.vint_pending = true;
    try expectEqual(@as(u3, 6), b.irq_level());
    b.ack_irq(6);
    try expectEqual(@as(u3, 4), b.irq_level());
    b.ack_irq(4);
    try expectEqual(@as(u3, 0), b.irq_level());
}

test "bus: dma_read16 reads ROM and work RAM for the VDP" {
    make_rom(&rom_buf);
    const md = try new_md(&rom_buf);
    defer std.testing.allocator.destroy(md);
    md.work_ram[0x20] = 0xAB;
    md.work_ram[0x21] = 0xCD;
    try expectEqual(@as(u16, 0xABCD), core.bus.dma_read16(md, 0xFF0020));
    try expectEqual(@as(u16, 0x60FE), core.bus.dma_read16(md, 0x200));
    try expectEqual(@as(u16, 0xFFFF), core.bus.dma_read16(md, 0xA00000));
}

test "rom: load-time checks refuse SMD, mappers, SVP and headerless files" {
    make_rom(&rom_buf);
    const ok = core.RomSource.from_slice(&rom_buf);
    try expectEqual(rom.Refusal.ok, rom.check(&ok));

    var junk: [0x400]u8 = @splat(0);
    const none = core.RomSource.from_slice(&junk);
    try expectEqual(rom.Refusal.no_header, rom.check(&none));

    // "SEGA SSF" system name.
    var ssf = rom_buf;
    @memcpy(ssf[0x100..][0..16], "SEGA SSF        ");
    const ssf_src = core.RomSource.from_slice(&ssf);
    try expectEqual(rom.Refusal.mapper, rom.check(&ssf_src));

    // SVP: "SV" at 1C8, or the Virtua Racing product code.
    var svp = rom_buf;
    svp[0x1C8] = 'S';
    svp[0x1C9] = 'V';
    const svp_src = core.RomSource.from_slice(&svp);
    try expectEqual(rom.Refusal.svp, rom.check(&svp_src));
    svp = rom_buf;
    @memcpy(svp[0x180..][0..14], "GM MK-1229 -00");
    const svp_src2 = core.RomSource.from_slice(&svp);
    try expectEqual(rom.Refusal.svp, rom.check(&svp_src2));

    // Declared over 4 MB.
    var over = rom_buf;
    std.mem.writeInt(u32, over[0x1A4..][0..4], 0x4FFFFF, .big);
    const over_src = core.RomSource.from_slice(&over);
    try expectEqual(rom.Refusal.mapper, rom.check(&over_src));

    // SMD: interleave one 16 KB block (odd bytes first, then the even) and
    // put a 512-byte copier header in front.
    const raw = try std.testing.allocator.alloc(u8, 0x4000);
    defer std.testing.allocator.free(raw);
    @memset(raw, 0);
    @memcpy(raw[0..0x400], &rom_buf);
    const smd = try std.testing.allocator.alloc(u8, 0x4000 + 512);
    defer std.testing.allocator.free(smd);
    @memset(smd[0..512], 0);
    for (0..0x2000) |i| {
        smd[512 + i] = raw[2 * i + 1];
        smd[512 + 0x2000 + i] = raw[2 * i];
    }
    const smd_src = core.RomSource.from_slice(smd);
    try expect(rom.is_smd(&smd_src));
    try expectEqual(rom.Refusal.smd_interleaved, rom.check(&smd_src));
    // Headerless SMD (the block alone) is found by the de-interleave probe.
    const bare = core.RomSource.from_slice(smd[512..]);
    try expectEqual(rom.Refusal.smd_interleaved, rom.check(&bare));
    // The copier header mark alone.
    smd[8] = 0xAA;
    smd[9] = 0xBB;
    try expect(rom.is_smd(&smd_src));
    // The raw block is not SMD.
    const raw_src = core.RomSource.from_slice(raw);
    try expect(!rom.is_smd(&raw_src));
    try expectEqual(rom.Refusal.ok, rom.check(&raw_src));
}

test "md: the squeeze line table shows 128 rows, in order, from lines 0..222" {
    var prev: i32 = -1;
    var row: u8 = 0;
    while (row < core.out_h) : (row += 1) {
        const line = core.vdp.line_for_row(.squeeze, row);
        try expectEqual(@as(u16, row) * 7 / 4, line);
        try expect(@as(i32, line) > prev);
        prev = line;
    }
    try expectEqual(@as(u16, 222), core.vdp.line_for_row(.squeeze, core.out_h - 1));
}

test "md: a frame runs the 68000 for 128,008 cycles, carry below one instruction" {
    make_rom(&rom_buf);
    const md = try new_md(&rom_buf);
    defer std.testing.allocator.destroy(md);
    md.step_frame(0, false);
    try expectEqual(@as(u32, 1), md.frame_count);
    try expectEqual(@as(u16, 0), md.vdp.line);
    // The longest 68000 instruction (DIVS worst case) is under 200 cycles.
    try expect(md.m68k_carry < 200);
    try expect(md.dma_stall == 0);
}

test "md: DMA stall cycles come out of the 68000's budget" {
    make_rom(&rom_buf);
    const a = try new_md(&rom_buf);
    defer std.testing.allocator.destroy(a);
    // A stall longer than a line is carried: the 68000 sits out lines.
    a.dma_stall = 1000;
    a.step_frame(0, false);
    try expectEqual(@as(u32, 0), a.dma_stall);
    try expect(a.m68k_carry < 200);
}

/// The bus without `dma_source`: the VDP's word-by-word DMA path.
const PlainBus = struct {
    b: core.bus.Bus,
    pub fn read16(self: *PlainBus, addr: u24) u16 {
        return self.b.read16(addr);
    }
};

/// A 68000-to-VRAM DMA of `words` words from `src` to VRAM `dst`, through
/// `bus`; returns the stall.
fn run_dma(md: *Md, bus: anytype, src: u32, words: u16, dst: u16) u32 {
    const v = &md.vdp;
    v.write_reg(1, 0x54); // display, DMA enabled
    v.write_reg(5, 0x7E); // sprite table at FC00
    v.write_reg(15, 2);
    v.write_reg(19, @truncate(words));
    v.write_reg(20, @truncate(words >> 8));
    v.write_reg(21, @truncate(src >> 1));
    v.write_reg(22, @truncate(src >> 9));
    v.write_reg(23, @truncate((src >> 17) & 0x7F));
    v.spr_dirty = false; // set by the register 5 write
    _ = v.write_control(0x4000 | (dst & 0x3FFF), bus);
    return v.write_control(0x0080 | (dst >> 14), bus);
}

test "bus: VDP DMA through dma_source matches the word-by-word path" {
    var big: [0x800]u8 = undefined;
    make_rom(&big);
    for (big[0x400..], 0..) |*x, i| x.* = @truncate(i * 7 + 3);
    const a = try new_md(&big);
    defer std.testing.allocator.destroy(a);
    const r = try new_md(&big);
    defer std.testing.allocator.destroy(r);
    for (&a.work_ram, &r.work_ram, 0..) |*x, *y, i| {
        x.* = @truncate(i * 13 + 1);
        y.* = x.*;
    }
    // ROM running past its end (open bus after), work RAM across its 64 KB
    // mirror and the 128 KB window wrap, VRAM wrapping over the sprite table.
    const cases = [_]struct { src: u32, words: u16, dst: u16 }{
        .{ .src = 0x0700, .words = 0x100, .dst = 0x1000 },
        .{ .src = 0xFFFF00, .words = 0x100, .dst = 0xFF00 },
        .{ .src = 0xFF0010, .words = 0x40, .dst = 0x2002 },
        .{ .src = 0x0400, .words = 0, .dst = 0x8000 },
    };
    for (cases) |c| {
        var ab = a.bus_for();
        var rb: PlainBus = .{ .b = r.bus_for() };
        const sa = run_dma(a, &ab, c.src, c.words, c.dst);
        const sr = run_dma(r, &rb, c.src, c.words, c.dst);
        try expectEqual(sr, sa);
        try std.testing.expect(std.meta.eql(a.vdp, r.vdp));
        // Only the transfers over FC00-FFFF touch the sprite table (length
        // 0 is 64 K words: all of VRAM).
        try expectEqual(c.dst == 0xFF00 or c.words == 0, a.vdp.spr_dirty);
    }
}

// ---- Fragmented ROM runs (PLAN.md M4 Track A) ----

/// A clustered copy of `data` over a fake volume: file cluster k lives in
/// volume cluster `order[k]` (cluster 2 = the start of `vol`).
const Frag = struct {
    vol: []u8,
    src: core.RomSource,

    fn init(data: []const u8, order: []const u16) !Frag {
        var top: usize = 0;
        for (order) |cl| top = @max(top, cl);
        const vol = try std.testing.allocator.alloc(u8, (top - 1) * 512);
        @memset(vol, 0xEE);
        for (order, 0..) |cl, k| {
            const n = @min(512, data.len - k * 512);
            @memcpy(vol[(@as(usize, cl) - 2) * 512 ..][0..n], data[k * 512 ..][0..n]);
        }
        return .{ .vol = vol, .src = .{ .size = @intCast(data.len), .clusters = order, .data_base = vol.ptr } };
    }

    fn deinit(f: *Frag) void {
        std.testing.allocator.free(f.vol);
    }
};

fn pattern(buf: []u8) void {
    for (buf, 0..) |*b, i| b.* = @truncate((i *% 131) ^ (i >> 9) ^ (i >> 3));
}

/// File clusters: [10] (a run of 1), [20 21 22] (3), [100..169] (70, past
/// the 64-cluster cap), [300] (the last, partial: 100 bytes).
const big_order = blk: {
    var o: [75]u16 = undefined;
    o[0] = 10;
    o[1] = 20;
    o[2] = 21;
    o[3] = 22;
    for (4..74) |k| o[k] = 100 + (k - 4);
    o[74] = 300;
    break :blk o;
};
const big_size: u32 = 74 * 512 + 100;

fn expect_run(src: *const core.RomSource, addr: u32, base: u32, len: u32) !void {
    const r = rom.run_at(src, addr) orelse return error.NoRun;
    try expectEqual(base, r.base);
    try expectEqual(len, r.len);
}

test "rom: run_at finds the cluster runs, capped at 64 each way, clipped to the size" {
    const data = try std.testing.allocator.alloc(u8, big_size);
    defer std.testing.allocator.free(data);
    pattern(data);
    var f = try Frag.init(data, &big_order);
    defer f.deinit();
    const src = &f.src;
    // A run of one cluster, a run of three.
    try expect_run(src, 0, 0, 512);
    try expect_run(src, 511, 0, 512);
    try expect_run(src, 512, 512, 3 * 512);
    try expect_run(src, 512 + 5, 512, 3 * 512);
    try expect_run(src, 4 * 512 - 1, 512, 3 * 512);
    // The 70-cluster run (file clusters 4..73): from its first cluster the
    // forward scan stops after 64 clusters; from the middle it is whole;
    // from its last cluster the backward scan stops after 64.
    try expect_run(src, 4 * 512, 4 * 512, 65 * 512);
    try expect_run(src, 40 * 512 + 2, 4 * 512, 70 * 512);
    try expect_run(src, 73 * 512 + 6, 9 * 512, 65 * 512);
    // The last, partial cluster; past the end.
    try expect_run(src, 74 * 512 + 50, 74 * 512, 100);
    try expect_run(src, big_size - 1, 74 * 512, 100);
    try expect(rom.run_at(src, big_size) == null);
    try expect(rom.run_at(src, big_size + 4096) == null);
    // Every address: the run holds it and reads the file's bytes.
    var a: u32 = 0;
    while (a < big_size) : (a += 1) {
        const r = rom.run_at(src, a).?;
        try expect(r.base <= a and a < r.base + r.len);
        try expect(r.base + r.len <= big_size);
        try expectEqual(data[a], r.ptr[a - r.base]);
    }
    // A long run whose end is the partial last cluster.
    const small = [_]u16{ 5, 6, 7 };
    var g = try Frag.init(data[0 .. 2 * 512 + 10], &small);
    defer g.deinit();
    try expect_run(&g.src, 0, 0, 2 * 512 + 10);
    try expect_run(&g.src, 2 * 512 + 9, 0, 2 * 512 + 10);
    try expect(rom.run_at(&g.src, 2 * 512 + 10) == null);
    // A base source is one run.
    const flat = core.RomSource.from_slice(data);
    try expect_run(&flat, 12345, 0, big_size);
    try expect(rom.run_at(&flat, big_size) == null);
}

/// 16 KB: the 1 KB `make_rom` header and vectors (PC 000200), then a NOP at
/// 0x200 and `add.w #imm,d0` (D07C imm) from 0x202, so every 512-byte
/// boundary falls between an opcode and its immediate; at 0x3F00 a
/// `bra.w` back to 0x200.
fn make_add_rom(buf: []u8) void {
    make_rom(buf[0..0x400]);
    @memset(buf[0x400..], 0);
    buf[0x200] = 0x4E;
    buf[0x201] = 0x71;
    var a: usize = 0x202;
    var k: u16 = 1;
    while (a + 4 <= 0x3F00) : (a += 4) {
        std.mem.writeInt(u16, buf[a..][0..2], 0xD07C, .big);
        std.mem.writeInt(u16, buf[a + 2 ..][0..2], k *% 0x9E37 +% 0x79B9, .big);
        k +%= 1;
    }
    std.mem.writeInt(u16, buf[0x3F00..][0..2], 0x6000, .big);
    std.mem.writeInt(u16, buf[0x3F02..][0..2], @bitCast(@as(i16, 0x200 - 0x3F02)), .big);
}

/// File cluster k of 32 in volume cluster `2 + perm(k)`: every cluster its
/// own run except a run of four at file clusters 8..11.
const frag_order = blk: {
    var o: [32]u16 = undefined;
    for (0..32) |k| o[k] = @intCast(2 + (k * 13) % 32 * 2);
    for (8..12) |k| o[k] = @intCast(100 + k);
    break :blk o;
};

const no_bytes = [2]u8{ 0, 0 };

/// The CPU without its fetch window (which points into either source).
fn cpu_state(md: *const Md) core.Cpu {
    var c = md.cpu;
    c.win_ptr = @ptrCast(&no_bytes);
    c.win_base = 0;
    c.win_len = 0;
    return c;
}

test "bus: a fragmented ROM fetches through run windows like the contiguous one" {
    var data: [0x4000]u8 = undefined;
    make_add_rom(&data);
    var f = try Frag.init(&data, &frag_order);
    defer f.deinit();
    const a = try new_md(&data);
    defer std.testing.allocator.destroy(a);
    const b = try std.testing.allocator.create(Md);
    defer std.testing.allocator.destroy(b);
    b.init_in_place(f.src);
    // The code window around every ROM address holds it and its bytes.
    var bb = b.bus_for();
    var addr: u32 = 0;
    while (addr < data.len) : (addr += 2) {
        const w = bb.code_window(@intCast(addr)) orelse return error.NoWindow;
        try expect(w.base <= addr and addr + 2 <= w.base + w.len);
        try expectEqual(data[addr], w.ptr[addr - w.base]);
        try expectEqual(data[addr + 1], w.ptr[addr + 1 - w.base]);
    }
    try expect(bb.code_window(@intCast(data.len)) == null);
    // Two frames run the same instructions to the same state.
    for (0..2) |_| {
        a.step_frame(0, false);
        b.step_frame(0, false);
        try expect(std.meta.eql(cpu_state(a), cpu_state(b)));
    }
    try expect(a.cpu.d[0] != 0);
    // b's window is a run of the volume, not the whole ROM.
    try expect(b.cpu.win_len < 0x800);
}

test "bus: a fragmented ROM DMAs run by run like the contiguous one" {
    var data: [0x4000]u8 = undefined;
    make_rom(data[0..0x400]);
    for (data[0x400..], 0..) |*x, i| x.* = @truncate(i * 7 + 3);
    var f = try Frag.init(&data, &frag_order);
    defer f.deinit();
    const a = try new_md(&data);
    defer std.testing.allocator.destroy(a);
    const b = try std.testing.allocator.create(Md);
    defer std.testing.allocator.destroy(b);
    b.init_in_place(f.src);
    const r = try new_md(&data);
    defer std.testing.allocator.destroy(r);

    // Spans: within one cluster, across single-cluster runs, through the
    // run of four, from an odd word inside a cluster, past the ROM's end.
    var bb = b.bus_for();
    const s0 = bb.dma_source(0x0402, 0x400).?;
    try expectEqual(@as(u32, (0x600 - 0x402) / 2), s0.words);
    const s1 = bb.dma_source(0x1000, 0x1000).?;
    try expectEqual(@as(u32, 4 * 512 / 2), s1.words);
    try expect(bb.dma_source(@intCast(data.len), 4) == null);
    const cases = [_]struct { src: u32, words: u16, dst: u16 }{
        .{ .src = 0x0410, .words = 0x40, .dst = 0x1000 },
        .{ .src = 0x05F0, .words = 0x300, .dst = 0x2000 },
        .{ .src = 0x0E06, .words = 0x700, .dst = 0x4000 },
        .{ .src = 0x3E00, .words = 0x200, .dst = 0x8000 },
    };
    for (cases) |c| {
        var ab = a.bus_for();
        var bbus = b.bus_for();
        var rb: PlainBus = .{ .b = r.bus_for() };
        const sa = run_dma(a, &ab, c.src, c.words, c.dst);
        const sb = run_dma(b, &bbus, c.src, c.words, c.dst);
        const sr = run_dma(r, &rb, c.src, c.words, c.dst);
        try expectEqual(sr, sa);
        try expectEqual(sr, sb);
        try expect(std.meta.eql(r.vdp, a.vdp));
        try expect(std.meta.eql(r.vdp, b.vdp));
    }

    // SRAM over the ROM (switched on at A130F1): spans stop below it for
    // both sources and the rest goes word by word through the SRAM.
    const sram: rom.SramMap = .{ .lo = 0x1100, .hi = 0x13FF };
    for ([_]*Md{ a, b, r }) |m| {
        m.sram_active = sram;
        for (m.sram[0..0x300], 0..) |*x, i| x.* = @truncate(i ^ 0x5A);
    }
    try expectEqual(@as(u32, (0x1100 - 0x1000) / 2), bb.dma_source(0x1000, 0x1000).?.words);
    var ab = a.bus_for();
    try expectEqual(@as(u32, 0x80), ab.dma_source(0x1000, 0x1000).?.words);
    try expect(bb.dma_source(0x1100, 4) == null);
    var bbus = b.bus_for();
    var rb: PlainBus = .{ .b = r.bus_for() };
    const sa = run_dma(a, &ab, 0x0F00, 0x300, 0xA000);
    const sb = run_dma(b, &bbus, 0x0F00, 0x300, 0xA000);
    const sr = run_dma(r, &rb, 0x0F00, 0x300, 0xA000);
    try expectEqual(sr, sa);
    try expectEqual(sr, sb);
    try expect(std.meta.eql(r.vdp, a.vdp));
    try expect(std.meta.eql(r.vdp, b.vdp));
}
