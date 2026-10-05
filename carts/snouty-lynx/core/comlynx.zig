//! ComLynx, the bus side of the UART (docs/COMLYNX.md; PLAN.md "M6
//! ComLynx: contract"). On hardware every Lynx of a game hangs on one
//! open-collector wire: a frame one console sends is heard by every
//! console, its sender included, and two frames on the wire at once are
//! ANDed bit by bit (a low wins), which gives garbage and framing errors.
//!
//! The core's half of that is a `Port` per console, attached with
//! `Lynx.attach_link` (a pointer outside `Lynx.Small`: the scrubber is off
//! while linked). Through it the UART (core/uart.zig):
//!
//! - **sends**: every frame it puts on the wire is appended to `out` as a
//!   `TxFrame` stamped with the emulated time of its start bit
//!   (`Lynx.time()` scale: 16 MHz ticks since reset) and its bit time, its
//!   8 data bits and its 9th bit; a TXBRK is a `break_on` / `break_off`
//!   pair. The bus takes them with `take`.
//! - **receives**: the bus hands frames back with `Lynx.link_deliver` (one
//!   `RxFrame` each: start time on this console's clock, bit time, data,
//!   9th bit, sender); they join `wire`, the frames on this console's wire
//!   in start order, which the receiver samples as a real one would (the
//!   level at any instant is the AND of every frame on the wire then).
//!
//! `echo` says where a console's own frames come back from: `.local` puts
//! each one on its own wire at once, as the cable does (the bus must then
//! not deliver it back); `.bus` leaves that to the bus, which delivers it
//! like any other frame (a relay that gives every console one order).
//!
//! The bus implementations live outside the core: core/comlynx_virtual.zig
//! (2-8 consoles in one process, for the tests) and, later, the badge
//! transport (frontend/linkport.zig is its seam). Badge-agnostic: no
//! allocator, no clock, no randomness.
const std = @import("std");

/// "No time" (an open break's end, an empty schedule).
pub const never: u64 = std.math.maxInt(u64);

/// Bits of an 11-bit frame on the wire, LSB first: start (0), data 0-7,
/// the 9th bit, stop (1).
pub const frame_bits: u32 = 11;

pub const Kind = enum(u8) {
    /// One 11-bit frame.
    frame,
    /// The sender's TXBRK went on: its line is low from `time` until the
    /// matching `break_off`.
    break_on,
    break_off,
};

/// A frame a console put on the wire (the bus's input).
pub const TxFrame = struct {
    /// Emulated time of the start bit's leading edge (16 MHz ticks since
    /// the sender's reset), or of the break's start / end.
    time: u64,
    /// Ticks per bit (8 timer-4 periods; 256 at 62,500 baud).
    bit_ticks: u32,
    data: u8,
    /// The 9th bit as sent (the parity bit, or PAREVEN with PAREN clear).
    ninth: bool,
    kind: Kind,
};

/// A frame the bus delivers to a console.
pub const RxFrame = struct {
    /// Start time on the receiving console's clock (`Lynx.time()` scale).
    /// A time already past is taken as now (late).
    start: u64,
    bit_ticks: u32,
    data: u8,
    ninth: bool,
    kind: Kind = .frame,
    /// The sending console's port id (its own id for the echo).
    src: u8,
};

/// The 11 wire bits of a frame, bit 0 first.
pub fn wire_bits(data: u8, ninth: bool) u16 {
    return (@as(u16, data) << 1) | (@as(u16, @intFromBool(ninth)) << 9) | (1 << 10);
}

/// One frame (or break span) on a console's wire.
pub const WireFrame = struct {
    start: u64,
    /// First tick after it (a frame: start + 11 bits; an open break: never).
    end: u64,
    bit_ticks: u32,
    /// `wire_bits` (unused for a break).
    bits: u16,
    src: u8,
    is_break: bool,

    /// Its level at tick `t` (1 outside it).
    pub fn level(f: *const WireFrame, t: u64) u1 {
        if (t < f.start or t >= f.end) return 1;
        if (f.is_break) return 0;
        const i = (t - f.start) / f.bit_ticks;
        return @truncate(f.bits >> @intCast(i));
    }

    /// The first tick at or after `t` (and inside it) where it is low.
    pub fn first_low(f: *const WireFrame, t: u64) u64 {
        const from = @max(t, f.start);
        if (from >= f.end) return never;
        if (f.is_break) return from;
        var i = (from - f.start) / f.bit_ticks;
        while (i < frame_bits) : (i += 1) {
            if ((f.bits >> @intCast(i)) & 1 == 0) return @max(from, f.start + i * f.bit_ticks);
        }
        return never;
    }

    /// The end of the low run it has at `t` (it is low at `t`).
    pub fn low_until(f: *const WireFrame, t: u64) u64 {
        if (f.is_break) return f.end;
        var i = (t - f.start) / f.bit_ticks;
        while (i < frame_bits and (f.bits >> @intCast(i)) & 1 == 0) i += 1;
        return f.start + i * f.bit_ticks;
    }
};

/// Frames a port queues each way. `out` holds what the UART sent since
/// the bus last took (at 62,500 baud a 1/60 s frame carries at most 95);
/// `wire` what is due on this console's wire (the bus delivers a frame
/// shortly before it is due, not a whole latency ahead).
pub const out_cap = 128;
pub const wire_cap = 64;

pub const Echo = enum(u8) { local, bus };

pub const Port = struct {
    /// This console's id on the bus (0-7 for the virtual bus).
    id: u8 = 0,
    echo: Echo = .local,

    out: [out_cap]TxFrame = undefined,
    out_head: u32 = 0,
    out_len: u32 = 0,

    wire: [wire_cap]WireFrame = undefined,
    wire_len: u32 = 0,
    /// Per sender (id mod 16): the end of its last frame on this wire, so
    /// frames delivered late keep their spacing instead of piling up.
    src_end: [16]u64 = @splat(0),

    // Counters (diagnostics; the tests read them).
    /// Frames the UART put on the wire / frames dropped because `out` was
    /// full (the bus did not take them in time).
    sent: u32 = 0,
    out_dropped: u32 = 0,
    /// Frames delivered / dropped because `wire` was full / delivered with
    /// a start already past (taken as now) and the ticks they were late.
    delivered: u32 = 0,
    wire_dropped: u32 = 0,
    late: u32 = 0,
    late_ticks: u64 = 0,
    /// Frames the receiver latched (good or not), and of those with a
    /// framing error, a parity error, or lost to an overrun.
    latched: u32 = 0,
    framing_errors: u32 = 0,
    parity_errors: u32 = 0,
    overruns: u32 = 0,

    /// Forget every queued frame (a console reset: its clock restarts).
    pub fn clear(p: *Port) void {
        p.out_head = 0;
        p.out_len = 0;
        p.wire_len = 0;
        p.src_end = @splat(0);
    }

    /// The bus side: the oldest frame sent and not yet taken.
    pub fn take(p: *Port) ?TxFrame {
        if (p.out_len == 0) return null;
        const f = p.out[p.out_head];
        p.out_head = (p.out_head + 1) % out_cap;
        p.out_len -= 1;
        return f;
    }

    /// The UART side: a frame went on the wire.
    pub fn push_out(p: *Port, f: TxFrame) void {
        p.sent +%= 1;
        if (p.out_len == out_cap) {
            p.out_dropped +%= 1;
            return;
        }
        p.out[(p.out_head + p.out_len) % out_cap] = f;
        p.out_len += 1;
    }

    /// Put a frame on the wire in start order. False when the wire is full.
    pub fn insert(p: *Port, f: WireFrame) bool {
        if (p.wire_len == wire_cap) {
            p.wire_dropped +%= 1;
            return false;
        }
        var i = p.wire_len;
        while (i > 0 and p.wire[i - 1].start > f.start) : (i -= 1) p.wire[i] = p.wire[i - 1];
        p.wire[i] = f;
        p.wire_len += 1;
        return true;
    }

    /// Close an open break of `src` at `t`.
    pub fn close_break(p: *Port, src: u8, t: u64) void {
        for (p.wire[0..p.wire_len]) |*f| {
            if (f.is_break and f.src == src and f.end == never) f.end = @max(t, f.start);
        }
    }

    /// Drop the frames over before `t` (the receiver will not look back).
    pub fn prune(p: *Port, t: u64) void {
        var k: u32 = 0;
        for (p.wire[0..p.wire_len]) |f| {
            if (f.end > t) {
                p.wire[k] = f;
                k += 1;
            }
        }
        p.wire_len = k;
    }

    /// The wire's level at `t`: the AND of every frame on it.
    pub fn level(p: *const Port, t: u64) u1 {
        for (p.wire[0..p.wire_len]) |*f| {
            if (f.start > t) break;
            if (f.level(t) == 0) return 0;
        }
        return 1;
    }

    /// The first tick at or after `t` where the wire is low (never if no
    /// frame on it goes low).
    pub fn first_low(p: *const Port, t: u64) u64 {
        var best = never;
        for (p.wire[0..p.wire_len]) |*f| {
            if (f.start >= best) break;
            best = @min(best, f.first_low(t));
        }
        return best;
    }

    /// The first tick at or after `t` where the wire is high.
    pub fn first_high(p: *const Port, t: u64) u64 {
        var at = t;
        while (true) {
            var moved = false;
            for (p.wire[0..p.wire_len]) |*f| {
                if (f.start > at) break;
                if (f.level(at) == 0) {
                    at = f.low_until(at);
                    moved = true;
                }
            }
            if (!moved or at == never) return at;
        }
    }

    /// Did a frame from another console (than `self`) overlap [a, b]?
    pub fn remote_in(p: *const Port, self: u8, a: u64, b: u64) bool {
        for (p.wire[0..p.wire_len]) |*f| {
            if (f.start > b) break;
            if (f.src != self and f.end > a) return true;
        }
        return false;
    }
};

test "comlynx: wire bits and levels" {
    const b = wire_bits(0xA5, true);
    try std.testing.expectEqual(@as(u16, 0b1_1_10100101_0), b);
    var p: Port = .{};
    _ = p.insert(.{ .start = 1000, .end = 1000 + 11 * 16, .bit_ticks = 16, .bits = b, .src = 1, .is_break = false });
    try std.testing.expectEqual(@as(u1, 1), p.level(999));
    try std.testing.expectEqual(@as(u1, 0), p.level(1000));
    try std.testing.expectEqual(@as(u1, 1), p.level(1016)); // d0 = 1
    try std.testing.expectEqual(@as(u1, 0), p.level(1032)); // d1 = 0
    try std.testing.expectEqual(@as(u64, 1000), p.first_low(0));
    try std.testing.expectEqual(@as(u64, 1032), p.first_low(1016));
    try std.testing.expectEqual(@as(u64, 1016), p.first_high(1000));
    // A second frame ANDed in.
    _ = p.insert(.{ .start = 1008, .end = 1008 + 11 * 16, .bit_ticks = 16, .bits = wire_bits(0xFF, true), .src = 2, .is_break = false });
    try std.testing.expectEqual(@as(u1, 0), p.level(1016)); // its start bit
    try std.testing.expectEqual(@as(u64, 1024), p.first_high(1000));
    p.prune(1200);
    try std.testing.expectEqual(@as(u32, 0), p.wire_len);
}
