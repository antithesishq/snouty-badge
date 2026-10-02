//! Mikey (SPEC.md sections 3 and 7): the eight timers and their link
//! chains, interrupts (INTSET/INTRST), the palette, the display registers
//! (DISPCTL, DISPADR, PBKUP), the audio register model (stored, never
//! heard: no sound in this project, docs/SOUND.md at the repository root),
//! IODIR/IODAT/SYSCTL1, the UART stubbed idle. PLAN.md "Frozen for M1" says
//! what the rest of the core sees.
//!
//! Sources: the Epyx hardware appendix (https://www.monlynx.de/lynx/hardware.html),
//! the timer chapter (lynx8.html), display (lynx5.html), CPU sleep
//! (lynx4.html), cc65's include/_mikey.h; Felix (https://github.com/laoo/Felix,
//! MIT) read for behaviour the documents leave open. Nothing copied.
//!
//! What lives elsewhere: the cart port strobes (SYSCTL1 bit 0, IODAT bit 1)
//! and CPUSLEEP ($91) need the whole console, so core/bus.zig handles them
//! around `write`; MAPCTL ($FFF9) is the bus's too. The display copy at
//! vertical blank is core/lynx.zig's: it watches `vblank_count`.
//!
//! Time. Mikey keeps its own clock `now` in 16 MHz ticks and the bus keeps
//! it equal to `Lynx.ticks` through `advance(dt)` (after every instruction,
//! and before every Mikey register access, so a timer read mid-instruction
//! sees the right count). `advance` is a compare against `next_event` on
//! the common path.
//!
//! Timer model (Epyx timer chapter):
//!
//! - A timer's clock is 1, 2, 4 .. 64 us = 16 << sel ticks (CTLA bits 2-0;
//!   7 = linked). Clock edges are global: they fall on multiples of the
//!   period (the hardware's prescaler is shared), so a freshly started
//!   timer with backup 5 lasts between 5 and 6 units the first time and 6
//!   after, exactly as the timer chapter describes.
//! - The count decrements on each edge; an edge arriving at count 0 is the
//!   underflow ("borrow out"): CTLB timer done is set, the interrupt bit is
//!   set in INTSET if CTLA bit 7 enables it, the count reloads from BACKUP
//!   if CTLA bit 4 says so, and the next timer of the chain gets a clock
//!   if it is linked (0 -> 2 -> 4, 1 -> 3 -> 5 -> 7).
//! - Without reload, the timer stops at 0 with timer done set ("timers can
//!   be set to stop when they reach a count of 0"; a non-reloading timer
//!   does not count while DONE is set) until DONE is cleared by a CTLB
//!   write or CTLA bit 6. RESET_DONE (CTLA bit 6) is a level, not a pulse:
//!   while it is set DONE stays clear, so a one-shot at 0 borrows (and
//!   interrupts) on every source clock.
//! - A CTLB write with bit 1 (borrow in) clocks the timer once, whatever
//!   its enable and source; the borrow out of that clock reaches a linked
//!   successor as usual. The bit does not stay set.
//!
//! drhelius's lynx-tests (MIT, https://github.com/drhelius/lynx-tests,
//! lynx-timers.md and the timers/timers2 carts) measured these on hardware.
//! - A running unlinked timer is represented by `expire`, the tick of its
//!   next underflow; its count is derived from `expire` and `now`. Only
//!   timers whose underflow is observable right away (an enabled
//!   interrupt, a linked timer behind them, or timers 0 and 2, the display
//!   timers) are events; the others ("quiet": typically timer 4, the UART
//!   baud clock, which may tick every 2 us) are caught up in closed form
//!   when read or written, so they cost nothing per frame.
//!
//! Simplifications (none affects known games; integration may revisit):
//!
//! - The audio channels' timers ($FD24-$FD27 etc.) are stored registers
//!   only: they are not clocked, so the tail of chain B (timer 7 -> audio
//!   0 -> 1 -> 2 -> 3 -> timer 1) is cut. Timer 1 linked never counts.
//! - CTLB borrow-in/out and last clock read 0.
//! - UART: transmitter always ready and empty (SERCTL reads $A0), nothing
//!   received; with TXINTEN set the serial interrupt (INTSET bit 4) is held
//!   on, level triggered as on hardware. Timer 4 never sets bit 4 itself.
//! - DISPCTL flip (bit 1) is ignored (M1).

/// Mikey's clock type: 16 MHz ticks since `Lynx.tick_base` (core/lynx.zig
/// rebases every clock by a multiple of 2^20 before it nears 2^31, so the
/// timer prescaler edges, the refresh grid and the bus's 16-tick round
/// robin keep their phase; 32-bit on the badge's 32-bit core).
pub const Tick = u32;
pub const ticks_never: Tick = ~@as(Tick, 0);

/// Register offsets ($FD00 + x).
pub const Reg = struct {
    pub const tim0bkup: u8 = 0x00;
    pub const tim2bkup: u8 = 0x08;
    pub const intrst: u8 = 0x80;
    pub const intset: u8 = 0x81;
    pub const magrdy0: u8 = 0x84;
    pub const magrdy1: u8 = 0x85;
    pub const audin: u8 = 0x86;
    pub const sysctl1: u8 = 0x87;
    pub const mikeyhrev: u8 = 0x88;
    pub const mikeysrev: u8 = 0x89;
    pub const iodir: u8 = 0x8A;
    pub const iodat: u8 = 0x8B;
    pub const serctl: u8 = 0x8C;
    pub const serdat: u8 = 0x8D;
    pub const sdoneack: u8 = 0x90;
    pub const cpusleep: u8 = 0x91;
    pub const dispctl: u8 = 0x92;
    pub const pbkup: u8 = 0x93;
    pub const dispadrl: u8 = 0x94;
    pub const dispadrh: u8 = 0x95;
    pub const mtest0: u8 = 0x9C;
    pub const mtest1: u8 = 0x9D;
    pub const mtest2: u8 = 0x9E;
    pub const green0: u8 = 0xA0;
    pub const bluered0: u8 = 0xB0;
};

/// CTLA bits.
pub const Ctla = struct {
    pub const irq_enable: u8 = 0x80;
    pub const reset_done: u8 = 0x40;
    pub const reload: u8 = 0x10;
    pub const count: u8 = 0x08;
    pub const clock_mask: u8 = 0x07;
    pub const linked: u8 = 0x07;
};

/// CTLB bits.
pub const Ctlb = struct {
    pub const done: u8 = 0x08;
    pub const last_clock: u8 = 0x04;
    pub const borrow_in: u8 = 0x02;
    pub const borrow_out: u8 = 0x01;
};

/// SERCTL read: transmitter buffer empty and transmitter done.
pub const serctl_idle: u8 = 0x80 | 0x20;

/// The timer clocked by timer i's underflow when it is linked (0xFF: none,
/// or the audio chain, which is not modelled).
const link_next = [8]u8{ 2, 3, 4, 5, 0xFF, 7, 0xFF, 0xFF };

/// Timer 2 counts 101..0 on the visible lines (101 = the top line).
pub const last_visible_line: u8 = 101;

/// Bus time the CPU loses to video DMA and DRAM refresh (lynx-tests
/// lynx-video-timing.md and lynx-sprite-performance.md, from hardware
/// captures), each charged when it happens (an event, like the timers'):
///
/// - On a visible line with DISPCTL bit 0, ten 8-byte display bursts of
///   about 28 ticks of RAM ownership, 192 ticks apart, the first
///   `dma_first_burst` ticks into the line's 1,920-tick active transfer
///   (which ends the line); the top line also has a prefetch burst at its
///   start (the timer 0 borrow). The bursts cover refresh.
/// - Everywhere else (blank lines, video DMA off, timer 0 stopped), a
///   4-tick refresh every 256 ticks, on the grid `refresh_phase` mod 256.
///
/// Lynx `steal` collects them; core/lynx.zig adds them to the clock after
/// the instruction during which they fell (the CPU runs about 11% fewer
/// cycles per visible frame, as on hardware); the timers are not affected.
/// Sprite runs see them the same way (a sprite run's bus time is extended
/// by the DMA that falls inside it).
pub const dma_ticks_per_burst: u32 = 28;
pub const dma_bursts_per_line: u8 = 10;
pub const dma_ticks_per_line: u32 = dma_bursts_per_line * dma_ticks_per_burst;
pub const dma_burst_spacing: Tick = 192;
pub const dma_active_ticks: Tick = 1920;
/// Ticks from the start of a group's LCD transfer to its DMA burst (8-12
/// in the captures).
pub const dma_first_burst: Tick = 10;
pub const refresh_ticks: u32 = 4;
pub const refresh_period: Tick = 256;
pub const refresh_phase: Tick = 0;

/// Count of timer 2 at which DISPADR is latched for the next frame: the
/// start of the third vertical blank line (timer 2 reloads to 104 at the
/// borrow that starts vertical blank; lynx-tests lynx-video-timing.md;
/// Felix latches one line later).
pub const dispadr_latch_line: u8 = 102;

pub const Timer = struct {
    backup: u8 = 0,
    ctla: u8 = 0,
    /// The count while the timer is stopped or linked; for a running
    /// unlinked timer see `expire`.
    value: u8 = 0,
    done: bool = false,
    /// Tick of the next underflow of a running unlinked timer, else never.
    expire: Tick = ticks_never,

    fn shift(t: *const Timer) u5 {
        return @intCast(4 + @as(u32, t.ctla & Ctla.clock_mask));
    }
    fn linked(t: *const Timer) bool {
        return t.ctla & Ctla.clock_mask == Ctla.linked;
    }
    /// Counting: enabled, and not a one-shot that has finished.
    fn running(t: *const Timer) bool {
        return t.ctla & Ctla.count != 0 and (t.ctla & Ctla.reload != 0 or !t.done);
    }
    fn free_running(t: *const Timer) bool {
        return t.running() and !t.linked();
    }
};

/// The first refresh grid point at or after tick `t`.
fn refresh_at_or_after(t: Tick) Tick {
    const base = (t -| refresh_phase + refresh_period - 1) / refresh_period * refresh_period;
    return base + refresh_phase;
}

pub const Mikey = struct {
    timers: [8]Timer = @splat(.{}),
    /// Pending interrupt bits (INTSET/INTRST read), without the UART level.
    intset: u8 = 0,
    /// Mikey's clock (= Lynx.ticks after every sync).
    now: Tick = 0,
    /// Earliest of `timer_event` and `dma_next`.
    next_event: Tick = 0,
    /// Earliest `expire` of the timers that are events.
    timer_event: Tick = ticks_never,
    /// Tick of the next display burst or refresh (see `dma_ticks_per_burst`).
    dma_next: Tick = 0,
    /// Display bursts left on the current visible line (0: refresh).
    dma_bursts_left: u8 = 0,
    /// Tick at which the current line ends (timer 0's period from its
    /// start), for the refresh after the last burst.
    dma_line_end: Tick = 0,
    /// Bit i set: timer i is an event (see the file comment).
    event_mask: u8 = 0,

    /// GREEN0..15 ($FDA0-$FDAF), low nibble used.
    green: [16]u8 = @splat(0),
    /// BLUERED0..15 ($FDB0-$FDBF): blue in the high nibble, red in the low.
    bluered: [16]u8 = @splat(0),
    /// DISPADR ($FD94/$FD95) as written (bits 1-0 ignored by the hardware).
    dispadr: u16 = 0,
    /// DISPADR as latched for the frame being displayed.
    dispadr_latched: u16 = 0,
    dispctl: u8 = 0,
    pbkup: u8 = 0,
    iodir: u8 = 0,
    iodat: u8 = 0,
    /// Reset value: power on, strobe low.
    sysctl1: u8 = 0x02,
    serctl: u8 = 0,
    /// Set when the sprite engine finished (CPUSLEEP woken by Suzy),
    /// cleared by a write to SDONEACK; while set, CPUSLEEP does nothing
    /// (Epyx CPU chapter: acknowledge Suzy before sleeping again; Felix).
    suzy_done: bool = false,
    /// Underflows of timer 2 (vertical blank starts) since reset.
    vblank_count: u32 = 0,
    /// Bus ticks taken from the CPU by video DMA and refresh, not yet
    /// charged (core/lynx.zig adds them to the clock).
    steal: u32 = 0,
    /// A display burst fell in `steal`: the CPU's DRAM page is lost.
    steal_burst: bool = false,
    /// Every other register as last written (audio, stereo, attenuation,
    /// MTEST): read back as stored.
    regs: [256]u8 = @splat(0),

    pub fn reset(m: *Mikey, now: Tick) void {
        m.* = .{ .now = now };
        m.dma_next = refresh_at_or_after(now);
        m.next_event = m.dma_next;
    }

    /// Interrupt bits as INTSET reads them (the UART's level included).
    pub fn pending(m: *const Mikey) u8 {
        return m.intset | (if (m.serctl & 0x80 != 0) @as(u8, 0x10) else 0);
    }

    /// The CPU's IRQ input.
    pub fn irq_line(m: *const Mikey) bool {
        return m.pending() != 0;
    }

    /// Advance the clock by `dt` ticks, running the timer events due.
    pub inline fn advance(m: *Mikey, dt: Tick) void {
        m.now += dt;
        if (m.now >= m.next_event) m.run_events();
    }

    /// `advance` to tick `t`, with the common case in line: only video
    /// DMA or refresh events due (the same steps as `run_events` for them).
    pub inline fn advance_to(m: *Mikey, t: Tick) void {
        m.now = t;
        if (t < m.next_event) return;
        if (m.timer_event <= t) return m.run_events();
        while (m.dma_next <= t) m.dma_event(m.dma_next);
        m.next_event = @min(m.timer_event, m.dma_next);
    }

    fn run_events(m: *Mikey) void {
        while (m.next_event <= m.now) {
            const t_ev = m.next_event;
            if (m.dma_next == t_ev) {
                m.dma_event(t_ev);
                m.next_event = @min(m.timer_event, m.dma_next);
                continue;
            }
            var i: u3 = 0;
            while (true) : (i += 1) {
                if (m.event_mask & (@as(u8, 1) << i) != 0 and m.timers[i].expire == t_ev) break;
                if (i == 7) unreachable;
            }
            m.expire_timer(i, t_ev);
            m.reschedule();
        }
    }

    /// Underflow of a running unlinked timer at its `expire` tick `at`.
    fn expire_timer(m: *Mikey, i: u3, at: Tick) void {
        const t = &m.timers[i];
        t.value = 0;
        t.expire = ticks_never;
        m.underflow(i, at);
        if (t.free_running()) t.expire = at + ((@as(Tick, t.value) + 1) << t.shift());
    }

    /// Borrow out of timer i: done, interrupt, reload, clock the next one.
    fn underflow(m: *Mikey, i: u3, at: Tick) void {
        const t = &m.timers[i];
        t.done = t.ctla & Ctla.reset_done == 0;
        if (t.ctla & Ctla.irq_enable != 0 and i != 4) m.intset |= @as(u8, 1) << i;
        if (t.ctla & Ctla.reload != 0) t.value = t.backup;
        if (i == 2) m.vblank_count +%= 1;
        const n = link_next[i];
        if (n != 0xFF) m.borrow_in(@intCast(n), at);
        if (i == 0) m.line_start(at);
    }

    /// Timer 0 borrowed: a display line starts (timer 2 has just counted).
    /// Latch DISPADR on the third vertical blank line, and charge the bus
    /// time video DMA (visible lines with DISPCTL bit 0) or DRAM refresh
    /// (otherwise) takes from the CPU over this line (`steal`).
    fn line_start(m: *Mikey, at: Tick) void {
        const line = m.timers[2].value;
        if (line == dispadr_latch_line) m.dispadr_latched = m.dispadr;
        const t0 = &m.timers[0];
        const len = (@as(Tick, t0.backup) + 1) << t0.shift();
        m.dma_line_end = at + len;
        if (m.dispctl & 1 != 0 and line <= last_visible_line) {
            if (line == last_visible_line) {
                m.steal += dma_ticks_per_burst;
                m.steal_burst = true;
            }
            m.dma_bursts_left = dma_bursts_per_line;
            m.dma_next = at + (len -| dma_active_ticks) + dma_first_burst;
        } else if (m.dma_bursts_left != 0) {
            m.dma_bursts_left = 0;
            m.dma_next = refresh_at_or_after(at);
        }
    }

    /// A display burst or a refresh is due at `at`.
    pub fn dma_event(m: *Mikey, at: Tick) void {
        if (m.dma_bursts_left != 0 and m.dispctl & 1 != 0) {
            m.steal += dma_ticks_per_burst;
            m.steal_burst = true;
            m.dma_bursts_left -= 1;
            // After the last burst, refresh resumes past the line's end
            // (the next line's start reschedules first).
            m.dma_next = if (m.dma_bursts_left != 0) at + dma_burst_spacing else refresh_at_or_after(m.dma_line_end + 1);
        } else {
            m.dma_bursts_left = 0;
            m.steal += refresh_ticks;
            m.dma_next = refresh_at_or_after(at + 1);
        }
    }

    /// A clock from the previous timer of the chain.
    fn borrow_in(m: *Mikey, i: u3, at: Tick) void {
        const t = &m.timers[i];
        if (!t.linked() or !t.running()) return;
        if (t.value > 0) {
            t.value -= 1;
        } else {
            m.underflow(i, at);
        }
    }

    /// Is timer i's underflow observable at once (it must be an event)?
    fn needs_event(m: *const Mikey, i: u3) bool {
        const t = &m.timers[i];
        if (i == 0 or i == 2) return true;
        if (t.ctla & Ctla.irq_enable != 0 and i != 4) return true;
        const n = link_next[i];
        if (n == 0xFF) return false;
        const nt = &m.timers[n];
        return nt.linked() and nt.ctla & Ctla.count != 0;
    }

    fn reschedule(m: *Mikey) void {
        var next = ticks_never;
        var mask: u8 = 0;
        for (&m.timers, 0..) |*t, k| {
            const i: u3 = @intCast(k);
            if (t.expire == ticks_never) continue;
            if (!m.needs_event(i)) continue;
            mask |= @as(u8, 1) << i;
            next = @min(next, t.expire);
        }
        m.event_mask = mask;
        m.timer_event = next;
        m.next_event = @min(next, m.dma_next);
    }

    /// Catch a quiet timer up to `now` in closed form.
    fn settle(m: *Mikey, i: u3) void {
        const t = &m.timers[i];
        if (t.expire > m.now) return;
        // Underflows at expire, expire + p, ... up to now; a quiet timer has
        // no interrupt and no linked successor, so only the end state shows.
        t.done = t.ctla & Ctla.reset_done == 0;
        if (t.ctla & Ctla.reload == 0 and t.done) {
            t.value = 0;
            t.expire = ticks_never;
        } else {
            // Reloading, or a one-shot held running by RESET_DONE (its
            // period is then one source clock: it stays at 0).
            const v: Tick = if (t.ctla & Ctla.reload != 0) t.backup else 0;
            const p = (v + 1) << t.shift();
            const n = (m.now - t.expire) / p + 1;
            t.expire += n * p;
            t.value = @intCast(v);
        }
    }

    fn settle_all(m: *Mikey) void {
        for (0..8) |k| m.settle(@intCast(k));
    }

    /// The count of timer i now.
    fn count(m: *Mikey, i: u3) u8 {
        m.settle(i);
        const t = &m.timers[i];
        if (t.expire == ticks_never) return t.value;
        const s = t.shift();
        const next_edge = ((m.now >> s) + 1) << s;
        return @intCast((t.expire - next_edge) >> s);
    }

    /// Stop the clock-derived representation: `value` becomes the count.
    fn freeze(m: *Mikey, i: u3) void {
        const t = &m.timers[i];
        if (t.expire == ticks_never) return;
        t.value = m.count(i);
        t.expire = ticks_never;
    }

    /// Restart the clock-derived representation if the timer runs unlinked:
    /// the next edge after `now`, then `value` more edges.
    fn thaw(m: *Mikey, i: u3) void {
        const t = &m.timers[i];
        if (!t.free_running()) return;
        const s = t.shift();
        const next_edge = ((m.now >> s) + 1) << s;
        t.expire = next_edge + (@as(Tick, t.value) << s);
    }

    fn timer_write(m: *Mikey, addr: u8, v: u8) void {
        const i: u3 = @intCast(addr >> 2);
        m.settle_all();
        m.freeze(i);
        const t = &m.timers[i];
        switch (addr & 3) {
            0 => t.backup = v,
            1 => {
                t.ctla = v;
                if (v & Ctla.reset_done != 0) t.done = false;
            },
            2 => t.value = v,
            else => {
                t.done = v & Ctlb.done != 0 and t.ctla & Ctla.reset_done == 0;
                // Software borrow in: one clock now.
                if (v & Ctlb.borrow_in != 0) {
                    if (t.value > 0) t.value -= 1 else m.underflow(i, m.now);
                }
            },
        }
        m.thaw(i);
        m.reschedule();
    }

    fn timer_read(m: *Mikey, addr: u8) u8 {
        const i: u3 = @intCast(addr >> 2);
        const t = &m.timers[i];
        return switch (addr & 3) {
            0 => t.backup,
            1 => t.ctla,
            2 => m.count(i),
            // DONE only: the borrow and last-clock bits are momentary
            // hardware states that read 0 between clocks (lynx-tests timers
            // CTLB RD/WR reads $00 after a reset, $08 after a done write).
            else => blk: {
                m.settle(i);
                break :blk if (t.done) Ctlb.done else 0;
            },
        };
    }

    /// A register read at $FD00 + addr.
    pub fn read(m: *Mikey, addr: u8) u8 {
        if (addr < 0x20) return m.timer_read(addr);
        return switch (addr) {
            Reg.intrst, Reg.intset => m.pending(),
            Reg.magrdy0, Reg.magrdy1, Reg.audin => 0,
            Reg.mikeyhrev => 0x01,
            Reg.iodir => m.iodir,
            Reg.iodat => m.iodat_read(),
            Reg.serctl => serctl_idle,
            Reg.serdat => 0,
            0xA0...0xAF => m.green[addr & 0xF],
            0xB0...0xBF => m.bluered[addr & 0xF],
            else => m.regs[addr],
        };
    }

    /// IODAT as read: output lines give back what was written, inputs read
    /// their pins: external power (bit 0) present, no expansion (bit 2) and
    /// rest (bit 3) low, AUDIN (bit 4) low; bits 7-5 are not connected.
    /// Epyx appendix ("only the lines that are set to input are valid") and
    /// Felix's ParallelPort for the input levels.
    pub fn iodat_read(m: *const Mikey) u8 {
        return (m.iodir & m.iodat & 0x1F) | (~m.iodir & 0x01);
    }

    /// A register write at $FD00 + addr. The port strobes (SYSCTL1) and
    /// CPUSLEEP side effects are the bus's; this stores the values.
    pub fn write(m: *Mikey, addr: u8, v: u8) void {
        if (addr < 0x20) return m.timer_write(addr, v);
        m.regs[addr] = v;
        switch (addr) {
            Reg.intrst => m.intset &= ~v,
            Reg.intset => m.intset |= v,
            Reg.sysctl1 => m.sysctl1 = v,
            Reg.iodir => m.iodir = v,
            Reg.iodat => m.iodat = v,
            Reg.serctl => m.serctl = v,
            Reg.sdoneack => m.suzy_done = false,
            Reg.dispctl => m.dispctl = v,
            Reg.pbkup => m.pbkup = v,
            Reg.dispadrl => m.dispadr = (m.dispadr & 0xFF00) | v,
            Reg.dispadrh => m.dispadr = (m.dispadr & 0x00FF) | @as(u16, v) << 8,
            // MTEST2 bit 0 (VBLANKEF): load the display address counter now.
            Reg.mtest2 => if (v & 1 != 0) {
                m.dispadr_latched = m.dispadr;
            },
            // GREEN is four bits wide (lynx-tests memio: reads back v & $0F).
            0xA0...0xAF => m.green[addr & 0xF] = v & 0x0F,
            0xB0...0xBF => m.bluered[addr & 0xF] = v,
            else => {},
        }
    }

    /// Move every clock value back by `d` (a multiple of 2^20, at most
    /// `now`): Lynx.rebase. The quiet timers are caught up first (as any
    /// read would), so every `expire` left is in the future; the only
    /// value that may lie further back, `dma_line_end`, clamps at 0 and is
    /// not read before the next line start sets it.
    pub fn rebase(m: *Mikey, d: Tick) void {
        m.settle_all();
        m.now -= d;
        m.next_event -|= d;
        if (m.timer_event != ticks_never) m.timer_event -|= d;
        m.dma_next -|= d;
        m.dma_line_end -|= d;
        for (&m.timers) |*t| {
            if (t.expire != ticks_never) t.expire -|= d;
        }
    }

    /// Ticks from now to the next timer event (ticks_never if none).
    pub fn ticks_to_event(m: *const Mikey) Tick {
        if (m.timer_event == ticks_never) return ticks_never;
        return m.timer_event - m.now;
    }

    /// Timer i's count without side effects on the catch-up state, for
    /// tests and diagnostics.
    pub fn timer_count(m: *Mikey, i: u3) u8 {
        return m.count(i);
    }
};
