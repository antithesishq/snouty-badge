//! TMF8820 time-of-flight sensor driver (docs/TOF.md, datasheet DS000693).
//!
//! A cooperative state machine: `poll(now_us)`, called once per update,
//! does a bounded slice of bus work (at most `budget_us` of estimated bus
//! time, `i2c.cost_us`) and returns. It powers the sensor up, downloads
//! the RAM application through the ROM bootloader, writes the measurement
//! configuration, starts measuring and then reads each result (and, when
//! enabled, the raw histograms) as the sensor raises them. It never
//! blocks: a missing sensor, a NACK, a timeout or an unexpected status
//! ends in a recorded error (`err`, `log`) and a retry, and an unplugged
//! sensor is re-probed every `timing.absent_retry_ms`.
//!
//! Generic over the bus (`Tof(Bus)`): lib/i2c_rp2350.zig on the badge,
//! lib/tof_virtual.zig (a register-level model of the device) in the
//! simulator, the host tests and `-Dtof-fake=true` badge builds. Bus
//! interface: see lib/i2c_rp2350.zig. A bus with `sync(now_us)` gets it
//! at the start of every poll (the model's clock).
//!
//! Protocol notes (which source each detail comes from is in
//! docs/TOF.md section 3):
//! - Every register access is one transaction: write the register
//!   address and either the data or, after a repeated START, read.
//! - Bootloader (appid 0x80): commands are written from BL_CMD_STAT
//!   (0x08) as `cmd, size, data..., csum` with csum = ~(cmd + size +
//!   data) (low byte); the status is read back from 0x08 as `status,
//!   size, csum`, busy while status >= 0x10. Download: DOWNLOAD_INIT
//!   (seed 0x29), ADDR_RAM 0x0000, W_RAM in chunks of up to 128 bytes,
//!   RAMREMAP_RESET; then the application (appid 0x03) starts.
//! - Application: commands go to CMD_STAT (0x08), busy while it reads
//!   >= 0x10, then 0x00 (OK) or 0x01 (accepted: measuring). The common
//!   configuration page is loaded into 0x20.. (cid_rid 0x16) with
//!   command 0x16, edited in place and written back with 0x15.
//! - Results: INT_STATUS (0xE1) bit 1. The record is at 0x20 (rid 0x10,
//!   tid, size, then result number, temperature, ambient, photon counts
//!   and 36 confidence/distance triplets from 0x38). For the 3x3 mode the
//!   first object of zone z (0..8) is triplet z and the second object
//!   triplet 18 + z (the ams driver's channel/sub-capture numbering).
//! - Raw histograms (HIST_DUMP bit 0): INT_STATUS bit 3, 30 subpackets
//!   (rid 0x81) of 128 bytes at 0x27, numbered at 0x24. Together they are
//!   5 TDCs x 256 bins x 3 byte planes (LSB plane first); each TDC's 256
//!   bins are two channels of 128, so subpacket n is channel n % 10, byte
//!   plane n / 10. Channel 0 is the reference SPAD, 1..9 the zones. The
//!   host acknowledges each subpacket by clearing the interrupt, and the
//!   sensor then publishes the next (tid changes); the result follows the
//!   last subpacket.
//! - User SPAD masks (M2, `set_user_mask`, lib/tof_spad.zig): checked
//!   against the datasheet's rules before anything is sent; then stop,
//!   the common page with spad_map_id 14 (as the ams driver orders it),
//!   command 0x17 loads the SPAD page (cid 0x17), the page 0x24..0x90 is
//!   written and committed with WRITE_CONFIG, loaded again and read back
//!   (ams recommends verifying), then MEASURE. A further mask while
//!   measuring on map 14 skips the common page. Frames carry the mask
//!   generation they were measured with (`frame_mask_gen`).
//! - Clock correction (the ams driver's clock_skew_correction, scaling
//!   distances by the host/sensor clock ratio, typically under 1 %) is not
//!   done.
const std = @import("std");
pub const types = @import("tof_types.zig");
pub const i2c = @import("i2c_rp2350.zig");
pub const virtual = @import("tof_virtual.zig");
/// The hand pose from a frame (lib/tof_pose.zig) and its synthetic frames,
/// here so a cart that uses the driver and the pose gets one `types`.
pub const pose = @import("tof_pose.zig");
pub const synth = @import("tof_synth.zig");
/// User SPAD masks (M2), the model's SPAD-level scene and the depth photo.
pub const spad = @import("tof_spad.zig");
pub const scene = @import("tof_scene.zig");
pub const depth = @import("tof_depth.zig");

const Frame = types.Frame;
const Histograms = types.Histograms;

/// The RAM application the bootloader runs (ams firmware for ams parts,
/// from SparkFun's MIT-licensed TMF882X library; lib/tof_firmware.NOTICE.md).
pub const firmware: []const u8 = @embedFile("tof_firmware.bin");

/// The sensor's I2C address (the default; this driver never changes it).
pub const address: u7 = 0x41;

pub const reg = struct {
    pub const appid = 0x00;
    pub const cmd_stat = 0x08;
    pub const active_range = 0x19;
    pub const config_result = 0x20;
    pub const tid = 0x21;
    /// Common configuration page, relative to 0x24.
    pub const period_ms = 0x24;
    pub const kilo_iterations = 0x26;
    pub const spad_map_id = 0x34;
    pub const hist_dump = 0x39;
    pub const enable = 0xE0;
    pub const int_status = 0xE1;
    pub const int_enab = 0xE2;
    pub const id = 0xE3;
    /// Undocumented in DS000693; the ams driver writes 0x80 here to reset
    /// the CPU (tmf882x_mode_cpu_reset).
    pub const reset = 0xF0;
    /// Undocumented; bit 6 is the PLL. The ams driver clears it before a
    /// CPU reset (tmf882x_mode_cpu_reset).
    pub const pll = 0xEC;
};

pub const bl = struct {
    pub const ramremap_reset = 0x11;
    pub const download_init = 0x14;
    pub const w_ram = 0x41;
    pub const addr_ram = 0x43;
    pub const seed = 0x29;
    pub const max_data = 128;
};

pub const cmd = struct {
    pub const measure = 0x10;
    pub const write_config = 0x15;
    pub const load_common = 0x16;
    /// Active range (short / long) commands; register 0x19 reports the
    /// same values. Not in DS000693's command list (see docs/TOF.md).
    pub const range_short = 0x6E;
    pub const range_long = 0x6F;
    pub const stop = 0xFF;
};

pub const rid = struct {
    pub const result = 0x10;
    pub const common = 0x16;
    pub const raw_hist = 0x81;
};

pub const int_result: u8 = 0x02;
pub const int_hist: u8 = 0x08;
pub const appid_app: u8 = 0x03;
pub const appid_bootloader: u8 = 0x80;
pub const chip_id: u8 = 0x08;

/// Histogram dump: 30 subpackets of 128 bytes.
pub const hist_packets = 30;
pub const hist_packet_bytes = 128;
/// Result record read length: 0x20 up to the last triplet used (26).
pub const result_len = 0x38 + 27 * 3 - 0x20;
/// Subpacket read length: header, subpacket header and 128 data bytes.
pub const packet_len = 0x27 + hist_packet_bytes - 0x20;

/// Adjustable timing (milliseconds unless noted), in one place.
pub const timing = struct {
    pub const absent_retry_ms = 500;
    pub const error_retry_ms = 1000;
    pub const cpu_ready_ms = 200;
    pub const bl_busy_ms = 50;
    pub const app_start_wait_ms = 10;
    pub const app_start_ms = 500;
    pub const cmd_ms = 100;
    /// No result for this long while measuring (or 4 periods, if longer)
    /// means the sensor stopped or lost power: start over.
    pub const frame_timeout_ms = 1000;
    pub const hist_set_ms = 2000;
    /// The update interval the histogram period is planned for (carts
    /// poll once per 60 Hz update).
    pub const poll_ms = 17;
    pub const reset_wait_ms = 10;
    /// Standby cycle (last resort): time between PON 0 and PON 1.
    pub const standby_ms = 10;
    /// Immediate re-reads of a busy status within one poll.
    pub const busy_spins = 3;
};

pub const Config = struct {
    /// Pre-defined SPAD map (datasheet 7.4.1): 1 normal 33x32 deg, 2/3
    /// macro, 6 wide 41x52 deg, 11/12 checkerboard.
    spad_map: u8 = 1,
    /// Iterations in thousands: 550 is the default (30 Hz).
    iterations_k: u16 = 550,
    period_ms: u16 = 33,
    /// Raw histogram dump with every result (slows the frame rate: 3840
    /// bytes per result over the bus).
    histograms: bool = false,
    /// Short-range high-accuracy mode (up to 1 m), where the firmware has it.
    short_range: bool = false,
};

pub const State = enum {
    /// Not polled yet.
    off,
    /// Nothing answers at 0x41; re-probed every `absent_retry_ms`.
    absent,
    /// Waking the sensor, reading its IDs.
    booting,
    /// Sending the RAM application to the bootloader.
    downloading,
    /// Application running: stopping, configuring, starting.
    configuring,
    measuring,
    /// An error; retried after `error_retry_ms` (see `err`).
    failed,
};

pub const Step = enum(u8) {
    probe,
    reset,
    reset_pll,
    reset_pll_off,
    standby_off,
    standby_on,
    reset_cpu,
    pon,
    wait_ready,
    read_id,
    read_app,
    bl_init,
    bl_addr,
    bl_write,
    bl_status,
    bl_remap_ps,
    bl_clear_ps,
    stop_drain,
    hist_tid,
    bl_remap,
    app_wait,
    app_check,
    app_open,
    app_serial,
    int_setup,
    int_clear,
    cmd_send,
    cmd_wait,
    set_range,
    range_check,
    read_cfg,
    write_cfg,
    measure_start,
    running_enter,
    run,
    read_result,
    result_tid,
    result_clear,
    read_hist,
    hist_clear,
    retry,
    first_frame,
    hist_set,
    spad_load,
    spad_check,
    spad_write,
    spad_reload,
    spad_verify,

    pub fn name(s: Step) []const u8 {
        return @tagName(s);
    }
};

pub const ErrCode = enum(u8) {
    none,
    /// The address stopped answering (unplugged, or reset) mid-sequence.
    lost,
    nack_data,
    bus_timeout,
    arb_lost,
    bus_abort,
    /// ID register (0xE3) is not 0x08: not a TMF882x at 0x41.
    bad_id,
    cpu_timeout,
    /// APPID neither bootloader (0x80) nor application (0x03).
    bad_appid,
    /// The bootloader rejected a command (raw: status; 2 = checksum).
    bl_status,
    bl_busy,
    /// After RAMREMAP the bootloader was still running.
    app_not_started,
    app_timeout,
    /// An application command failed (raw: cmd << 8 | status).
    cmd_status,
    cmd_busy,
    /// The configuration page did not load (raw: cid_rid read).
    bad_rid,
    frame_timeout,

    pub fn name(e: ErrCode) []const u8 {
        return @tagName(e);
    }
};

pub const LastError = struct {
    code: ErrCode = .none,
    step: Step = .probe,
    /// Status byte, register value or abort source, per code.
    raw: u32 = 0,
    time_us: u64 = 0,
};

pub const LogEntry = struct {
    step: Step = .probe,
    time_us: u64 = 0,
    status: u16 = 0,
};

/// What the sensor said about itself.
pub const Info = struct {
    enable: u8 = 0,
    id: u8 = 0,
    revid: u8 = 0,
    appid: u8 = 0,
    /// APPID 0x80: bootloader version (MINOR register).
    bl_version: u8 = 0,
    /// Application version: minor, patch, build (0x01..0x03).
    app_version: [3]u8 = @splat(0),
    app_status: u8 = 0,
    measure_status: u8 = 0,
    alg_status: u8 = 0,
    serial: [4]u8 = @splat(0),
    /// Register 0x19: 0 = no short-range support, 0x6E short, 0x6F long.
    active_range: u8 = 0,
    /// The configuration page as the firmware loaded it (before edits):
    /// period, kilo-iterations, SPAD map.
    default_period_ms: u16 = 0,
    default_iterations_k: u16 = 0,
    default_spad_map: u8 = 0,
    /// Reused a running application instead of downloading.
    reused_app: bool = false,
};

pub const Stats = struct {
    frames: u32 = 0,
    /// Result numbers skipped between frames.
    missed: u32 = 0,
    /// The same result number twice.
    duplicates: u32 = 0,
    /// A chunked result whose tid changed while it was being read.
    torn: u32 = 0,
    /// Records with an unexpected rid where a result was expected.
    bad_rid: u32 = 0,
    i2c_errors: u32 = 0,
    hist_sets: u32 = 0,
    hist_errors: u32 = 0,
    /// No result for the frame timeout with histograms on: resynced (all
    /// interrupts cleared) instead of restarting, once per run.
    stalls: u32 = 0,
    /// The configuration page read back as something else (a result)
    /// and was loaded again.
    cfg_retries: u32 = 0,
    /// Bootloader status replies whose checksum did not add up (the
    /// datasheet does not say replies carry one; counted, not fatal).
    bl_csum_mismatch: u32 = 0,
    /// Results with non-zero triplets 9..17 (expected empty on a 3x3
    /// TMF8820; a hint that the object layout differs).
    mid_triplets: u32 = 0,
    /// Times the driver went through probe (boots + retries).
    boots: u32 = 0,
    downloads: u32 = 0,
    max_spent_us: u32 = 0,
    last_spent_us: u32 = 0,
    /// User SPAD masks: pages written, masks refused by the validator
    /// (never sent), read-backs that differed from what was written.
    /// CPU resets and standby cycles forced while waiting for cpu_ready.
    rescues: u32 = 0,
    mask_writes: u32 = 0,
    mask_rejects: u32 = 0,
    spad_mismatch: u32 = 0,
    /// The last read-back difference (tof_spad.diff: 0xFF0n a size or
    /// offset, else row << 8 | column; 0xFFFF the page did not load).
    spad_diff: u16 = 0,
    /// Time from `set_user_mask` to the first frame measured with it:
    /// the last one and the worst.
    mask_switch_us: u32 = 0,
    mask_switch_max_us: u32 = 0,
    mask_switches: u32 = 0,
};

pub const log_len = 16;

/// Pick the bus: the real one on the badge unless `fake`, else the model.
pub fn Sensor(comptime fake: bool) type {
    return Tof(if (i2c.is_badge and !fake) i2c.Bus else virtual.Bus);
}

/// A driver on the default bus: I2C0 at `hz`, or the shared model.
pub fn open(comptime fake: bool, hz: u32) Sensor(fake) {
    if (i2c.is_badge and !fake) return Sensor(fake).init(i2c.Bus.init(hz));
    return Sensor(fake).init(virtual.Bus.default(hz));
}

pub fn Tof(comptime Bus: type) type {
    return struct {
        const Self = @This();

        bus: Bus,
        addr: u7 = address,
        /// Estimated bus time allowed per poll (us). 3 ms holds a whole
        /// result read at 400 kHz (2.7 ms with the interrupt read), so a
        /// 30 Hz sensor needs one poll per frame; at 1 MHz it takes 1.2 ms.
        budget_us: u32 = 3000,
        config: Config = .{},
        /// A configuration waiting to be applied (stop, reconfigure, start).
        pending: ?Config = null,

        state: State = .off,
        step: Step = .probe,
        info: Info = .{},
        err: LastError = .{},
        /// The error that started the current run of failures (the
        /// cause; `err` is the latest, often a symptom of the recovery).
        first_err: LastError = .{},
        /// Failures since the sensor last measured.
        fail_streak: u16 = 0,
        stats: Stats = .{},
        log: [log_len]LogEntry = @splat(.{}),
        log_count: u32 = 0,

        /// The latest result (valid once `stats.frames` > 0).
        frame: Frame = .{},
        /// Time of the bootloader download (first command to RAMREMAP).
        download_us: u32 = 0,
        fw_pos: u16 = 0,

        // ---- histograms: `hist[front]` is the latest complete set ----
        hist: [2]Histograms = .{ .{}, .{} },
        front: u1 = 0,
        hist_valid: bool = false,
        hist_mask: u32 = 0,
        hist_ready: bool = false,
        last_packet_tid: ?u8 = null,
        hist_start_us: u64 = 0,

        // ---- sequencing ----
        after: Step = .probe,
        cur_cmd: u8 = 0,
        cmd_soft: bool = false,
        wait_until: u64 = 0,
        deadline: u64 = 0,
        spins: u8 = 0,
        attempt: u8 = 0,
        force_reset: bool = false,
        /// This attempt's escalations while the CPU would not come up:
        /// 1 after a forced CPU reset, 2 after a standby cycle.
        rescue: u8 = 0,
        pending_n: u8 = 0,
        pll_reg: u8 = 0,
        download_start: u64 = 0,
        last_frame_us: u64 = 0,
        /// The ranging period actually written (`Config.period_ms`, or
        /// longer with histograms: see `hist_period_ms`).
        period_ms: u16 = 33,
        stalled: bool = false,
        drain_next: Step = .set_range,
        cfg_tries: u8 = 0,
        last_num: ?u8 = null,
        frame_logged: bool = false,
        buf: [packet_len]u8 = undefined,
        buf_pos: u8 = 0,
        page: [0x3C - 0x24]u8 = undefined,

        t0: u64 = 0,
        spent: u32 = 0,

        // ---- user SPAD mask (spad_map_id 14) ----
        /// The mask spad_map_id 14 uses; generation 1 is the default 3x3.
        mask: spad.Mask = spad.grid_3x3(),
        mask_gen: u32 = 1,
        /// `mask` changed since it was last written.
        mask_dirty: bool = false,
        /// Read the SPAD page back after writing it (ams's advice).
        verify_mask: bool = true,
        written_gen: u32 = 0,
        active_gen: u32 = 0,
        /// The mask generation the latest frame was measured with (0: a
        /// pre-defined SPAD map).
        frame_mask_gen: u32 = 0,
        /// The last mask the validator refused.
        mask_problem: ?spad.Problem = null,
        switch_t0: ?u64 = null,

        pub fn init(bus: Bus) Self {
            return .{ .bus = bus };
        }

        // ---- the cart's view ----

        pub fn measuring(self: *const Self) bool {
            return self.state == .measuring;
        }

        pub fn latest(self: *const Self) ?*const Frame {
            return if (self.stats.frames > 0) &self.frame else null;
        }

        pub fn histograms(self: *const Self) ?*const Histograms {
            return if (self.hist_valid) &self.hist[self.front] else null;
        }

        /// Bytes of the firmware sent so far (during `downloading`).
        pub fn download_progress(self: *const Self) u16 {
            return self.fw_pos;
        }

        /// The last `n` log entries, oldest first, into `out`.
        pub fn recent_log(self: *const Self, out: []LogEntry) []LogEntry {
            const n = @min(out.len, @min(self.log_count, log_len));
            for (0..n) |i| {
                const idx = (self.log_count - n + i) % log_len;
                out[i] = self.log[idx];
            }
            return out[0..n];
        }

        /// Apply a new configuration: if the sensor is running it is
        /// stopped, reconfigured and started again on the next polls.
        pub fn configure(self: *Self, c: Config) void {
            switch (self.state) {
                .measuring, .configuring => {
                    if (self.pending == null and std.meta.eql(c, self.config)) return;
                    self.pending = c;
                },
                else => self.config = c,
            }
        }

        /// Measure with a user SPAD mask (spad_map_id 14): checked against
        /// the datasheet's rules first (the problem is returned and nothing
        /// is sent), then written on the next polls. Keeps the rest of the
        /// configuration; `configure` with another `spad_map` goes back.
        pub fn set_user_mask(self: *Self, m: *const spad.Mask) ?spad.Problem {
            if (spad.validate(m)) |p| {
                self.stats.mask_rejects += 1;
                self.mask_problem = p;
                return p;
            }
            self.mask = m.*;
            self.mask_gen +%= 1;
            if (self.mask_gen == 0) self.mask_gen = 1;
            self.mask_dirty = true;
            self.switch_t0 = self.now();
            var c = self.pending orelse self.config;
            if (c.spad_map != spad.map_id) {
                c.spad_map = spad.map_id;
                self.configure(c);
            }
            return null;
        }

        /// The mask generation measuring now (0: a pre-defined map).
        pub fn active_mask_gen(self: *const Self) u32 {
            return self.active_gen;
        }

        /// Start over from the probe (keeps a running application, so it
        /// is quick: use after changing the bus speed).
        pub fn restart(self: *Self) void {
            if (self.pending) |p| self.config = p;
            self.pending = null;
            self.attempt = 0;
            self.state = .booting;
            self.goto_probe(0);
        }

        /// Start over with a CPU reset and a fresh firmware download.
        pub fn reload(self: *Self) void {
            self.restart();
            self.force_reset = true;
        }

        /// Not inlined: once per update is plenty, and inlining the state
        /// machine into a cart's update changed snouty-morph's float code
        /// generation (+0.12 ms a frame in badge-bench) when M2 grew it.
        pub noinline fn poll(self: *Self, now_us: u64) void {
            if (@hasDecl(Bus, "sync")) self.bus.sync(now_us);
            self.t0 = now_us;
            self.spent = 0;
            self.spins = 0;
            if (self.state == .off) self.goto_probe(0);
            var n: u32 = 0;
            while (n < 64) : (n += 1) {
                if (self.now() < self.wait_until) break;
                if (!self.step_once()) break;
            }
            self.stats.last_spent_us = self.spent;
            self.stats.max_spent_us = @max(self.stats.max_spent_us, self.spent);
        }

        fn now(self: *const Self) u64 {
            return self.t0 + self.spent;
        }

        // ---- bus helpers: one transaction, budgeted ----

        const Stop = error{Stop};

        /// One transaction within the budget. error.Budget: not now (next
        /// poll); a bus error is returned as is for the step to judge.
        fn xfer(self: *Self, w: []const u8, r: []u8) (error{Budget} || i2c.Error)!void {
            const c = i2c.cost_us(self.bus.speed_hz(), w.len, r.len);
            if (self.spent > 0 and self.spent + c > self.budget_us) return error.Budget;
            self.spent += c;
            return self.bus.write_read(self.addr, w, r) catch |e| {
                self.stats.i2c_errors += 1;
                return e;
            };
        }

        /// `xfer` with the usual error handling: a bus error fails the
        /// sequence (an address NACK means the sensor went away).
        fn io(self: *Self, w: []const u8, r: []u8) Stop!void {
            self.xfer(w, r) catch |e| {
                if (e != error.Budget) self.bus_failed(e);
                return error.Stop;
            };
        }

        fn read(self: *Self, r: u8, out: []u8) Stop!void {
            return self.io(&.{r}, out);
        }

        fn write(self: *Self, bytes: []const u8) Stop!void {
            return self.io(bytes, &.{});
        }

        fn bus_failed(self: *Self, e: (error{Budget} || i2c.Error)) void {
            switch (e) {
                error.AddrNack => {
                    if (self.step == .probe) {
                        // Nobody there: quietly try again later.
                        if (self.state != .absent) self.note(.probe, 0xFF);
                        self.state = .absent;
                        self.wait_ms(timing.absent_retry_ms);
                        return;
                    }
                    self.fail(.lost, 0);
                    self.state = .absent;
                    self.goto_probe(timing.absent_retry_ms);
                },
                error.DataNack => self.fail(.nack_data, 0),
                error.Timeout => self.fail(.bus_timeout, 0),
                error.ArbLost => self.fail(.arb_lost, 0),
                error.Abort, error.Budget => self.fail(.bus_abort, 0),
            }
        }

        // ---- bookkeeping ----

        fn note(self: *Self, s: Step, status: u16) void {
            self.log[self.log_count % log_len] = .{ .step = s, .time_us = self.now(), .status = status };
            self.log_count +%= 1;
        }

        fn fail(self: *Self, code: ErrCode, raw: u32) void {
            self.err = .{ .code = code, .step = self.step, .raw = raw, .time_us = self.now() };
            if (self.fail_streak == 0) self.first_err = self.err;
            self.fail_streak +|= 1;
            self.note(self.step, @truncate(raw | 0x8000));
            switch (code) {
                .cpu_timeout, .app_timeout, .bad_appid, .app_not_started, .frame_timeout => self.force_reset = true,
                else => {},
            }
            self.state = .failed;
            self.attempt +%= 1;
            self.goto_probe(timing.error_retry_ms);
        }

        /// The CPU did not come up in time (`raw`: ENABLE, 0xFF if it did
        /// not answer). As the ams driver does, force a CPU reset once;
        /// then try a standby cycle; then give up for this attempt.
        fn rescue_cpu(self: *Self, raw: u8) void {
            self.note(.wait_ready, @as(u16, raw) | 0x4000);
            switch (self.rescue) {
                0 => {
                    self.rescue = 1;
                    self.step = .reset;
                },
                1 => {
                    self.rescue = 2;
                    self.step = .standby_off;
                },
                else => {
                    self.fail(.cpu_timeout, raw);
                    return;
                },
            }
            self.stats.rescues += 1;
        }

        fn goto_probe(self: *Self, wait: u32) void {
            self.step = .probe;
            self.rescue = 0;
            self.wait_until = 0;
            if (wait > 0) self.wait_ms(wait);
            self.last_num = null;
            self.hist_mask = 0;
            self.hist_ready = false;
            self.last_packet_tid = null;
        }

        fn wait_ms(self: *Self, ms: u32) void {
            self.wait_until = self.now() + @as(u64, ms) * 1000;
        }

        fn wait_us(self: *Self, us: u32) void {
            self.wait_until = self.now() + us;
        }

        fn set_deadline(self: *Self, ms: u32) void {
            self.deadline = self.now() + @as(u64, ms) * 1000;
        }

        fn past_deadline(self: *const Self) bool {
            return self.now() > self.deadline;
        }

        /// A status was busy: re-read at once a few times, then next poll.
        fn busy(self: *Self) bool {
            self.spins += 1;
            return self.spins <= timing.busy_spins;
        }

        fn start_cmd(self: *Self, c: u8, after: Step) void {
            self.cur_cmd = c;
            self.after = after;
            self.cmd_soft = c == cmd.range_short or c == cmd.range_long;
            self.step = .cmd_send;
        }

        /// Room left in this poll's budget (the whole budget on its first
        /// transaction, so a tiny budget still makes progress).
        fn room(self: *const Self) u32 {
            return if (self.spent == 0) self.budget_us else self.budget_us -| self.spent;
        }

        /// How many of `left` bytes to read next: all of them, or as many
        /// as fit the rest of this poll (at least `min_chunk`); 0 = wait
        /// for the next poll.
        fn read_chunk(self: *const Self, left: usize) usize {
            const fit = read_fit(self.bus.speed_hz(), self.room(), 1);
            if (fit >= left) return left;
            if (fit >= min_chunk) return fit;
            return if (self.spent == 0) @min(left, min_chunk) else 0;
        }

        /// The next bootloader W_RAM payload: as much as fits the rest of
        /// this poll together with the status read after it (register,
        /// cmd, size, data, csum written); 0 = wait for the next poll.
        fn bl_chunk(self: *const Self, left: usize) usize {
            const hz = self.bus.speed_hz();
            const r = self.room() -| i2c.cost_us(hz, 1, 3);
            const avail_bits = @as(u64, r -| i2c.overhead_us) * hz / 1_000_000;
            const bytes = (avail_bits -| 2) / 9; // address + written bytes
            const fit: usize = @intCast(@min(bytes -| 5, bl.max_data));
            if (fit >= left) return left;
            if (fit >= min_chunk) return fit;
            return if (self.spent == 0) @min(left, @max(fit, 4)) else 0;
        }

        // ---- the state machine: each step at most one transaction ----

        /// One step; false when this poll should stop (waiting, out of
        /// budget, or failed).
        fn step_once(self: *Self) bool {
            return self.do_step() catch false;
        }

        fn do_step(self: *Self) Stop!bool {
            switch (self.step) {
                .probe => {
                    var b: [1]u8 = undefined;
                    try self.read(reg.enable, &b);
                    self.info.enable = b[0];
                    self.note(.probe, b[0]);
                    self.stats.boots += 1;
                    self.state = .booting;
                    self.step = if (self.force_reset) .reset else .pon;
                },
                .reset => {
                    // The ams driver's CPU reset (tmf882x_mode_cpu_reset):
                    // powerup_select = 1 (bootloader, stay awake) with PON,
                    // the PLL off, then 0xF0 = 0x80. powerup_select lives
                    // in an always-on domain, so this also clears a 2
                    // ("start the RAM application") left by anything else.
                    try self.write(&.{ reg.enable, (self.info.enable & ~@as(u8, 0x30)) | 0x10 | 0x01 });
                    self.step = .reset_pll;
                },
                .reset_pll => {
                    var b: [1]u8 = undefined;
                    try self.read(reg.pll, &b);
                    self.pll_reg = b[0];
                    self.step = .reset_pll_off;
                },
                .reset_pll_off => {
                    try self.write(&.{ reg.pll, self.pll_reg & ~@as(u8, 0x40) });
                    self.step = .reset_cpu;
                },
                .standby_off => {
                    // Last resort when a CPU reset did not bring it up:
                    // ask for standby (PON 0, powerup_select 1), then PON
                    // 0 -> 1 restarts the oscillator and the bootloader
                    // resets (DS000693 8.2.3).
                    try self.write(&.{ reg.enable, 0x10 });
                    self.note(.standby_off, 0);
                    self.step = .standby_on;
                    self.wait_ms(timing.standby_ms);
                },
                .standby_on => {
                    try self.write(&.{ reg.enable, 0x11 });
                    self.info.enable = 0x11;
                    self.step = .wait_ready;
                    self.set_deadline(timing.cpu_ready_ms);
                    self.wait_ms(timing.reset_wait_ms);
                },
                .reset_cpu => {
                    try self.write(&.{ reg.reset, 0x80 });
                    self.note(.reset, 0);
                    self.force_reset = false;
                    self.info.enable = 0x01;
                    self.step = .wait_ready;
                    self.set_deadline(timing.cpu_ready_ms);
                    self.wait_ms(timing.reset_wait_ms);
                },
                .pon => {
                    if (self.info.enable & 0x01 == 0) {
                        try self.write(&.{ reg.enable, (self.info.enable & 0x30) | 0x01 });
                        self.note(.pon, 0);
                        self.wait_ms(2);
                    }
                    self.step = .wait_ready;
                    self.set_deadline(timing.cpu_ready_ms);
                },
                .wait_ready => {
                    var b: [1]u8 = undefined;
                    self.xfer(&.{reg.enable}, &b) catch |e| switch (e) {
                        error.Budget => return false,
                        // Resetting: it may not answer for a moment.
                        error.AddrNack => if (!self.past_deadline()) {
                            self.wait_ms(1);
                            return false;
                        } else {
                            self.rescue_cpu(0xFF);
                            return false;
                        },
                        else => {
                            self.bus_failed(e);
                            return false;
                        },
                    };
                    self.info.enable = b[0];
                    if (b[0] & 0x40 != 0) {
                        self.step = .read_id;
                    } else if (self.past_deadline()) {
                        self.rescue_cpu(b[0]);
                        return false;
                    } else if (b[0] & 0x01 == 0) {
                        self.step = .pon;
                    } else {
                        self.wait_ms(1);
                        return false;
                    }
                },
                .read_id => {
                    var b: [5]u8 = undefined;
                    try self.read(reg.enable, &b);
                    self.info.enable = b[0];
                    self.info.id = b[3];
                    self.info.revid = b[4];
                    self.note(.read_id, @as(u16, b[3]) << 8 | b[4]);
                    if (b[3] & 0x3F != chip_id) {
                        self.fail(.bad_id, b[3]);
                        return false;
                    }
                    self.step = .read_app;
                },
                .read_app => {
                    var b: [4]u8 = undefined;
                    try self.read(reg.appid, &b);
                    self.info.appid = b[0];
                    self.note(.read_app, @as(u16, b[0]) << 8 | b[1]);
                    switch (b[0]) {
                        appid_bootloader => {
                            self.info.bl_version = b[1];
                            self.info.reused_app = false;
                            self.state = .downloading;
                            self.download_start = self.now();
                            self.fw_pos = 0;
                            self.pending_n = 0;
                            self.stats.downloads += 1;
                            self.step = .bl_init;
                        },
                        appid_app => {
                            self.info.reused_app = true;
                            self.step = .app_open;
                        },
                        else => {
                            self.fail(.bad_appid, b[0]);
                            return false;
                        },
                    }
                },
                .bl_init => {
                    try self.bl_command(bl.download_init, &.{bl.seed});
                    self.after = .bl_addr;
                },
                .bl_addr => {
                    // The image's start (0x00200000) as the bootloader's 16-bit RAM pointer.
                    self.pending_n = 0;
                    try self.bl_command(bl.addr_ram, &.{ 0x00, 0x00 });
                    self.after = .bl_write;
                },
                .bl_write => {
                    const n: u8 = @intCast(self.bl_chunk(firmware.len - self.fw_pos));
                    if (n == 0) return false;
                    try self.bl_command(bl.w_ram, firmware[self.fw_pos..][0..n]);
                    self.pending_n = n;
                    self.after = .bl_write;
                },
                .bl_status => {
                    var b: [3]u8 = undefined;
                    try self.read(0x08, &b);
                    if (b[0] >= 0x10) {
                        if (self.past_deadline()) {
                            self.fail(.bl_busy, b[0]);
                            return false;
                        }
                        return self.busy();
                    }
                    if (b[0] != 0) {
                        self.fail(.bl_status, @as(u32, b[1]) << 8 | b[0]);
                        return false;
                    }
                    if (b[0] +% b[1] +% b[2] != 0xFF) self.stats.bl_csum_mismatch += 1;
                    self.step = self.after;
                    if (self.after == .bl_write) {
                        self.fw_pos += self.pending_n;
                        self.pending_n = 0;
                        if (self.fw_pos >= firmware.len) self.step = .bl_remap_ps;
                    }
                },
                .bl_remap_ps => {
                    // Remap as the ams driver does, never with
                    // powerup_select = 2 (DS000693 8.9.5 suggests it, but
                    // it survives resets and standby, and on a badge a
                    // later reset then hung with ENABLE 0x21). Clear a 2
                    // left by an older build of this driver.
                    var b: [1]u8 = undefined;
                    try self.read(reg.enable, &b);
                    self.info.enable = b[0];
                    self.step = if ((b[0] >> 4) & 3 == 2) .bl_clear_ps else .bl_remap;
                },
                .bl_clear_ps => {
                    try self.write(&.{ reg.enable, (self.info.enable & ~@as(u8, 0x30)) | 0x10 | 0x01 });
                    self.note(.bl_clear_ps, self.info.enable);
                    self.step = .bl_remap;
                },
                .bl_remap => {
                    try self.write(&.{ 0x08, bl.ramremap_reset, 0, 0xFF ^ bl.ramremap_reset });
                    self.download_us = @intCast(@min(self.now() - self.download_start, std.math.maxInt(u32)));
                    self.note(.bl_remap, @intCast(@min(self.download_us / 1000, 0x7FFF)));
                    self.state = .booting;
                    self.step = .app_wait;
                    self.set_deadline(timing.app_start_ms);
                    self.wait_ms(timing.app_start_wait_ms);
                },
                .app_wait => {
                    var b: [1]u8 = undefined;
                    self.xfer(&.{reg.enable}, &b) catch |e| switch (e) {
                        error.Budget => return false,
                        error.AddrNack => {
                            if (self.past_deadline()) self.fail(.app_timeout, 0xFF) else self.wait_ms(2);
                            return false;
                        },
                        else => {
                            self.bus_failed(e);
                            return false;
                        },
                    };
                    self.info.enable = b[0];
                    if (b[0] & 0x40 != 0) {
                        // The ams driver waits another 10 ms after
                        // cpu_ready for the application to settle.
                        self.step = .app_check;
                        self.wait_ms(timing.app_start_wait_ms);
                        return false;
                    } else if (self.past_deadline()) {
                        self.fail(.app_timeout, b[0]);
                        return false;
                    } else {
                        self.wait_ms(2);
                        return false;
                    }
                },
                .app_check => {
                    var b: [1]u8 = undefined;
                    try self.read(reg.appid, &b);
                    self.info.appid = b[0];
                    self.note(.app_check, b[0]);
                    if (b[0] != appid_app) {
                        if (b[0] == appid_bootloader) self.fail(.app_not_started, b[0]) else self.fail(.bad_appid, b[0]);
                        return false;
                    }
                    self.step = .app_open;
                },
                .app_open => {
                    var b: [8]u8 = undefined;
                    try self.read(reg.appid, &b);
                    self.info.appid = b[0];
                    self.info.app_version = .{ b[1], b[2], b[3] };
                    self.info.app_status = b[4];
                    self.info.measure_status = b[5];
                    self.info.alg_status = b[6];
                    self.note(.app_open, @as(u16, b[1]) << 8 | b[2]);
                    self.state = .configuring;
                    self.step = .app_serial;
                },
                .app_serial => {
                    // ACTIVE_RANGE (0x19) and SERIAL_NUMBER (0x1C..0x1F).
                    var b: [7]u8 = undefined;
                    try self.read(reg.active_range, &b);
                    self.info.active_range = b[0];
                    self.info.serial = b[3..7].*;
                    self.step = .int_setup;
                },
                .int_setup => {
                    try self.write(&.{ reg.int_enab, int_result | int_hist });
                    self.step = .int_clear;
                },
                .int_clear => {
                    try self.write(&.{ reg.int_status, 0xFF });
                    self.start_cmd(cmd.stop, .set_range);
                },
                .cmd_send => {
                    try self.write(&.{ reg.cmd_stat, self.cur_cmd });
                    self.step = .cmd_wait;
                    self.set_deadline(timing.cmd_ms);
                },
                .cmd_wait => {
                    var b: [1]u8 = undefined;
                    try self.read(reg.cmd_stat, &b);
                    if (b[0] >= 0x10) {
                        if (self.past_deadline()) {
                            self.fail(.cmd_busy, @as(u32, self.cur_cmd) << 8 | b[0]);
                            return false;
                        }
                        return self.busy();
                    }
                    if (b[0] > 1) {
                        if (!self.cmd_soft) {
                            self.fail(.cmd_status, @as(u32, self.cur_cmd) << 8 | b[0]);
                            return false;
                        }
                        self.note(.cmd_wait, @as(u16, self.cur_cmd) << 8 | b[0]);
                    }
                    self.step = self.after;
                },
                .set_range => {
                    const want: u8 = if (self.config.short_range) cmd.range_short else cmd.range_long;
                    // 0: the firmware has no range modes (register 0x19 reads 0).
                    if (self.info.active_range != 0 and self.info.active_range != want) {
                        self.start_cmd(want, .range_check);
                    } else {
                        self.start_cmd(cmd.load_common, .read_cfg);
                    }
                },
                .range_check => {
                    var b: [1]u8 = undefined;
                    try self.read(reg.active_range, &b);
                    self.info.active_range = b[0];
                    self.note(.range_check, b[0]);
                    self.start_cmd(cmd.load_common, .read_cfg);
                },
                .read_cfg => {
                    var b: [0x3C - 0x20]u8 = undefined;
                    try self.read(reg.config_result, &b);
                    if (b[0] != rid.common) {
                        // A result or histogram published around the STOP
                        // (a badge read rid 0x10 here): clear the
                        // interrupts and load the page again.
                        if (self.cfg_tries < 3) {
                            self.cfg_tries += 1;
                            self.stats.cfg_retries += 1;
                            self.note(.read_cfg, b[0]);
                            self.drain_next = .set_range;
                            self.step = .stop_drain;
                            self.wait_ms(2);
                            return false;
                        }
                        self.fail(.bad_rid, b[0]);
                        return false;
                    }
                    self.cfg_tries = 0;
                    self.page = b[4..].*;
                    const p = &self.page;
                    self.info.default_period_ms = le16(p[0..2]);
                    self.info.default_iterations_k = le16(p[2..4]);
                    self.info.default_spad_map = p[reg.spad_map_id - 0x24];
                    const c = self.config;
                    self.period_ms = if (c.histograms) @max(c.period_ms, self.hist_period_ms()) else c.period_ms;
                    p[0] = @truncate(self.period_ms);
                    p[1] = @truncate(self.period_ms >> 8);
                    p[2] = @truncate(c.iterations_k);
                    p[3] = @truncate(c.iterations_k >> 8);
                    p[reg.spad_map_id - 0x24] = c.spad_map;
                    p[reg.hist_dump - 0x24] = @intFromBool(c.histograms);
                    self.step = .write_cfg;
                },
                .write_cfg => {
                    var w: [1 + reg.hist_dump - 0x24 + 1]u8 = undefined;
                    w[0] = reg.period_ms;
                    @memcpy(w[1..], self.page[0 .. w.len - 1]);
                    try self.write(&w);
                    self.start_cmd(cmd.write_config, .spad_load);
                },
                .spad_load => {
                    if (self.config.spad_map != spad.map_id) {
                        self.step = .measure_start;
                        return true;
                    }
                    self.start_cmd(spad.cmd_load, .spad_check);
                },
                .spad_check => {
                    var b: [4]u8 = undefined;
                    try self.read(reg.config_result, &b);
                    if (b[0] != spad.cid) {
                        self.fail(.bad_rid, b[0]);
                        return false;
                    }
                    self.step = .spad_write;
                },
                .spad_write => {
                    var w: [1 + spad.page_len]u8 = undefined;
                    w[0] = spad.reg.enable;
                    spad.encode(&self.mask, w[1..]);
                    try self.write(&w);
                    self.written_gen = self.mask_gen;
                    self.mask_dirty = false;
                    self.stats.mask_writes += 1;
                    self.note(.spad_write, @truncate(self.written_gen));
                    self.start_cmd(cmd.write_config, if (self.verify_mask) .spad_reload else .measure_start);
                },
                .spad_reload => {
                    self.buf_pos = 0;
                    self.start_cmd(spad.cmd_load, .spad_verify);
                },
                .spad_verify => {
                    const len = spad.reg.y_size + 1 - reg.config_result;
                    const n = self.read_chunk(len - self.buf_pos);
                    if (n == 0) return false;
                    try self.read(@intCast(reg.config_result + self.buf_pos), self.buf[self.buf_pos..][0..n]);
                    self.buf_pos += @intCast(n);
                    if (self.buf_pos < len) return true;
                    self.buf_pos = 0;
                    const d: ?u16 = if (self.buf[0] != spad.cid) 0xFFFF else blk: {
                        const back = spad.decode(self.buf[spad.reg.enable - reg.config_result ..][0..spad.page_len]);
                        break :blk spad.diff(&self.mask, &back.mask);
                    };
                    if (d) |v| {
                        self.stats.spad_mismatch += 1;
                        self.stats.spad_diff = v;
                    }
                    self.note(.spad_verify, d orelse 0);
                    self.step = .measure_start;
                },
                .measure_start => {
                    try self.write(&.{ reg.int_status, 0xFF });
                    self.start_cmd(cmd.measure, .running_enter);
                },
                .running_enter => {
                    self.active_gen = if (self.config.spad_map == spad.map_id) self.written_gen else 0;
                    self.state = .measuring;
                    self.attempt = 0;
                    self.fail_streak = 0;
                    self.last_frame_us = self.now();
                    self.last_num = null;
                    self.hist_mask = 0;
                    self.hist_ready = false;
                    self.last_packet_tid = null;
                    self.frame_logged = false;
                    self.note(.measure_start, 0);
                    self.step = .run;
                },
                .run => {
                    if (self.pending) |p| {
                        self.config = p;
                        self.pending = null;
                        self.state = .configuring;
                        self.drain_next = .set_range;
                        self.start_cmd(cmd.stop, .stop_drain);
                        return true;
                    }
                    if (self.mask_dirty and self.config.spad_map == spad.map_id) {
                        // A new mask on map 14: stop, SPAD page, start.
                        self.state = .configuring;
                        self.drain_next = .spad_load;
                        self.start_cmd(cmd.stop, .stop_drain);
                        return true;
                    }
                    const period: u64 = @max(timing.frame_timeout_ms, 4 * @as(u64, self.period_ms));
                    const limit = if (self.config.histograms) @max(period, timing.hist_set_ms) else period;
                    if (self.now() > self.last_frame_us + limit * 1000) {
                        if (self.config.histograms and !self.stalled) {
                            // Lost step with the dump (a sensor that
                            // moved on): clear everything and pick up the
                            // next set rather than reboot.
                            self.stalled = true;
                            self.stats.stalls += 1;
                            self.note(.run, 0x5700);
                            self.drain_next = .run;
                            self.step = .stop_drain;
                            self.last_frame_us = self.now();
                            return true;
                        }
                        self.fail(.frame_timeout, 0);
                        return false;
                    }
                    if (self.spins > 0) return false; // one interrupt read per poll
                    self.spins += 1;
                    var b: [1]u8 = undefined;
                    try self.read(reg.int_status, &b);
                    // A result first: it closes the histogram set before it.
                    if (b[0] & int_result != 0) {
                        self.buf_pos = 0;
                        self.step = .read_result;
                    } else if (b[0] & int_hist != 0) {
                        if (self.hist_mask == 0) self.hist_start_us = self.now();
                        self.buf_pos = 0;
                        self.step = .read_hist;
                    } else return false;
                },
                .read_result => {
                    const n = self.read_chunk(result_len - self.buf_pos);
                    if (n == 0) return false;
                    try self.read(@intCast(reg.config_result + self.buf_pos), self.buf[self.buf_pos..][0..n]);
                    const first = self.buf_pos == 0;
                    self.buf_pos += @intCast(n);
                    if (self.buf_pos < result_len) return true;
                    if (first) {
                        self.decode_result();
                        self.step = .result_clear;
                    } else self.step = .result_tid;
                },
                .result_tid => {
                    var b: [1]u8 = undefined;
                    try self.read(reg.tid, &b);
                    if (b[0] == self.buf[1]) self.decode_result() else {
                        // Overwritten mid-read (a period shorter than the
                        // read): dropped, but the sensor is alive.
                        self.stats.torn += 1;
                        self.last_frame_us = self.now();
                    }
                    self.step = .result_clear;
                },
                .result_clear => {
                    try self.write(&.{ reg.int_status, int_result });
                    self.step = .run;
                },
                .read_hist => {
                    const n = self.read_chunk(packet_len - self.buf_pos);
                    if (n == 0) return false;
                    try self.read(@intCast(reg.config_result + self.buf_pos), self.buf[self.buf_pos..][0..n]);
                    const first = self.buf_pos == 0;
                    self.buf_pos += @intCast(n);
                    // Check the header as soon as it is in: is this the next subpacket?
                    if (first and !self.packet_header_ok()) return false;
                    if (self.buf_pos < packet_len) return true;
                    self.buf_pos = 0;
                    self.take_packet();
                },
                .hist_clear => {
                    try self.write(&.{ reg.int_status, int_hist });
                    self.step = .hist_tid;
                    if (self.hist_mask == (1 << hist_packets) - 1) {
                        self.hist_mask = 0;
                        self.last_packet_tid = null;
                        self.step = .run;
                    }
                },
                .hist_tid => {
                    // The next subpacket follows the acknowledgement within
                    // microseconds (the ams driver re-reads at once): wait
                    // for its TID on one byte, not the whole packet.
                    var b: [1]u8 = undefined;
                    try self.read(reg.tid, &b);
                    if (self.last_packet_tid) |t| if (t == b[0]) {
                        if (self.now() > self.hist_start_us + @as(u64, timing.hist_set_ms) * 1000) {
                            self.drop_hist_set();
                            return true;
                        }
                        if (self.busy()) return true;
                        self.wait_us(500);
                        return false;
                    };
                    self.buf_pos = 0;
                    self.step = .read_hist;
                },
                .stop_drain => {
                    // After STOP (or a stall): acknowledge whatever the
                    // sensor published so it neither holds the page nor
                    // waits on us.
                    try self.write(&.{ reg.int_status, 0xFF });
                    self.hist_mask = 0;
                    self.hist_ready = false;
                    self.last_packet_tid = null;
                    self.buf_pos = 0;
                    self.step = self.drain_next;
                },
                .retry, .first_frame, .hist_set => self.step = .probe,
            }
            return true;
        }

        fn bl_command(self: *Self, c: u8, data: []const u8) Stop!void {
            var w: [3 + bl.max_data + 1]u8 = undefined;
            w[0] = 0x08;
            w[1] = c;
            w[2] = @intCast(data.len);
            @memcpy(w[3..][0..data.len], data);
            w[3 + data.len] = bl_checksum(w[1 .. 3 + data.len]);
            try self.write(w[0 .. 4 + data.len]);
            self.step = .bl_status;
            self.set_deadline(timing.bl_busy_ms);
        }

        /// The shortest ranging period with histogram dumps on that lets
        /// this driver read a whole dump (30 subpackets and the result)
        /// before the next measurement, at the bus speed and per-poll
        /// budget in use. A sensor that falls due mid-dump abandons it and
        /// its result (a badge at 400 kHz and 33 ms got no results), so a
        /// short period is lengthened to this.
        pub fn hist_period_ms(self: *const Self) u16 {
            const hz = self.bus.speed_hz();
            const pkt: u64 = i2c.cost_us(hz, 1, packet_len) + i2c.cost_us(hz, 2, 0) + i2c.cost_us(hz, 1, 1) + 3 * i2c.overhead_us;
            const budget: u64 = @max(self.budget_us, 1000);
            const polls: u64 = if (pkt <= budget)
                (hist_packets + budget / pkt - 1) / (budget / pkt)
            else
                hist_packets * ((pkt + budget - 1) / budget);
            // + the result and a poll of slack, then 25 % margin.
            const ms = (polls + 2) * timing.poll_ms * 5 / 4;
            return @intCast(std.math.clamp(ms, 33, 3000));
        }

        fn drop_hist_set(self: *Self) void {
            self.stats.hist_errors += 1;
            self.hist_mask = 0;
            self.hist_ready = false;
            self.last_packet_tid = null;
            self.buf_pos = 0;
            self.step = .run;
        }

        /// The first chunk of a subpacket read is in `buf`. False: not the
        /// next subpacket yet (read again later) or not a histogram at all.
        fn packet_header_ok(self: *Self) bool {
            const b = &self.buf;
            if (b[0] != rid.raw_hist) {
                // Not a histogram (yet, or any more): give up on this set.
                self.drop_hist_set();
                return true;
            }
            if (self.last_packet_tid) |t| if (t == b[1]) {
                // The next subpacket is not published yet.
                if (self.now() > self.hist_start_us + @as(u64, timing.hist_set_ms) * 1000) {
                    self.drop_hist_set();
                    return true;
                }
                self.buf_pos = 0;
                self.wait_us(500);
                return false;
            };
            return true;
        }

        /// A whole subpacket is in `buf`: file it under its number.
        fn take_packet(self: *Self) void {
            const b = &self.buf;
            self.last_packet_tid = b[1];
            const num = b[0x24 - 0x20];
            if (num < hist_packets) {
                if (self.hist_mask == 0) {
                    self.hist[self.front ^ 1] = .{};
                    self.hist_ready = false;
                }
                const work = &self.hist[self.front ^ 1];
                const ch = num % 10;
                const shift: u5 = @intCast(8 * (num / 10));
                const data = b[0x27 - 0x20 ..][0..hist_packet_bytes];
                for (&work.bins[ch], data) |*bin, v| bin.* |= @as(u32, v) << shift;
                self.hist_mask |= @as(u32, 1) << @intCast(num);
                if (self.hist_mask == (1 << hist_packets) - 1) {
                    self.hist_ready = true;
                    self.stats.hist_sets += 1;
                }
            } else self.stats.hist_errors += 1;
            self.step = .hist_clear;
        }

        fn decode_result(self: *Self) void {
            const b = &self.buf;
            if (b[0] != rid.result) {
                self.stats.bad_rid += 1;
                return;
            }
            const num = b[0x24 - 0x20];
            var f = &self.frame;
            if (self.last_num) |prev| {
                const delta = num -% prev;
                if (delta == 0) {
                    self.stats.duplicates += 1;
                    return;
                }
                self.stats.missed += delta - 1;
                f.seq +%= delta;
            } else if (self.stats.frames > 0) f.seq +%= 1 else f.seq = num;
            self.last_num = num;
            f.time_us = self.now();
            f.temperature_c = @bitCast(b[0x25 - 0x20]);
            f.ambient = le32(b[0x28 - 0x20 ..][0..4]);
            f.photons = le32(b[0x2C - 0x20 ..][0..4]);
            f.ref_photons = le32(b[0x30 - 0x20 ..][0..4]);
            for (&f.zones, 0..) |*z, i| {
                z.near = triplet(b, i);
                z.far = triplet(b, 18 + i);
            }
            var mid = false;
            for (9..18) |i| mid = mid or triplet(b, i).confidence != 0;
            if (mid) self.stats.mid_triplets += 1;
            self.frame_mask_gen = self.active_gen;
            if (self.switch_t0) |t| if (self.active_gen == self.mask_gen) {
                const us: u32 = @intCast(@min(self.now() -| t, std.math.maxInt(u32)));
                self.stats.mask_switch_us = us;
                self.stats.mask_switch_max_us = @max(self.stats.mask_switch_max_us, us);
                self.stats.mask_switches += 1;
                self.switch_t0 = null;
            };
            if (!self.frame_logged) self.note(.first_frame, num);
            self.frame_logged = true;
            self.stats.frames += 1;
            self.last_frame_us = self.now();
            self.stalled = false;
            if (self.hist_ready) {
                const work = &self.hist[self.front ^ 1];
                work.seq = f.seq;
                self.front ^= 1;
                self.hist_valid = true;
                self.hist_ready = false;
            }
        }
    };
}

fn triplet(b: []const u8, i: usize) types.Target {
    const o = 0x38 - 0x20 + 3 * i;
    return .{ .confidence = b[o], .mm = le16(b[o + 1 ..][0..2]) };
}

/// The largest read that fits `budget_us` after `wlen` written bytes.
pub fn read_fit(hz: u32, budget_us: u32, wlen: usize) usize {
    const avail_bits = @as(u64, budget_us -| i2c.overhead_us) * hz / 1_000_000;
    // START, address + written bytes, repeated START, address, data, STOP.
    const fixed = 2 + 9 * (1 + wlen) + 1 + 9;
    return @intCast(@min((avail_bits -| fixed) / 9, packet_len));
}

/// Smallest chunk worth a transaction of its own when a poll's budget is
/// nearly spent (smaller remainders wait for the next poll).
pub const min_chunk = 16;

/// ~(sum of bytes), the low byte (DS000693 8.9.4).
pub fn bl_checksum(bytes: []const u8) u8 {
    var sum: u8 = 0;
    for (bytes) |v| sum +%= v;
    return ~sum;
}

fn le16(b: *const [2]u8) u16 {
    return @as(u16, b[0]) | @as(u16, b[1]) << 8;
}

fn le32(b: *const [4]u8) u32 {
    return @as(u32, b[0]) | @as(u32, b[1]) << 8 | @as(u32, b[2]) << 16 | @as(u32, b[3]) << 24;
}

/// Approximate histogram bin of a distance: DS000693 7.1 puts the
/// crosstalk (zero distance) peak near bin 15 and 2 m 35 bins later.
pub fn bin_of_mm(mm: u32) u32 {
    return 15 + (mm * 35 + 1000) / 2000;
}

test "bootloader checksum matches the datasheet's fixed examples" {
    // RAMREMAP_RESET: 0x11, size 0 -> 0xEE; RAM_BIST 0x2A -> 0xD5; I2C_BIST 0x2C -> 0xD3.
    try std.testing.expectEqual(@as(u8, 0xEE), bl_checksum(&.{ 0x11, 0 }));
    try std.testing.expectEqual(@as(u8, 0xD5), bl_checksum(&.{ 0x2A, 0 }));
    try std.testing.expectEqual(@as(u8, 0xD3), bl_checksum(&.{ 0x2C, 0 }));
}

test "firmware image is the 0x9AC-byte RAM application" {
    try std.testing.expectEqual(@as(usize, 0x9AC), firmware.len);
    // Its vector table: initial SP 0x00208000, reset handler 0x0020009D.
    try std.testing.expectEqual(@as(u32, 0x00208000), le32(firmware[0..4]));
    try std.testing.expectEqual(@as(u32, 0x0020009D), le32(firmware[4..8]));
}
