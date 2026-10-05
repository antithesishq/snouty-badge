//! Serial port: the link cable (docs/LINK.md M1 at the root) or, with no
//! partner, a stub that captures bytes written with a transfer request so
//! test ROMs (Blargg) can be read on the host.
//!
//! The cable is byte-level, not clock-level: the badge link carries whole
//! bytes. `Gb.link` is the frontend's wire to the partner Game Boy (set
//! only while a partner running Snouty Boy is connected; null keeps the
//! stub exactly as before). With a wire:
//!
//! - Internal clock (the master, SC = 0x81): the transfer sends a request
//!   carrying our SB and keeps running the CPU, as a real Game Boy does
//!   while its shift register clocks. It completes once one byte time has
//!   passed (1024 M-cycles, 32 with the CGB fast clock) and the partner's
//!   reply has arrived: SB takes the partner's byte, SC bit 7 clears, the
//!   serial interrupt fires. A late reply only makes the transfer look slow.
//!   No reply within `resend_m`: send the request again (packets can be
//!   lost); none within `timeout_m`: complete with 0xFF, as with no cable.
//! - External clock (the slave, SC = 0x80): nothing happens until a request
//!   arrives. Then the reply is our SB; if our transfer is waiting, SB takes
//!   the master's byte, SC bit 7 clears and the interrupt fires. A slave
//!   that is not waiting (or is itself a master) still answers with SB but
//!   changes nothing, so two masters simply swap bytes.
//! - Requests carry a sequence number; a repeated request (our reply was
//!   lost) gets the same reply again without being applied twice.
//!
//! `service` runs the wire every `poll_m` M-cycles from `tick` (the
//! scheduler wakes for it, `next_event_m`), and the frontend calls it
//! between frames too, so a slave answers even while its badge waits for
//! vsync.
const gb_mod = @import("gb.zig");
const Gb = gb_mod.Gb;

/// One message on the wire: a request (master's byte) or a reply (slave's
/// byte) for transfer `seq`.
pub const Msg = struct {
    kind: Kind,
    seq: u8,
    byte: u8,

    pub const Kind = enum(u8) { request = 1, reply = 2 };

    pub fn encode(m: Msg) [3]u8 {
        return .{ @backingInt(m.kind), m.seq, m.byte };
    }

    pub fn decode(b: []const u8) ?Msg {
        if (b.len != 3) return null;
        const kind: Kind = switch (b[0]) {
            1 => .request,
            2 => .reply,
            else => return null,
        };
        return .{ .kind = kind, .seq = b[1], .byte = b[2] };
    }
};

/// The frontend's side of the cable (function pointers so the core stays
/// badge-agnostic; host tests plug in a simulated cable).
pub const Wire = struct {
    ctx: *anyopaque,
    /// Queue one message to the partner (dropped silently if it cannot go).
    send: *const fn (ctx: *anyopaque, m: Msg) void,
    /// The next message from the partner, or null.
    recv: *const fn (ctx: *anyopaque) ?Msg,
};

/// One byte at 8192 Hz: 8 bits of 128 M-cycles; the CGB fast clock is 32
/// times quicker (the M-cycle count is the same in double speed, where the
/// serial clock doubles with the CPU).
pub const byte_m: u32 = 1024;
pub const byte_m_fast: u32 = 32;
/// Wire service period while linked (about one scanline).
pub const poll_m: u32 = 114;
/// Resend an unanswered request after this long (about 4 ms).
pub const resend_m: u32 = 4096;
/// Give up on an unanswered request (about 0.25 s): the partner is gone.
pub const timeout_m: u32 = 262144;

pub const Serial = struct {
    out: [256]u8 = @splat(0),
    len: u16 = 0,

    // ---- Link cable (console state: keyframes carry it, and a restore
    // mid-transfer resumes the wait) ----
    /// An internal-clock transfer is waiting for its time or its reply.
    master: bool = false,
    /// M-cycles until the byte time has passed (0: passed).
    master_left: u32 = 0,
    /// M-cycles since the transfer started (timeout), and until the next
    /// resend of an unanswered request.
    master_waited: u32 = 0,
    master_resend_left: u32 = 0,
    master_seq: u8 = 0,
    master_reply: ?u8 = null,
    /// The request still has to go out (start, or a resend is due).
    master_send: bool = false,
    /// Our reply to the partner's last request, for a repeated request.
    slave_seq: ?u8 = null,
    slave_reply: u8 = 0,
    /// M-cycles until the next `service` from `tick`.
    poll_left: u32 = poll_m,

    pub fn text(s: *const Serial) []const u8 {
        return s.out[0..s.len];
    }
};

/// Called by the MMU on a write to SC (0xFF02) with bit 7 set.
///
/// No wire: an internal-clock transfer completes instantly and no peer
/// answers (received byte 0xFF, SPEC.md 10.3), so SC bit 7 clears and the
/// serial interrupt fires; an external-clock transfer waits for a clock
/// that never comes (SC bit 7 stays set, no interrupt). Tetris and Tetris
/// DX probe for a link cable this way on the title screen every frame;
/// completing the transfer (or raising the interrupt) makes them think a
/// second Game Boy answered and they stop reading the joypad.
///
/// With a wire the internal-clock transfer goes to the partner (see the
/// file comment); the external-clock one waits for the partner's request.
pub fn start_transfer(gb: *Gb) void {
    const sc = gb.io[gb_mod.Reg.sc];
    if ((sc & 0x01) == 0) return;
    capture(gb, gb.io[gb_mod.Reg.sb]);
    if (gb.link == null) return complete(gb, 0xFF);
    const s = &gb.serial;
    s.master = true;
    s.master_left = if (gb.is_cgb() and (sc & 0x02) != 0) byte_m_fast else byte_m;
    s.master_waited = 0;
    s.master_resend_left = resend_m;
    s.master_seq +%= 1;
    s.master_reply = null;
    s.master_send = true;
    service(gb);
    gb.reschedule();
}

/// Keep the bytes written by a transfer request (Blargg's text output).
fn capture(gb: *Gb, byte: u8) void {
    const s = &gb.serial;
    if (s.len == s.out.len) {
        // Full: drop the oldest half so the tail (e.g. "Passed") stays visible.
        const half = s.out.len / 2;
        @memcpy(s.out[0..half], s.out[half..]);
        s.len = half;
    }
    s.out[s.len] = byte;
    s.len += 1;
}

fn complete(gb: *Gb, received: u8) void {
    gb.serial.master = false;
    gb.io[gb_mod.Reg.sb] = received;
    gb.io[gb_mod.Reg.sc] &= 0x7F;
    gb.request_irq(gb_mod.Irq.serial);
}

pub inline fn tick(gb: *Gb, m: u32) void {
    if (gb.link == null) return;
    const s = &gb.serial;
    if (s.master) {
        s.master_left -|= m;
        s.master_waited +|= m;
        if (s.master_waited >= timeout_m) {
            complete(gb, 0xFF);
        } else if (s.master_reply == null) {
            if (s.master_resend_left <= m) {
                s.master_resend_left = resend_m;
                s.master_send = true;
            } else {
                s.master_resend_left -= m;
            }
        }
    }
    if (s.poll_left <= m) {
        s.poll_left = poll_m;
        service(gb);
    } else {
        s.poll_left -= m;
    }
    if (s.master and s.master_left == 0) {
        if (s.master_reply) |r| complete(gb, r);
    }
}

/// M-cycles until serial needs a `tick` (the scheduler's `ev_m` bound):
/// the next wire service and the end of the byte time.
pub fn next_event_m(gb: *const Gb) u32 {
    if (gb.link == null) return 0xFFFF_FFFF;
    const s = &gb.serial;
    var e = s.poll_left;
    if (s.master and s.master_left != 0) e = @min(e, s.master_left);
    return @max(e, 1);
}

/// Run the wire: send a pending request, answer the partner's requests,
/// take its replies. Called from `tick` and by the frontend between frames.
pub fn service(gb: *Gb) void {
    const w = gb.link orelse return;
    const s = &gb.serial;
    if (s.master and s.master_send) {
        s.master_send = false;
        w.send(w.ctx, .{ .kind = .request, .seq = s.master_seq, .byte = gb.io[gb_mod.Reg.sb] });
    }
    while (w.recv(w.ctx)) |m| switch (m.kind) {
        .request => {
            if (s.slave_seq != m.seq) {
                s.slave_seq = m.seq;
                s.slave_reply = gb.io[gb_mod.Reg.sb];
                const sc = gb.io[gb_mod.Reg.sc];
                if ((sc & 0x81) == 0x80) {
                    // Our external-clock transfer was waiting: done.
                    gb.io[gb_mod.Reg.sb] = m.byte;
                    gb.io[gb_mod.Reg.sc] = sc & 0x7F;
                    gb.request_irq(gb_mod.Irq.serial);
                }
            }
            w.send(w.ctx, .{ .kind = .reply, .seq = m.seq, .byte = s.slave_reply });
        },
        .reply => if (s.master and m.seq == s.master_seq and s.master_reply == null) {
            s.master_reply = m.byte;
            if (s.master_left == 0) complete(gb, m.byte);
        },
    };
}

/// The wire went away mid-transfer: finish as if no cable were there.
pub fn unlink(gb: *Gb) void {
    if (gb.serial.master) complete(gb, 0xFF);
    gb.serial.slave_seq = null;
}
