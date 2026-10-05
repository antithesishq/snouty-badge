//! comlynx: the UART (core/uart.zig) and the ComLynx bus (core/comlynx.zig,
//! core/comlynx_virtual.zig); docs/COMLYNX.md. Register-level tests drive a
//! console whose cart does not boot (the CPU halted) through the bus, so
//! only Mikey runs; the ring tests run tests/comlynx/ring.lnx (our cc65
//! token ring, committed) on 4 and 8 consoles; the Warbirds test needs
//! Adrian's local dump (~/roms/lynx/Warbirds.lnx, skipped when absent).
const std = @import("std");
const core = @import("core");
const files = @import("testfiles.zig");
const runner = @import("runner.zig");
const bus = core.bus;
const uart = core.uart;
const comlynx = core.comlynx;
const virt = core.comlynx_virtual;
const Lynx = core.Lynx;
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

const SERCTL: u16 = 0xFD8C;
const SERDAT: u16 = 0xFD8D;
const INTRST: u16 = 0xFD80;
const INTSET: u16 = 0xFD81;
const TIM4BKUP: u16 = 0xFD10;
const TIM4CTLA: u16 = 0xFD11;
const TIM4CNT: u16 = 0xFD12;
const MTEST0: u16 = 0xFD9C;
const St = uart.St;
const Ctl = uart.Ctl;

/// Ticks per bit at 62,500 baud (timer 4 backup 1, 1 us clock).
const bit62k: u64 = 256;

var halted_data: [600]u8 = @splat(0x12);
var halted_lay: core.cart.Layout = undefined;

/// A console that does not boot: the CPU halted, Mikey running.
fn halted(l: *Lynx) void {
    halted_lay = core.cart.parse(&halted_data, halted_data.len);
    l.init_in_place(core.Cart.from_slice(&halted_lay, &halted_data));
}

fn wr(l: *Lynx, a: u16, v: u8) void {
    Lynx.write(l, a, v);
}

fn rd(l: *Lynx, a: u16) u8 {
    return Lynx.read(l, a);
}

/// Let `n` ticks pass (Mikey's events, the UART's included, run).
fn wait(l: *Lynx, n: u64) void {
    l.ticks += @intCast(n);
    bus.sync_mikey(l);
}

/// Timer 4 as the baud clock: backup `b` on the 1 us clock.
fn baud(l: *Lynx, b: u8) void {
    wr(l, TIM4BKUP, b);
    wr(l, TIM4CNT, b);
    wr(l, TIM4CTLA, 0x18);
}

/// Ticks from now until `SERCTL & mask == want` (at most `limit`).
fn ticks_until(l: *Lynx, mask: u8, want: u8, limit: u64) ?u64 {
    const t0 = l.time();
    while (l.time() - t0 < limit) {
        if (rd(l, SERCTL) & mask == want) return l.time() - t0;
        wait(l, 4);
    }
    return null;
}

var c0: Lynx = undefined;
var c1: Lynx = undefined;
var p0: comlynx.Port = .{};

test "comlynx: no port attached keeps the M1 stub (SERCTL $A0, SERDAT 0, TXINTEN level)" {
    halted(&c0);
    try expectEqual(@as(u8, 0xA0), rd(&c0, SERCTL));
    wr(&c0, SERDAT, 0x55);
    wait(&c0, 10_000);
    try expectEqual(@as(u8, 0xA0), rd(&c0, SERCTL));
    try expectEqual(@as(u8, 0), rd(&c0, SERDAT));
    wr(&c0, SERCTL, 0x80);
    try expectEqual(@as(u8, 0x10), rd(&c0, INTSET) & 0x10);
    wr(&c0, SERCTL, 0);
    try expectEqual(@as(u8, 0), rd(&c0, INTSET) & 0x10);
}

test "comlynx: a lone console hears its own frame (TXRDY 2 bits, echo, TXEMPTY 13 bits)" {
    halted(&c0);
    c0.attach_link(&p0);
    baud(&c0, 1);
    wr(&c0, SERCTL, Ctl.txopen);
    wait(&c0, 4 * bit62k);
    try expectEqual(@as(u8, St.txrdy | St.txempty), rd(&c0, SERCTL) & 0xE0);
    wr(&c0, SERDAT, 0xA5);
    try expectEqual(@as(u8, 0), rd(&c0, SERCTL) & (St.txrdy | St.txempty));
    const rdy = ticks_until(&c0, St.txrdy, St.txrdy, 20 * bit62k).?;
    try expect(rdy > bit62k and rdy <= 2 * bit62k + 16);
    const echo = rdy + ticks_until(&c0, St.rxrdy, St.rxrdy, 20 * bit62k).?;
    try expect(echo > 10 * bit62k and echo <= 12 * bit62k + 16);
    try expectEqual(@as(u8, 0), rd(&c0, SERCTL) & St.txempty);
    const empty = echo + ticks_until(&c0, St.txempty, St.txempty, 20 * bit62k).?;
    try expect(empty > 12 * bit62k and empty <= 13 * bit62k + 16);
    try expectEqual(@as(u8, 0xA5), rd(&c0, SERDAT));
    try expectEqual(@as(u8, 0), rd(&c0, SERCTL) & St.rxrdy);
    // The frame went out on the port, stamped with its start bit.
    const f = p0.take().?;
    try expectEqual(@as(u8, 0xA5), f.data);
    try expectEqual(@as(u32, 256), f.bit_ticks);
    try expect(p0.take() == null);
    c0.attach_link(null);
}

test "comlynx: back-to-back frames are 11 bits apart, the held byte starts with TXRDY" {
    halted(&c0);
    c0.attach_link(&p0);
    baud(&c0, 1);
    wr(&c0, SERCTL, Ctl.txopen);
    wait(&c0, 4 * bit62k);
    wr(&c0, SERDAT, 1);
    _ = ticks_until(&c0, St.txrdy, St.txrdy, 20 * bit62k).?;
    wr(&c0, SERDAT, 2);
    const t = ticks_until(&c0, St.txrdy, St.txrdy, 30 * bit62k).?;
    try expect(t >= 10 * bit62k and t <= 11 * bit62k + 16);
    _ = ticks_until(&c0, St.txempty, St.txempty, 30 * bit62k).?;
    c0.link_sync();
    const a = p0.take().?;
    const b = p0.take().?;
    try expectEqual(@as(u64, 11 * bit62k), b.time - a.time);
    c0.attach_link(null);
}

test "comlynx: the 9th bit (parity even/odd, PAREVEN as mark/space) and PARERR" {
    halted(&c0);
    c0.attach_link(&p0);
    baud(&c0, 1);
    const cases = [_]struct { ctl: u8, data: u8, ninth: bool }{
        .{ .ctl = Ctl.paren | Ctl.pareven, .data = 0x55, .ninth = false }, // even count, even parity
        .{ .ctl = Ctl.paren | Ctl.pareven, .data = 0x01, .ninth = true },
        .{ .ctl = Ctl.paren, .data = 0x55, .ninth = true }, // odd parity
        .{ .ctl = Ctl.paren, .data = 0x01, .ninth = false },
        .{ .ctl = 0, .data = 0x01, .ninth = false }, // space
        .{ .ctl = Ctl.pareven, .data = 0x00, .ninth = true }, // mark
    };
    for (cases) |c| {
        wr(&c0, SERCTL, Ctl.txopen | c.ctl);
        wr(&c0, SERDAT, c.data);
        _ = ticks_until(&c0, St.rxrdy, St.rxrdy, 20 * bit62k).?;
        const s = rd(&c0, SERCTL);
        try expectEqual(@as(u8, @intFromBool(c.ninth)), s & St.parbit);
        try expectEqual(@as(u8, 0), s & St.parerr);
        try expectEqual(c.data, rd(&c0, SERDAT));
        _ = ticks_until(&c0, St.txempty, St.txempty, 20 * bit62k).?;
    }
    // Sent with even parity, received expecting odd: PARERR; RESETERR clears.
    wr(&c0, SERCTL, Ctl.txopen | Ctl.paren | Ctl.pareven);
    wr(&c0, SERDAT, 0x01);
    wait(&c0, 4 * bit62k);
    wr(&c0, SERCTL, Ctl.txopen | Ctl.paren);
    _ = ticks_until(&c0, St.rxrdy, St.rxrdy, 20 * bit62k).?;
    try expectEqual(St.parerr, rd(&c0, SERCTL) & St.parerr);
    wr(&c0, SERCTL, Ctl.txopen | Ctl.paren | Ctl.reseterr);
    try expectEqual(@as(u8, 0), rd(&c0, SERCTL) & St.parerr);
    c0.attach_link(null);
}

test "comlynx: two echoes 1.1 ms apart both kept, three overrun; at 62,500 the newest replaces" {
    halted(&c0);
    c0.attach_link(&p0);
    // 9,600 baud (backup 12): frames 1,144 us apart, over the 800 us rule.
    baud(&c0, 12);
    wr(&c0, SERCTL, Ctl.txopen);
    wait(&c0, 20 * 13 * 128);
    wr(&c0, SERDAT, 0xA5);
    _ = ticks_until(&c0, St.txrdy, St.txrdy, 40 * 13 * 128).?;
    wr(&c0, SERDAT, 0x5A);
    _ = ticks_until(&c0, St.txempty, St.txempty, 40 * 13 * 128).?;
    wait(&c0, 4 * 13 * 128);
    try expectEqual(@as(u8, 0), rd(&c0, SERCTL) & St.overrun);
    try expectEqual(@as(u8, 0xA5), rd(&c0, SERDAT));
    try expectEqual(St.rxrdy, rd(&c0, SERCTL) & St.rxrdy);
    try expectEqual(@as(u8, 0x5A), rd(&c0, SERDAT));
    try expectEqual(@as(u8, 0), rd(&c0, SERCTL) & St.rxrdy);
    // 62,500: the second echo lands 176 us after the first and replaces it.
    baud(&c0, 1);
    wait(&c0, 20 * bit62k);
    wr(&c0, SERDAT, 0x11);
    _ = ticks_until(&c0, St.txrdy, St.txrdy, 20 * bit62k).?;
    wr(&c0, SERDAT, 0x22);
    _ = ticks_until(&c0, St.txempty, St.txempty, 40 * bit62k).?;
    wait(&c0, 4 * bit62k);
    try expectEqual(St.overrun, rd(&c0, SERCTL) & St.overrun);
    try expectEqual(@as(u8, 0x22), rd(&c0, SERDAT));
    try expectEqual(@as(u8, 0), rd(&c0, SERCTL) & St.rxrdy);
    wr(&c0, SERCTL, Ctl.txopen | Ctl.reseterr);
    try expectEqual(@as(u8, 0), rd(&c0, SERCTL) & St.overrun);
    c0.attach_link(null);
}

test "comlynx: the serial interrupt is a level latched into INTSET (INTRST holds only once it drops)" {
    halted(&c0);
    c0.attach_link(&p0);
    baud(&c0, 1);
    // TXINTEN with TXRDY high: INTRST cannot clear bit 4.
    wr(&c0, SERCTL, Ctl.txopen | Ctl.txinten);
    try expectEqual(@as(u8, 0x10), rd(&c0, INTSET) & 0x10);
    wr(&c0, INTRST, 0x10);
    try expectEqual(@as(u8, 0x10), rd(&c0, INTSET) & 0x10);
    // Interrupts off: the latch stays until INTRST.
    wr(&c0, SERCTL, Ctl.txopen);
    try expectEqual(@as(u8, 0x10), rd(&c0, INTSET) & 0x10);
    wr(&c0, INTRST, 0x10);
    try expectEqual(@as(u8, 0), rd(&c0, INTSET) & 0x10);
    // RXINTEN: the echo raises it at its latch (a Mikey event: no register
    // access needed), reading SERDAT drops the level.
    wr(&c0, SERCTL, Ctl.txopen | Ctl.rxinten);
    wr(&c0, SERDAT, 0x42);
    var t: u64 = 0;
    while (c0.mikey.pending() & 0x10 == 0 and t < 20 * bit62k) : (t += 16) wait(&c0, 16);
    try expect(t > 10 * bit62k and t < 12 * bit62k + 32);
    try expect(c0.mikey.irq_line());
    try expectEqual(@as(u8, 0x42), rd(&c0, SERDAT));
    wr(&c0, INTRST, 0x10);
    try expectEqual(@as(u8, 0), rd(&c0, INTSET) & 0x10);
    c0.attach_link(null);
}

test "comlynx: TXBRK holds the byte and silences the receiver; it starts after the release" {
    halted(&c0);
    c0.attach_link(&p0);
    baud(&c0, 1);
    wr(&c0, SERCTL, Ctl.txopen | Ctl.txbrk);
    wr(&c0, SERDAT, 0x77);
    wait(&c0, 30 * bit62k);
    try expectEqual(@as(u8, 0), rd(&c0, SERCTL) & (St.txrdy | St.rxrdy | St.txempty));
    wr(&c0, SERCTL, Ctl.txopen);
    const t = ticks_until(&c0, St.txrdy, St.txrdy, 20 * bit62k).?;
    try expect(t >= 2 * bit62k and t <= 3 * bit62k + 16);
    _ = ticks_until(&c0, St.rxrdy, St.rxrdy, 20 * bit62k).?;
    try expectEqual(@as(u8, 0x77), rd(&c0, SERDAT));
    c0.link_sync();
    try expectEqual(comlynx.Kind.break_on, p0.take().?.kind);
    try expectEqual(comlynx.Kind.break_off, p0.take().?.kind);
    try expectEqual(comlynx.Kind.frame, p0.take().?.kind);
    c0.attach_link(null);
}

test "comlynx: baud from timer 4 (backup and clock select) and MTEST0 turbo" {
    halted(&c0);
    c0.attach_link(&p0);
    wr(&c0, SERCTL, Ctl.txopen);
    const cases = [_]struct { b: u8, sel: u8, bit: u64 }{
        .{ .b = 1, .sel = 0, .bit = 256 }, // 62,500
        .{ .b = 3, .sel = 0, .bit = 512 }, // 31,250
        .{ .b = 12, .sel = 0, .bit = 13 * 128 }, // 9,615
        .{ .b = 51, .sel = 3, .bit = 52 * 128 * 8 }, // 300
    };
    for (cases) |c| {
        wr(&c0, TIM4BKUP, c.b);
        wr(&c0, TIM4CNT, c.b);
        wr(&c0, TIM4CTLA, 0x18 | c.sel);
        wait(&c0, 3 * c.bit);
        wr(&c0, SERDAT, 0x3C);
        _ = ticks_until(&c0, St.txempty, St.txempty, 20 * c.bit).?;
        c0.link_sync();
        try expectEqual(@as(u32, @intCast(c.bit)), p0.take().?.bit_ticks);
        _ = rd(&c0, SERDAT);
    }
    wr(&c0, MTEST0, uart.mtest0_turbo);
    wr(&c0, SERDAT, 0x3C);
    _ = ticks_until(&c0, St.txempty, St.txempty, 20 * 16).?;
    c0.link_sync();
    try expectEqual(@as(u32, 16), p0.take().?.bit_ticks);
    wr(&c0, MTEST0, 0);
    c0.attach_link(null);
}

var bus2: virt.VirtualBus = undefined;

test "comlynx: two consoles sending at once collide on the wire (garbage, framing errors)" {
    halted(&c0);
    halted(&c1);
    const cs = [_]*Lynx{ &c0, &c1 };
    bus2.init(.{ .mode = .wire, .slice = 64 }, &cs);
    for (cs) |l| {
        baud(l, 1);
        wr(l, SERCTL, Ctl.txopen);
    }
    // Half a bit apart: every bit of the two frames overlaps.
    bus2.pump(0, false);
    wr(&c0, SERDAT, 0xF0);
    wait(&c1, 128);
    wr(&c1, SERDAT, 0x0F);
    var k: u32 = 0;
    while (k < 100) : (k += 1) {
        const t = c1.time() + 64;
        wait(&c0, t - c0.time());
        wait(&c1, t - c1.time());
        bus2.pump(t, false);
    }
    const s0 = rd(&c0, SERCTL);
    const d0 = rd(&c0, SERDAT);
    try expectEqual(St.rxrdy, s0 & St.rxrdy);
    try expect(d0 != 0xF0 and d0 != 0x0F);
    try expect(bus2.ports[0].latched >= 1);
    bus2.deinit();
}

// ---------------------------------------------------------------------------
// The token ring (tests/comlynx/ring.s)

const Res = struct {
    pub const base: u16 = 0x1F00;
    fn ok(l: *const Lynx) bool {
        return l.ram[base] == 0xC3;
    }
    fn messages(l: *const Lynx) u16 {
        return @as(u16, l.ram[base + 4]) | @as(u16, l.ram[base + 5]) << 8;
    }
    fn holds(l: *const Lynx) u16 {
        return @as(u16, l.ram[base + 6]) | @as(u16, l.ram[base + 7]) << 8;
    }
    fn errors(l: *const Lynx) u8 {
        return l.ram[base + 8];
    }
    fn regens(l: *const Lynx) u8 {
        return l.ram[base + 9];
    }
};

var ring_buf: [4096]u8 = undefined;
var ring_lay: core.cart.Layout = undefined;
var ring_consoles: [8]Lynx = undefined;
var ring_bus: virt.VirtualBus = undefined;

const RingResult = struct {
    /// Messages console 0 parsed in the last 4 s; the spread of the
    /// counts between consoles; format/sequence errors and watchdog
    /// regenerations summed over the consoles; the bus's late deliveries.
    per_s: u32,
    spread: u16,
    errors: u32,
    regens: u32,
    late: u64,
};

fn run_ring(n: u8, polling: bool, cfg: virt.Config, frames: u32) !RingResult {
    const file = files.read_cart_file("tests/comlynx/ring.lnx", &ring_buf) orelse return error.SkipZigTest;
    ring_lay = core.cart.parse(file, @intCast(file.len));
    var ptrs: [8]*Lynx = undefined;
    for (0..n) |i| {
        ring_consoles[i].init_in_place(core.Cart.from_slice(&ring_lay, file));
        ptrs[i] = &ring_consoles[i];
    }
    ring_bus.init(cfg, ptrs[0..n]);
    defer ring_bus.deinit();
    var pads: [8]u16 = undefined;
    for (0..n) |i| pads[i] = @as(u16, @intCast(i)) | @as(u16, n) << 4 | (if (polling) @as(u16, 8) else 0);
    var at: u16 = 0;
    for (0..frames) |f| {
        ring_bus.step_frame(pads[0..n]);
        if (f + 240 == frames) at = Res.messages(&ring_consoles[0]);
    }
    var lo: u16 = 0xFFFF;
    var hi: u16 = 0;
    var errs: u32 = 0;
    var regens: u32 = 0;
    for (ring_consoles[0..n]) |*l| {
        try expect(Res.ok(l));
        lo = @min(lo, Res.messages(l));
        hi = @max(hi, Res.messages(l));
        errs += Res.errors(l);
        regens += Res.regens(l);
    }
    return .{ .per_s = (Res.messages(&ring_consoles[0]) -% at) / 4, .spread = hi - lo, .errors = errs, .regens = regens, .late = ring_bus.stats.late };
}

test "comlynx: token ring of 4 and 8 consoles, interrupt and polling receivers, wire and relay" {
    for ([_]u8{ 4, 8 }) |n| {
        for ([_]bool{ false, true }) |polling| {
            const r = try run_ring(n, polling, .{ .mode = .wire }, 600);
            try expectEqual(@as(u32, 0), r.errors);
            try expectEqual(@as(u32, 0), r.regens);
            try expect(r.spread <= 1);
            // A pass is two frames on the wire (352 us) plus the code.
            try expect(r.per_s > 1500);
        }
    }
    // The relay (echo through it, one order, frame batching) at 4 ms: one
    // pass per frame (each hop waits for the sender's frame to end).
    const r = try run_ring(4, false, .{ .mode = .relay, .latency = 4 * 16_000 }, 600);
    try expectEqual(@as(u32, 0), r.errors);
    try expectEqual(@as(u32, 0), r.regens);
    try expect(r.per_s >= 55);
}

test "comlynx: token ring latency table (printed with COMLYNX_TABLE=1; docs/COMLYNX.md section 5)" {
    if (std.testing.environ.getPosix("COMLYNX_TABLE") == null) return error.SkipZigTest;
    const lat_ms = [_]u32{ 0, 1, 2, 5, 10, 20, 30, 40, 50 };
    std.debug.print("\ncomlynx ring: messages/s on console 0 | errors | watchdog regenerations\n", .{});
    for ([_]u8{ 4, 8 }) |n| {
        for ([_]bool{ false, true }) |polling| {
            for ([_]virt.Mode{ .wire, .relay }) |mode| {
                std.debug.print("  n={d} {s:4} {s:5}:", .{ n, if (polling) "poll" else "irq", @tagName(mode) });
                for (lat_ms) |ms| {
                    const r = try run_ring(n, polling, .{ .mode = mode, .latency = @as(u64, ms) * 16_000 }, 600);
                    std.debug.print(" {d}ms {d}/{d}/{d}", .{ ms, r.per_s, r.errors, r.regens });
                }
                std.debug.print("\n", .{});
            }
        }
    }
}

// ---------------------------------------------------------------------------
// drhelius's lynx-tests UART carts (hardware-measured; tests/roms/lynx-tests,
// fetched by tools/fetch_test_roms.sh, skipped when absent)

var lt_buf: [64 * 1024]u8 = undefined;
var lt_controls: [300]u16 = @splat(0);

/// The result screen of `name` on a console with a lone port (nothing else
/// on the wire), as `zig build run-lynx -- <rom> - 300 <dir> --uart`.
fn lone_hash(comptime name: []const u8) !u64 {
    const file = files.read_cart_file("tests/roms/lynx-tests/" ++ name ++ ".lnx", &lt_buf) orelse return error.SkipZigTest;
    const cart = switch (runner.cart_from_file(file)) {
        .ok => |x| x,
        .refused => return error.TestUnexpectedResult,
    };
    var run = runner.Run.init(&c0, cart, &lt_controls);
    c0.attach_link(&p0);
    defer c0.attach_link(null);
    var h: u64 = 0;
    while (!run.done()) h = run.step().hash;
    return h;
}

test "comlynx: lynx-tests uart, uart2, uart3 on a lone console (every row but uart TXRDY FULL 9600)" {
    // Reviewed 2026-10-05 (docs/COMLYNX.md section 4): uart2 and uart3 all
    // PASS; uart all but TXRDY FULL (row 4, the 9,600 baud sample one
    // 64 us tick short: $11 for $12/$13).
    try expectEqual(@as(u64, 0x17FEB9A54FCE887F), try lone_hash("uart"));
    try expectEqual(@as(u64, 0xAE784EE5DFC633DD), try lone_hash("uart2"));
    try expectEqual(@as(u64, 0x365C91EEA5B7A13F), try lone_hash("uart3"));
}

test "comlynx: lynx-tests uart4 on two consoles over the wire (every row on both)" {
    const file = files.read_cart_file("tests/roms/lynx-tests/uart4.lnx", &lt_buf) orelse return error.SkipZigTest;
    const lay = core.cart.parse(file, @intCast(file.len));
    c0.init_in_place(core.Cart.from_slice(&lay, file));
    c1.init_in_place(core.Cart.from_slice(&lay, file));
    const cs = [_]*Lynx{ &c0, &c1 };
    bus2.init(.{ .mode = .wire }, &cs);
    defer bus2.deinit();
    // Switched on 7 frames apart (run-lynx-link's default --stagger).
    bus2.power_on_at(1, 7);
    for (0..900) |_| bus2.step_frame(&.{ 0, 0 });
    // Reviewed 2026-10-05: MASTER and SLAVE, every row PASS.
    try expectEqual(@as(u64, 0xB0E860945F079DC8), runner.frame_hash(c0.frame()));
    try expectEqual(@as(u64, 0xFFB4522B2DE143A6), runner.frame_hash(c1.frame()));
}
