//! Z80 behaviour the SingleStepTests do not reach (they never raise an
//! interrupt): interrupt acceptance in IM 0/1/2, HALT, the EI delay, reset.
const std = @import("std");
const core = @import("core");
const expectEqual = std.testing.expectEqual;

const Bus = struct {
    mem: [0x10000]u8 = @splat(0),
    irq: bool = false,

    pub fn read(self: *Bus, addr: u16) u8 {
        return self.mem[addr];
    }
    pub fn write(self: *Bus, addr: u16, v: u8) void {
        self.mem[addr] = v;
    }
    pub fn in(self: *Bus, port: u8) u8 {
        _ = self;
        _ = port;
        return 0xFF;
    }
    pub fn out(self: *Bus, port: u8, v: u8) void {
        _ = self;
        _ = port;
        _ = v;
    }
    pub fn irq_line(self: *Bus) bool {
        return self.irq;
    }
};

const Cpu = core.z80.Z80(Bus);

fn setup(code: []const u8) !struct { *Bus, Cpu } {
    const bus = try std.testing.allocator.create(Bus);
    bus.* = .{};
    @memcpy(bus.mem[0x100..][0..code.len], code);
    var cpu: Cpu = .{};
    cpu.reset();
    cpu.pc = 0x100;
    return .{ bus, cpu };
}

test "z80: reset gives the post-BIOS state" {
    var cpu: Cpu = .{ .pc = 0x1234, .sp = 0, .a = 0, .im = 2, .iff1 = true };
    cpu.reset();
    try expectEqual(@as(u16, 0), cpu.pc);
    try expectEqual(@as(u16, 0xDFF0), cpu.sp);
    try expectEqual(@as(u8, 0xFF), cpu.a);
    try expectEqual(@as(u8, 0xFF), cpu.f);
    try expectEqual(@as(u2, 1), cpu.im);
    try std.testing.expect(!cpu.iff1 and !cpu.iff2 and !cpu.halted);
}

test "z80: IM 1 acceptance pushes PC, jumps to 38h, 13 T" {
    const bus, var cpu = try setup(&.{ 0x00, 0x00 });
    defer std.testing.allocator.destroy(bus);
    cpu.iff1 = true;
    cpu.iff2 = true;
    cpu.sp = 0xD000;
    cpu.r = 0x7F;
    bus.irq = true;
    try expectEqual(@as(u32, 13), cpu.step(bus));
    try expectEqual(@as(u16, 0x38), cpu.pc);
    try expectEqual(@as(u16, 0xCFFE), cpu.sp);
    try expectEqual(@as(u8, 0x00), bus.mem[0xCFFE]);
    try expectEqual(@as(u8, 0x01), bus.mem[0xCFFF]);
    try std.testing.expect(!cpu.iff1 and !cpu.iff2);
    // R's low 7 bits wrap, bit 7 is kept.
    try expectEqual(@as(u8, 0x00), cpu.r);
    // IFF1 off: the line is ignored.
    try expectEqual(@as(u32, 4), cpu.step(bus));
    try expectEqual(@as(u16, 0x39), cpu.pc);
}

test "z80: IM 0 acts as RST 38h" {
    const bus, var cpu = try setup(&.{0x00});
    defer std.testing.allocator.destroy(bus);
    cpu.im = 0;
    cpu.iff1 = true;
    bus.irq = true;
    try expectEqual(@as(u32, 13), cpu.step(bus));
    try expectEqual(@as(u16, 0x38), cpu.pc);
}

test "z80: IM 2 reads the vector at I:FF, 19 T" {
    const bus, var cpu = try setup(&.{0x00});
    defer std.testing.allocator.destroy(bus);
    cpu.im = 2;
    cpu.i = 0x80;
    cpu.iff1 = true;
    cpu.sp = 0xD000;
    bus.mem[0x80FF] = 0x34;
    bus.mem[0x8100] = 0x12;
    bus.irq = true;
    try expectEqual(@as(u32, 19), cpu.step(bus));
    try expectEqual(@as(u16, 0x1234), cpu.pc);
    try expectEqual(@as(u16, 0x1234), cpu.wz);
    try expectEqual(@as(u8, 0x01), bus.mem[0xCFFF]);
}

test "z80: HALT holds PC at 4 T per step until an interrupt" {
    // HALT at 0x100, NOP after it.
    const bus, var cpu = try setup(&.{ 0x76, 0x00 });
    defer std.testing.allocator.destroy(bus);
    cpu.iff1 = true;
    cpu.sp = 0xD000;
    try expectEqual(@as(u32, 4), cpu.step(bus));
    try std.testing.expect(cpu.halted);
    const r0 = cpu.r;
    var n: u32 = 0;
    while (n < 10) : (n += 1) try expectEqual(@as(u32, 4), cpu.step(bus));
    try expectEqual(@as(u16, 0x101), cpu.pc);
    try expectEqual(r0 +% 10, cpu.r);
    bus.irq = true;
    try expectEqual(@as(u32, 13), cpu.step(bus));
    try std.testing.expect(!cpu.halted);
    try expectEqual(@as(u16, 0x38), cpu.pc);
    // The return address is the instruction after HALT.
    try expectEqual(@as(u8, 0x01), bus.mem[0xCFFE]);
    try expectEqual(@as(u8, 0x01), bus.mem[0xCFFF]);
}

test "z80: HALT with interrupts off stays halted" {
    const bus, var cpu = try setup(&.{0x76});
    defer std.testing.allocator.destroy(bus);
    bus.irq = true;
    _ = cpu.step(bus);
    var n: u32 = 0;
    while (n < 5) : (n += 1) try expectEqual(@as(u32, 4), cpu.step(bus));
    try std.testing.expect(cpu.halted);
    try expectEqual(@as(u16, 0x101), cpu.pc);
}

test "z80: EI delays acceptance by one instruction" {
    // EI, NOP, NOP
    const bus, var cpu = try setup(&.{ 0xFB, 0x00, 0x00 });
    defer std.testing.allocator.destroy(bus);
    bus.irq = true;
    try expectEqual(@as(u32, 4), cpu.step(bus)); // EI
    try expectEqual(@as(u32, 4), cpu.step(bus)); // NOP runs despite the line
    try expectEqual(@as(u16, 0x102), cpu.pc);
    try expectEqual(@as(u32, 13), cpu.step(bus)); // accepted after it
    try expectEqual(@as(u16, 0x38), cpu.pc);
}

test "z80: EI EI keeps delaying" {
    const bus, var cpu = try setup(&.{ 0xFB, 0xFB, 0xFB, 0x00 });
    defer std.testing.allocator.destroy(bus);
    bus.irq = true;
    _ = cpu.step(bus);
    _ = cpu.step(bus);
    _ = cpu.step(bus);
    try expectEqual(@as(u16, 0x103), cpu.pc);
    try expectEqual(@as(u32, 4), cpu.step(bus)); // NOP after the last EI
    try expectEqual(@as(u32, 13), cpu.step(bus));
}

test "z80: EI then DI accepts nothing" {
    const bus, var cpu = try setup(&.{ 0xFB, 0xF3, 0x00 });
    defer std.testing.allocator.destroy(bus);
    bus.irq = true;
    _ = cpu.step(bus);
    _ = cpu.step(bus);
    try expectEqual(@as(u32, 4), cpu.step(bus));
    try expectEqual(@as(u16, 0x103), cpu.pc);
}

test "z80: RETN/RETI copy IFF2 to IFF1" {
    const bus, var cpu = try setup(&.{ 0xED, 0x4D });
    defer std.testing.allocator.destroy(bus);
    cpu.sp = 0xC000;
    bus.mem[0xC000] = 0x00;
    bus.mem[0xC001] = 0x02;
    cpu.iff2 = true;
    try expectEqual(@as(u32, 14), cpu.step(bus));
    try std.testing.expect(cpu.iff1);
    try expectEqual(@as(u16, 0x200), cpu.pc);
}

test "z80: LDIR repeats at 21 T and ends at 16 T" {
    // LDIR copying 3 bytes from 0x200 to 0x300.
    const bus, var cpu = try setup(&.{ 0xED, 0xB0 });
    defer std.testing.allocator.destroy(bus);
    bus.mem[0x200] = 1;
    bus.mem[0x201] = 2;
    bus.mem[0x202] = 3;
    cpu.set_hl(0x200);
    cpu.set_de(0x300);
    cpu.set_bc(3);
    try expectEqual(@as(u32, 21), cpu.step(bus));
    try expectEqual(@as(u32, 21), cpu.step(bus));
    try expectEqual(@as(u32, 16), cpu.step(bus));
    try expectEqual(@as(u16, 0x102), cpu.pc);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, bus.mem[0x300..0x303]);
}
