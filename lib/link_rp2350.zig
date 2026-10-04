//! lib/link.zig's port on the badge: the UART header's GPIO28 (pin 1) and
//! GPIO29 (pin 3) as SIO pins while searching and as a PIO2 UART (8N1,
//! `link.baud`) once locked. Neither OS (pin a6ce19f or upstream 5955625)
//! touches UART0, GPIO28/29 or PIO2 (pio0 is audio, pio1 the neopixels),
//! and ACCESSCTRL's reset value lets core 1 at secure level reach RESETS,
//! IO_BANK0, PADS_BANK0 and PIO2. PIO, not the UART0 block, because UART0
//! has TX fixed on GPIO28: a straight cable needs one badge to transmit on
//! GPIO29.
//!
//! Addresses and fields are from pico-sdk's rp2350 hardware_regs headers;
//! the programs are pico-examples' uart_tx and uart_rx (assembled words,
//! the receiver relocated to offset 4).
//!
//! The PIO keeps running after the cart exits (no exit hook): the transmit
//! pin stays idle-high and received bytes sit in the FIFO; the next cart to
//! use the link resets PIO2.
const std = @import("std");
const builtin = @import("builtin");
const link = @import("link.zig");
const Pin = link.Pin;

pub const is_badge = builtin.os.tag == .freestanding and (builtin.cpu.arch.isThumb() or builtin.cpu.arch.isArm());

/// What carts use: the PIO port on the badge, the null port elsewhere.
pub const Port = if (is_badge) Rp2350 else link.NullPort;

/// clk_sys: microzig's RP2350 default; neither OS changes it, and the
/// badge-bench calibration capture measured it.
pub const clk_sys_hz: u32 = 150_000_000;

/// The UART speed; both badges must agree. `link.baud` by default; the
/// test cart switches to 115200 for a Raspberry Pi Debug Probe and a
/// serial terminal. Takes effect at the next lock (link `restart`).
pub var baud: u32 = link.baud;

const gpio_a: u5 = 28;
const gpio_b: u5 = 29;

const resets_base: u32 = 0x40020000;
const resets_reset = resets_base + 0x0;
const resets_reset_done = resets_base + 0x8;
const alias_set: u32 = 0x2000;
const alias_clr: u32 = 0x3000;
const reset_pio2: u32 = 1 << 13;

const io_bank0_base: u32 = 0x40028000;
const funcsel_sio: u32 = 5;
const funcsel_pio2: u32 = 8;

const pads_bank0_base: u32 = 0x40038000;
/// IE | PDE | SCHMITT, DRIVE 2 mA (the weakest: plenty for 1 Mbaud on a
/// short cable, and it limits the current if two outputs ever meet on a
/// wire, on top of the header's 100 R per side); ISO, OD, PUE and
/// SLEWFAST clear.
const pad_value: u32 = 0x40 | 0x04 | 0x02;

const sio_base: u32 = 0xD0000000;
const sio_gpio_in = sio_base + 0x004;
const sio_gpio_out_set = sio_base + 0x018;
const sio_gpio_out_clr = sio_base + 0x020;
const sio_gpio_oe_set = sio_base + 0x038;
const sio_gpio_oe_clr = sio_base + 0x040;

const pio2_base: u32 = 0x50400000;
const pio_ctrl = pio2_base + 0x000;
const pio_fstat = pio2_base + 0x004;
const pio_fdebug = pio2_base + 0x008;
const pio_flevel = pio2_base + 0x00C;
const pio_txf0 = pio2_base + 0x010;
const pio_rxf1 = pio2_base + 0x024;
const pio_irq = pio2_base + 0x030;
const pio_instr_mem0 = pio2_base + 0x048;
const sm0 = pio2_base + 0x0C8;
const sm1 = sm0 + 0x18;
const sm_clkdiv = 0x0;
const sm_execctrl = 0x4;
const sm_shiftctrl = 0x8;
const sm_addr = 0xC;
const sm_instr = 0x10;
const sm_pinctrl = 0x14;

const fstat_txfull_sm0: u32 = 1 << 16;
const fstat_rxempty_sm1: u32 = 1 << 9;
/// `irq 4 rel` on state machine 1 raises flag 5: a framing error or break.
const irq_framing: u32 = 1 << 5;

/// Offset 0: `.side_set 1 opt`; pull side 1 [7] / set x, 7 side 0 [7] /
/// bitloop: out pins, 1 / jmp x-- bitloop [6]. Eight PIO cycles a bit.
const tx_program = [_]u16{ 0x9FA0, 0xF727, 0x6001, 0x0642 };
const tx_wrap_top = 3;
/// Offset 4: wait 0 pin 0 / set x, 7 [10] / bitloop: in pins, 1 /
/// jmp x-- bitloop [6] / jmp pin good_stop / irq 4 rel / wait 1 pin 0 /
/// jmp start / good_stop: push. Jump targets include the +4.
const rx_program = [_]u16{ 0x2020, 0xEA27, 0x4001, 0x0646, 0x00CC, 0xC014, 0x20A0, 0x0004, 0x8020 };
const rx_offset = 4;
const rx_wrap_top = rx_offset + rx_program.len - 1;

fn reg(addr: u32) *volatile u32 {
    return @ptrFromInt(addr);
}

fn gpio(pin: Pin) u5 {
    return if (pin == .a) gpio_a else gpio_b;
}

fn set_funcsel(n: u5, f: u32) void {
    reg(io_bank0_base + 8 * @as(u32, n) + 4).* = f;
}

fn set_pad(n: u5) void {
    reg(pads_bank0_base + 4 + 4 * @as(u32, n)).* = pad_value;
}

pub const Rp2350 = struct {
    pub const available = true;

    pub fn search(_: *Rp2350, drive: Pin) void {
        const d = gpio(drive);
        const l = gpio(drive.other());
        reg(pio_ctrl).* = 0; // state machines off
        reg(sio_gpio_out_set).* = @as(u32, 1) << d;
        reg(sio_gpio_oe_set).* = @as(u32, 1) << d;
        reg(sio_gpio_oe_clr).* = @as(u32, 1) << l;
        set_funcsel(d, funcsel_sio);
        set_funcsel(l, funcsel_sio);
        set_pad(d);
        set_pad(l);
    }

    pub fn read(_: *Rp2350, pin: Pin) bool {
        return (reg(sio_gpio_in).* >> gpio(pin)) & 1 != 0;
    }

    /// RP2350 erratum E9: an input pad with its pull-down enabled can hold
    /// a floating pin at ~2 V, reading high, after something drove it high
    /// (our own search drives each pin in turn). Drive the pin low for a
    /// moment, let go and read: only a line that something drives comes
    /// back high. The listen pin is an SIO input while searching.
    pub fn probe(_: *Rp2350, pin: Pin) bool {
        const bit = @as(u32, 1) << gpio(pin);
        reg(sio_gpio_out_clr).* = bit;
        reg(sio_gpio_oe_set).* = bit;
        wait_us(2);
        reg(sio_gpio_oe_clr).* = bit;
        wait_us(5);
        return reg(sio_gpio_in).* & bit != 0;
    }

    pub fn uart_start(_: *Rp2350, tx: Pin) void {
        start(gpio(tx), gpio(tx.other()));
    }

    pub fn uart_put(_: *Rp2350, byte: u8) bool {
        return put(byte);
    }

    pub fn uart_get(_: *Rp2350) ?u8 {
        return get();
    }

    pub fn take_framing_errors(_: *Rp2350) u32 {
        if (reg(pio_irq).* & irq_framing == 0) return 0;
        reg(pio_irq).* = irq_framing;
        return 1;
    }
};

fn put(byte: u8) bool {
    if (reg(pio_fstat).* & fstat_txfull_sm0 != 0) return false;
    reg(pio_txf0).* = byte;
    return true;
}

fn get() ?u8 {
    if (reg(pio_fstat).* & fstat_rxempty_sm1 != 0) return null;
    return @truncate(reg(pio_rxf1).* >> 24);
}

/// The UART: transmit on GPIO `t`, receive on GPIO `r` (the same pin for
/// the self test).
fn start(t: u32, r: u32) void {
    reg(resets_reset + alias_set).* = reset_pio2;
    reg(resets_reset + alias_clr).* = reset_pio2;
    while (reg(resets_reset_done).* & reset_pio2 == 0) {}

    for (tx_program, 0..) |w, i| reg(pio_instr_mem0 + 4 * @as(u32, @intCast(i))).* = w;
    for (rx_program, 0..) |w, i| reg(pio_instr_mem0 + 4 * @as(u32, @intCast(rx_offset + i))).* = w;

    // clk_sys / (8 * baud) in 16.8 fixed point (18.75 at 1 Mbaud).
    const div: u32 = @intCast(@as(u64, clk_sys_hz) * 256 / (8 * @as(u64, baud)));
    const clkdiv = (div >> 8) << 16 | (div & 0xFF) << 8;

    // SM0 transmits: side-set (optional, 1 pin) and OUT on tx; SET on
    // tx to drive it high and make it an output before starting.
    reg(sm0 + sm_clkdiv).* = clkdiv;
    reg(sm0 + sm_execctrl).* = 1 << 30 | tx_wrap_top << 12 | 0 << 7;
    reg(sm0 + sm_shiftctrl).* = 1 << 30 | 1 << 19 | 1 << 18; // join TX, shift right
    reg(sm0 + sm_pinctrl).* = 2 << 29 | 1 << 26 | 1 << 20 | t << 10 | t << 5 | t;
    reg(sm0 + sm_instr).* = 0xE001; // set pins, 1
    reg(sm0 + sm_instr).* = 0xE081; // set pindirs, 1
    reg(sm0 + sm_instr).* = 0x0000; // jmp 0

    // SM1 receives: IN and JMP pin on rx.
    reg(sm1 + sm_clkdiv).* = clkdiv;
    reg(sm1 + sm_execctrl).* = r << 24 | rx_wrap_top << 12 | rx_offset << 7;
    reg(sm1 + sm_shiftctrl).* = 1 << 31 | 1 << 18; // join RX, shift right
    reg(sm1 + sm_pinctrl).* = r << 15;
    reg(sm1 + sm_instr).* = rx_offset; // jmp 4

    reg(pio_irq).* = 0xFF;
    reg(pio_ctrl).* = 0x3 << 8 | 0x3 << 4; // restart clock dividers and SMs
    reg(pio_ctrl).* = 0x3; // enable SM0 and SM1

    // Hand the pins over: tx was SIO-driven high and PIO now drives it
    // high too, so the line never glitches low.
    set_funcsel(@intCast(t), funcsel_pio2);
    set_funcsel(@intCast(r), funcsel_pio2);
    reg(sio_gpio_oe_clr).* = @as(u32, 1) << @intCast(t) | @as(u32, 1) << @intCast(r);
}

/// Registers worth a look when the link misbehaves.
pub const Regs = struct {
    ctrl: u32,
    fstat: u32,
    fdebug: u32,
    flevel: u32,
    /// Program counters: SM0 (transmit) 0..3, SM1 (receive) 4..12.
    pc0: u32,
    pc1: u32,
    irq: u32,
    resets_pio2_held: bool,
    /// IO_BANK0 GPIO_STATUS and GPIO_CTRL, PADS_BANK0 for GPIO28, GPIO29.
    status: [2]u32,
    ctrl_pins: [2]u32,
    pads: [2]u32,
};

pub fn regs() Regs {
    return .{
        .ctrl = reg(pio_ctrl).*,
        .fstat = reg(pio_fstat).*,
        .fdebug = reg(pio_fdebug).*,
        .flevel = reg(pio_flevel).*,
        .pc0 = reg(sm0 + sm_addr).*,
        .pc1 = reg(sm1 + sm_addr).*,
        .irq = reg(pio_irq).*,
        .resets_pio2_held = reg(resets_reset).* & reset_pio2 != 0,
        .status = .{ reg(io_bank0_base + 8 * @as(u32, gpio_a)).*, reg(io_bank0_base + 8 * @as(u32, gpio_b)).* },
        .ctrl_pins = .{ reg(io_bank0_base + 8 * @as(u32, gpio_a) + 4).*, reg(io_bank0_base + 8 * @as(u32, gpio_b) + 4).* },
        .pads = .{ reg(pads_bank0_base + 4 + 4 * @as(u32, gpio_a)).*, reg(pads_bank0_base + 4 + 4 * @as(u32, gpio_b)).* },
    };
}

pub const SelfTest = struct {
    pub const pattern = [4]u8{ 0x55, 0xA5, 0x00, 0xFF };
    got: [4]u8 = @splat(0),
    n: u8 = 0,
    /// Falling edges SIO saw on the pin while the bytes went out: zero
    /// means the transmitter never moved the pad.
    edges: u32 = 0,
    framing: bool = false,
    /// The pin read back while SIO drove it low, then high: 0 and 1 if
    /// SIO, IO_BANK0 and the pad work at all.
    sio_low: bool = true,
    sio_high: bool = false,
    regs: Regs = undefined,

    pub fn ok(t: *const SelfTest) bool {
        return t.n == 4 and std.mem.eql(u8, &t.got, &pattern) and !t.framing;
    }
};

/// Loopback on one header pin, no cable needed: the PIO receiver listens on
/// the pin its transmitter drives. Takes about 1 ms and leaves the UART
/// running on that pin; call the link's `restart` afterwards.
pub fn self_test(pin: Pin) SelfTest {
    var t: SelfTest = .{};
    if (!is_badge) return t;
    const n = gpio(pin);
    const bit = @as(u32, 1) << n;
    set_pad(n);
    set_funcsel(n, funcsel_sio);
    reg(sio_gpio_out_clr).* = bit;
    reg(sio_gpio_oe_set).* = bit;
    wait_us(5);
    t.sio_low = reg(sio_gpio_in).* & bit != 0;
    reg(sio_gpio_out_set).* = bit;
    wait_us(5);
    t.sio_high = reg(sio_gpio_in).* & bit != 0;
    start(n, n);
    wait_us(50);
    while (get()) |_| {}
    reg(pio_irq).* = 0xFF;
    for (SelfTest.pattern) |byte| _ = put(byte);
    const t0 = now_us();
    var last_high = (reg(sio_gpio_in).* >> n) & 1 != 0;
    while (now_us() -% t0 < 500 and t.n < 4) {
        const high = (reg(sio_gpio_in).* >> n) & 1 != 0;
        if (last_high and !high) t.edges += 1;
        last_high = high;
        if (get()) |byte| {
            t.got[t.n] = byte;
            t.n += 1;
        }
    }
    t.framing = reg(pio_irq).* & irq_framing != 0;
    t.regs = regs();
    return t;
}

const timer0_timerawl: u32 = 0x400B0028;

fn now_us() u32 {
    return reg(timer0_timerawl).*;
}

fn wait_us(us: u32) void {
    const t0 = now_us();
    while (now_us() -% t0 < us) {}
}
