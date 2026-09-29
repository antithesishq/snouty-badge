//! Cross-subsystem smoke test: a hand-assembled ROM sets the mapper, writes
//! RAM, a VDP register, CRAM, a VRAM byte and the PSG through the ports,
//! then spins; `step_frame` runs it and the bytes must have landed.
//!
const std = @import("std");
const core = @import("core");
const Gg = core.Gg;
const expectEqual = std.testing.expectEqual;

/// Address of the final `jr $`.
const loop_pc = 0x003C;

const program = [_]u8{
    0xF3, // 0000 di
    0x31, 0xF0, 0xDF, // 0001 ld sp,DFF0
    0x3E, 0x03, // 0004 ld a,03
    0x32, 0xFF, 0xFF, // 0006 ld (FFFF),a      slot 2 = bank 3
    0x3E, 0x42, // 0009 ld a,42
    0x32, 0x00, 0xC1, // 000B ld (C100),a      RAM
    0x3E, 0x05, // 000E ld a,05
    0xD3, 0xBF, // 0010 out (BF),a
    0x3E, 0x87, // 0012 ld a,87
    0xD3, 0xBF, // 0014 out (BF),a       VDP register 7 = 05
    0xAF, // 0016 xor a
    0xD3, 0xBF, // 0017 out (BF),a
    0x3E, 0xC0, // 0019 ld a,C0
    0xD3, 0xBF, // 001B out (BF),a       CRAM write, address 0
    0x3E, 0x0F, // 001D ld a,0F
    0xD3, 0xBE, // 001F out (BE),a       CRAM low byte (latched)
    0x3E, 0x0A, // 0021 ld a,0A
    0xD3, 0xBE, // 0023 out (BE),a       CRAM[0] = 0A0F
    0xAF, // 0025 xor a
    0xD3, 0xBF, // 0026 out (BF),a
    0x3E, 0x60, // 0028 ld a,60
    0xD3, 0xBF, // 002A out (BF),a       VRAM write, address 2000
    0x3E, 0xAA, // 002C ld a,AA
    0xD3, 0xBE, // 002E out (BE),a       VRAM[2000] = AA
    0x3E, 0x93, // 0030 ld a,93
    0xD3, 0x7F, // 0032 out (7F),a       PSG ch0 attenuation 3
    0x3E, 0x8E, // 0034 ld a,8E
    0xD3, 0x7F, // 0036 out (7F),a       PSG ch0 tone low E
    0x3E, 0x0F, // 0038 ld a,0F
    0xD3, 0x7F, // 003A out (7F),a       PSG ch0 tone high 0F -> period 0FE
    0x18, 0xFE, // 003C jr $
};

var rom: [0x10000]u8 = undefined;

fn build_rom() void {
    @memset(&rom, 0);
    @memcpy(rom[0..program.len], &program);
    // Bank 3 starts with a marker the mapped slot 2 must show.
    rom[3 * 0x4000] = 0xB3;
}

test "smoke: a tiny ROM drives mapper, RAM, VDP and PSG through step_frame" {
    build_rom();
    const gg = try std.testing.allocator.create(Gg);
    defer std.testing.allocator.destroy(gg);
    gg.init_in_place(core.Rom.from_slice(&rom));

    for (0..3) |_| gg.step_frame(0);
    try expectEqual(@as(u32, 3), gg.frame_count);
    // A frame is 262 x 228 T-states, give or take one instruction.
    try std.testing.expect(gg.frame_t >= core.frame_tstates - 23 and gg.frame_t <= core.frame_tstates + 23);

    try expectEqual(@as(u16, loop_pc), gg.cpu.pc);
    var b = gg.bus_for();
    try expectEqual(@as(u8, 3), gg.mapper.slot[2]);
    try expectEqual(@as(u8, 0xB3), b.read(0x8000));
    try expectEqual(@as(u8, 0x03), b.read(0xFFFF)); // mapper register is RAM too
    try expectEqual(@as(u8, 0x42), gg.ram[0x100]);
    try expectEqual(@as(u8, 0x05), gg.vdp.regs[7]);
    try expectEqual(@as(u16, 0x0A0F), gg.vdp.cram[0]);
    try expectEqual(@as(u8, 0xAA), gg.vdp.vram[0x2000]);
    try expectEqual(@as(u8, 3), gg.psg.atten[0]);
    try expectEqual(@as(u16, 0x0FE), gg.psg.tone[0]);
    try expectEqual(@as(u16, 0xDFF0), gg.cpu.sp);
}

test "smoke: frames are deterministic and survive snapshot/restore" {
    build_rom();
    const a = try std.testing.allocator.create(Gg);
    defer std.testing.allocator.destroy(a);
    const k = try std.testing.allocator.create(Gg.Keyframe);
    defer std.testing.allocator.destroy(k);
    a.init_in_place(core.Rom.from_slice(&rom));
    a.step_frame(core.Pad.right);
    a.snapshot(k);
    a.step_frame(core.Pad.b1);
    const pc = a.cpu.pc;
    const line = a.vdp.line;
    a.restore(k);
    a.step_frame(core.Pad.b1);
    try expectEqual(pc, a.cpu.pc);
    try expectEqual(line, a.vdp.line);
    try expectEqual(@as(u32, 2), a.frame_count);
}
