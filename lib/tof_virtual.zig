//! A register-level model of the TMF8820 behind lib/i2c_rp2350.zig's bus
//! interface, so the real driver (lib/tof.zig) boots and measures on it:
//! the simulator always uses it (live data in the browser), badge builds
//! with `-Dtof-fake=true` use it (badge-bench measures the whole data
//! path), and the host tests drive it with fault injection.
//!
//! What it models (docs/TOF.md section 3 lists what is the datasheet's
//! and what is the ams driver's):
//! - ENABLE (0xE0): starts in standby (PON 0, cpu_ready 0); PON 0 -> 1
//!   boots the bootloader (cpu_ready after `boot_us`); 0xF0 = 0x80 resets
//!   the CPU (powerup_select 2 with a valid image starts the application,
//!   else the bootloader). Only 0xE0 reads back in standby.
//! - Bootloader: commands written from 0x08 (`cmd, size, data, csum`),
//!   executed at the end of the write: a short write is STAT_ERR_SIZE, a
//!   bad checksum or unknown command STAT_ERR_CSUM; DOWNLOAD_INIT,
//!   ADDR_RAM, W_RAM (range-checked), RAMREMAP_RESET (starts the
//!   application if RAM holds the firmware image byte for byte, else the
//!   chip hangs until reset or power cycle). Status reads back from 0x08
//!   as `status, 0, csum`, busy (0x10) for `bl_busy_us`.
//! - Application: CMD_STAT busy (reads the command) for `cmd_us`, then
//!   0 / 1 (measuring) or an error; LOAD_COMMON fills 0x20.. with the
//!   configuration page (cid 0x16), WRITE_CONFIG validates and stores it
//!   (needs a loaded page), MEASURE / STOP, active range 0x6E / 0x6F.
//! - Measurements every max(period, iterations time): a result record
//!   (rid 0x10) with INT_STATUS bit 1, or first the 30 histogram
//!   subpackets (rid 0x81), each published after the host clears bit 3 of
//!   the previous one, then the result. A result the host has not cleared
//!   is overwritten (`stats.overwritten`).
//! - User SPAD masks (M2): command 0x17 loads the SPAD page (cid 0x17,
//!   registers 0x24..0x90, lib/tof_spad.zig's layout); WRITE_CONFIG with
//!   that page decodes it and checks the datasheet's rules (STAT_ERR_CONFIG
//!   0x02 if broken, STAT_WARNING 0x0A "ignored" unless the common page
//!   already has spad_map_id 14); it reads back as written. MEASURE with
//!   spad_map_id 14 and no valid page fails with 0x02 (the device's
//!   behaviour there is unknown). Results under a user mask come from the
//!   SPAD-level scene (lib/tof_scene.zig): channel c in zone c - 1; the
//!   room by default, or (`user_scene = .hand`, M5) the 3x3 scene's
//!   wandering hand traced SPAD by SPAD, so the STRIPES layout is fed.
//! - A synthetic scene, deterministic in time: a wall at about 900 mm and
//!   a hand blob at 300..450 mm wandering over the zones (two objects
//!   where it partly covers a zone), with histograms to match: reference
//!   channel peak, crosstalk near bin 15, target peaks at
//!   `tof.bin_of_mm`, noise.
const std = @import("std");
const tof = @import("tof.zig");
const i2c = @import("i2c_rp2350.zig");
const types = @import("tof_types.zig");
const spad = @import("tof_spad.zig");
const spad_scene = @import("tof_scene.zig");

pub const Error = i2c.Error;

pub const Fault = struct {
    /// Nothing answers (unplugged).
    absent: bool = false,
    /// Fail the Nth transaction from now (0 = the next) with `kind`, once.
    fail_at: ?u32 = null,
    fail_kind: Error = error.DataNack,
    /// Bootloader and application commands never finish.
    stuck_busy: bool = false,
    /// The bootloader answers every W_RAM with STAT_ERR_CSUM.
    bl_reject: bool = false,
    /// The downloaded image is corrupted in RAM: the application never starts.
    corrupt_ram: bool = false,
    /// The firmware has no active range commands (register 0x19 reads 0).
    no_range: bool = false,
    /// The SPAD page reads back with SPAD (0, 0)'s enable bit flipped.
    spad_corrupt: bool = false,
    /// A CPU reset or power-on with powerup_select = 2 hangs (ENABLE
    /// reads 0x21, cpu_ready never comes) instead of starting the RAM
    /// application: what a badge showed after the driver had set 2.
    ps2_hang: bool = false,
    /// A CPU reset (0xF0) with the PLL still on (0xEC bit 6) hangs: the
    /// ams driver always turns it off first.
    reset_needs_pll_off: bool = false,
    /// A measurement falling due during a histogram dump abandons the dump
    /// (its result is never published) and starts the new one, instead of
    /// waiting for the host. What a badge showed: a host slower than the
    /// ranging period got histogram scraps and no results at all.
    hist_overrun: bool = false,
    /// STOP during a histogram dump still publishes that measurement's
    /// result this long later (0: off), over whatever page is in 0x20 by
    /// then (a badge read rid 0x10 where the common page should be).
    late_result_us: u32 = 0,
};

pub const timing = struct {
    pub const boot_us = 1500;
    pub const app_boot_us = 3000;
    /// Address NACKed for this long after RAMREMAP_RESET or a CPU reset.
    pub const reset_nack_us = 300;
    pub const bl_busy_us = 40;
    pub const cmd_us = 250;
};

const Mode = enum { standby, booting, bootloader, app, dead };

pub const Stats = struct {
    transactions: u32 = 0,
    bl_commands: u32 = 0,
    /// Bootloader commands whose checksum (or size) was wrong.
    bl_bad: u32 = 0,
    app_commands: u32 = 0,
    results: u32 = 0,
    hist_packets: u32 = 0,
    overwritten: u32 = 0,
    remaps: u32 = 0,
    /// RAMREMAP_RESET issued with powerup_select = 2 set.
    remaps_ps2: u32 = 0,
    /// Histogram dumps abandoned for the next measurement (hist_overrun).
    hist_abandoned: u32 = 0,
    late_results: u32 = 0,
    boots: u32 = 0,
    /// SPAD pages accepted, rejected (rules broken), ignored (map not 14).
    spad_writes: u32 = 0,
    spad_rejects: u32 = 0,
    spad_ignored: u32 = 0,
    spad_loads: u32 = 0,
};

/// One measurement as the model published it (tests compare the driver's
/// decode with this).
pub const Snapshot = struct {
    frame: types.Frame = .{},
    /// Measurement time (drives the histogram noise).
    t_us: u64 = 0,
    hand_on: bool = false,
};

pub const Model = struct {
    t_us: u64 = 0,
    fault: Fault = .{},
    stats: Stats = .{},
    /// Other addresses that acknowledge (scan tests).
    others: u128 = 0,

    mode: Mode = .standby,
    boot_target: Mode = .bootloader,
    ready_at: u64 = 0,
    nack_until: u64 = 0,
    pon: bool = false,
    powerup_select: u2 = 0,
    /// 0xEC bit 6 (undocumented PLL bit); on whenever the CPU runs.
    pll_on: bool = true,
    int_status: u8 = 0,
    int_enab: u8 = 0,
    regs: [256]u8 = @splat(0),
    ptr: u8 = 0,

    // bootloader
    ram: [4096]u8 = @splat(0),
    ram_ptr: u16 = 0,
    bl_status: u8 = 0,
    bl_busy_until: u64 = 0,
    image_valid: bool = false,

    // application
    cmd_busy_until: u64 = 0,
    cmd_status: u8 = 0,
    cmd_cur: u8 = 0,
    period_ms: u16 = 33,
    kiter: u16 = 550,
    spad_map: u8 = 1,
    hist_dump: bool = false,
    active_range: u8 = 0x6F,
    /// The configuration page in 0x20.. (0 none, 0x16 common, 0x17 SPAD).
    loaded_cid: u8 = 0,
    /// What the SPADs see under a user mask: the room (the depth photo's)
    /// or the hand (carts' `-Dtof-fake=true` builds, docs/TOF.md M5).
    /// Pre-defined maps always use `scene` below. Kept across power
    /// cycles (a setting of the model, not of the chip).
    user_scene: spad_scene.Kind = .room,
    /// The user SPAD page as last accepted, and its mask.
    spad_page: spad.Page = @splat(0),
    user_mask: spad.Mask = .{},
    user_valid: bool = false,
    measuring: bool = false,
    next_meas_at: u64 = 0,
    /// Fault.late_result: when the stopped measurement's result lands.
    late_result_at: ?u64 = null,
    result_num: u8 = 0,
    tid: u8 = 0,
    /// Next subpacket to publish when the host clears the current one
    /// (null: no dump in progress).
    hist_next: ?u8 = null,
    pending: Snapshot = .{},
    /// The last measurement published as a result.
    published: Snapshot = .{},
    /// The last eight published results, by result number % 8.
    history: [8]Snapshot = @splat(.{}),

    pub fn init() Model {
        return .{};
    }

    /// Power cycle (plug in): standby, bootloader, RAM contents lost.
    pub fn power_cycle(m: *Model) void {
        const keep_t = m.t_us;
        const keep_fault = m.fault;
        const keep_stats = m.stats;
        const keep_others = m.others;
        const keep_scene = m.user_scene;
        m.* = .{};
        m.user_scene = keep_scene;
        m.t_us = keep_t;
        m.fault = keep_fault;
        m.stats = keep_stats;
        m.others = keep_others;
        m.fault.absent = false;
    }

    pub fn unplug(m: *Model) void {
        m.fault.absent = true;
    }

    pub fn plug(m: *Model) void {
        m.power_cycle();
    }

    pub fn sync(m: *Model, now_us: u64) void {
        if (now_us > m.t_us) m.t_us = now_us;
        m.advance();
    }

    fn cpu_ready(m: *const Model) bool {
        return m.mode == .bootloader or m.mode == .app;
    }

    /// Where a CPU reset or power-on goes: the RAM application with
    /// powerup_select 2 and a valid image, else the bootloader; `dead`
    /// under the hang faults.
    fn boot_target_now(m: *const Model, cpu_reset: bool) Mode {
        if (m.powerup_select == 2 and m.fault.ps2_hang) return .dead;
        if (cpu_reset and m.pll_on and m.fault.reset_needs_pll_off) return .dead;
        return if (m.powerup_select == 2 and m.image_valid) .app else .bootloader;
    }

    fn reset_to(m: *Model, target: Mode) void {
        m.mode = .booting;
        m.boot_target = target;
        m.ready_at = m.t_us + if (target == .app) @as(u64, timing.app_boot_us) else timing.boot_us;
        m.nack_until = m.t_us + timing.reset_nack_us;
        m.pll_on = true;
        m.measuring = false;
        m.hist_next = null;
        m.int_status = 0;
        m.stats.boots += 1;
    }

    fn enter(m: *Model, mode: Mode) void {
        m.mode = mode;
        @memset(&m.regs, 0);
        switch (mode) {
            .bootloader => {
                m.regs[0] = tof.appid_bootloader;
                m.regs[1] = 0x29; // bootloader version
                m.bl_status = 0;
            },
            .app => {
                m.regs[0] = tof.appid_app;
                m.regs[1] = 4; // minor, patch, build: a plausible version
                m.regs[2] = 0x14;
                m.regs[3] = 0;
                m.regs[0x1C] = 0x12;
                m.regs[0x1D] = 0x34;
                m.regs[0x1E] = 0x56;
                m.regs[0x1F] = 0x78;
                m.active_range = if (m.fault.no_range) 0 else 0x6F;
                m.period_ms = 33;
                m.kiter = 550;
                m.spad_map = 1;
                m.hist_dump = false;
                m.loaded_cid = 0;
                m.spad_page = @splat(0);
                m.user_valid = false;
                m.cmd_status = 0;
                m.cmd_busy_until = 0;
            },
            else => {},
        }
    }

    /// Time-driven events up to `t_us`.
    fn advance(m: *Model) void {
        if (m.mode == .booting and m.t_us >= m.ready_at) m.enter(m.boot_target);
        if (m.late_result_at) |t| if (m.t_us >= t) {
            m.late_result_at = null;
            if (m.mode == .app) {
                m.publish_result();
                m.stats.late_results += 1;
            }
        };
        if (m.mode == .app and m.measuring) {
            const period = m.period_us();
            if (m.t_us > m.next_meas_at + 10 * period) m.next_meas_at = m.t_us;
            while (m.measuring and m.t_us >= m.next_meas_at) {
                // A histogram dump in progress, or (with dumps on) a result
                // the host has not acknowledged, holds the next measurement.
                if (m.hist_next != null) {
                    if (!m.fault.hist_overrun) break;
                    m.stats.hist_abandoned += 1;
                    m.hist_next = null;
                }
                if (m.hist_dump and m.int_status & tof.int_result != 0) break;
                m.measure(m.next_meas_at);
                m.next_meas_at += period;
            }
        }
    }

    fn period_us(m: *const Model) u64 {
        const meas: u64 = 3500 + @as(u64, m.kiter) * 52;
        return @max(@as(u64, m.period_ms) * 1000, meas);
    }

    fn measure(m: *Model, t: u64) void {
        m.result_num +%= 1;
        m.pending = .{ .t_us = t };
        if (m.spad_map == spad.map_id) {
            spad_scene.zone_results_in(m.user_scene, t, &m.user_mask, &m.pending.frame.zones);
            m.pending.hand_on = m.user_scene == .room or spad_scene.hand_at(t) != null;
        } else m.pending.hand_on = scene(t, &m.pending.frame.zones);
        const f = &m.pending.frame;
        f.seq = m.result_num;
        f.time_us = t;
        const warm: u8 = @intCast(@min(t / 60_000_000, 4));
        f.temperature_c = @intCast(27 + warm);
        f.ambient = 600 + tri(t, 5_000_000, 400);
        f.photons = 0;
        for (f.zones) |z| f.photons += @as(u32, z.near.confidence) * 37 + @as(u32, z.far.confidence) * 11;
        f.ref_photons = 31_000 + tri(t, 3_000_000, 900);
        if (m.hist_dump) {
            m.publish_packet(0);
        } else m.publish_result();
    }

    fn publish_packet(m: *Model, n: u8) void {
        m.hist_next = n + 1;
        m.tid +%= 1;
        const remaining: u16 = @as(u16, tof.hist_packets - n) * tof.hist_packet_bytes;
        m.regs[0x20] = tof.rid.raw_hist;
        m.regs[0x21] = m.tid;
        m.regs[0x22] = @truncate(remaining);
        m.regs[0x23] = @truncate(remaining >> 8);
        m.regs[0x24] = n;
        m.regs[0x25] = tof.hist_packet_bytes;
        m.regs[0x26] = 0;
        const ch = n % 10;
        const shift: u5 = @intCast(8 * (n / 10));
        for (0..tof.hist_packet_bytes) |b| {
            m.regs[0x27 + b] = @truncate(hist_bin(&m.pending, ch, @intCast(b)) >> shift);
        }
        m.int_status |= tof.int_hist;
        m.stats.hist_packets += 1;
    }

    fn publish_result(m: *Model) void {
        m.hist_next = null;
        if (m.int_status & tof.int_result != 0) m.stats.overwritten += 1;
        m.tid +%= 1;
        const f = &m.pending.frame;
        @memset(m.regs[0x20..0xC8], 0);
        m.regs[0x20] = tof.rid.result;
        m.regs[0x21] = m.tid;
        m.regs[0x22] = 0xA4 - 0x24;
        m.regs[0x24] = m.result_num;
        m.regs[0x25] = @bitCast(f.temperature_c);
        var valid: u8 = 0;
        for (f.zones) |z| valid += @intFromBool(z.near.valid());
        m.regs[0x26] = valid;
        put32(m.regs[0x28..0x2C], f.ambient);
        put32(m.regs[0x2C..0x30], f.photons);
        put32(m.regs[0x30..0x34], f.ref_photons);
        put32(m.regs[0x34..0x38], @as(u32, @truncate(m.pending.t_us * 5)) | 1);
        for (f.zones, 0..) |z, i| {
            put_triplet(&m.regs, i, z.near);
            put_triplet(&m.regs, 18 + i, z.far);
        }
        m.int_status |= tof.int_result;
        m.published = m.pending;
        m.history[m.result_num % 8] = m.pending;
        m.stats.results += 1;
    }

    // ---- the I2C side ----

    fn transact(m: *Model, addr: u7, w: []const u8, r: []u8) Error!void {
        m.stats.transactions += 1;
        if (addr != tof.address) {
            if (m.others & (@as(u128, 1) << addr) != 0) {
                @memset(r, 0);
                return;
            }
            return error.AddrNack;
        }
        if (m.fault.absent) return error.AddrNack;
        if (m.fault.fail_at) |n| {
            if (n == 0) {
                m.fault.fail_at = null;
                return m.fault.fail_kind;
            }
            m.fault.fail_at = n - 1;
        }
        if (m.t_us < m.nack_until) return error.AddrNack;

        if (w.len > 0) {
            m.ptr = w[0];
            const start = w[0];
            for (w[1..]) |v| {
                m.write_reg(m.ptr, v);
                m.ptr +%= 1;
            }
            if (w.len > 1) m.end_write(start, w.len - 1);
        }
        for (r) |*v| {
            v.* = m.read_reg(m.ptr);
            m.ptr +%= 1;
        }
    }

    pub fn write_reg(m: *Model, a: u8, v: u8) void {
        switch (a) {
            tof.reg.enable => {
                m.powerup_select = @truncate(v >> 4);
                const was = m.pon;
                m.pon = v & 1 != 0;
                if (!was and m.pon) {
                    if (m.mode == .standby) m.reset_to(m.boot_target_now(false));
                } else if (was and !m.pon) {
                    m.mode = .standby;
                    m.measuring = false;
                }
            },
            tof.reg.int_status => {
                const cleared = m.int_status & v;
                m.int_status &= ~v;
                // The host acknowledged a subpacket: publish the next one,
                // or after the last, the result.
                if (cleared & tof.int_hist != 0 and m.mode == .app) {
                    if (m.hist_next) |n| {
                        if (n < tof.hist_packets) m.publish_packet(n) else m.publish_result();
                    }
                }
            },
            tof.reg.int_enab => m.int_enab = v,
            tof.reg.reset => if (v == 0x80) {
                m.reset_to(m.boot_target_now(true));
            },
            tof.reg.pll => m.pll_on = v & 0x40 != 0,
            else => if (m.cpu_ready() and a < 0xE0) {
                m.regs[a] = v;
            },
        }
    }

    fn read_reg(m: *Model, a: u8) u8 {
        return switch (a) {
            tof.reg.enable => @as(u8, @intFromBool(m.cpu_ready())) << 6 | @as(u8, m.powerup_select) << 4 | @intFromBool(m.pon),
            tof.reg.int_status => if (m.cpu_ready()) m.int_status else 0,
            tof.reg.int_enab => if (m.cpu_ready()) m.int_enab else 0,
            tof.reg.id => if (m.cpu_ready()) tof.chip_id else 0,
            tof.reg.id + 1 => if (m.cpu_ready()) 0x01 else 0,
            tof.reg.pll => if (m.pll_on) 0x40 else 0,
            else => blk: {
                if (!m.cpu_ready() or a >= 0xE0) break :blk 0;
                if (a == tof.reg.cmd_stat) {
                    if (m.mode == .bootloader) break :blk if (m.t_us < m.bl_busy_until or m.fault.stuck_busy) 0x10 else m.bl_status;
                    break :blk if (m.t_us < m.cmd_busy_until or m.fault.stuck_busy) m.cmd_cur else m.cmd_status;
                }
                if (m.mode == .bootloader and a == 0x09) break :blk 0;
                if (m.mode == .bootloader and a == 0x0A) break :blk 0xFF -% m.bl_status;
                if (m.mode == .app and a == tof.reg.active_range) break :blk m.active_range;
                break :blk m.regs[a];
            },
        };
    }

    fn end_write(m: *Model, start: u8, n: usize) void {
        if (start != tof.reg.cmd_stat or !m.cpu_ready()) return;
        switch (m.mode) {
            .bootloader => m.bl_command(n),
            .app => m.app_command(m.regs[tof.reg.cmd_stat]),
            else => {},
        }
    }

    fn bl_command(m: *Model, written: usize) void {
        m.stats.bl_commands += 1;
        const c = m.regs[0x08];
        const size = m.regs[0x09];
        m.bl_busy_until = m.t_us + timing.bl_busy_us;
        if (written != 3 + @as(usize, size) or size > tof.bl.max_data) {
            m.stats.bl_bad += 1;
            m.bl_status = 0x01; // STAT_ERR_SIZE
            return;
        }
        if (tof.bl_checksum(m.regs[0x08 .. 0x0A + @as(usize, size)]) != m.regs[0x0A + @as(usize, size)]) {
            m.stats.bl_bad += 1;
            m.bl_status = 0x02; // STAT_ERR_CSUM
            return;
        }
        const data = m.regs[0x0A..][0..size];
        m.bl_status = 0;
        switch (c) {
            tof.bl.download_init => {},
            tof.bl.addr_ram => m.ram_ptr = @as(u16, data[0]) | @as(u16, data[1]) << 8,
            tof.bl.w_ram => {
                if (m.fault.bl_reject) {
                    m.bl_status = 0x02;
                    return;
                }
                if (@as(usize, m.ram_ptr) + size > m.ram.len) {
                    m.bl_status = 0x03; // STAT_ERR_RANGE
                    return;
                }
                @memcpy(m.ram[m.ram_ptr..][0..size], data);
                m.ram_ptr += size;
            },
            tof.bl.ramremap_reset => {
                m.stats.remaps += 1;
                if (m.powerup_select == 2) m.stats.remaps_ps2 += 1;
                m.image_valid = !m.fault.corrupt_ram and std.mem.eql(u8, m.ram[0..tof.firmware.len], tof.firmware);
                if (m.image_valid) {
                    m.reset_to(.app);
                } else {
                    m.reset_to(.dead);
                    m.ready_at = std.math.maxInt(u64);
                }
            },
            else => {
                m.stats.bl_bad += 1;
                m.bl_status = 0x02;
            },
        }
    }

    /// WRITE_CONFIG with the SPAD page loaded: decode, check, keep.
    fn write_spad_page(m: *Model) void {
        if (m.spad_map != spad.map_id) {
            m.cmd_status = spad.stat_ignored;
            m.stats.spad_ignored += 1;
            return;
        }
        const page: *const spad.Page = m.regs[spad.reg.enable..][0..spad.page_len];
        const d = spad.decode(page);
        if (d.bad_size or d.ch0 > 0 or spad.validate(&d.mask) != null) {
            m.cmd_status = 2; // STAT_ERR_CONFIG
            m.stats.spad_rejects += 1;
            return;
        }
        m.spad_page = page.*;
        m.user_mask = d.mask;
        m.user_valid = true;
        m.stats.spad_writes += 1;
    }

    fn app_command(m: *Model, c: u8) void {
        m.stats.app_commands += 1;
        m.cmd_cur = c;
        m.cmd_busy_until = m.t_us + timing.cmd_us;
        m.cmd_status = 0;
        switch (c) {
            tof.cmd.load_common => {
                m.tid +%= 1;
                @memset(m.regs[0x20..0xE0], 0);
                m.regs[0x20] = tof.rid.common;
                m.regs[0x21] = m.tid;
                m.regs[0x22] = 0x3E - 0x24;
                put16(m.regs[0x24..0x26], m.period_ms);
                put16(m.regs[0x26..0x28], m.kiter);
                m.regs[0x30] = 6; // confidence threshold
                m.regs[tof.reg.spad_map_id] = m.spad_map;
                m.regs[0x35] = 0x04; // ALG_SETTING_0: report distances
                m.regs[tof.reg.hist_dump] = @intFromBool(m.hist_dump);
                m.regs[0x3B] = @as(u8, tof.address) << 1;
                m.loaded_cid = tof.rid.common;
            },
            spad.cmd_load => {
                m.tid +%= 1;
                @memset(m.regs[0x20..0xE0], 0);
                m.regs[0x20] = spad.cid;
                m.regs[0x21] = m.tid;
                m.regs[0x22] = spad.page_len;
                @memcpy(m.regs[spad.reg.enable..][0..spad.page_len], &m.spad_page);
                if (m.fault.spad_corrupt) m.regs[spad.reg.enable] ^= 1;
                m.loaded_cid = spad.cid;
                m.stats.spad_loads += 1;
            },
            tof.cmd.write_config => {
                if (m.loaded_cid == spad.cid and m.regs[0x20] == spad.cid) {
                    m.write_spad_page();
                    return;
                }
                if (m.loaded_cid != tof.rid.common or m.regs[0x20] != tof.rid.common) {
                    m.cmd_status = 9; // STAT_ERR_UNKNOWN_CID
                    return;
                }
                const period = get16(m.regs[0x24..0x26]);
                const kiter = get16(m.regs[0x26..0x28]);
                const map = m.regs[tof.reg.spad_map_id];
                const spad_ok = switch (map) {
                    1, 2, 3, 6, 11, 12, 14 => true,
                    else => false,
                };
                if (period == 0 or kiter < 10 or !spad_ok) {
                    m.cmd_status = 2; // STAT_ERR_CONFIG
                    return;
                }
                m.period_ms = period;
                m.kiter = kiter;
                m.spad_map = map;
                m.hist_dump = m.regs[tof.reg.hist_dump] & 1 != 0;
            },
            tof.cmd.measure => {
                if (m.spad_map == spad.map_id and !m.user_valid) {
                    m.cmd_status = 2; // STAT_ERR_CONFIG
                    return;
                }
                m.measuring = true;
                m.next_meas_at = m.t_us + m.period_us();
                m.cmd_status = 1;
            },
            tof.cmd.stop => {
                if (m.fault.late_result_us != 0 and m.hist_next != null) m.late_result_at = m.t_us + m.fault.late_result_us;
                m.measuring = false;
                m.hist_next = null;
            },
            tof.cmd.range_short, tof.cmd.range_long => {
                if (m.active_range == 0) {
                    m.cmd_status = 6; // STAT_ERR_UNKNOWN_CMD
                } else m.active_range = c;
            },
            else => m.cmd_status = 6,
        }
    }
};

/// The model the simulator and `-Dtof-fake=true` builds share.
pub var shared: Model = .{};

/// The bus a driver talks through: the model's clock moves by each
/// transaction's `i2c.cost_us`, and to `now_us` at every poll (`sync`).
pub const Bus = struct {
    model: *Model,
    hz: u32 = i2c.default_hz,
    stats: i2c.Stats = .{},

    pub fn default(hz: u32) Bus {
        return .{ .model = &shared, .hz = hz };
    }

    pub fn sync(b: *Bus, now_us: u64) void {
        b.model.sync(now_us);
    }

    pub fn set_speed(b: *Bus, hz: u32) void {
        b.hz = hz;
    }

    pub fn speed_hz(b: *const Bus) u32 {
        return b.hz;
    }

    pub fn lines(_: *const Bus) i2c.Lines {
        return .{ .sda = true, .scl = true };
    }

    pub fn write(b: *Bus, addr: u7, bytes: []const u8) Error!void {
        return b.write_read(addr, bytes, &.{});
    }

    pub fn write_read(b: *Bus, addr: u7, w: []const u8, r: []u8) Error!void {
        const cost = i2c.cost_us(b.hz, w.len, r.len);
        // On the badge (-Dtof-fake=true) take as long as the real bus
        // would, so badge-bench's update times include the wire time.
        if (i2c.is_badge) spin_us(cost);
        b.model.t_us += cost;
        b.model.advance();
        b.stats.transactions += 1;
        b.model.transact(addr, w, r) catch |e| {
            switch (e) {
                error.AddrNack => b.stats.addr_nacks += 1,
                error.DataNack => b.stats.data_nacks += 1,
                error.Timeout => b.stats.timeouts += 1,
                error.ArbLost => b.stats.arb_lost += 1,
                error.Abort => b.stats.aborts += 1,
            }
            return e;
        };
    }
};

fn spin_us(us: u32) void {
    const timerawl: *volatile u32 = @ptrFromInt(0x400B0028);
    const t0 = timerawl.*;
    while (timerawl.* -% t0 < us) {}
}

// ---- the scene ----

/// A triangle wave 0..amp..0 with the given period.
fn tri(t: u64, period: u64, amp: u32) u32 {
    const ph = t % period;
    const half = period / 2;
    const x = if (ph < half) ph else period - ph;
    return @intCast(x * amp / half);
}

fn hash(a: u64) u32 {
    var x = a *% 0x9E3779B97F4A7C15;
    x ^= x >> 31;
    x *%= 0xBF58476D1CE4E5B9;
    x ^= x >> 29;
    return @truncate(x);
}

pub const wall_mm: u16 = 900;

/// The scene at `t_us` into `zones` (device order, row-major 3x3).
/// Returns whether the hand is in view. Fixed point: positions in 1/256
/// of a zone.
pub fn scene(t_us: u64, zones: *[9]types.Zone) bool {
    // The hand is in view 6.5 s of every 8.
    const hand_on = t_us % 8_000_000 < 6_500_000;
    const hx: i32 = 51 + @as(i32, @intCast(tri(t_us, 4_000_000, 666))); // 0.2 .. 2.8 zones
    const hy: i32 = 90 + @as(i32, @intCast(tri(t_us + 700_000, 2_700_000, 588)));
    const hand_mm: u16 = @intCast(300 + tri(t_us, 3_100_000, 150));
    const step = t_us / 33_000;
    for (zones, 0..) |*z, i| {
        const col: i32 = @intCast(i % 3);
        const row: i32 = @intCast(i / 3);
        const corner = col != 1 and row != 1;
        const edge = !corner and !(col == 1 and row == 1);
        const wall: u16 = wall_mm + @as(u16, if (corner) 72 else if (edge) 27 else 0) + @as(u16, @intCast(hash(step * 16 + i) % 7));
        // Coverage of the zone by a disk of radius 0.75 zone: 256 at the
        // centre, falling to 0 over the zone's half width beyond the rim.
        var cov: u32 = 0;
        if (hand_on) {
            const dx = col * 256 + 128 - hx;
            const dy = row * 256 + 128 - hy;
            const d = isqrt(@intCast(dx * dx + dy * dy));
            cov = @min(@as(u32, 256), 320 -| d);
        }
        const hand: u16 = hand_mm + @as(u16, @intCast(hash(step * 16 + i + 9) % 5));
        if (cov >= 200) {
            z.near = .{ .mm = hand, .confidence = 230 };
            z.far = if (cov < 240) .{ .mm = wall, .confidence = 40 } else .{};
        } else if (cov >= 40) {
            z.near = .{ .mm = hand, .confidence = @intCast(80 + cov / 2) };
            z.far = .{ .mm = wall, .confidence = @intCast(200 - cov / 2) };
        } else {
            z.near = .{ .mm = wall, .confidence = @intCast(180 + hash(step * 16 + i + 3) % 20) };
            z.far = .{};
        }
    }
    return hand_on;
}

fn isqrt(v: u32) u32 {
    var x: u32 = 0;
    var bit: u32 = 1 << 30;
    var n = v;
    while (bit > n) bit >>= 2;
    while (bit != 0) : (bit >>= 2) {
        if (n >= x + bit) {
            n -= x + bit;
            x = (x >> 1) + bit;
        } else x >>= 1;
    }
    return x;
}

/// Gaussian-ish peak shape, /256, at offsets 0..3 bins.
const peak = [_]u32{ 256, 180, 64, 12 };

fn add_peak(v: *u32, bin: u32, centre: u32, amp: u32) void {
    const d = if (bin > centre) bin - centre else centre - bin;
    if (d < peak.len) v.* += amp * peak[d] / 256;
}

/// The model's histogram bin `bin` of channel `ch` (0 = reference, 1..9
/// the zones) for the measurement `s`: 24-bit.
pub fn hist_bin(s: *const Snapshot, ch: u8, bin: u8) u32 {
    var v: u32 = 0;
    const noise = hash(s.t_us *% 1315423911 +% @as(u64, ch) * 131 + bin) % 24;
    if (ch == 0) {
        v = 40 + noise;
        add_peak(&v, bin, 10, 400_000);
    } else {
        const z = s.frame.zones[ch - 1];
        v = 150 + s.frame.ambient / 16 + noise;
        add_peak(&v, bin, 15, 2_500);
        if (z.near.valid()) add_peak(&v, bin, tof.bin_of_mm(z.near.mm), @as(u32, z.near.confidence) * 40);
        if (z.far.valid()) add_peak(&v, bin, tof.bin_of_mm(z.far.mm), @as(u32, z.far.confidence) * 40);
    }
    return @min(v, 0xFFFFFF);
}

fn put16(b: []u8, v: u16) void {
    b[0] = @truncate(v);
    b[1] = @truncate(v >> 8);
}

fn get16(b: []const u8) u16 {
    return @as(u16, b[0]) | @as(u16, b[1]) << 8;
}

fn put32(b: []u8, v: u32) void {
    for (0..4) |i| b[i] = @truncate(v >> @intCast(8 * i));
}

fn put_triplet(regs: *[256]u8, i: usize, t: types.Target) void {
    const o = 0x38 + 3 * i;
    regs[o] = t.confidence;
    put16(regs[o + 1 ..][0..2], t.mm);
}
