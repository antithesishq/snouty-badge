//! Mikey's UART, the ComLynx serial port (docs/COMLYNX.md; PLAN.md "M6
//! ComLynx: contract"). Its state is `Mikey.uart` (so `Lynx.Small` and the
//! scrubber cover it); it runs only while a `comlynx.Port` is attached
//! (`Lynx.attach_link`, `Uart.on`). Unattached, core/mikey.zig keeps the
//! M1 stub exactly: SERCTL reads $A0 (transmitter ready and empty),
//! SERDAT 0, TXINTEN holds INTSET bit 4 on; nothing here runs.
//!
//! Sources: the Epyx hardware appendix (SERCTL/SERDAT bits, "break
//! received (24 bit periods)", the bug list: "the UART interrupt is not
//! edge sensitive", TXD powering up TTL high), the timer chapter (timer 4
//! is the baud generator, its interrupt bit is the UART's), cc65's
//! lynx-comlynx.s driver (62,500 baud = timer 4 backup 1 on the 1 us
//! clock; the 9th bit always sent; parity errors always reported; disable
//! the interrupt before clearing it), drhelius's lynx-tests uart, uart2,
//! uart3 and uart4 carts (MIT; hardware-measured timings and flags, the
//! rows docs/COMLYNX.md lists) and Gearlynx (GPL, read for behaviour, its
//! fitted constants named where used; nothing copied).
//!
//! The model:
//!
//! - **Bit clock.** One bit is 8 timer-4 underflows (the UART's /8
//!   prescaler, free running): 16 MHz / ((backup + 1) << (4 + clock)) / 8;
//!   timer 4 backup 1 on the 1 us clock is ComLynx's 62,500 baud (256
//!   ticks a bit, 2,816 a frame). MTEST0 bit 4 (UARTturbo) clocks a bit
//!   every 1 us instead. Timer 4 stays a quiet timer: the UART computes
//!   its edges from the timer's period (`next_bit`, `bit_ticks`), and
//!   steps only while it has work; a linked timer 4 clocks it through
//!   `t4_borrow`.
//! - **Transmitter**: the holding register (SERDAT write) and the shifter.
//!   A write to an idle transmitter loads the shifter: the start bit goes
//!   on the wire at the next bit edge and TXRDY comes back one edge later
//!   (lynx-tests uart "TXRDY IDLE": 2 bits after the write), the frame's
//!   11 bits follow, and TXEMPTY rises one bit after the stop bit ("TXEMPTY
//!   IDLE": 13 bits). A byte written while the shifter is busy waits in
//!   the holding register (a second write replaces it) and starts the
//!   moment the frame before ends, with TXRDY at once: back-to-back frames
//!   are exactly 11 bits apart ("TXRDY FULL" 11 bits, "TXEMPTY FULL" 22).
//!   The 9th bit is fixed when a frame starts: with PAREN the parity of the
//!   data (PAREVEN set: even parity, i.e. the bit is 1 for an odd count;
//!   lynx-tests uart2 "PARITY"), without it PAREVEN itself (mark/space).
//!   TXBRK holds the line low and freezes the transmitter (a held byte
//!   starts three bit edges after the release); TXOPEN clear (the TTL
//!   driver) keeps frames off the bus (the console still hears itself).
//! - **Receiver**: samples the wire (core/comlynx.zig: the AND of every
//!   frame on it, the console's own included) like a real UART: a falling
//!   edge starts a frame, the start bit is checked half a bit in, then
//!   each bit is sampled mid-bit at the receiver's own bit time and the
//!   frame is latched at the middle of its stop bit (a low stop bit is a
//!   framing error; low for 24 bits, RXBRK). The 9th bit is PARBIT; PARERR
//!   compares it with the parity the receiver's own PAREN/PAREVEN expect
//!   (with PAREN clear: PAREVEN). Latched frames go into a two-deep queue
//!   (RXRDY while it holds one): a frame landing on one unread is kept
//!   behind it, unless it is the console's own echo arriving within 800 us
//!   of the one before, which then replaces the newest with OVERRUN set
//!   (Gearlynx's hardware fit; lynx-tests uart2 "OVERRUN ERR" keeps two
//!   at 9,600 baud, uart3 "BURST ECHO" and "SLOW READER" lose one at
//!   62,500). SERDAT reads the oldest. The receiver is off while the
//!   console itself sends a break (uart2 "SERCTL CHANGE").
//! - **Interrupt** (INTSET bit 4, the bug list's level): the level is
//!   (TXINTEN and TXRDY) or (RXINTEN and RXRDY); while it is high the bit
//!   is set in INTSET, and it stays set until INTRST clears it, which
//!   only lasts if the level has dropped (lynx-tests uart2 "IRQ LEVEL";
//!   cc65: "disable the interrupt before clearing it").
//! - **Cost**: nothing on the CPU path. The UART catches up when SERCTL,
//!   SERDAT, INTSET/INTRST or timer 4 are touched, at `Lynx.link_sync`
//!   (the bus's pump points) and at `uart_event`: a Mikey event set only
//!   for the next bit edge at which an enabled interrupt level could rise,
//!   none while the UART is idle or its interrupts are off.
const std = @import("std");
const mikey_mod = @import("mikey.zig");
const comlynx = @import("comlynx.zig");
const lynx_mod = @import("lynx.zig");

const Mikey = mikey_mod.Mikey;
const never = comlynx.never;

/// SERCTL write bits.
pub const Ctl = struct {
    pub const txinten: u8 = 0x80;
    pub const rxinten: u8 = 0x40;
    pub const paren: u8 = 0x10;
    pub const reseterr: u8 = 0x08;
    pub const txopen: u8 = 0x04;
    pub const txbrk: u8 = 0x02;
    pub const pareven: u8 = 0x01;
};

/// SERCTL read bits.
pub const St = struct {
    pub const txrdy: u8 = 0x80;
    pub const rxrdy: u8 = 0x40;
    pub const txempty: u8 = 0x20;
    pub const parerr: u8 = 0x10;
    pub const overrun: u8 = 0x08;
    pub const framerr: u8 = 0x04;
    pub const rxbrk: u8 = 0x02;
    pub const parbit: u8 = 0x01;
    /// The per-frame flags a queue entry carries.
    pub const frame_flags: u8 = parerr | framerr | rxbrk | parbit;
};

/// A second frame landing within this long of the one before (unread)
/// replaces it when both are the console's own echo (Gearlynx's fit of
/// lynx-tests uart2/uart3: "the changeover sits near 800us of gap").
pub const rx_hold_ticks: u64 = 800 * 16;

/// Bit edges a held byte waits after TXBRK is released (Gearlynx's fit).
pub const brk_release_edges: u8 = 3;

/// MTEST0 bit 4: the UART clocked at 1 MBd.
pub const mtest0_turbo: u8 = 0x10;
pub const turbo_bit_ticks: u64 = 16;

pub const Uart = struct {
    /// A port is attached: the UART runs (else the stub in mikey.zig).
    on: bool = false,
    /// SERCTL as last written (RESETERR is a strobe, not kept).
    ctl: u8 = 0,

    // Transmitter.
    hold: u8 = 0,
    hold_valid: bool = false,
    /// The shifter holds a frame (waiting for its start edge or shifting).
    active: bool = false,
    shift: u8 = 0,
    ninth: bool = false,
    /// Bit edges before the start bit goes on the wire (an idle write: 1).
    lead: u8 = 0,
    /// Index of the bit on the wire (0 = start .. 10 = stop).
    bit: u8 = 0,
    /// Bit edges until TXRDY rises (an idle write: 2; after a break: the
    /// edges before the held byte starts).
    ready_wait: u8 = 0,
    /// Bit edges after the last frame until TXEMPTY rises.
    empty_wait: u8 = 0,
    /// The frame in the shifter started straight from the holding
    /// register (TXEMPTY then follows its stop bit at once).
    chained: bool = false,
    tx_ready: bool = true,
    tx_empty: bool = true,

    // The bit clock (absolute ticks, `Lynx.time()` scale).
    /// The next bit edge, or never (timer 4 stopped, linked, one-shot).
    next_bit: u64 = never,
    /// Ticks per bit (0: no clock yet).
    bit_ticks: u64 = 0,
    /// Timer-4 underflows since the last bit edge (a linked timer 4; and
    /// the phase carried across a timer-4 reprogramming).
    presc: u8 = 0,

    // Receiver.
    rxq_data: [2]u8 = .{ 0, 0 },
    rxq_flags: [2]u8 = .{ 0, 0 },
    rxq_head: u8 = 0,
    rxq_count: u8 = 0,
    /// SERDAT as it reads (the oldest frame, or the last one read).
    rx_data: u8 = 0,
    /// SERCTL's per-frame flags as they read (the oldest frame's).
    flags: u8 = 0,
    overrun: bool = false,
    /// The receiver looks for a start bit at or after this tick.
    rx_armed: u64 = 0,
    /// Falling edge of the frame being received, or never.
    rx_start: u64 = never,
    rx_bit_ticks: u64 = 0,
    /// When the last frame was latched (the 800 us rule).
    rx_last: u64 = 0,
    /// The newest queue entry is the console's own echo.
    rx_last_own: bool = false,
};

// ---------------------------------------------------------------------------
// Access to the console

fn lynx_of(m: *Mikey) *lynx_mod.Lynx {
    return @alignCast(@fieldParentPtr("mikey", m));
}

fn port_of(m: *Mikey) *comlynx.Port {
    return lynx_of(m).link.?;
}

/// Mikey's `now` on the absolute clock.
fn abs_now(m: *Mikey) u64 {
    return lynx_of(m).tick_base + m.now;
}

// ---------------------------------------------------------------------------
// Registers (core/mikey.zig calls these only while `on`)

pub fn read_ctl(m: *Mikey) u8 {
    sync(m);
    const u = &m.uart;
    var v: u8 = u.flags;
    if (u.tx_ready) v |= St.txrdy;
    if (u.rxq_count != 0) v |= St.rxrdy;
    if (u.tx_empty) v |= St.txempty;
    if (u.overrun) v |= St.overrun;
    return v;
}

pub fn read_data(m: *Mikey) u8 {
    sync(m);
    const u = &m.uart;
    const v = u.rx_data;
    if (u.rxq_count != 0) {
        u.rxq_head ^= 1;
        u.rxq_count -= 1;
        reflect_head(u);
    }
    relevel(m);
    resched(m);
    return v;
}

pub fn write_ctl(m: *Mikey, v: u8) void {
    sync(m);
    const u = &m.uart;
    const was = u.ctl;
    u.ctl = v & ~Ctl.reseterr;
    const now = abs_now(m);
    if (v & Ctl.reseterr != 0) {
        u.flags &= St.parbit;
        u.overrun = false;
    }
    const brk = v & Ctl.txbrk != 0;
    const was_brk = was & Ctl.txbrk != 0;
    const p = port_of(m);
    const on_wire = brk and v & Ctl.txopen != 0;
    const was_on_wire = was_brk and was & Ctl.txopen != 0;
    if (on_wire != was_on_wire) {
        p.push_out(.{ .time = now, .bit_ticks = @intCast(u.bit_ticks), .data = 0, .ninth = false, .kind = if (on_wire) .break_on else .break_off });
    }
    if (brk) {
        u.tx_empty = false;
        u.tx_ready = false;
        // The receiver is off while we send a break.
        u.rx_start = never;
    } else if (was_brk) {
        u.rx_armed = @max(u.rx_armed, now);
        if (!u.active and u.hold_valid) {
            u.ready_wait = brk_release_edges;
        } else if (!u.active and !u.hold_valid) {
            u.tx_empty = true;
            u.tx_ready = true;
        }
        skip_idle_edges(u, now);
    }
    relevel(m);
    resched(m);
}

pub fn write_data(m: *Mikey, v: u8) void {
    sync(m);
    const u = &m.uart;
    if (!u.active and u.ctl & Ctl.txbrk == 0 and !u.hold_valid) {
        skip_idle_edges(u, abs_now(m));
        begin(u, v);
        u.lead = 1;
        u.ready_wait = 2;
    } else {
        u.hold = v;
        u.hold_valid = true;
        u.tx_ready = false;
        u.tx_empty = false;
    }
    relevel(m);
    resched(m);
}

/// Before INTSET/INTRST are read or INTRST written: the UART caught up.
pub fn sync_irq(m: *Mikey) void {
    sync(m);
}

/// After an INTRST write: the bit comes back while the level holds.
pub fn after_intrst(m: *Mikey) void {
    relevel(m);
}

// ---------------------------------------------------------------------------
// Timer 4

/// Before a timer-4 register (or MTEST0) write: catch up, and work out how
/// far the prescaler is into its 8 underflows under the old settings.
pub fn before_clock_change(m: *Mikey) void {
    sync(m);
    const u = &m.uart;
    if (u.next_bit == never or u.bit_ticks == 0 or turbo(m)) return;
    const t = &m.timers[4];
    const per = t4_period(t);
    const nu = abs_next_underflow(m);
    if (nu == never or per == 0) return;
    // Underflows still to come up to and including the next edge.
    const left = (u.next_bit - nu) / per + 1;
    u.presc = @intCast(8 - @min(left, 8));
}

/// After it: the edges from the new settings.
pub fn after_clock_change(m: *Mikey) void {
    clock_resync(m);
    resched(m);
}

/// A linked timer 4 (or a CTLB borrow-in) underflowed at `at` (Mikey's
/// clock): one prescaler step.
pub fn t4_borrow(m: *Mikey, at: mikey_mod.Tick) void {
    const u = &m.uart;
    if (!u.on or turbo(m) or !m.timers[4].linked()) return;
    const t_abs = lynx_of(m).tick_base + at;
    u.presc += 1;
    if (u.presc < 8) return;
    u.presc = 0;
    catch_up(m, t_abs, false);
    tx_edge(m, t_abs);
    relevel(m);
}

fn turbo(m: *const Mikey) bool {
    return m.regs[mikey_mod.Reg.mtest0] & mtest0_turbo != 0;
}

fn t4_period(t: *const mikey_mod.Timer) u64 {
    return (@as(u64, t.backup) + 1) << t.shift();
}

/// Timer 4's next underflow after now (absolute), or never.
fn abs_next_underflow(m: *Mikey) u64 {
    const e = m.next_underflow(4);
    if (e == mikey_mod.ticks_never) return never;
    return lynx_of(m).tick_base + e;
}

/// `next_bit` and `bit_ticks` from timer 4 as it is set now.
fn clock_resync(m: *Mikey) void {
    const u = &m.uart;
    const now = abs_now(m);
    if (turbo(m)) {
        u.bit_ticks = turbo_bit_ticks;
        u.next_bit = (now / turbo_bit_ticks + 1) * turbo_bit_ticks;
        return;
    }
    const t = &m.timers[4];
    if (t.linked()) {
        // Clocked by timer 2's borrows (`t4_borrow`); the bit time for the
        // frames' records is unknown: take the line time x 8.
        const t0 = &m.timers[0];
        u.bit_ticks = 8 * ((@as(u64, t0.backup) + 1) << t0.shift()) * (@as(u64, m.timers[2].backup) + 1) * (@as(u64, t.backup) + 1);
        u.next_bit = never;
        return;
    }
    const per = t4_period(t);
    u.bit_ticks = 8 * per;
    const nu = abs_next_underflow(m);
    if (nu == never) {
        u.next_bit = never;
        return;
    }
    const k: u64 = 7 - @as(u64, u.presc);
    if (t.ctla & mikey_mod.Ctla.reload != 0) {
        u.next_bit = nu + k * per;
    } else {
        u.next_bit = if (k == 0) nu else never;
    }
}

/// Move `next_bit` past `now` over edges at which nothing happens (an idle
/// transmitter: none of its counters run).
fn skip_idle_edges(u: *Uart, now: u64) void {
    if (u.next_bit == never or u.next_bit > now or u.bit_ticks == 0) return;
    const n = (now - u.next_bit) / u.bit_ticks + 1;
    u.next_bit += n * u.bit_ticks;
}

fn advance_edge(m: *Mikey) void {
    const u = &m.uart;
    const t = &m.timers[4];
    if (turbo(m) or t.ctla & mikey_mod.Ctla.reload != 0) {
        u.next_bit += u.bit_ticks;
    } else {
        u.next_bit = never;
    }
}

// ---------------------------------------------------------------------------
// Catching up

/// Bring the UART up to Mikey's `now`.
pub fn sync(m: *Mikey) void {
    if (!m.uart.on) return;
    catch_up(m, abs_now(m), true);
}

/// The UART's Mikey event at `at` (Mikey's clock).
pub fn on_event(m: *Mikey, at: mikey_mod.Tick) void {
    _ = at;
    m.uart_event = mikey_mod.ticks_never;
    sync(m);
    relevel(m);
    resched(m);
}

fn tx_busy(u: *const Uart) bool {
    return u.active or u.hold_valid or u.empty_wait != 0;
}

/// Every transmitter edge and receiver step up to `t`, in time order.
/// `edges`: the closed-form bit edges run too (false for a linked timer 4,
/// whose edges come from `t4_borrow`).
fn catch_up(m: *Mikey, t: u64, edges: bool) void {
    const u = &m.uart;
    while (true) {
        const te = if (edges and tx_busy(u) and u.ctl & Ctl.txbrk == 0) u.next_bit else never;
        const rt = rx_next(m);
        const first = @min(te, rt);
        if (first > t or first == never) break;
        if (te <= rt) {
            tx_edge(m, te);
            advance_edge(m);
        } else {
            rx_step(m, rt);
        }
    }
    if (edges) skip_idle_edges(u, t);
    // A transmitter frozen by TXBRK keeps its edges in step with the clock.
    if (u.ctl & Ctl.txbrk != 0) skip_idle_edges(u, t);
    const p = port_of(m);
    const keep = if (u.rx_start != never) u.rx_start else u.rx_armed;
    p.prune(@min(keep, t));
}

// ---------------------------------------------------------------------------
// Transmitter

/// Load the shifter with `data` (its 9th bit from the settings now).
fn begin(u: *Uart, data: u8) void {
    u.shift = data;
    if (u.ctl & Ctl.paren != 0) {
        const odd = @popCount(data) & 1 != 0;
        u.ninth = if (u.ctl & Ctl.pareven != 0) odd else !odd;
    } else {
        u.ninth = u.ctl & Ctl.pareven != 0;
    }
    u.active = true;
    u.bit = 0;
    u.lead = 0;
    u.tx_ready = false;
    u.tx_empty = false;
    u.empty_wait = 0;
    u.chained = false;
}

/// Start the held byte at edge `e`: its start bit goes out now.
fn begin_held(m: *Mikey, e: u64) void {
    const u = &m.uart;
    begin(u, u.hold);
    u.hold_valid = false;
    u.tx_ready = true;
    u.ready_wait = 0;
    put_on_wire(m, e);
}

/// The frame in the shifter goes on the wire at `s`.
fn put_on_wire(m: *Mikey, s: u64) void {
    const u = &m.uart;
    const p = port_of(m);
    const bt: u32 = @intCast(@min(u.bit_ticks, std.math.maxInt(u32)));
    if (u.ctl & Ctl.txopen != 0) {
        p.push_out(.{ .time = s, .bit_ticks = bt, .data = u.shift, .ninth = u.ninth, .kind = .frame });
    } else {
        p.sent +%= 1;
    }
    if (p.echo == .local and bt != 0) {
        _ = p.insert(.{
            .start = s,
            .end = s + comlynx.frame_bits * @as(u64, bt),
            .bit_ticks = bt,
            .bits = comlynx.wire_bits(u.shift, u.ninth),
            .src = p.id,
            .is_break = false,
        });
    }
}

/// One bit edge of the transmitter at `e`.
fn tx_edge(m: *Mikey, e: u64) void {
    const u = &m.uart;
    if (u.ctl & Ctl.txbrk != 0) {
        u.tx_empty = false;
        return;
    }
    if (!u.active) {
        if (u.hold_valid) {
            if (u.ready_wait > 0) {
                u.ready_wait -= 1;
                if (u.ready_wait != 0) return;
            }
            begin_held(m, e);
            return;
        }
        if (u.empty_wait > 0) {
            u.empty_wait -= 1;
            if (u.empty_wait == 0) u.tx_empty = true;
        }
        return;
    }
    if (!u.tx_ready and u.ready_wait > 0) {
        u.ready_wait -= 1;
        if (u.ready_wait == 0) u.tx_ready = true;
    }
    if (u.lead > 0) {
        u.lead -= 1;
        if (u.lead == 0) put_on_wire(m, e);
        return;
    }
    u.bit += 1;
    if (u.bit < comlynx.frame_bits) return;
    // The stop bit is out.
    u.active = false;
    const was_chained = u.chained;
    if (u.hold_valid) {
        begin_held(m, e);
        u.chained = true;
    } else {
        u.tx_ready = true;
        u.chained = false;
        if (was_chained) {
            u.tx_empty = true;
        } else {
            u.empty_wait = 1;
        }
    }
}

// ---------------------------------------------------------------------------
// Receiver

/// The receiver's next step time (a start to take or a frame to latch),
/// or never.
fn rx_next(m: *Mikey) u64 {
    const u = &m.uart;
    if (u.ctl & Ctl.txbrk != 0) return never;
    if (u.rx_start != never) return u.rx_start + 10 * u.rx_bit_ticks + u.rx_bit_ticks / 2;
    const p = port_of(m);
    if (p.wire_len == 0) return never;
    var a = u.rx_armed;
    if (p.level(a) == 0) {
        a = p.first_high(a);
        if (a == never) return never;
    }
    return p.first_low(a);
}

fn rx_step(m: *Mikey, t: u64) void {
    const u = &m.uart;
    const p = port_of(m);
    if (u.rx_start == never) {
        // A falling edge at t.
        const b = u.bit_ticks;
        if (b == 0 or (u.next_bit == never and !m.timers[4].linked() and !turbo(m))) {
            // No bit clock: the receiver does not run. Skip this low run.
            u.rx_armed = p.first_high(t);
            if (u.rx_armed == never) u.rx_armed = t + 1;
            return;
        }
        if (p.level(t + b / 2) != 0) {
            // A glitch, not a start bit.
            u.rx_armed = t + b / 2;
            return;
        }
        u.rx_start = t;
        u.rx_bit_ticks = b;
        return;
    }
    // Latch the frame at t (mid stop bit).
    const s = u.rx_start;
    const b = u.rx_bit_ticks;
    var data: u8 = 0;
    var k: u64 = 1;
    while (k <= 8) : (k += 1) {
        data |= @as(u8, p.level(s + k * b + b / 2)) << @intCast(k - 1);
    }
    const ninth = p.level(s + 9 * b + b / 2) == 1;
    const stop = p.level(t) == 1;
    var fl: u8 = if (ninth) St.parbit else 0;
    const expect: bool = if (u.ctl & Ctl.paren != 0) blk: {
        const odd = @popCount(data) & 1 != 0;
        break :blk if (u.ctl & Ctl.pareven != 0) odd else !odd;
    } else u.ctl & Ctl.pareven != 0;
    if (ninth != expect) fl |= St.parerr;
    if (!stop) {
        fl |= St.framerr;
        // Low for 24 bits from the start: a break.
        if (p.first_high(t) >= s + 24 * b) fl |= St.rxbrk;
    }
    const own = !p.remote_in(p.id, s, t);
    push(m, data, fl, own, t);
    u.rx_start = never;
    u.rx_armed = t;
}

fn push(m: *Mikey, data: u8, fl: u8, own: bool, t: u64) void {
    const u = &m.uart;
    const p = port_of(m);
    p.latched +%= 1;
    if (fl & St.framerr != 0) p.framing_errors +%= 1;
    if (fl & St.parerr != 0) p.parity_errors +%= 1;
    const room = u.rxq_count == 0 or
        (u.rxq_count == 1 and !(own and u.rx_last_own and t - u.rx_last < rx_hold_ticks));
    const slot: u8 = if (room) (u.rxq_head + u.rxq_count) & 1 else (u.rxq_head + u.rxq_count - 1) & 1;
    if (!room) {
        u.overrun = true;
        p.overruns +%= 1;
    }
    u.rxq_data[slot] = data;
    u.rxq_flags[slot] = fl;
    if (room) u.rxq_count += 1;
    u.rx_last = t;
    u.rx_last_own = own;
    reflect_head(u);
}

fn reflect_head(u: *Uart) void {
    if (u.rxq_count == 0) return;
    const h = u.rxq_head & 1;
    u.rx_data = u.rxq_data[h];
    u.flags = u.rxq_flags[h];
}

// ---------------------------------------------------------------------------
// Interrupt

fn level(u: *const Uart) bool {
    return (u.ctl & Ctl.txinten != 0 and u.tx_ready) or (u.ctl & Ctl.rxinten != 0 and u.rxq_count != 0);
}

/// Set INTSET bit 4 while the level is high.
fn relevel(m: *Mikey) void {
    if (level(&m.uart)) m.intset |= 0x10;
}

/// The next tick at which the level could rise (absolute), or never.
fn next_rise(m: *Mikey) u64 {
    const u = &m.uart;
    if (level(u)) return never;
    var best = never;
    const nb = u.next_bit;
    const bt = u.bit_ticks;
    const edge_k = struct {
        fn at(n: u64, b: u64, k: u64) u64 {
            if (n == never) return never;
            return n + (@max(k, 1) - 1) * b;
        }
    }.at;
    const brk = u.ctl & Ctl.txbrk != 0;
    if (u.ctl & Ctl.txinten != 0 and !u.tx_ready and !brk) {
        if (u.active) {
            if (u.ready_wait > 0) {
                best = @min(best, edge_k(nb, bt, u.ready_wait));
            } else if (u.hold_valid) {
                best = @min(best, edge_k(nb, bt, @as(u64, u.lead) + comlynx.frame_bits - u.bit));
            }
        } else if (u.hold_valid) {
            best = @min(best, edge_k(nb, bt, u.ready_wait));
        }
    }
    if (u.ctl & Ctl.rxinten != 0 and !brk) {
        best = @min(best, rx_next(m));
        // Our own next frame start (its echo starts a reception).
        if (port_of(m).echo == .local and nb != never) {
            if (u.active and u.lead > 0) {
                best = @min(best, edge_k(nb, bt, u.lead));
            } else if (u.active and u.hold_valid) {
                best = @min(best, edge_k(nb, bt, comlynx.frame_bits - u.bit));
            } else if (!u.active and u.hold_valid) {
                best = @min(best, edge_k(nb, bt, u.ready_wait));
            }
        }
    }
    return best;
}

/// Set `uart_event` for the next possible rise and rebuild Mikey's event
/// schedule.
pub fn resched(m: *Mikey) void {
    const t = next_rise(m);
    const l = lynx_of(m);
    m.uart_event = if (t == never) mikey_mod.ticks_never else @intCast(@max(t, l.tick_base + m.now) - l.tick_base);
    m.reschedule();
}

// ---------------------------------------------------------------------------
// Attach / detach (core/lynx.zig)

/// The port went on: the UART takes over from the stub, idle.
pub fn attach(m: *Mikey) void {
    const stub_ctl = m.serctl;
    m.uart = .{ .on = true };
    m.serctl = 0;
    m.uart.ctl = stub_ctl & ~Ctl.reseterr;
    m.uart.rx_armed = abs_now(m);
    clock_resync(m);
    relevel(m);
    resched(m);
}

/// The port went away: back to the stub (TXINTEN carried over).
pub fn detach(m: *Mikey) void {
    const ctl = m.uart.ctl;
    m.uart = .{};
    m.serctl = ctl;
    m.uart_event = mikey_mod.ticks_never;
    m.reschedule();
}
