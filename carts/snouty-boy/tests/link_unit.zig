//! The link cable (core/serial.zig, docs/LINK.md M1): two consoles joined
//! by a simulated wire that can drop messages. Unit checks of the byte
//! exchange, then two Tetris consoles playing into a 2-player game when
//! tests/roms/tetris.gb is there (copy your own dump; skipped otherwise).
const std = @import("std");
const core = @import("core");
const Gb = core.Gb;
const Pad = core.Pad;
const serial = core.serial;
const Msg = serial.Msg;

const expectEqual = std.testing.expectEqual;

/// One direction of the simulated cable.
const Pipe = struct {
    buf: [64]Msg = undefined,
    head: usize = 0,
    len: usize = 0,
    sent: u32 = 0,
    /// Drop every message whose index (from 0) satisfies this.
    drop_first: u32 = 0,
    drop_every: u32 = 0,
    dropped: u32 = 0,

    fn push(p: *Pipe, m: Msg) void {
        const i = p.sent;
        p.sent += 1;
        if (i < p.drop_first or (p.drop_every != 0 and i % p.drop_every == p.drop_every - 1)) {
            p.dropped += 1;
            return;
        }
        if (p.len == p.buf.len) return;
        p.buf[(p.head + p.len) % p.buf.len] = m;
        p.len += 1;
    }

    fn pop(p: *Pipe) ?Msg {
        if (p.len == 0) return null;
        const m = p.buf[p.head];
        p.head = (p.head + 1) % p.buf.len;
        p.len -= 1;
        return m;
    }
};

/// One end: sends into `out`, receives from `in`.
const End = struct {
    out: *Pipe,
    in: *Pipe,

    fn send(ctx: *anyopaque, m: Msg) void {
        const e: *End = @ptrCast(@alignCast(ctx));
        e.out.push(m);
    }

    fn recv(ctx: *anyopaque) ?Msg {
        const e: *End = @ptrCast(@alignCast(ctx));
        return e.in.pop();
    }

    fn wire(e: *End) serial.Wire {
        return .{ .ctx = e, .send = send, .recv = recv };
    }
};

const Cable = struct {
    a_to_b: Pipe = .{},
    b_to_a: Pipe = .{},
    end_a: End = undefined,
    end_b: End = undefined,

    fn plug(c: *Cable, a: *Gb, b: *Gb) void {
        c.end_a = .{ .out = &c.a_to_b, .in = &c.b_to_a };
        c.end_b = .{ .out = &c.b_to_a, .in = &c.a_to_b };
        a.link = c.end_a.wire();
        b.link = c.end_b.wire();
    }
};

var ram_a: [Gb.max_cart_ram]u8 = undefined;
var ram_b: [Gb.max_cart_ram]u8 = undefined;
var blank_rom: [0x8000]u8 = @splat(0);

fn new_gb(rom: []const u8, ram: []u8) !*Gb {
    const gb = try std.testing.allocator.create(Gb);
    gb.* = Gb.init_slice(rom, if (rom[0x143] & 0x80 != 0) .cgb else .dmg, ram);
    return gb;
}

/// Run both consoles `m` M-cycles in slices, as two badges would run side
/// by side (no CPU: a blank ROM's NOPs would do the same).
fn run_both(a: *Gb, b: *Gb, m: u32) void {
    var left = m;
    while (left > 0) {
        const n: u8 = @intCast(@min(left, 64));
        a.tick(n);
        b.tick(n);
        left -= n;
    }
}

fn start(gb: *Gb, sb: u8, sc: u8) void {
    gb.write8(0xFF0F, 0x00);
    gb.write8(0xFF01, sb);
    gb.write8(0xFF02, sc);
}

test "link: master and slave swap bytes after one byte time, both interrupted" {
    const a = try new_gb(&blank_rom, &ram_a);
    defer std.testing.allocator.destroy(a);
    const b = try new_gb(&blank_rom, &ram_b);
    defer std.testing.allocator.destroy(b);
    var cable: Cable = .{};
    cable.plug(a, b);

    start(b, 0x99, 0x80); // slave waits
    start(a, 0x42, 0x81); // master clocks
    run_both(a, b, 512);
    // The slave is done when the request arrives; the master not before
    // its byte time.
    try expectEqual(@as(u8, 0x42), b.read8(0xFF01));
    try expectEqual(@as(u8, 0), b.read8(0xFF02) & 0x80);
    try expectEqual(@as(u8, core.Irq.serial), b.read8(0xFF0F) & core.Irq.serial);
    try expectEqual(@as(u8, 0x80), a.read8(0xFF02) & 0x80);
    run_both(a, b, 1024);
    try expectEqual(@as(u8, 0x99), a.read8(0xFF01));
    try expectEqual(@as(u8, 0), a.read8(0xFF02) & 0x80);
    try expectEqual(@as(u8, core.Irq.serial), a.read8(0xFF0F) & core.Irq.serial);
}

test "link: lost requests and replies are resent, applied once" {
    const a = try new_gb(&blank_rom, &ram_a);
    defer std.testing.allocator.destroy(a);
    const b = try new_gb(&blank_rom, &ram_b);
    defer std.testing.allocator.destroy(b);
    var cable: Cable = .{};
    cable.plug(a, b);
    cable.a_to_b.drop_first = 2; // the request and its first resend
    cable.b_to_a.drop_first = 1; // the first reply

    for (0..20) |i| {
        const byte: u8 = @intCast(i);
        start(b, 0x80 | byte, 0x80);
        start(a, byte, 0x81);
        run_both(a, b, 4 * serial.resend_m + 4096);
        try expectEqual(@as(u8, 0x80 | byte), a.read8(0xFF01));
        try expectEqual(byte, b.read8(0xFF01));
        try expectEqual(@as(u8, 0), a.read8(0xFF02) & 0x80);
        try expectEqual(@as(u8, 0), b.read8(0xFF02) & 0x80);
    }
    try std.testing.expect(cable.a_to_b.dropped == 2 and cable.b_to_a.dropped == 1);
}

test "link: a slave not waiting answers with SB and keeps its state" {
    const a = try new_gb(&blank_rom, &ram_a);
    defer std.testing.allocator.destroy(a);
    const b = try new_gb(&blank_rom, &ram_b);
    defer std.testing.allocator.destroy(b);
    var cable: Cable = .{};
    cable.plug(a, b);

    start(b, 0x11, 0x00); // no transfer requested
    start(a, 0x22, 0x81);
    run_both(a, b, 2048);
    try expectEqual(@as(u8, 0x11), a.read8(0xFF01));
    try expectEqual(@as(u8, 0x11), b.read8(0xFF01));
    try expectEqual(@as(u8, 0), b.read8(0xFF0F) & core.Irq.serial);
}

test "link: no answer times out to 0xFF, as with no cable" {
    const a = try new_gb(&blank_rom, &ram_a);
    defer std.testing.allocator.destroy(a);
    var cable: Cable = .{};
    cable.end_a = .{ .out = &cable.a_to_b, .in = &cable.b_to_a };
    a.link = cable.end_a.wire(); // nobody services the other end
    start(a, 0x42, 0x81);
    var left: u32 = serial.timeout_m - 2048;
    while (left > 0) : (left -= 64) a.tick(64);
    try expectEqual(@as(u8, 0x80), a.read8(0xFF02) & 0x80);
    for (0..64) |_| a.tick(64);
    try expectEqual(@as(u8, 0xFF), a.read8(0xFF01));
    try expectEqual(@as(u8, 0), a.read8(0xFF02) & 0x80);
}

test "link: with no wire the stub is unchanged" {
    const a = try new_gb(&blank_rom, &ram_a);
    defer std.testing.allocator.destroy(a);
    start(a, 0x42, 0x81);
    try expectEqual(@as(u8, 0xFF), a.read8(0xFF01));
    try expectEqual(@as(u8, 0), a.read8(0xFF02) & 0x80);
}

// ---- Tetris ----

fn load_rom(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var buf: [256]u8 = undefined;
    const rooted = try std.fmt.bufPrint(&buf, "carts/snouty-boy/{s}", .{path});
    for ([_][]const u8{ rooted, path }) |p| {
        return std.Io.Dir.cwd().readFileAlloc(std.testing.io, p, gpa, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
    }
    return error.SkipZigTest;
}

/// Tetris's game state byte (hGameState): 0x07 the 1/2-player menu, 0x2B
/// the 2-player music select, 0x17 MARIO VS. LUIGI, 0x1A a 2-player game.
const tetris_state = 0xFFE1;

/// Both consoles boot, Start on the title, Right to 2PLAYER on both, Start
/// on A (the master) then on B, Start through MARIO VS. LUIGI: by frame
/// 1500 both are in the same 2-player game.
fn tetris_pair(drop_every: u32) !void {
    const gpa = std.testing.allocator;
    const rom = try load_rom(gpa, "tests/roms/tetris.gb");
    defer gpa.free(rom);
    const a = try new_gb(rom, &ram_a);
    defer gpa.destroy(a);
    const b = try new_gb(rom, &ram_b);
    defer gpa.destroy(b);
    var cable: Cable = .{};
    cable.a_to_b.drop_every = drop_every;
    cable.b_to_a.drop_every = drop_every;
    cable.plug(a, b);
    const Press = struct { from: u32, a: u8, b: u8 };
    const script = [_]Press{
        .{ .from = 300, .a = Pad.start, .b = Pad.start },
        .{ .from = 360, .a = Pad.right, .b = Pad.right },
        .{ .from = 420, .a = Pad.start, .b = 0 },
        .{ .from = 480, .a = 0, .b = Pad.start },
        .{ .from = 600, .a = Pad.start, .b = 0 },
        .{ .from = 660, .a = 0, .b = Pad.start },
        .{ .from = 800, .a = Pad.start, .b = 0 },
    };
    var f: u32 = 0;
    while (f < 1500) : (f += 1) {
        var pa: u8 = 0;
        var pb: u8 = 0;
        for (script) |p| if (f >= p.from and f < p.from + 5) {
            pa = p.a;
            pb = p.b;
        };
        a.step_frame(pa);
        b.step_frame(pb);
        if (f == 650) {
            try expectEqual(@as(u8, 0x17), a.read8(tetris_state));
            try expectEqual(@as(u8, 0x17), b.read8(tetris_state));
        }
    }
    try expectEqual(@as(u8, 0x1A), a.read8(tetris_state));
    try expectEqual(@as(u8, 0x1A), b.read8(tetris_state));
    // A clocks, B listens.
    try expectEqual(@as(u8, 0x01), a.read8(0xFF02) & 0x01);
    try expectEqual(@as(u8, 0x00), b.read8(0xFF02) & 0x01);
    // The same playfield on both (the master sends the piece sequence):
    // the 10x18 tile map at 0x9800, columns 2..11.
    for (0..18) |row| for (2..12) |col| {
        const addr: u16 = @intCast(0x9800 + row * 32 + col);
        try expectEqual(a.read8(addr), b.read8(addr));
    };
    if (drop_every != 0) try std.testing.expect(cable.a_to_b.dropped > 50 and cable.b_to_a.dropped > 50);
}

test "link: two Tetris consoles play into a 2-player game" {
    try tetris_pair(0);
}

test "link: ... with every 5th message lost each way" {
    try tetris_pair(5);
}
