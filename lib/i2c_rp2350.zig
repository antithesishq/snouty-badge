//! I2C0 master on the badge's Qwiic port (docs/TOF.md section 2).
//!
//! SYCL Badge V2 revision r2 (the production board): Qwiic J2 carries
//! SDA on GPIO12 and SCL on GPIO13, which is RP2350 I2C0's pin mux, with
//! 10k pull-ups on the board. The OS sets both pins to the I2C function
//! and initialises I2C0 at boot (sycl-badge/src/os/drivers/i2c.zig) but
//! never touches it again and offers carts no API, so a cart drives I2C0
//! (a Synopsys DW_apb_i2c, 16-entry FIFOs) directly from core 1, as
//! lib/link_rp2350.zig drives PIO2. ACCESSCTRL's reset value (0xfc) lets
//! core 1 reach I2C0. Revision r1 dev boards have SDA and SCL the other
//! way round, which I2C0 cannot do; r0 has no connector.
//!
//! Short blocking transactions only (`write`, `write_read` with a
//! repeated start), each bounded by a timeout measured in microseconds:
//! a missing device, a stuck line or a confused controller ends in an
//! error, never a hang. After a timeout the controller is aborted, the
//! bus is clocked free (nine SCL pulses and a STOP, bit-banged through
//! SIO) and I2C0 is set up again.
//!
//! Register addresses and fields are from pico-sdk's rp2350
//! hardware_regs headers (i2c.h, pads_bank0.h, resets.h); the speed
//! calculation follows pico-sdk's i2c_set_baudrate (clk_sys, fast mode
//! timing for every speed).
//!
//! `Bus` is the hardware on the badge and `NullBus` (nothing answers)
//! elsewhere, so code that names the hardware bus still compiles for the
//! wasm simulator and the host; the simulator uses lib/tof_virtual.zig.
//! Bus interface (what lib/tof.zig and `Scan` need):
//!   fn write(b, addr: u7, bytes: []const u8) Error!void
//!   fn write_read(b, addr: u7, w: []const u8, r: []u8) Error!void
//!                                 (w empty: a plain read)
//!   fn speed_hz(b) u32
const std = @import("std");
const builtin = @import("builtin");

pub const is_badge = builtin.os.tag == .freestanding and (builtin.cpu.arch.isThumb() or builtin.cpu.arch.isArm());

pub const Error = error{
    /// Nobody acknowledged the address: no device (or it is in reset).
    AddrNack,
    /// The device acknowledged its address but refused a data byte.
    DataNack,
    /// The transaction did not finish in time (a line held low, clock
    /// stretched for too long, or the controller stuck).
    Timeout,
    /// Another master (or noise) won arbitration.
    ArbLost,
    /// Any other controller abort (`Stats.last_abort` has the source).
    Abort,
};

/// The speeds the probe cart offers. 400 kHz until hardware proves
/// 1 MHz (Fast-mode Plus) works with the Qwiic cable and pull-ups.
pub const speeds = [_]u32{ 100_000, 400_000, 1_000_000 };
pub const default_hz: u32 = 400_000;

/// Software and controller overhead per transaction, on top of the wire
/// time (setting the target, starting, waiting for STOP).
pub const overhead_us: u32 = 15;

/// Estimated time of one transaction: START, address, `wlen` written
/// bytes, then (if `rlen` > 0) a repeated START, address and `rlen` read
/// bytes, then STOP; nine bits per byte. lib/tof.zig budgets its bus
/// time with this, and lib/tof_virtual.zig advances its clock by it, so
/// the host tests measure the same thing the driver plans with.
pub fn cost_us(hz: u32, wlen: usize, rlen: usize) u32 {
    var bits: u64 = 2;
    if (wlen > 0 or rlen == 0) bits += 9 * (1 + @as(u64, wlen));
    if (rlen > 0) bits += 1 + 9 * (1 + @as(u64, rlen));
    return @intCast(bits * 1_000_000 / hz + overhead_us);
}

/// Counters for the diagnostics page.
pub const Stats = struct {
    transactions: u32 = 0,
    addr_nacks: u32 = 0,
    data_nacks: u32 = 0,
    timeouts: u32 = 0,
    arb_lost: u32 = 0,
    aborts: u32 = 0,
    /// Times the bus was clocked free after a timeout.
    recoveries: u32 = 0,
    /// IC_TX_ABRT_SOURCE of the last abort (0 if none yet).
    last_abort: u32 = 0,
};

/// What carts use for the real sensor: I2C0 on the badge, nothing elsewhere.
pub const Bus = if (is_badge) Rp2350 else NullBus;

/// No bus: every address NACKs.
pub const NullBus = struct {
    hz: u32 = default_hz,
    stats: Stats = .{},

    pub fn init(hz: u32) NullBus {
        return .{ .hz = hz };
    }
    pub fn set_speed(b: *NullBus, hz: u32) void {
        b.hz = hz;
    }
    pub fn speed_hz(b: *const NullBus) u32 {
        return b.hz;
    }
    pub fn write(b: *NullBus, _: u7, _: []const u8) Error!void {
        b.stats.addr_nacks += 1;
        return error.AddrNack;
    }
    pub fn write_read(b: *NullBus, _: u7, _: []const u8, _: []u8) Error!void {
        b.stats.addr_nacks += 1;
        return error.AddrNack;
    }
    pub fn lines(_: *const NullBus) Lines {
        return .{ .sda = true, .scl = true };
    }
};

/// SDA and SCL levels (both high on an idle bus with its pull-ups).
pub const Lines = struct { sda: bool, scl: bool };

/// A rolling scan of the 7-bit addresses 0x08..0x77 with one-byte reads,
/// `n` addresses per `step` so a cart can spread it over frames (a NACKed
/// address costs ~40 us at 400 kHz). `found` is the last complete pass.
pub const Scan = struct {
    pub const first: u7 = 0x08;
    pub const last: u7 = 0x77;

    found: u128 = 0,
    work: u128 = 0,
    next: u7 = first,
    /// Complete passes so far (0: `found` is not valid yet).
    passes: u32 = 0,

    pub fn step(s: *Scan, bus: anytype, n: u8) void {
        var i: u8 = 0;
        while (i < n) : (i += 1) {
            var b: [1]u8 = undefined;
            if (bus.write_read(s.next, &.{}, &b)) |_| {
                s.work |= @as(u128, 1) << s.next;
            } else |_| {}
            if (s.next == last) {
                s.found = s.work;
                s.work = 0;
                s.next = first;
                s.passes += 1;
            } else s.next += 1;
        }
    }

    pub fn has(s: *const Scan, addr: u7) bool {
        return s.found & (@as(u128, 1) << addr) != 0;
    }

    pub fn count(s: *const Scan) u8 {
        return @popCount(s.found);
    }

    /// The acknowledging addresses of the last pass, lowest first.
    pub fn list(s: *const Scan, out: []u7) []u7 {
        var n: usize = 0;
        var a: u8 = first;
        while (a <= last and n < out.len) : (a += 1) {
            if (s.has(@intCast(a))) {
                out[n] = @intCast(a);
                n += 1;
            }
        }
        return out[0..n];
    }
};

// ---- the hardware ----

/// clk_sys, which clocks I2C0 on the RP2350 (microzig's default; neither
/// OS changes it; lib/link_rp2350.zig uses the same).
pub const clk_sys_hz: u32 = 150_000_000;

const gpio_sda: u5 = 12;
const gpio_scl: u5 = 13;

const resets_base: u32 = 0x40020000;
const resets_reset = resets_base + 0x0;
const resets_reset_done = resets_base + 0x8;
const alias_set: u32 = 0x2000;
const alias_clr: u32 = 0x3000;
const reset_i2c0: u32 = 1 << 4;

const io_bank0_base: u32 = 0x40028000;
const funcsel_i2c: u32 = 3;
const funcsel_sio: u32 = 5;

const pads_bank0_base: u32 = 0x40038000;
/// IE | DRIVE 4 mA | PUE | SCHMITT; ISO, OD, PDE and SLEWFAST clear (the
/// OS sets slow slew and Schmitt too; the board's 10k pull-ups do the
/// real work, the pad's ~50k pull-up only helps).
const pad_value: u32 = 0x40 | 0x10 | 0x08 | 0x02;

const sio_base: u32 = 0xD0000000;
const sio_gpio_in = sio_base + 0x004;
const sio_gpio_out_clr = sio_base + 0x020;
const sio_gpio_oe_set = sio_base + 0x038;
const sio_gpio_oe_clr = sio_base + 0x040;

const i2c0_base: u32 = 0x40090000;
const ic_con = i2c0_base + 0x00;
const ic_tar = i2c0_base + 0x04;
const ic_data_cmd = i2c0_base + 0x10;
const ic_fs_scl_hcnt = i2c0_base + 0x1C;
const ic_fs_scl_lcnt = i2c0_base + 0x20;
const ic_intr_mask = i2c0_base + 0x30;
const ic_raw_intr_stat = i2c0_base + 0x34;
const ic_rx_tl = i2c0_base + 0x38;
const ic_tx_tl = i2c0_base + 0x3C;
const ic_clr_intr = i2c0_base + 0x40;
const ic_clr_tx_abrt = i2c0_base + 0x54;
const ic_clr_stop_det = i2c0_base + 0x60;
const ic_enable = i2c0_base + 0x6C;
const ic_status = i2c0_base + 0x70;
const ic_rxflr = i2c0_base + 0x78;
const ic_sda_hold = i2c0_base + 0x7C;
const ic_tx_abrt_source = i2c0_base + 0x80;
const ic_dma_cr = i2c0_base + 0x88;
const ic_enable_status = i2c0_base + 0x9C;
const ic_fs_spklen = i2c0_base + 0xA0;

const con_master: u32 = 1 << 0;
const con_speed_fast: u32 = 2 << 1;
const con_restart_en: u32 = 1 << 5;
const con_slave_disable: u32 = 1 << 6;
const con_tx_empty_ctrl: u32 = 1 << 8;

const cmd_read: u32 = 1 << 8;
const cmd_stop: u32 = 1 << 9;
const cmd_restart: u32 = 1 << 10;

const intr_tx_abrt: u32 = 1 << 6;
const intr_stop_det: u32 = 1 << 9;

const status_tfnf: u32 = 1 << 1;

const abrt_7b_addr_noack: u32 = 1 << 0;
const abrt_txdata_noack: u32 = 1 << 3;
const abrt_arb_lost: u32 = 1 << 12;

const fifo_depth = 16;

fn reg(addr: u32) *volatile u32 {
    return @ptrFromInt(addr);
}

const timer0_timerawl: u32 = 0x400B0028;

fn now_us() u32 {
    return reg(timer0_timerawl).*;
}

fn wait_us(us: u32) void {
    const t0 = now_us();
    while (now_us() -% t0 < us) {}
}

pub const Rp2350 = struct {
    hz: u32 = default_hz,
    stats: Stats = .{},

    /// Takes I2C0 over: resets the block, sets the pads and pin functions
    /// and programs the speed. Call once at cart start (and `set_speed`
    /// to change speed later).
    pub fn init(hz: u32) Rp2350 {
        var b: Rp2350 = .{ .hz = hz };
        b.setup();
        return b;
    }

    pub fn set_speed(b: *Rp2350, hz: u32) void {
        b.hz = hz;
        b.setup();
    }

    pub fn speed_hz(b: *const Rp2350) u32 {
        return b.hz;
    }

    pub fn lines(_: *const Rp2350) Lines {
        const in = reg(sio_gpio_in).*;
        return .{ .sda = (in >> gpio_sda) & 1 != 0, .scl = (in >> gpio_scl) & 1 != 0 };
    }

    pub fn write(b: *Rp2350, addr: u7, bytes: []const u8) Error!void {
        return b.xfer(addr, bytes, &.{});
    }

    pub fn write_read(b: *Rp2350, addr: u7, w: []const u8, r: []u8) Error!void {
        return b.xfer(addr, w, r);
    }

    fn setup(b: *Rp2350) void {
        reg(resets_reset + alias_set).* = reset_i2c0;
        reg(resets_reset + alias_clr).* = reset_i2c0;
        const t0 = now_us();
        while (reg(resets_reset_done).* & reset_i2c0 == 0 and now_us() -% t0 < 1000) {}

        set_pins(funcsel_i2c);

        disable();
        reg(ic_con).* = con_speed_fast | con_master | con_slave_disable | con_restart_en | con_tx_empty_ctrl;
        reg(ic_tx_tl).* = 0;
        reg(ic_rx_tl).* = 0;
        reg(ic_intr_mask).* = 0;
        reg(ic_dma_cr).* = 0;

        // pico-sdk i2c_set_baudrate: period in clk_sys cycles, 3/5 low.
        const period = (clk_sys_hz + b.hz / 2) / b.hz;
        const lcnt = period * 3 / 5;
        const hcnt = period - lcnt;
        reg(ic_fs_scl_hcnt).* = hcnt;
        reg(ic_fs_scl_lcnt).* = lcnt;
        reg(ic_fs_spklen).* = if (lcnt < 16) 1 else lcnt / 16;
        const hold: u32 = if (b.hz < 1_000_000)
            (clk_sys_hz * 3) / 10_000_000 + 1
        else
            (clk_sys_hz * 3) / 25_000_000 + 1;
        reg(ic_sda_hold).* = (reg(ic_sda_hold).* & 0xFFFF0000) | hold;
    }

    fn xfer(b: *Rp2350, addr: u7, w: []const u8, r: []u8) Error!void {
        b.stats.transactions += 1;
        const total = w.len + r.len;
        if (total == 0) return;
        const limit = 2 * cost_us(b.hz, w.len, r.len) + 2000;
        const t0 = now_us();

        disable();
        reg(ic_tar).* = addr;
        _ = reg(ic_clr_intr).*;
        reg(ic_enable).* = 1;
        // Nothing stale in the receive FIFO (disabling flushes it; bounded anyway).
        var stale: u8 = 0;
        while (reg(ic_rxflr).* > 0 and stale < fifo_depth) : (stale += 1) _ = reg(ic_data_cmd).*;

        var issued: usize = 0;
        var got: usize = 0;
        while (issued < total or got < r.len) {
            if (reg(ic_raw_intr_stat).* & intr_tx_abrt != 0) return b.aborted(t0, limit);
            if (issued < total and reg(ic_status).* & status_tfnf != 0) {
                const reading = issued >= w.len;
                // Keep outstanding reads within the receive FIFO.
                if (!reading or issued - w.len - got < fifo_depth) {
                    var cmd: u32 = if (reading) cmd_read else w[issued];
                    if (reading and issued == w.len and w.len > 0) cmd |= cmd_restart;
                    if (issued == total - 1) cmd |= cmd_stop;
                    reg(ic_data_cmd).* = cmd;
                    issued += 1;
                }
            }
            while (got < r.len and reg(ic_rxflr).* > 0) {
                r[got] = @truncate(reg(ic_data_cmd).*);
                got += 1;
            }
            if (now_us() -% t0 > limit) return b.timed_out();
        }
        // Everything is queued (and every read byte is in): wait for the
        // STOP, which also tells whether the last written byte was NACKed.
        while (true) {
            const raw = reg(ic_raw_intr_stat).*;
            if (raw & intr_tx_abrt != 0) return b.aborted(t0, limit);
            if (raw & intr_stop_det != 0) break;
            if (now_us() -% t0 > limit) return b.timed_out();
        }
        _ = reg(ic_clr_stop_det).*;
    }

    /// The controller aborted (NACK, arbitration): it flushes its FIFO and
    /// sends STOP by itself. Wait for that STOP, then classify.
    fn aborted(b: *Rp2350, t0: u32, limit: u32) Error {
        const src = reg(ic_tx_abrt_source).*;
        _ = reg(ic_clr_tx_abrt).*;
        while (reg(ic_raw_intr_stat).* & intr_stop_det == 0 and now_us() -% t0 <= limit + 500) {}
        _ = reg(ic_clr_intr).*;
        b.stats.last_abort = src;
        if (src & abrt_7b_addr_noack != 0) {
            b.stats.addr_nacks += 1;
            return error.AddrNack;
        }
        if (src & abrt_txdata_noack != 0) {
            b.stats.data_nacks += 1;
            return error.DataNack;
        }
        if (src & abrt_arb_lost != 0) {
            b.stats.arb_lost += 1;
            return error.ArbLost;
        }
        b.stats.aborts += 1;
        return error.Abort;
    }

    /// Abort, clock the bus free and start again.
    fn timed_out(b: *Rp2350) Error {
        b.stats.timeouts += 1;
        reg(ic_enable).* = 1 | 2; // ABORT: STOP and flush
        const t0 = now_us();
        while (reg(ic_enable).* & 2 != 0 and now_us() -% t0 < 1000) {}
        disable();
        recover();
        b.stats.recoveries += 1;
        b.setup();
        return error.Timeout;
    }
};

fn disable() void {
    reg(ic_enable).* = 0;
    const t0 = now_us();
    while (reg(ic_enable_status).* & 1 != 0 and now_us() -% t0 < 500) {}
}

fn set_pins(funcsel: u32) void {
    for ([_]u5{ gpio_sda, gpio_scl }) |n| {
        reg(pads_bank0_base + 4 + 4 * @as(u32, n)).* = pad_value;
        reg(io_bank0_base + 8 * @as(u32, n) + 4).* = funcsel;
    }
}

/// Bus recovery (I2C spec 3.1.16): a device that was mid-byte when the
/// controller gave up may hold SDA low. Clock SCL nine times (open drain
/// through SIO: drive low, or release to the pull-up), then make a STOP.
fn recover() void {
    const sda = @as(u32, 1) << gpio_sda;
    const scl = @as(u32, 1) << gpio_scl;
    reg(sio_gpio_out_clr).* = sda | scl;
    reg(sio_gpio_oe_clr).* = sda | scl;
    set_pins(funcsel_sio);
    for (0..9) |_| {
        reg(sio_gpio_oe_set).* = scl;
        wait_us(5);
        reg(sio_gpio_oe_clr).* = scl;
        wait_us(5);
    }
    // STOP: SDA low while SCL is high, then release SDA.
    reg(sio_gpio_oe_set).* = sda;
    wait_us(5);
    reg(sio_gpio_oe_clr).* = sda;
    wait_us(5);
    set_pins(funcsel_i2c);
}

test "cost_us counts START, address, data, repeated START and STOP" {
    // Write 1 byte then read 1 at 100 kHz: 2 + 18 + 1 + 18 = 39 bits = 390 us.
    try std.testing.expectEqual(@as(u32, 390 + overhead_us), cost_us(100_000, 1, 1));
    // A plain one-byte read: 2 + 1 + 18 = 21 bits.
    try std.testing.expectEqual(@as(u32, 210 + overhead_us), cost_us(100_000, 0, 1));
    // 128-byte read at 400 kHz is about 3 ms.
    const c = cost_us(400_000, 1, 128);
    try std.testing.expect(c > 2900 and c < 3100);
}

test "Scan records acknowledging addresses over passes" {
    const Fake = struct {
        pub fn write_read(_: *@This(), addr: u7, _: []const u8, r: []u8) Error!void {
            if (addr != 0x41 and addr != 0x29) return error.AddrNack;
            r[0] = 0;
        }
    };
    var f: Fake = .{};
    var s: Scan = .{};
    s.step(&f, 50);
    try std.testing.expectEqual(@as(u32, 0), s.passes);
    s.step(&f, 100);
    try std.testing.expectEqual(@as(u32, 1), s.passes);
    try std.testing.expect(s.has(0x41) and s.has(0x29) and !s.has(0x40));
    var buf: [8]u7 = undefined;
    const l = s.list(&buf);
    try std.testing.expectEqual(@as(usize, 2), l.len);
    try std.testing.expectEqual(@as(u7, 0x29), l[0]);
}
