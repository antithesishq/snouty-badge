//! Lynx memory map (SPEC.md sections 3 and 20; PLAN.md "Frozen for M1"):
//! the CPU's bus functions over `*Lynx` (bound into `Lynx` as `fetch`,
//! `read`, `write`, `irq_line`, so `cpu65.Cpu(Lynx)` calls them), the tick
//! accounting, the MAPCTL overlays and the cart port.
//!
//! - `$0000-$FBFF` RAM. The read/write fast path is that single compare.
//! - `$FC00-$FCFF` Suzy unless MAPCTL bit 0; `$FCB0-$FCB3` (JOYSTICK,
//!   SWITCHES, RCART0, RCART1) are served here, the rest by core/suzy.zig.
//! - `$FD00-$FDFF` Mikey unless MAPCTL bit 1 (core/mikey.zig; SYSCTL1's
//!   cart strobe and CPUSLEEP have their effects here).
//! - `$FE00-$FFF7` boot ROM unless MAPCTL bit 2: reads give 0x00 (never ROM
//!   bytes; core/lynx.zig traps the two ROM entry points before they run).
//! - `$FFF8` always RAM, `$FFF9` MAPCTL always.
//! - `$FFFA-$FFFF` vectors unless MAPCTL bit 3: `boot.vector_*`.
//! - Writes to ROM and vector space go to the RAM underneath (the boot
//!   ROM's own clear loop relies on it).
//!
//! Ticks (16 MHz, SPEC.md 3 and 20): an opcode or operand fetch takes 4
//! ticks in page mode, 5 otherwise; any other RAM/ROM/vector or MAPCTL
//! access 5, an internal CPU cycle (`dummy`) 5, Mikey reads and writes 5
//! (timer and audio registers plus their wait, below), Suzy writes 5, Suzy
//! reads 9 (the 9-15 range of the CPU chapter: one value), RCART reads 15.
//!
//! Page mode, as measured by drhelius's lynx-tests (MIT; lynx-page-mode.md,
//! the page-mode cart): a fetch is a 4-tick page-mode cycle when MAPCTL bit
//! 7 is clear, the instruction stream is open and the address is not at a
//! 16-byte boundary ($xxx0). Any data read or write closes the stream (the
//! next fetch is a normal 5-tick cycle that reopens it); a fetch at $xxx0
//! is normal but keeps it open. Internal cycles (`dummy`: implied
//! instructions' second cycle, indexing, RMW re-reads, stack dummies) leave
//! it open, as does a taken branch with displacement 0 (cpu65.zig issues a
//! `read` for a taken branch to another address, which closes it). A video
//! DMA burst closes it, a refresh does not (core/lynx.zig).
//!
//! Mikey's timer and audio registers ($FD00-$FD3F) are served round robin:
//! the 16 units (timers 0-7, audio 0-3 at slots 8-11) each own one tick of
//! a 16-tick cycle, and an access waits for its unit's turn: it completes
//! at a tick t with (t - slot) mod 16 == `timer_slot_phase` (at least 5
//! ticks). lynx-tests timers2 measures it: 64 `LDA TIMnBKUP` take $83/$84
//! us (32 ticks per LDA abs: 18 plus the wait), writes $83/$84 for timers
//! 0-1 and $84 for 2-7, against $4F/$50 for RAM, INTSET/INTRST and SERCTL
//! (18 ticks plus refresh). Gearlynx (GPL, read for behaviour only, nothing
//! copied) models the same wait. Internal cycles at those addresses do not
//! wait.
//!
//! Cart port (Epyx cart chapter, SPEC.md 3): the block number is an 8-bit
//! shift register clocked on each 0 -> 1 edge of SYSCTL1 bit 0 with IODAT
//! bit 1 as the data, MSB first; while the strobe is high the ripple
//! counter is held at 0; every RCART0/RCART1 read or write advances it,
//! masked to the block size (the cart wires 9, 10 or 11 of its 11 bits).
//! Bank 1 (RCART1) is absent: it reads 0xFF.
const lynx_mod = @import("lynx.zig");
const Lynx = lynx_mod.Lynx;
const cart_mod = @import("cart.zig");
const boot = @import("boot.zig");
const mikey_mod = @import("mikey.zig");

pub const suzy_base: u16 = 0xFC00;
pub const mikey_base: u16 = 0xFD00;
pub const rom_base: u16 = 0xFE00;
pub const mapctl_addr: u16 = 0xFFF9;

/// MAPCTL bits: set = the overlay is off and RAM shows through.
pub const Mapctl = struct {
    pub const suzy_off: u8 = 0x01;
    pub const mikey_off: u8 = 0x02;
    pub const rom_off: u8 = 0x04;
    pub const vectors_off: u8 = 0x08;
    pub const sequential_off: u8 = 0x80;
};

/// Tick costs.
pub const Ticks = struct {
    pub const fetch: u8 = 4;
    pub const fetch_full: u8 = 5;
    pub const ram: u64 = 5;
    pub const mikey: u64 = 5;
    pub const suzy_write: u64 = 5;
    pub const suzy_read: u64 = 9;
    pub const rcart: u64 = 15;
};

/// Suzy addresses the bus serves itself.
pub const joystick: u8 = 0xB0;
pub const switches: u8 = 0xB1;
pub const rcart0: u8 = 0xB2;
pub const rcart1: u8 = 0xB3;
/// SPRSYS: bit 0 (sprite working) also covers a run paused by an
/// interrupt (core/lynx.zig `sprite_left`).
pub const sprsys: u8 = 0x92;

/// SWITCHES bits 1 and 2 (cart 0/1 I/O inactive): read set, as Felix
/// reads them on a normal cart.
pub const switches_cart_inactive: u8 = 0x06;

pub const CartPort = struct {
    /// The block shift register (the cart's high address bits).
    block: u8 = 0,
    /// The ripple counter (byte within the block).
    counter: u32 = 0,
    /// SYSCTL1 bit 0 as last written.
    strobe: bool = false,

    /// A SYSCTL1 write: `high` is bit 0, `data` IODAT bit 1.
    pub fn set_strobe(p: *CartPort, high: bool, data: bool) void {
        if (high and !p.strobe) p.block = (p.block << 1) | @intFromBool(data);
        if (high) p.counter = 0;
        p.strobe = high;
    }

    /// Advance the counter (not while the strobe holds it at 0).
    pub inline fn step(p: *CartPort, c: *const cart_mod.Cart) void {
        if (!p.strobe) p.counter = (p.counter + 1) & (c.block_size - 1);
    }

    /// RCART0: the byte at (block, counter), then the counter advances.
    pub fn read0(p: *CartPort, c: *const cart_mod.Cart) u8 {
        const b = c.read(p.block, p.counter);
        p.step(c);
        return b;
    }
};

/// The cart port as `boot.post_boot` / `boot.decrypt_frame` read it.
pub const PortReader = struct {
    port: *CartPort,
    cart: *const cart_mod.Cart,

    pub fn read_byte(r: *PortReader) u8 {
        return r.port.read0(r.cart);
    }
};

// ---------------------------------------------------------------------------
// The CPU's bus

pub inline fn fetch(l: *Lynx, addr: u16) u8 {
    l.ticks += if (l.stream_open and addr & 0xF != 0) l.fetch_ticks else Ticks.fetch_full;
    l.stream_open = true;
    if (addr < suzy_base) return l.ram[addr];
    return high_read(l, addr, false);
}

pub inline fn read(l: *Lynx, addr: u16) u8 {
    l.stream_open = false;
    if (addr < suzy_base) {
        l.ticks += Ticks.ram;
        return l.ram[addr];
    }
    return high_read(l, addr, true);
}

/// An internal CPU cycle (cpu65.zig `dummy`): a full 5-tick cycle that no
/// device sees and that leaves the page-mode stream as it is.
pub inline fn dummy(l: *Lynx, addr: u16) void {
    _ = addr;
    l.ticks += Ticks.ram;
}

pub inline fn write(l: *Lynx, addr: u16, v: u8) void {
    l.stream_open = false;
    if (addr < suzy_base) {
        l.ticks += Ticks.ram;
        l.ram[addr] = v;
        return;
    }
    high_write(l, addr, v);
}

pub inline fn irq_line(l: *Lynx) bool {
    return l.mikey.irq_line();
}

/// A read at $FC00-$FFFF. `charge`: false for a fetch (already charged).
fn high_read(l: *Lynx, addr: u16, charge: bool) u8 {
    const m = l.mapctl;
    const lo: u8 = @truncate(addr);
    switch (addr >> 8) {
        0xFC => if (m & Mapctl.suzy_off == 0) {
            if (charge) l.ticks += if (lo == rcart0 or lo == rcart1) Ticks.rcart else Ticks.suzy_read;
            return suzy_read(l, lo);
        },
        0xFD => if (m & Mapctl.mikey_off == 0) {
            if (charge) l.ticks += mikey_ticks(l.ticks, lo);
            sync_mikey(l);
            return l.mikey.read(lo);
        },
        else => {
            if (charge) l.ticks += Ticks.ram;
            if (addr == mapctl_addr) return m;
            if (addr >= 0xFFFA) {
                if (m & Mapctl.vectors_off == 0) return vector_byte(addr);
            } else if (addr < 0xFFF8 and m & Mapctl.rom_off == 0) {
                return 0x00;
            }
            return l.ram[addr];
        },
    }
    if (charge) l.ticks += Ticks.ram;
    return l.ram[addr];
}

fn high_write(l: *Lynx, addr: u16, v: u8) void {
    const m = l.mapctl;
    const lo: u8 = @truncate(addr);
    switch (addr >> 8) {
        0xFC => if (m & Mapctl.suzy_off == 0) {
            l.ticks += Ticks.suzy_write;
            suzy_write(l, lo, v);
            return;
        },
        0xFD => if (m & Mapctl.mikey_off == 0) {
            l.ticks += mikey_ticks(l.ticks, lo);
            mikey_write(l, lo, v);
            return;
        },
        else => if (addr == mapctl_addr) {
            l.ticks += Ticks.ram;
            set_mapctl(l, v);
            return;
        },
    }
    l.ticks += Ticks.ram;
    l.ram[addr] = v;
}

/// A Mikey register access starting at tick `t`: 5 ticks, after waiting
/// for the unit's turn when it is a timer or audio register (see the file
/// comment).
pub inline fn mikey_ticks(t: u64, lo: u8) u64 {
    if (lo >= 0x40) return Ticks.mikey;
    const slot: u64 = if (lo < 0x20) lo >> 2 else 8 + ((lo - 0x20) >> 3);
    return ((slot +% timer_slot_phase -% t -% Ticks.mikey) & 15) + Ticks.mikey;
}

/// The phase of the timer round robin against the bus clock: an access to
/// unit n completes at a tick t with (t - n) mod 16 == `timer_slot_phase`.
/// Fitted to lynx-tests timers2 (reads and writes of each timer, the
/// phase rows) with the 1 us clock edges at multiples of 16 ticks.
pub const timer_slot_phase: u64 = 0;

pub fn set_mapctl(l: *Lynx, v: u8) void {
    l.mapctl = v;
    l.fetch_ticks = if (v & Mapctl.sequential_off != 0) Ticks.fetch_full else Ticks.fetch;
}

/// The boot ROM's vector bytes at $FFFA-$FFFF.
pub fn vector_byte(addr: u16) u8 {
    const w: u16 = switch (addr) {
        0xFFFA, 0xFFFB => boot.vector_nmi,
        0xFFFC, 0xFFFD => boot.vector_reset,
        else => boot.vector_irq,
    };
    return if (addr & 1 == 0) @truncate(w) else @truncate(w >> 8);
}

/// Bring Mikey's clock up to the bus's (timer reads see the exact count).
/// Also ends `Lynx.run_cpu`'s fast run after the current instruction (the
/// access may change Mikey's events, interrupts or DMA steal).
pub inline fn sync_mikey(l: *Lynx) void {
    l.fast_end = 0;
    l.mikey.advance(l.ticks - l.mikey.now);
}

fn suzy_read(l: *Lynx, lo: u8) u8 {
    return switch (lo) {
        joystick => joystick_byte(l.pad, l.suzy.lefthand()),
        switches => @as(u8, @intFromBool(l.pad & lynx_mod.Pad.pause != 0)) | switches_cart_inactive,
        rcart0 => l.port.read0(&l.cart),
        rcart1 => blk: {
            l.port.step(&l.cart);
            break :blk 0xFF;
        },
        // A run paused by an interrupt still reads "sprite working".
        sprsys => l.suzy.read_at(lo, l.ticks) | @intFromBool(l.sprite_left != 0),
        else => l.suzy.read_at(lo, l.ticks),
    };
}

fn suzy_write(l: *Lynx, lo: u8, v: u8) void {
    switch (lo) {
        joystick, switches => {},
        // A write strobes the cart too (RAM carts, EEPROMs: not emulated);
        // the counter advances.
        rcart0, rcart1 => l.port.step(&l.cart),
        else => l.suzy.write_at(lo, v, l.ticks),
    }
}

/// JOYSTICK from the pad word (core.Pad: the layout with LEFTHAND clear,
/// cc65 _suzy.h); LEFTHAND (SPRSYS bit 3) swaps up/down and left/right
/// (Epyx appendix; Felix swaps the same way).
pub fn joystick_byte(pad: u16, lefthand: bool) u8 {
    const b: u8 = @truncate(pad);
    if (!lefthand) return b;
    const P = lynx_mod.Pad;
    var out: u8 = b & 0x0F;
    if (pad & P.up != 0) out |= @truncate(P.down);
    if (pad & P.down != 0) out |= @truncate(P.up);
    if (pad & P.left != 0) out |= @truncate(P.right);
    if (pad & P.right != 0) out |= @truncate(P.left);
    return out;
}

fn mikey_write(l: *Lynx, lo: u8, v: u8) void {
    sync_mikey(l);
    l.mikey.write(lo, v);
    switch (lo) {
        mikey_mod.Reg.sysctl1 => l.port.set_strobe(v & 1 != 0, l.mikey.iodat & 0x02 != 0),
        mikey_mod.Reg.cpusleep => l.cpu_sleep(),
        else => {},
    }
}
