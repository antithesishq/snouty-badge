//! Memory map, Sega mapper and port decode (core/bus.zig). Runs against
//! whatever VDP is linked: port routing is checked through fields both the
//! M0 stub and the real VDP keep (`latch_pending`, `regs`).
const std = @import("std");
const core = @import("core");
const Gg = core.Gg;
const Pad = core.Pad;
const expectEqual = std.testing.expectEqual;

/// A ROM whose every byte names its bank and position: byte at offset o is
/// `bank * 16 + (o & 0x0F)` except the first byte of each 1 KB block, which
/// is `0xA0 | bank` (so the fixed first 1 KB is told apart from slot 0).
fn fill_rom(buf: []u8) void {
    for (buf, 0..) |*b, o| {
        const bank: u8 = @intCast(o / 0x4000);
        b.* = if (o % 0x400 == 0) 0xA0 | bank else bank *% 16 +% @as(u8, @intCast(o & 0x0F));
    }
}

var rom64: [0x10000]u8 = undefined;
var rom48: [0xC000]u8 = undefined;

fn console(buf: []u8) !*Gg {
    fill_rom(buf);
    const gg = try std.testing.allocator.create(Gg);
    gg.init_in_place(core.Rom.from_slice(buf));
    return gg;
}

test "bus: post-BIOS slots and the fixed first 1 KB" {
    const gg = try console(&rom64);
    defer std.testing.allocator.destroy(gg);
    var b = gg.bus_for();
    try expectEqual(@as(u8, 0xA0), b.read(0x0000));
    try expectEqual(@as(u8, 0xA1), b.read(0x4000));
    try expectEqual(@as(u8, 0xA2), b.read(0x8000));
    try expectEqual(@as(u8, 0x25), b.read(0xBFF5));

    // Slot 0 -> bank 3: 0000-03FF stays bank 0, 0400-3FFF follows.
    b.write(0xFFFD, 3);
    try expectEqual(@as(u8, 0xA0), b.read(0x0000));
    try expectEqual(@as(u8, 0x03), b.read(0x03F3));
    try expectEqual(@as(u8, 0xA3), b.read(0x0400));
    try expectEqual(@as(u8, 0x37), b.read(0x3FF7));
    // Slots 1 and 2.
    b.write(0xFFFE, 0);
    b.write(0xFFFF, 1);
    try expectEqual(@as(u8, 0xA0), b.read(0x4000));
    try expectEqual(@as(u8, 0xA1), b.read(0x8000));
}

test "bus: bank numbers wrap on a 64 KB ROM (mask)" {
    const gg = try console(&rom64);
    defer std.testing.allocator.destroy(gg);
    var b = gg.bus_for();
    b.write(0xFFFF, 6); // 6 & 3 = 2
    try expectEqual(@as(u8, 0xA2), b.read(0x8000));
    b.write(0xFFFE, 0x1F); // 3
    try expectEqual(@as(u8, 0xA3), b.read(0x4000));
    try expectEqual(@as(u8, 0x1F), gg.mapper.slot[1]);
    try expectEqual(@as(u8, 3), gg.mapper.bank[1]);
}

test "bus: bank numbers wrap on a 48 KB ROM (modulo), default slots need no mapper" {
    const gg = try console(&rom48);
    defer std.testing.allocator.destroy(gg);
    var b = gg.bus_for();
    try expectEqual(@as(u8, 0xA0), b.read(0x0000));
    try expectEqual(@as(u8, 0xA1), b.read(0x4000));
    try expectEqual(@as(u8, 0xA2), b.read(0x8000));
    b.write(0xFFFF, 3); // 3 % 3 = 0
    try expectEqual(@as(u8, 0xA0), b.read(0x8000));
    b.write(0xFFFF, 7); // 7 % 3 = 1
    try expectEqual(@as(u8, 0xA1), b.read(0x8000));
}

test "bus: 32 KB ROM, default slot 2 mirrors bank 0" {
    var rom32: [0x8000]u8 = undefined;
    const gg = try console(&rom32);
    defer std.testing.allocator.destroy(gg);
    var b = gg.bus_for();
    try expectEqual(@as(u8, 0xA0), b.read(0x8000));
    try expectEqual(@as(u8, 0), gg.mapper.bank[2]);
}

test "bus: cart RAM enable, disable and mirror" {
    const gg = try console(&rom64);
    defer std.testing.allocator.destroy(gg);
    var b = gg.bus_for();
    // Disabled: slot 2 writes are ROM writes, dropped.
    b.write(0x8000, 0x55);
    try expectEqual(@as(u8, 0xA2), b.read(0x8000));
    try expectEqual(@as(u8, 0), gg.cart_ram[0]);

    b.write(0xFFFC, 0x08);
    try expectEqual(@as(u8, 0), b.read(0x8000));
    b.write(0x8000, 0x55);
    b.write(0x9FFF, 0x66);
    try expectEqual(@as(u8, 0x55), b.read(0x8000));
    try expectEqual(@as(u8, 0x55), gg.cart_ram[0]);
    // 8 KB mirrored in the 16 KB slot.
    try expectEqual(@as(u8, 0x55), b.read(0xA000));
    try expectEqual(@as(u8, 0x66), b.read(0xBFFF));
    b.write(0xA001, 0x77);
    try expectEqual(@as(u8, 0x77), gg.cart_ram[1]);
    // Bit 2 (16 KB RAM bank) is ignored.
    b.write(0xFFFC, 0x0C);
    try expectEqual(@as(u8, 0x55), b.read(0x8000));

    // Disabled again: ROM is back, cart RAM kept.
    b.write(0xFFFC, 0x00);
    try expectEqual(@as(u8, 0xA2), b.read(0x8000));
    try expectEqual(@as(u8, 0x55), gg.cart_ram[0]);
    // Slots 0/1 never see cart RAM.
    b.write(0xFFFC, 0x08);
    try expectEqual(@as(u8, 0xA1), b.read(0x4000));
}

test "bus: RAM and its E000 mirror" {
    const gg = try console(&rom64);
    defer std.testing.allocator.destroy(gg);
    var b = gg.bus_for();
    b.write(0xC123, 0x42);
    try expectEqual(@as(u8, 0x42), b.read(0xE123));
    b.write(0xFFF0, 0x99);
    try expectEqual(@as(u8, 0x99), b.read(0xDFF0));
    try expectEqual(@as(u8, 0x99), gg.ram[0x1FF0]);
}

test "bus: mapper registers read back as RAM" {
    const gg = try console(&rom64);
    defer std.testing.allocator.destroy(gg);
    var b = gg.bus_for();
    b.write(0xFFFC, 0x08);
    b.write(0xFFFD, 0x01);
    b.write(0xFFFE, 0x02);
    b.write(0xFFFF, 0x13);
    try expectEqual(@as(u8, 0x08), b.read(0xFFFC));
    try expectEqual(@as(u8, 0x01), b.read(0xDFFD));
    try expectEqual(@as(u8, 0x02), b.read(0xFFFE));
    try expectEqual(@as(u8, 0x13), b.read(0xFFFF));
    try expectEqual(@as(u8, 0x08), gg.mapper.control);
    try expectEqual([3]u8{ 1, 2, 0x13 }, gg.mapper.slot);
    // Writing the DFFC-DFFF copy does not touch the mapper.
    b.write(0xDFFF, 0x00);
    try expectEqual(@as(u8, 0x13), gg.mapper.slot[2]);
    b.write(0xFFFC, 0x00);
    try expectEqual(@as(u8, 0xA3), b.read(0x8000)); // 0x13 & 3
}

test "bus: pad bits on port DC and Start on port 00" {
    const gg = try console(&rom64);
    defer std.testing.allocator.destroy(gg);
    var b = gg.bus_for();
    gg.pad = 0;
    try expectEqual(@as(u8, 0xFF), b.in(0xDC));
    try expectEqual(@as(u8, 0xC0), b.in(0x00));
    const cases = [_]struct { pad: u8, dc: u8 }{
        .{ .pad = Pad.up, .dc = 0xFE },
        .{ .pad = Pad.down, .dc = 0xFD },
        .{ .pad = Pad.left, .dc = 0xFB },
        .{ .pad = Pad.right, .dc = 0xF7 },
        .{ .pad = Pad.b1, .dc = 0xEF },
        .{ .pad = Pad.b2, .dc = 0xDF },
        .{ .pad = Pad.start, .dc = 0xFF },
        .{ .pad = Pad.up | Pad.b1 | Pad.start, .dc = 0xEE },
    };
    for (cases) |c| {
        gg.pad = c.pad;
        try expectEqual(c.dc, b.in(0xDC));
        try expectEqual(c.dc, b.in(0xC0));
        const p00: u8 = if (c.pad & Pad.start != 0) 0x40 else 0xC0;
        try expectEqual(p00, b.in(0x00));
        // Second pad port: nothing connected.
        try expectEqual(@as(u8, 0xFF), b.in(0xDD));
        try expectEqual(@as(u8, 0xFF), b.in(0xC1));
    }
}

test "bus: link, stereo and memory/I/O control ports" {
    const gg = try console(&rom64);
    defer std.testing.allocator.destroy(gg);
    var b = gg.bus_for();
    try expectEqual(@as(u8, 0x7F), b.in(0x01));
    try expectEqual(@as(u8, 0xFF), b.in(0x02));
    try expectEqual(@as(u8, 0x00), b.in(0x03));
    try expectEqual(@as(u8, 0xFF), b.in(0x04));
    try expectEqual(@as(u8, 0x00), b.in(0x05));
    b.out(0x03, 0x12); // link writes dropped
    try expectEqual(@as(u8, 0x00), b.in(0x03));
    b.out(0x06, 0x5A);
    try expectEqual(@as(u8, 0x5A), gg.psg.stereo);
    try expectEqual(@as(u8, 0x5A), b.in(0x06));
    b.out(0x3E, 0xA8);
    b.out(0x3F, 0xF5);
    try expectEqual(@as(u8, 0xA8), gg.mem_control);
    try expectEqual(@as(u8, 0xF5), gg.io_control);
    b.out(0x08, 0x11); // even mirror of 3E
    b.out(0x07, 0x22); // odd mirror of 3F
    try expectEqual(@as(u8, 0x11), gg.mem_control);
    try expectEqual(@as(u8, 0x22), gg.io_control);
    try expectEqual(@as(u8, 0xFF), b.in(0x3E));
    try expectEqual(@as(u8, 0xFF), b.in(0x3F));
}

test "bus: ports 40-7F write the PSG" {
    const gg = try console(&rom64);
    defer std.testing.allocator.destroy(gg);
    var b = gg.bus_for();
    b.out(0x7F, 0x9A); // ch0 attenuation 10
    try expectEqual(@as(u8, 10), gg.psg.atten[0]);
    b.out(0x40, 0xF3); // mirror: ch3 attenuation 3
    try expectEqual(@as(u8, 3), gg.psg.atten[3]);
    b.out(0x7E, 0xC5); // ch2 tone low 5
    b.out(0x41, 0x12); // data: high bits
    try expectEqual(@as(u16, 0x125), gg.psg.tone[2]);
}

test "bus: ports 40-7F read the V and H counters" {
    const gg = try console(&rom64);
    defer std.testing.allocator.destroy(gg);
    var b = gg.bus_for();
    try expectEqual(gg.vdp.v_counter(), b.in(0x7E));
    try expectEqual(gg.vdp.h_counter(), b.in(0x7F));
    try expectEqual(gg.vdp.v_counter(), b.in(0x40));
    try expectEqual(gg.vdp.h_counter(), b.in(0x41));
}

test "bus: ports 80-BF reach the VDP control and data ports" {
    const gg = try console(&rom64);
    defer std.testing.allocator.destroy(gg);
    var b = gg.bus_for();
    // Register write through BF: value then 0x80 | register.
    b.out(0xBF, 0x05);
    b.out(0xBF, 0x87);
    b.out(0x81, 0x00); // odd mirror of BF: first byte of a new command
    const stub = gg.vdp.regs[7] != 0x05;
    if (!stub) {
        // Real VDP (Track B): the register landed, a first byte is latched.
        try expectEqual(@as(u8, 0x05), gg.vdp.regs[7]);
        try std.testing.expect(gg.vdp.latch_pending);
    }
    // Status read (odd port) clears the latch, on the stub and the real VDP.
    gg.vdp.latch_pending = true;
    _ = b.in(0xBF);
    try std.testing.expect(!gg.vdp.latch_pending);
    gg.vdp.latch_pending = true;
    _ = b.in(0x81);
    try std.testing.expect(!gg.vdp.latch_pending);
    // Data read (even port) clears it too.
    gg.vdp.latch_pending = true;
    _ = b.in(0xBE);
    try std.testing.expect(!gg.vdp.latch_pending);
    gg.vdp.latch_pending = true;
    b.out(0x80, 0x00);
    try std.testing.expect(!gg.vdp.latch_pending);
}

const Capture = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,

    fn on_byte(ctx: *anyopaque, v: u8) void {
        const c: *Capture = @ptrCast(@alignCast(ctx));
        c.buf[c.len] = v;
        c.len += 1;
    }
};

test "bus: SDSC console capture on port FD" {
    const gg = try console(&rom64);
    defer std.testing.allocator.destroy(gg);
    var b = gg.bus_for();
    b.out(0xFD, 'x'); // no sink: dropped
    var cap: Capture = .{};
    gg.console_sink = .{ .ctx = &cap, .func = &Capture.on_byte };
    b.out(0xFC, 0x01); // control port: dropped
    for ("OK\n") |ch| b.out(0xFD, ch);
    b.out(0xDC, 'y'); // other C0-FF writes: dropped
    try std.testing.expectEqualStrings("OK\n", cap.buf[0..cap.len]);
    // reset keeps the sink.
    gg.reset();
    b.out(0xFD, '!');
    try std.testing.expectEqualStrings("OK\n!", cap.buf[0..cap.len]);
}

test "bus: unlisted ports read FF" {
    const gg = try console(&rom64);
    defer std.testing.allocator.destroy(gg);
    var b = gg.bus_for();
    gg.pad = 0x7F;
    for ([_]u8{ 0x07, 0x10, 0x3D, 0xC2, 0xDB, 0xDE, 0xF0, 0xFC, 0xFD, 0xFF }) |p|
        try expectEqual(@as(u8, 0xFF), b.in(p));
}
