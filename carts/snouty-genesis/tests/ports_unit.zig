//! Multiplayer peripherals (core/ports.zig, docs/MULTIPLAYER.md) at the bus:
//! each test does what a game's pad driver does, the documented read
//! sequence through the 68000's I/O addresses, and checks the nibbles, IDs
//! and pad lines against the pads given to the console. Synthetic ROMs
//! (bra.s * at the reset vector), so nothing else touches the ports.
//! Mega Bomberman (a real Team Player game, local only) is in
//! tests/mp_bomberman.zig.
const std = @import("std");
const core = @import("core");
const Md = core.Md;
const Pad = core.Pad;
const ports = core.ports;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const data1: u24 = 0xA10003;
const data2: u24 = 0xA10005;
const ctrl1: u24 = 0xA10009;
const ctrl2: u24 = 0xA1000B;

/// SSP FFFE00, PC 000200, "SEGA GENESIS" at 0x100, `bra.s *` at 0x200;
/// `serial` at 0x180, `devices` at 0x190.
fn make_rom(buf: []u8, serial: []const u8, devices: []const u8) void {
    @memset(buf, 0);
    std.mem.writeInt(u32, buf[0..4], 0x00FFFE00, .big);
    std.mem.writeInt(u32, buf[4..8], 0x00000200, .big);
    @memcpy(buf[0x100..][0..16], "SEGA GENESIS    ");
    @memset(buf[0x180..0x1A0], ' ');
    @memcpy(buf[0x180..][0..serial.len], serial);
    @memcpy(buf[0x190..][0..devices.len], devices);
    buf[0x200] = 0x60;
    buf[0x201] = 0xFE;
}

var rom_buf: [0x400]u8 = undefined;

fn new_md(kind: ports.Kind) !*Md {
    make_rom(&rom_buf, "GM 00000000-00", "J");
    const md = try std.testing.allocator.create(Md);
    md.init_in_place(core.RomSource.from_slice(&rom_buf));
    md.setup.cfg = .{ .kind = kind };
    md.reset();
    return md;
}

/// Hold `pads` for a frame (the program only loops, so the ports keep
/// whatever the test wrote).
fn hold(md: *Md, pads: []const u16) void {
    var p: core.Pads = @splat(0);
    @memcpy(p[0..pads.len], pads);
    md.step_frame_pads(&p, false);
}

// ---- Plain pads ----

test "ports: default is one pad on port 1, port 2 empty (as before)" {
    const md = try new_md(.pad1);
    defer std.testing.allocator.destroy(md);
    try expectEqual(ports.Kind.pad1, md.setup.cfg.kind);
    hold(md, &.{ Pad.up | Pad.b, Pad.left | Pad.start });
    var b = md.bus_for();
    b.write8(ctrl1, 0x40);
    b.write8(ctrl2, 0x40);
    b.write8(data1, 0x40);
    b.write8(data2, 0x40);
    try expectEqual(@as(u8, 0x40 | 0x2E), b.read8(data1));
    try expectEqual(@as(u8, 0x7F), b.read8(data2));
    b.write8(data2, 0x00);
    try expectEqual(@as(u8, 0x3F), b.read8(data2));
}

test "ports: two pads, pad 2 on port 2 in both TH states" {
    const md = try new_md(.pads2);
    defer std.testing.allocator.destroy(md);
    hold(md, &.{ Pad.right, Pad.down | Pad.a | Pad.c });
    var b = md.bus_for();
    b.write8(ctrl2, 0x40);
    b.write8(data2, 0x40);
    try expectEqual(ports.pad_lines(Pad.down | Pad.a | Pad.c, true), b.read8(data2));
    b.write8(data2, 0x00);
    try expectEqual(ports.pad_lines(Pad.down | Pad.a | Pad.c, false), b.read8(data2));
    b.write8(ctrl1, 0x40);
    b.write8(data1, 0x40);
    try expectEqual(ports.pad_lines(Pad.right, true), b.read8(data1));
}

// ---- Team Player ----

/// What a Team Player driver reads from the tap at `data` (Street
/// Racer's, as r57shell commented it, and Plutiedev's): the two ID reads,
/// then a TR toggle per nibble waiting for TL to follow. Returns the four
/// slot types and each slot's pad word (`Pad` bits, 0 when absent).
const TapRead = struct { ids: [4]u4, pads: [4]u16 };

fn read_tap(md: *Md, data: u24, ctrl: u24) !TapRead {
    var b = md.bus_for();
    b.write8(ctrl, 0x60);
    b.write8(data, 0x60);
    try expectEqual(@as(u8, 0x3), b.read8(data) & 0xF);
    b.write8(data, 0x20);
    try expectEqual(@as(u8, 0xF), b.read8(data) & 0xF);
    var tr: u8 = 0x20;
    const S = struct {
        fn nibble(bb: *core.bus.Bus, d: u24, t: *u8) !u4 {
            t.* ^= 0x20;
            bb.write8(d, t.*);
            const v = bb.read8(d);
            // TL (bit 4) follows TR (bit 5): the acknowledge.
            try expectEqual(t.* >> 1, v & 0x10);
            return @truncate(v);
        }
    };
    try expectEqual(@as(u4, 0), try S.nibble(&b, data, &tr));
    try expectEqual(@as(u4, 0), try S.nibble(&b, data, &tr));
    var out: TapRead = .{ .ids = undefined, .pads = @splat(0) };
    for (&out.ids) |*id| id.* = try S.nibble(&b, data, &tr);
    for (out.ids, &out.pads) |id, *pad| {
        if (id == 0xF) continue;
        const rldu = ~try S.nibble(&b, data, &tr);
        const sacb = ~try S.nibble(&b, data, &tr);
        var p: u16 = rldu;
        if (sacb & 1 != 0) p |= Pad.b;
        if (sacb & 2 != 0) p |= Pad.c;
        if (sacb & 4 != 0) p |= Pad.a;
        if (sacb & 8 != 0) p |= Pad.start;
        if (id == 1) {
            const mxyz = ~try S.nibble(&b, data, &tr);
            if (mxyz & 1 != 0) p |= Pad.z;
            if (mxyz & 2 != 0) p |= Pad.y;
            if (mxyz & 4 != 0) p |= Pad.x;
            if (mxyz & 8 != 0) p |= Pad.mode;
        } else try expect(id == 0);
        pad.* = p;
    }
    // Past the last nibble: F. TH high ends the transfer.
    try expectEqual(@as(u4, 0xF), try S.nibble(&b, data, &tr));
    b.write8(data, 0x60);
    try expectEqual(@as(u8, 0x3), b.read8(data) & 0xF);
    return out;
}

test "ports: Team Player on port 1, four 3-button pads, buttons through the nibbles" {
    const md = try new_md(.tap1);
    defer std.testing.allocator.destroy(md);
    const want = [_]u16{ Pad.up | Pad.a, Pad.down | Pad.right | Pad.b | Pad.start, 0, Pad.left | Pad.c | Pad.a | Pad.b | Pad.start };
    hold(md, &want);
    const r = try read_tap(md, data1, ctrl1);
    try expectEqual([4]u4{ 0, 0, 0, 0 }, r.ids);
    try expectEqual(want, r.pads);
    // Twice in a row: the transfer starts over at TH high.
    try expectEqual(want, (try read_tap(md, data1, ctrl1)).pads);
}

test "ports: Team Player slot types: a 6-button pad and an empty slot" {
    const md = try new_md(.tap1);
    defer std.testing.allocator.destroy(md);
    md.setup.cfg.six = 0b0010;
    md.setup.cfg.absent = 0b0100;
    const want = [_]u16{ Pad.right, Pad.up | Pad.x | Pad.mode | Pad.c, Pad.start, Pad.down | Pad.z | Pad.y };
    hold(md, &want);
    const r = try read_tap(md, data1, ctrl1);
    try expectEqual([4]u4{ 0, 1, 0xF, 0 }, r.ids);
    // Slot 3 is absent; slot 4 is a 3-button pad, so its X Y Z do not show.
    try expectEqual([4]u16{ Pad.right, Pad.up | Pad.x | Pad.mode | Pad.c, 0, Pad.down }, r.pads);
}

test "ports: Team Player on port 2 holds pads 2-5, a plain pad 1 on port 1" {
    const md = try new_md(.tap2);
    defer std.testing.allocator.destroy(md);
    const want = [_]u16{ Pad.b, Pad.left, Pad.right | Pad.a, Pad.up, Pad.down | Pad.start };
    hold(md, &want);
    const r = try read_tap(md, data2, ctrl2);
    try expectEqual([4]u16{ want[1], want[2], want[3], want[4] }, r.pads);
    var b = md.bus_for();
    b.write8(ctrl1, 0x40);
    b.write8(data1, 0x40);
    try expectEqual(ports.pad_lines(Pad.b, true), b.read8(data1));
}

test "ports: Team Players on both ports, eight pads" {
    const md = try new_md(.taps);
    defer std.testing.allocator.destroy(md);
    var want: [8]u16 = undefined;
    for (&want, 0..) |*p, i| p.* = @as(u16, 1) << @intCast(i);
    hold(md, &want);
    try expectEqual([4]u16{ want[0], want[1], want[2], want[3] }, (try read_tap(md, data1, ctrl1)).pads);
    try expectEqual([4]u16{ want[4], want[5], want[6], want[7] }, (try read_tap(md, data2, ctrl2)).pads);
}

test "ports: Team Player on port 1 and a plain pad 5 on port 2" {
    const md = try new_md(.tap1);
    defer std.testing.allocator.destroy(md);
    hold(md, &.{ 0, 0, 0, 0, Pad.c | Pad.up });
    var b = md.bus_for();
    b.write8(ctrl2, 0x40);
    b.write8(data2, 0x40);
    try expectEqual(ports.pad_lines(Pad.c | Pad.up, true), b.read8(data2));
}

test "ports: Team Player state survives a keyframe round trip mid-transfer" {
    const md = try new_md(.tap1);
    defer std.testing.allocator.destroy(md);
    hold(md, &.{ Pad.up, Pad.down, Pad.left, Pad.right });
    var b = md.bus_for();
    b.write8(ctrl1, 0x60);
    b.write8(data1, 0x60);
    b.write8(data1, 0x20);
    b.write8(data1, 0x00);
    b.write8(data1, 0x20);
    b.write8(data1, 0x00); // slot A's ID next
    const kf = try std.testing.allocator.create(Md.Keyframe);
    defer std.testing.allocator.destroy(kf);
    md.snapshot(kf);
    const h = md.state_hash();
    b.write8(data1, 0x20);
    md.restore(kf);
    try expectEqual(h, md.state_hash());
    try expectEqual(@as(u8, 3), md.ports.step[0]);
}

// ---- EA 4 Way Play ----

test "ports: 4 Way Play detection as Plutiedev and Street Racer do it" {
    const md = try new_md(.ea4way);
    defer std.testing.allocator.destroy(md);
    hold(md, &.{ 0, 0, 0, 0 });
    var b = md.bus_for();
    // Plutiedev: $0C then $7C on port 2, bits 1-0 of port 1.
    b.write8(ctrl1, 0x40);
    b.write8(ctrl2, 0x7F);
    b.write8(data1, 0x40);
    b.write8(data2, 0x0C);
    try expect(b.read8(data1) & 3 != 0);
    b.write8(data2, 0x7C);
    try expectEqual(@as(u8, 0), b.read8(data1) & 3);
    // Street Racer: control 43, data 7C, control 7F, data 7C.
    b.write8(ctrl2, 0x43);
    b.write8(data2, 0x7C);
    b.write8(ctrl2, 0x7F);
    b.write8(data2, 0x7C);
    try expectEqual(@as(u8, 0), b.read8(data1) & 3);
    // Without the adapter (one pad) the same reads say no.
    const plain = try new_md(.pad1);
    defer std.testing.allocator.destroy(plain);
    hold(plain, &.{0});
    var c = plain.bus_for();
    c.write8(ctrl1, 0x40);
    c.write8(ctrl2, 0x7F);
    c.write8(data1, 0x40);
    c.write8(data2, 0x7C);
    try expect(c.read8(data1) & 3 != 0);
}

test "ports: 4 Way Play pads 1-4 through the port 2 select, both TH states" {
    const md = try new_md(.ea4way);
    defer std.testing.allocator.destroy(md);
    const want = [_]u16{ Pad.up | Pad.start, Pad.b | Pad.right, Pad.a | Pad.c | Pad.down, Pad.left };
    hold(md, &want);
    var b = md.bus_for();
    b.write8(ctrl1, 0x40);
    b.write8(ctrl2, 0x7F);
    for (want, 0..) |p, i| {
        b.write8(data2, @as(u8, @intCast(i)) << 4 | 0x0C);
        b.write8(data1, 0x40);
        try expectEqual(ports.pad_lines(p, true), b.read8(data1));
        b.write8(data1, 0x00);
        try expectEqual(ports.pad_lines(p, false), b.read8(data1));
    }
    // An absent pad reads as an empty port.
    md.setup.cfg.absent = 0b1000;
    b.write8(data2, 0x3C);
    b.write8(data1, 0x40);
    try expectEqual(@as(u8, 0x7F), b.read8(data1));
}

// ---- J-Cart ----

test "ports: J-Cart pads 3 and 4 at 38FFFE, TH by write, the ports keep pads 1-2" {
    const md = try new_md(.jcart);
    defer std.testing.allocator.destroy(md);
    const want = [_]u16{ Pad.up, Pad.down, Pad.left | Pad.b | Pad.start, Pad.right | Pad.c | Pad.a };
    hold(md, &want);
    var b = md.bus_for();
    b.write16(0x38FFFE, 0x0001);
    try expectEqual(@as(u16, ports.pad_lines(want[3], true)) << 8 | ports.pad_lines(want[2], true), b.read16(0x38FFFE));
    try expectEqual(ports.pad_lines(want[3], true), b.read8(0x38FFFE));
    try expectEqual(ports.pad_lines(want[2], true), b.read8(0x38FFFF));
    b.write8(0x38FFFF, 0x00);
    try expectEqual(@as(u16, ports.pad_lines(want[3], false)) << 8 | ports.pad_lines(want[2], false), b.read16(0x38FFFE));
    // New pads show at the next frame, with TH as last written.
    hold(md, &.{ 0, 0, Pad.a, 0 });
    try expectEqual(@as(u16, ports.pad_lines(0, false)) << 8 | ports.pad_lines(Pad.a, false), b.read16(0x38FFFE));
    // The SRAM control register does not unmap it.
    b.write8(0xA130F1, 0);
    try expectEqual(ports.pad_lines(Pad.a, false), b.read8(0x38FFFF));
    // Pads 1 and 2 on the ports.
    b.write8(ctrl2, 0x40);
    b.write8(data2, 0x40);
    try expectEqual(ports.pad_lines(0, true), b.read8(data2));
    // Without a J-Cart the address is ROM (open bus past this ROM's end).
    const plain = try new_md(.pad1);
    defer std.testing.allocator.destroy(plain);
    var c = plain.bus_for();
    try expectEqual(@as(u16, 0xFFFF), c.read16(0x38FFFE));
}

// ---- Choosing the peripheral ----

fn detect_for(serial: []const u8, checksum: u16, devices: []const u8) ports.Config {
    make_rom(&rom_buf, serial, devices);
    std.mem.writeInt(u16, rom_buf[0x18E..][0..2], checksum, .big);
    const src = core.RomSource.from_slice(&rom_buf);
    return ports.detect(&src);
}

test "ports: detect from the header serial, checksum for placeholder serials, '4' fallback" {
    try expectEqual(ports.Kind.tap1, detect_for("GM MK-1573-00 ", 0x29F3, "J4").kind);
    try expectEqual(ports.Kind.tap1, detect_for("GM T-48123 -00", 0x1111, "J").kind);
    try expectEqual(ports.Kind.ea4way, detect_for("GM T-50656 -00", 0x5512, "J").kind);
    try expectEqual(ports.Kind.jcart, detect_for("GM T-120096-50", 0xEF29, "J").kind);
    // A placeholder serial needs its checksum.
    try expectEqual(ports.Kind.jcart, detect_for("GM XXXXXXXX-XX", 0xDF39, "J").kind);
    try expectEqual(ports.Kind.pad1, detect_for("GM XXXXXXXX-XX", 0xDF3A, "J").kind);
    try expectEqual(ports.Kind.ea4way, detect_for("GM T-      -00", 0xC5F1, "J64").kind);
    // Unknown serial: '4' in the device field means a Team Player.
    try expectEqual(ports.Kind.tap1, detect_for("GM HOMEBREW-00", 0, "J46").kind);
    try expectEqual(ports.Kind.pad1, detect_for("GM HOMEBREW-00", 0, "J6").kind);
    // The shipped ROMs keep the one-pad default.
    try expectEqual(ports.Kind.pad1, detect_for("GM SNOUTY01-00", 0x00B2, "J").kind);
    try expectEqual(ports.Kind.pad1, detect_for("GM SIK-MINI-04", 0x5873, "J").kind);
}

test "ports: init_in_place picks the peripheral, reset keeps a frontend override" {
    make_rom(&rom_buf, "GM MK-1573-00 ", "J4");
    const md = try std.testing.allocator.create(Md);
    defer std.testing.allocator.destroy(md);
    md.init_in_place(core.RomSource.from_slice(&rom_buf));
    try expectEqual(ports.Kind.tap1, md.setup.cfg.kind);
    md.setup.cfg = .{ .kind = .ea4way };
    md.reset();
    try expectEqual(ports.Kind.ea4way, md.setup.cfg.kind);
}

// ---- Lockstep: rendering leaves the state alone ----

test "ports: lockstep keeps the renderer's sprite collision bit out of the state" {
    const S = struct {
        fn sink(_: *anyopaque, _: u8, _: [*]const u8, _: u16, _: *const [64]u16) void {}
    };
    var dummy: u8 = 0;
    for ([_]bool{ false, true }) |lockstep| {
        const md = try new_md(.pad1);
        defer std.testing.allocator.destroy(md);
        md.line_sink = .{ .ctx = &dummy, .func = &S.sink };
        md.setup.lockstep = lockstep;
        // Display on, H40, sprite table at C000; two opaque 8x8 sprites at
        // the same place (tile 1, all pixels colour 1).
        md.vdp.regs[1] = 0x44;
        md.vdp.regs[12] = 0x81;
        md.vdp.regs[5] = 0x60;
        @memset(md.vdp.vram[32..64], 0x11);
        const sat: usize = 0xC000;
        for (0..2) |i| {
            const e = md.vdp.vram[sat + i * 8 ..][0..8];
            std.mem.writeInt(u16, e[0..2], 128 + 40, .big);
            std.mem.writeInt(u16, e[2..4], if (i == 0) 1 else 0, .big);
            std.mem.writeInt(u16, e[4..6], 1, .big);
            std.mem.writeInt(u16, e[6..8], 128 + 60, .big);
        }
        md.vdp.spr_dirty = true;
        md.step_frame(0, true);
        const collided = md.vdp.status & 0x20 != 0;
        try expectEqual(!lockstep, collided);
    }
}
