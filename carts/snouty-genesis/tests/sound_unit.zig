//! M1 Track D: the sound side. Z80 map (RAM mirror, bank register, the
//! 68000 window over ROM and work RAM, YM and PSG ports), the YM2612
//! register model (latches, key-on, timers, the picker), the PSG model,
//! the FM-versus-PSG pick, and the shipped test ROM's Z80 driver run
//! through Gear's Z80.
const std = @import("std");
const core = @import("core");
const rom_data = @import("rom");
const Md = core.Md;
const z80bus = core.z80bus;
const Ym = core.ym2612.Ym2612;
const Psg = core.psg.Psg;
const Tone = core.Tone;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

fn new_md(src: core.RomSource) !*Md {
    const md = try std.testing.allocator.create(Md);
    md.init_in_place(src);
    z80bus.reset_genesis(&md.z80);
    return md;
}

/// Shift a 9-bit bank value into 6000, LSB first, through the Z80 bus.
fn set_bank(zb: *z80bus.Z80Bus, bank: u16) void {
    var i: u4 = 0;
    while (i < 9) : (i += 1) zb.write(0x6000 + @as(u16, i) * 17, @truncate(bank >> i));
}

// ---- Z80 map ----

test "sound: Z80 RAM is mirrored at 2000-3FFF" {
    const data: [0x200]u8 = @splat(0);
    const md = try new_md(core.RomSource.from_slice(&data));
    defer std.testing.allocator.destroy(md);
    var zb = z80bus.Z80Bus.init(md);
    zb.write(0x0123, 0x5A);
    try expectEqual(@as(u8, 0x5A), zb.read(0x2123));
    zb.write(0x3FFF, 0x77);
    try expectEqual(@as(u8, 0x77), md.z80_ram[0x1FFF]);
    try expectEqual(@as(u8, 0x77), zb.read(0x1FFF));
    // Unmapped and VDP reads are FF; ports are FF.
    try expectEqual(@as(u8, 0xFF), zb.read(0x6000));
    try expectEqual(@as(u8, 0xFF), zb.read(0x7F04));
    try expectEqual(@as(u8, 0xFF), zb.read(0x7000));
    try expectEqual(@as(u8, 0xFF), zb.in(0x7F));
}

test "sound: bank register shifts nine bits in, LSB first" {
    const data: [0x200]u8 = @splat(0);
    const md = try new_md(core.RomSource.from_slice(&data));
    defer std.testing.allocator.destroy(md);
    var zb = z80bus.Z80Bus.init(md);
    // One write of 1: bit 8 set (A23).
    zb.write(0x6000, 0x01);
    try expectEqual(@as(u16, 0x100), md.z80_bank);
    try expectEqual(@as(u32, 0x800000), z80bus.window_base(md));
    // Only bit 0 of the byte counts; every address in 6000-60FF works.
    zb.write(0x60FF, 0xFE);
    try expectEqual(@as(u16, 0x080), md.z80_bank);
    // A full sequence: bank 0x1C3 -> window at E18000.
    set_bank(&zb, 0x1C3);
    try expectEqual(@as(u16, 0x1C3), md.z80_bank);
    try expectEqual(@as(u32, 0xE18000), z80bus.window_base(md));
    // Nine zero writes clear it whatever it held.
    set_bank(&zb, 0);
    try expectEqual(@as(u16, 0), md.z80_bank);
    // The typical driver sequence for 68000 address 0x123456: bits 15-23
    // of the address, LSB first (0x123456 >> 15 = 0x24).
    var a: u32 = 0x123456 >> 15;
    for (0..9) |_| {
        zb.write(0x6000, @truncate(a & 1));
        a >>= 1;
    }
    try expectEqual(@as(u32, 0x120000), z80bus.window_base(md));
    // 6100 is past the register: no shift.
    zb.write(0x6100, 1);
    try expectEqual(@as(u32, 0x120000), z80bus.window_base(md));
}

test "sound: the window reads ROM (flat and clustered) and work RAM" {
    // A 96 KB ROM, byte i = hash(i); a flat and a clustered copy.
    const size = 3 * 0x8000;
    const data = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(data);
    for (data, 0..) |*b, i| b.* = @truncate((i *% 131) ^ (i >> 9));
    const n_cl = size / 512;
    const vol = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(vol);
    var order: [n_cl]u16 = undefined;
    // File cluster k lives in volume cluster 2 + (k * 37 mod n_cl).
    for (&order, 0..) |*cl, k| {
        cl.* = @intCast(2 + (k * 37) % n_cl);
        @memcpy(vol[(@as(usize, cl.*) - 2) * 512 ..][0..512], data[k * 512 ..][0..512]);
    }
    const flat = core.RomSource.from_slice(data);
    const frag: core.RomSource = .{ .size = size, .clusters = &order, .data_base = vol.ptr };

    for ([_]core.RomSource{ flat, frag }) |src| {
        const md = try new_md(src);
        defer std.testing.allocator.destroy(md);
        var zb = z80bus.Z80Bus.init(md);
        for ([_]u16{ 0, 1, 2 }) |bank| {
            set_bank(&zb, bank);
            for ([_]u16{ 0x8000, 0x8001, 0x81FF, 0x8200, 0xC000, 0xFFFF }) |addr| {
                const a = @as(u32, bank) << 15 | (addr & 0x7FFF);
                try expectEqual(data[a], zb.read(addr));
            }
        }
        // Past the end of the ROM: open bus FF.
        set_bank(&zb, 3);
        try expectEqual(@as(u8, 0xFF), zb.read(0x8000));
        // The Z80 area (A00000) and the VDP (C00000) are unreachable.
        set_bank(&zb, 0xA00000 >> 15);
        try expectEqual(@as(u8, 0xFF), zb.read(0x8000));
        set_bank(&zb, 0xC00000 >> 15);
        try expectEqual(@as(u8, 0xFF), zb.read(0x8011));
        // Work RAM: FF0000 and its mirror E08000, read and write.
        md.work_ram[0x0010] = 0xAB;
        md.work_ram[0x8020] = 0xCD;
        set_bank(&zb, 0xFF0000 >> 15);
        try expectEqual(@as(u8, 0xAB), zb.read(0x8010));
        zb.write(0x8011, 0x42);
        try expectEqual(@as(u8, 0x42), md.work_ram[0x0011]);
        set_bank(&zb, 0xE08000 >> 15);
        try expectEqual(@as(u8, 0xCD), zb.read(0x8020));
        zb.write(0xFFFF, 0x99);
        try expectEqual(@as(u8, 0x99), md.work_ram[0xFFFF]);
        // ROM writes are dropped.
        set_bank(&zb, 0);
        zb.write(0x8000, ~data[0]);
        try expectEqual(data[0], zb.read(0x8000));
    }
}

test "sound: a bank change through another bus instance invalidates the cached window" {
    var data: [0x10000]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i >> 8);
    const md = try new_md(core.RomSource.from_slice(&data));
    defer std.testing.allocator.destroy(md);
    var zb = z80bus.Z80Bus.init(md);
    try expectEqual(@as(u8, 0x00), zb.read(0x8000));
    var other = md.z80bus_for(); // e.g. the 68000 writing A06000
    set_bank(&other, 1);
    try expectEqual(@as(u8, 0x80), zb.read(0x8000));
    try expectEqual(@as(u8, 0xFF), zb.read(0xFFFF));
}

test "sound: YM2612 and PSG ports from the Z80" {
    const data: [0x200]u8 = @splat(0);
    const md = try new_md(core.RomSource.from_slice(&data));
    defer std.testing.allocator.destroy(md);
    var zb = z80bus.Z80Bus.init(md);
    // Part I: 4000/4001; part II: 4002/4003; mirrors every 4 bytes.
    zb.write(0x4000, 0xB0);
    zb.write(0x4001, 0x07);
    zb.write(0x4002, 0xB1);
    zb.write(0x4003, 0x05);
    zb.write(0x5FFC, 0x40); // mirror of 4000
    zb.write(0x5FFD, 0x11);
    try expectEqual(@as(u8, 0x07), md.ym.regs[0][0xB0]);
    try expectEqual(@as(u8, 0x05), md.ym.regs[1][0xB1]);
    try expectEqual(@as(u8, 0x11), md.ym.regs[0][0x40]);
    // The address latch holds across data writes.
    zb.write(0x4001, 0x12);
    try expectEqual(@as(u8, 0x12), md.ym.regs[0][0x40]);
    try expectEqual(@as(u8, 0x05), md.ym.regs[1][0xB1]);
    // Status reads on every port, never busy.
    md.ym.status = 3;
    try expectEqual(@as(u8, 3), zb.read(0x4000));
    try expectEqual(@as(u8, 3), zb.read(0x4003));
    try expectEqual(@as(u8, 3), zb.read(0x5001));
    // PSG at 7F11 (and its odd mirrors); even VDP addresses are not PSG.
    zb.write(0x7F11, 0x90);
    try expectEqual(@as(u4, 0), md.psg.atten[0]);
    zb.write(0x7F17, 0xB3);
    try expectEqual(@as(u4, 3), md.psg.atten[1]);
    zb.write(0x7F10, 0x9F);
    try expectEqual(@as(u4, 0), md.psg.atten[0]);
}

test "sound: reset_genesis and HALT slices" {
    const data: [0x200]u8 = @splat(0);
    const md = try new_md(core.RomSource.from_slice(&data));
    defer std.testing.allocator.destroy(md);
    try expectEqual(@as(u16, 0), md.z80.pc);
    try expectEqual(@as(u2, 0), md.z80.im);
    try expect(!md.z80.iff1);
    try expectEqual(@as(u16, 0xFFFF), md.z80.sp);
    // halt at 0: a slice of 228 cycles overshoots by less than 4.
    md.z80_ram[0] = 0x76;
    var used = z80bus.run(md, 228);
    try expect(md.z80.halted);
    try expect(used >= 228 and used < 232);
    used = z80bus.run(md, 228 * 262);
    try expect(used >= 228 * 262 and used < 228 * 262 + 4);
    // Interrupts disabled: INT does not wake it.
    md.z80_int = true;
    _ = z80bus.run(md, 228);
    try expect(md.z80.halted);
    // reset_line resets the Z80 and the YM2612, not the bank register.
    md.z80_bank = 0x55;
    md.ym.regs[0][0x30] = 1;
    z80bus.reset_line(md);
    try expect(!md.z80.halted);
    try expectEqual(@as(u8, 0), md.ym.regs[0][0x30]);
    try expectEqual(@as(u16, 0x55), md.z80_bank);
}

// ---- YM2612 ----

fn ym_w(y: *Ym, part: u1, r: u8, v: u8) void {
    y.write_addr(part, r);
    y.write_data(part, v);
}

test "sound: YM2612 key-on register and part II channels" {
    var y: Ym = .{};
    y.reset();
    ym_w(&y, 0, 0x28, 0xF0);
    try expectEqual(@as(u4, 0xF), y.key_on[0]);
    ym_w(&y, 0, 0x28, 0x16); // channel 6, operator 1
    try expectEqual(@as(u4, 1), y.key_on[5]);
    ym_w(&y, 0, 0x28, 0x84); // channel 4, operator 4
    try expectEqual(@as(u4, 8), y.key_on[3]);
    ym_w(&y, 0, 0x28, 0xF3); // invalid channel: ignored
    ym_w(&y, 0, 0x28, 0xF7);
    for (y.key_on, [_]u4{ 0xF, 0, 0, 8, 0, 1 }) |got, want| try expectEqual(want, got);
    ym_w(&y, 0, 0x28, 0x00);
    try expectEqual(@as(u4, 0), y.key_on[0]);
    // 28 through part II is a global: ignored.
    ym_w(&y, 1, 0x28, 0xF1);
    try expectEqual(@as(u4, 0), y.key_on[1]);
    // Part II register B2 is channel 6's algorithm.
    ym_w(&y, 1, 0xB2, 0x07);
    try expectEqual(@as(u3, 7), y.algorithm(5));
    // TL layout: 40 op1, 44 op3, 48 op2, 4C op4 (+ channel).
    ym_w(&y, 1, 0x4A, 0x33); // part II, op 2, channel 6
    try expectEqual(@as(u7, 0x33), y.total_level(5, 1));
}

test "sound: YM2612 frequency latch, and fm_hz against reference values" {
    var y: Ym = .{};
    y.reset();
    ym_w(&y, 0, 0xA4, 0x24);
    try expectEqual(@as(u16, 0), y.freq[0]); // not committed yet
    ym_w(&y, 0, 0xA0, 0x3A);
    try expectEqual(@as(u16, 4 << 11 | 1082), y.freq[0]);
    ym_w(&y, 1, 0xA6, 0x26);
    ym_w(&y, 1, 0xA2, 0x56);
    try expectEqual(@as(u16, 4 << 11 | 1622), y.freq[5]);
    // Special mode frequencies: AD then A9 = operator 1.
    ym_w(&y, 0, 0xAD, 0x1A);
    ym_w(&y, 0, 0xA9, 0x44);
    try expectEqual(@as(u16, 0x1A44), y.ch3_freq[0]);
    ym_w(&y, 0, 0xAC, 0x0B);
    ym_w(&y, 0, 0xA8, 0x01);
    try expectEqual(@as(u16, 0x0B01), y.ch3_freq[2]);

    // Reference: fnum * 2^(block-1) * 53693175 / (7 * 144 * 2^20).
    const F = core.ym2612.fm_hz;
    try expectEqual(@as(u16, 440), F(4, 1082)); // 439.72 A4
    try expectEqual(@as(u16, 659), F(4, 1622)); // 659.17 E5
    try expectEqual(@as(u16, 262), F(4, 644)); // 261.72 C4
    try expectEqual(@as(u16, 220), F(3, 1082)); // 219.86
    try expectEqual(@as(u16, 879), F(5, 1082)); // 879.44
    try expectEqual(@as(u16, 251), F(4, 617)); // 250.75
    try expectEqual(@as(u16, 6655), F(7, 2047)); // 6655.13
    try expectEqual(@as(u16, 0), F(0, 1)); // 0.025
}

test "sound: YM2612 timer A period, flags, reset strobes" {
    var y: Ym = .{};
    y.reset();
    // TA = 1000: 24 * 144 = 3456 clocks.
    ym_w(&y, 0, 0x24, 1000 >> 2);
    ym_w(&y, 0, 0x25, 1000 & 3);
    try expectEqual(@as(u32, 3456), y.period_a());
    ym_w(&y, 0, 0x27, 0x05); // load + enable A
    y.tick(3455);
    try expectEqual(@as(u8, 0), y.read_status());
    y.tick(1);
    try expectEqual(@as(u8, 1), y.read_status());
    // Reset strobe clears the flag, the timer keeps running in phase.
    ym_w(&y, 0, 0x27, 0x15);
    try expectEqual(@as(u8, 0), y.read_status());
    try expectEqual(@as(u8, 0x05), y.regs[0][0x27]);
    y.tick(3455);
    try expectEqual(@as(u8, 0), y.read_status());
    y.tick(1);
    try expectEqual(@as(u8, 1), y.read_status());
    // Several periods in one tick keep the phase: 2.5 periods from here.
    ym_w(&y, 0, 0x27, 0x15);
    y.tick(3456 * 2 + 1728);
    try expectEqual(@as(u8, 1), y.read_status());
    try expectEqual(@as(u32, 1728), y.timer_a_left);
    // Not enabled: overflows do not set the flag.
    ym_w(&y, 0, 0x27, 0x11);
    try expectEqual(@as(u8, 0), y.read_status());
    y.tick(10 * 3456);
    try expectEqual(@as(u8, 0), y.read_status());
    // TA = 3FF: one sample, 144 clocks, i.e. every 144 68000 cycles.
    ym_w(&y, 0, 0x24, 0xFF);
    ym_w(&y, 0, 0x25, 0x03);
    ym_w(&y, 0, 0x27, 0x00);
    ym_w(&y, 0, 0x27, 0x05); // reload on the 0-to-1 edge
    try expectEqual(@as(u32, 144), y.timer_a_left);
    y.tick(143);
    try expectEqual(@as(u8, 0), y.read_status());
    y.tick(1);
    try expectEqual(@as(u8, 1), y.read_status());
    // Not loaded: no counting.
    ym_w(&y, 0, 0x27, 0x10);
    y.tick(100000);
    try expectEqual(@as(u8, 0), y.read_status());
}

test "sound: YM2612 timer B period and independence from A" {
    var y: Ym = .{};
    y.reset();
    // TB = 200: 56 * 2304 = 129024 clocks (about one frame of 68000 time).
    ym_w(&y, 0, 0x26, 200);
    try expectEqual(@as(u32, 129024), y.period_b());
    ym_w(&y, 0, 0x27, 0x0A); // load + enable B
    // Tick per line as the frame loop would: 488/489 cycles.
    var t: u32 = 0;
    var line: u32 = 0;
    while (y.read_status() == 0) : (line += 1) {
        const c: u32 = if (line & 1 == 0) 488 else 489;
        y.tick(c);
        t += c;
    }
    try expectEqual(@as(u8, 2), y.read_status());
    try expect(t >= 129024 and t < 129024 + 489);
    ym_w(&y, 0, 0x27, 0x2A);
    try expectEqual(@as(u8, 0), y.read_status());
    // TB = FF: 2304 clocks. Both timers at once.
    ym_w(&y, 0, 0x26, 0xFF);
    ym_w(&y, 0, 0x24, 0xFF);
    ym_w(&y, 0, 0x25, 0x03);
    ym_w(&y, 0, 0x27, 0x00);
    ym_w(&y, 0, 0x27, 0x0F);
    y.tick(144);
    try expectEqual(@as(u8, 1), y.read_status());
    y.tick(2304 - 144);
    try expectEqual(@as(u8, 3), y.read_status());
    ym_w(&y, 0, 0x27, 0x1F);
    try expectEqual(@as(u8, 2), y.read_status());
}

/// Channel `ch` (0-5): algorithm, TLs of operators 1-4, block/fnum.
fn voice(y: *Ym, ch: u8, alg: u8, tl: [4]u8, block: u8, fnum: u16) void {
    const part: u1 = @intCast(ch / 3);
    const c = ch % 3;
    ym_w(y, part, 0xB0 + c, alg);
    const offs = [4]u8{ 0x0, 0x8, 0x4, 0xC };
    for (tl, offs) |t, o| ym_w(y, part, 0x40 + o + c, t);
    ym_w(y, part, 0xA4 + c, block << 3 | @as(u8, @intCast(fnum >> 8)));
    ym_w(y, part, 0xA0 + c, @truncate(fnum));
}

fn key(y: *Ym, ch: u8, ops: u8) void {
    ym_w(y, 0, 0x28, ops << 4 | (if (ch < 3) ch else ch + 1));
}

test "sound: carriers by algorithm" {
    var y: Ym = .{};
    y.reset();
    // Operator 1 loud (TL 0), operator 2 at 16, 3 at 32, 4 at 48.
    const tl = [4]u8{ 0, 16, 32, 48 };
    const want = [8]u7{ 48, 48, 48, 48, 16, 16, 16, 0 };
    for (want, 0..) |w, alg| {
        voice(&y, 0, @intCast(alg), tl, 4, 1082);
        key(&y, 0, 0xF);
        try expectEqual(@as(?u7, w), y.carrier_tl(0));
    }
    // Only keyed-on carriers count: algorithm 4 with operator 2 off.
    voice(&y, 0, 4, tl, 4, 1082);
    key(&y, 0, 0b1001);
    try expectEqual(@as(?u7, 48), y.carrier_tl(0));
    // A keyed modulator alone is silent.
    key(&y, 0, 0b0001);
    try expectEqual(@as(?u7, null), y.carrier_tl(0));
    try expectEqual(@as(?Tone, null), y.pick());
}

test "sound: YM2612 pick orders by carrier TL, skips DAC channel 6" {
    var y: Ym = .{};
    y.reset();
    try expectEqual(@as(?Tone, null), y.pick());
    voice(&y, 0, 7, .{ 40, 40, 40, 40 }, 4, 1082); // A4, TL 40
    voice(&y, 4, 0, .{ 0, 0, 0, 20 }, 4, 1622); // E5, carrier TL 20
    voice(&y, 5, 0, .{ 0, 0, 0, 0 }, 3, 1082); // 220 Hz, carrier TL 0
    key(&y, 0, 0xF);
    try expectEqual(@as(?Tone, .{ .hz = 440, .level = 0 }), y.pick());
    key(&y, 4, 0xF);
    try expectEqual(@as(?Tone, .{ .hz = 659, .level = 8 }), y.pick()); // 15 - 20*3/8
    key(&y, 5, 0xF);
    try expectEqual(@as(?Tone, .{ .hz = 220, .level = 15 }), y.pick());
    // DAC enabled: channel 6 is a sample player, skipped.
    ym_w(&y, 0, 0x2B, 0x80);
    try expectEqual(@as(?Tone, .{ .hz = 659, .level = 8 }), y.pick());
    ym_w(&y, 0, 0x2A, 0x80); // DAC data: stored only
    try expectEqual(@as(u8, 0x80), y.regs[0][0x2A]);
    ym_w(&y, 0, 0x2B, 0x00);
    // Key off channel 6 and 5: channel 1 again.
    key(&y, 5, 0);
    key(&y, 4, 0);
    try expectEqual(@as(?Tone, .{ .hz = 440, .level = 0 }), y.pick());
    // TL 127 is silent.
    voice(&y, 0, 7, .{ 127, 127, 127, 127 }, 4, 1082);
    try expectEqual(@as(?Tone, null), y.pick());
    // Ties go to the lower channel.
    voice(&y, 1, 0, .{ 0, 0, 0, 8 }, 4, 1622);
    voice(&y, 2, 0, .{ 0, 0, 0, 8 }, 4, 1082);
    key(&y, 2, 0xF);
    key(&y, 1, 0xF);
    try expectEqual(@as(?Tone, .{ .hz = 659, .level = 12 }), y.pick());
}

test "sound: channel 3 special mode picks operator 4's frequency" {
    var y: Ym = .{};
    y.reset();
    voice(&y, 2, 7, .{ 10, 10, 10, 30 }, 4, 1082); // A2/A6: op 4 = A4
    // Special mode with other frequencies for operators 1-3.
    ym_w(&y, 0, 0x27, 0x40);
    ym_w(&y, 0, 0xAD, 0x26);
    ym_w(&y, 0, 0xA9, 0x56);
    ym_w(&y, 0, 0xAE, 0x1A);
    ym_w(&y, 0, 0xAA, 0x00);
    try expectEqual(@as(u2, 1), y.ch3_mode());
    key(&y, 2, 0xF);
    const t = y.pick().?;
    try expectEqual(@as(u16, 440), t.hz);
    try expectEqual(@as(u4, 15 - 10 * 3 / 8), t.level);
    // The A8-AE pairs landed in the special-mode slots, not in freq.
    try expectEqual(@as(u16, 0x2656), y.ch3_freq[0]);
    try expectEqual(@as(u16, 0x1A00), y.ch3_freq[1]);
    try expectEqual(@as(u16, 4 << 11 | 1082), y.freq[2]);
}

// ---- PSG ----

test "sound: PSG latch and data protocol, and pick" {
    var p: Psg = .{};
    p.reset();
    try expectEqual(@as(?Tone, null), p.pick());
    // Tone 0 period 0x1FC at attenuation 4 (the test ROM's bytes).
    for ([_]u8{ 0x9F, 0xBF, 0xDF, 0xFF, 0x8C, 0x1F, 0x94 }) |b| p.write(b);
    try expectEqual(@as(u16, 0x1FC), p.tone[0]);
    try expectEqual(@as(u4, 4), p.atten[0]);
    try expectEqual(@as(?Tone, .{ .hz = 220, .level = 11 }), p.pick());
    // Data bytes go to the latched register: a volume latch then data.
    p.write(0xB0); // ch 1 atten 0
    p.write(0x05); // data: ch 1 atten 5
    try expectEqual(@as(u4, 5), p.atten[1]);
    // Channel 1 has no period yet (0): not a candidate.
    try expectEqual(@as(u16, 220), p.pick().?.hz);
    p.write(0xA6); // ch 1 tone low 6
    p.write(0x3F); // high 6 bits
    try expectEqual(@as(u16, 0x3F6), p.tone[1]);
    // Ch 0 (atten 4) still louder than ch 1 (atten 5).
    try expectEqual(@as(u16, 220), p.pick().?.hz);
    p.write(0xB2);
    try expectEqual(@as(?Tone, .{ .hz = 3579545 / (32 * 0x3F6), .level = 13 }), p.pick());
    // Ties to the lower channel.
    p.write(0x92);
    try expectEqual(@as(u16, 220), p.pick().?.hz);
    // Noise: latch E, data bits.
    p.write(0xE5);
    try expectEqual(@as(u8, 5), p.noise);
    p.write(0xF0); // noise loud: never picked
    p.write(0x9F);
    p.write(0xBF);
    try expectEqual(@as(?Tone, null), p.pick());
    // Periods 0-6 are silent, 7 is not.
    p.write(0xC6);
    p.write(0x00);
    p.write(0xD0);
    try expectEqual(@as(?Tone, null), p.pick());
    p.write(0xC7);
    try expectEqual(@as(?Tone, .{ .hz = 3579545 / (32 * 7), .level = 15 }), p.pick());
}

test "sound: pick_tone weighs FM against PSG, FM wins ties" {
    var y: Ym = .{};
    y.reset();
    var p: Psg = .{};
    p.reset();
    const pick = core.ym2612.pick_tone;
    try expectEqual(@as(?Tone, null), pick(&y, &p));
    // PSG alone.
    for ([_]u8{ 0x8C, 0x1F, 0x94 }) |b| p.write(b);
    try expectEqual(@as(?Tone, .{ .hz = 220, .level = 11 }), pick(&y, &p));
    // FM carrier TL 8 = level 12 beats PSG level 11 (the test ROM's mix).
    voice(&y, 0, 4, .{ 0x1C, 0x08, 0x7F, 0x7F }, 4, 1082);
    key(&y, 0, 0xF);
    try expectEqual(@as(?Tone, .{ .hz = 440, .level = 12 }), pick(&y, &p));
    // PSG louder (atten 0 = level 15).
    p.write(0x90);
    try expectEqual(@as(?Tone, .{ .hz = 220, .level = 15 }), pick(&y, &p));
    // A tie at 15 goes to FM (TL 0..2 map to 15).
    voice(&y, 0, 4, .{ 0x1C, 0x02, 0x7F, 0x7F }, 4, 1082);
    try expectEqual(@as(?Tone, .{ .hz = 440, .level = 15 }), pick(&y, &p));
    // FM keyed off: PSG again.
    key(&y, 0, 0);
    try expectEqual(@as(u16, 220), pick(&y, &p).?.hz);
}

// ---- End to end: the test ROM's Z80 driver ----

/// First bytes of tools/testrom/z80.s: di; im 1; ld sp,2000h; jp 0044h.
const driver_sig = [_]u8{ 0xF3, 0xED, 0x56, 0x31, 0x00, 0x20, 0xC3, 0x43, 0x00 };
/// tools/testrom/README.md: "copy the 264 driver bytes to A00000".
const driver_len = 267;

/// Run the shipped driver for `frames` frames of 262 lines x 228 cycles,
/// INT raised for line 224. `pulse`: INT drops as soon as the Z80 accepts
/// it (one interrupt per frame); otherwise INT is level-triggered for the
/// whole line, as SPEC.md section 9 and the hardware have it. Checks at
/// every frame end that the pick is A4 or E5 as the count of accepted
/// interrupts says (the driver toggles every 30), and returns the count.
fn run_driver(frames: u32, pulse: bool) !u32 {
    if (!std.mem.eql(u8, rom_data.name, "snouty-test.bin")) return error.SkipZigTest;
    const at = std.mem.indexOf(u8, rom_data.data, &driver_sig) orelse return error.TestUnexpectedResult;
    const driver = rom_data.data[at..][0..driver_len];
    try expectEqual(@as(u8, 0xFF), driver[driver_len - 1]); // ym_init terminator

    const data: [0x200]u8 = @splat(0);
    const md = try new_md(core.RomSource.from_slice(&data));
    defer std.testing.allocator.destroy(md);
    @memcpy(md.z80_ram[0..driver_len], driver);
    z80bus.reset_line(md);

    var zb = z80bus.Z80Bus.init(md);
    var carry: u32 = 0;
    var accepted: u32 = 0;
    var total: u64 = 0;
    var frame: u32 = 0;
    while (frame < frames) : (frame += 1) {
        var line: u32 = 0;
        while (line < 262) : (line += 1) {
            md.z80_int = line == 224;
            // z80bus.run, with the interrupt acceptances counted (the
            // driver never reaches 0038 other than through INT).
            const budget = 228 - @min(228, carry);
            var used: u32 = 0;
            while (used < budget) {
                zb.left = budget - used;
                used += md.z80.step(&zb);
                if (md.z80.pc == 0x38) {
                    accepted += 1;
                    if (pulse) md.z80_int = false;
                }
            }
            carry = carry + used - 228;
            total += used;
            md.ym.tick(if (line & 1 == 0) 488 else 489);
        }
        md.z80_int = false;
        const want: u16 = if ((accepted / 30) & 1 == 0) 440 else 659;
        const t = core.ym2612.pick_tone(&md.ym, &md.psg) orelse return error.TestUnexpectedResult;
        if (t.hz != want) {
            std.debug.print("frame {d}: {d} Hz, want {d} after {d} interrupts\n", .{ frame, t.hz, want, accepted });
            return error.TestUnexpectedResult;
        }
        try expectEqual(@as(u4, 12), t.level); // carrier TL 8
    }
    try expectEqual(@as(u8, @intCast(accepted % 30)), md.z80_ram[0x1F00]); // vcount
    try expectEqual(@as(u8, @intCast((accepted / 30) & 1)), md.z80_ram[0x1F01]); // note
    try expect(md.z80.halted);
    try expectEqual(@as(u2, 1), md.z80.im);
    // Time kept: 228 cycles per line on average.
    try expect(total >= @as(u64, frames) * 262 * 228 and total < @as(u64, frames) * 262 * 228 + 32);
    // The driver's init: algorithm 4, all four operators keyed, DAC off.
    try expectEqual(@as(u3, 4), md.ym.algorithm(0));
    try expectEqual(@as(u4, 0xF), md.ym.key_on[0]);
    try expect(!md.ym.dac_enabled());
    return accepted;
}

test "sound: the test ROM's Z80 driver, INT as a pulse: A4, E5 every 30 frames" {
    // One acceptance per frame: frames 0-28 play A4, 29-58 E5, ...
    try expectEqual(@as(u32, 200), try run_driver(200, true));
}

test "sound: the test ROM's Z80 driver, INT held for the line: still one acceptance per frame" {
    // The M0 driver's handler ended `ei; reti` about 70 cycles in, so a
    // line-long INT was taken three times per frame (Track D found it);
    // the fixed driver returns with interrupts disabled and waits out the
    // line before EI; HALT, so the frame loop's line-long INT (SPEC.md
    // section 9) is accepted exactly once.
    try expectEqual(@as(u32, 200), try run_driver(200, false));
}
