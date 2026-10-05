//! lib/tof.zig (the TMF8820 driver) against lib/tof_virtual.zig (the
//! register-level model): boot, download, configure, measure, histograms,
//! reconfiguration, every fault path, and the per-poll bus budget.
const std = @import("std");
const tof = @import("../tof.zig");
const virtual = @import("../tof_virtual.zig");
const i2c = @import("../i2c_rp2350.zig");
const types = @import("../tof_types.zig");

const T = tof.Tof(virtual.Bus);
const frame_us: u64 = 16_667;

const Rig = struct {
    model: virtual.Model,
    drv: T,
    now: u64,
    /// The most bus time (model clock) any poll used.
    max_bus_us: u64 = 0,
    polls: u32 = 0,

    fn init(rig: *Rig, hz: u32) void {
        rig.model = .{};
        rig.drv = T.init(.{ .model = &rig.model, .hz = hz });
        rig.now = 1_000_000;
        rig.max_bus_us = 0;
        rig.polls = 0;
    }

    fn tick(rig: *Rig) !void {
        rig.now += frame_us;
        const before = @max(rig.model.t_us, rig.now);
        rig.drv.poll(rig.now);
        const used = rig.model.t_us - before;
        rig.max_bus_us = @max(rig.max_bus_us, used);
        rig.polls += 1;
        // The driver never plans more than its budget, and its plan is
        // what the bus took.
        try std.testing.expect(used <= rig.drv.budget_us);
        try std.testing.expectEqual(@as(u64, rig.drv.stats.last_spent_us), used);
    }

    fn run(rig: *Rig, us: u64) !void {
        const end = rig.now + us;
        while (rig.now < end) try rig.tick();
    }

    fn run_until_state(rig: *Rig, s: tof.State, limit_us: u64) !u64 {
        const t0 = rig.now;
        while (rig.now - t0 < limit_us) {
            try rig.tick();
            if (rig.drv.state == s) return rig.now - t0;
        }
        std.debug.print("state {s} step {s} err {s} raw {x}\n", .{
            @tagName(rig.drv.state), rig.drv.step.name(), rig.drv.err.code.name(), rig.drv.err.raw,
        });
        return error.NeverReached;
    }

    fn run_until_frames(rig: *Rig, n: u32, limit_us: u64) !void {
        const t0 = rig.now;
        while (rig.now - t0 < limit_us) {
            try rig.tick();
            if (rig.drv.stats.frames >= n) return;
        }
        return error.NoFrames;
    }
};

fn expect_frame_matches(rig: *const Rig) !void {
    const f = rig.drv.latest() orelse return error.NoFrame;
    const snap = &rig.model.history[f.seq % 8];
    try std.testing.expectEqual(@as(u32, f.seq & 0xFF), snap.frame.seq);
    for (f.zones, snap.frame.zones) |got, want| {
        try std.testing.expectEqual(want.near, got.near);
        try std.testing.expectEqual(want.far, got.far);
    }
    try std.testing.expectEqual(snap.frame.temperature_c, f.temperature_c);
    try std.testing.expectEqual(snap.frame.ambient, f.ambient);
    try std.testing.expectEqual(snap.frame.photons, f.photons);
    try std.testing.expectEqual(snap.frame.ref_photons, f.ref_photons);
}

test "boots, downloads the firmware and measures at every speed" {
    for (i2c.speeds) |hz| {
        var rig: Rig = undefined;
        rig.init(hz);
        // At 100 kHz a result takes ~11 ms of bus time, several polls:
        // a 33 ms period would overwrite it mid-read (torn), so slow down.
        if (hz < 400_000) rig.drv.configure(.{ .period_ms = 100 });
        const t = try rig.run_until_state(.measuring, 8_000_000);
        // Every bootloader command had the right checksum and size, the
        // image arrived byte for byte, and one remap started it.
        try std.testing.expectEqual(@as(u32, 0), rig.model.stats.bl_bad);
        try std.testing.expectEqual(@as(u32, 1), rig.model.stats.remaps);
        try std.testing.expectEqual(tof.appid_app, rig.drv.info.appid);
        try std.testing.expectEqual(tof.chip_id, rig.drv.info.id);
        try std.testing.expectEqual(@as(u8, 0x29), rig.drv.info.bl_version);
        try std.testing.expect(!rig.drv.info.reused_app);
        try std.testing.expect(rig.drv.download_us > 0);
        try std.testing.expectEqual(@as(u16, tof.firmware.len), rig.drv.download_progress());
        // The configuration page as the firmware loaded it.
        try std.testing.expectEqual(@as(u16, 33), rig.drv.info.default_period_ms);
        try std.testing.expectEqual(@as(u8, 1), rig.drv.info.default_spad_map);
        try std.testing.expectEqual(@as(u16, 550), rig.drv.info.default_iterations_k);
        // 400 kHz and up boot in well under a second; 100 kHz in a few.
        try std.testing.expect(t < @as(u64, if (hz >= 400_000) 800_000 else 6_000_000));
        try rig.run_until_frames(5, 1_000_000);
        try std.testing.expectEqual(tof.ErrCode.none, rig.drv.err.code);
    }
}

test "results decode to the model's scene, with no frame lost at 400 kHz" {
    var rig: Rig = undefined;
    rig.init(400_000);
    _ = try rig.run_until_state(.measuring, 2_000_000);
    var seen: u32 = 0;
    var two_objects = false;
    var last = rig.drv.stats.frames;
    while (rig.drv.stats.frames < 200) {
        try rig.tick();
        if (rig.drv.stats.frames != last) {
            last = rig.drv.stats.frames;
            try expect_frame_matches(&rig);
            seen += 1;
            for (rig.drv.frame.zones) |z| two_objects = two_objects or (z.near.valid() and z.far.valid());
        }
        if (rig.now > 20_000_000) return error.TooSlow;
    }
    try std.testing.expect(seen > 150);
    try std.testing.expect(two_objects);
    try std.testing.expectEqual(@as(u32, 0), rig.drv.stats.missed);
    try std.testing.expectEqual(@as(u32, 0), rig.drv.stats.torn);
    try std.testing.expectEqual(@as(u32, 0), rig.drv.stats.mid_triplets);
    try std.testing.expectEqual(@as(u32, 0), rig.model.stats.overwritten);
}

test "100 kHz with a 33 ms period: torn results are dropped, the driver keeps measuring" {
    var rig: Rig = undefined;
    rig.init(100_000);
    _ = try rig.run_until_state(.measuring, 8_000_000);
    try rig.run(3_000_000);
    try std.testing.expectEqual(tof.State.measuring, rig.drv.state);
    try std.testing.expect(rig.drv.stats.torn > 10);
    try std.testing.expectEqual(tof.ErrCode.none, rig.drv.err.code);
}

test "the hand moves: near distances vary between wall and hand" {
    var rig: Rig = undefined;
    rig.init(1_000_000);
    _ = try rig.run_until_state(.measuring, 2_000_000);
    var min_mm: u16 = 0xFFFF;
    var max_mm: u16 = 0;
    try rig.run_until_frames(rig.drv.stats.frames + 1, 1_000_000);
    const end = rig.now + 8_000_000;
    while (rig.now < end) {
        try rig.tick();
        for (rig.drv.frame.zones) |z| if (z.near.valid()) {
            min_mm = @min(min_mm, z.near.mm);
            max_mm = @max(max_mm, z.near.mm);
        };
    }
    try std.testing.expect(min_mm < 460);
    try std.testing.expect(max_mm > 890);
}

test "histograms decode: 10 channels x 128 bins, matching the model" {
    for ([_]u32{ 400_000, 1_000_000 }) |hz| {
        var rig: Rig = undefined;
        rig.init(hz);
        rig.drv.configure(.{ .histograms = true });
        _ = try rig.run_until_state(.measuring, 3_000_000);
        var checked: u32 = 0;
        var last_seq: u32 = 0;
        while (checked < 3) {
            try rig.tick();
            if (rig.now > 30_000_000) return error.NoHistograms;
            const h = rig.drv.histograms() orelse continue;
            if (h.seq == last_seq) continue;
            last_seq = h.seq;
            const snap = &rig.model.history[h.seq % 8];
            try std.testing.expectEqual(@as(u32, h.seq & 0xFF), snap.frame.seq);
            for (0..types.hist_channels) |ch| for (0..types.hist_bins) |b| {
                try std.testing.expectEqual(virtual.hist_bin(snap, @intCast(ch), @intCast(b)), h.bins[ch][b]);
            };
            // The reference channel's peak needs all three byte planes.
            try std.testing.expect(h.bins[0][10] > 0xFFFF);
            checked += 1;
        }
        try std.testing.expectEqual(@as(u32, 0), rig.drv.stats.hist_errors);
        try std.testing.expect(rig.drv.stats.hist_sets >= 3);
    }
}

test "histograms on the HIST budget keep a usable rate at 400 kHz" {
    var rig: Rig = undefined;
    rig.init(400_000);
    rig.drv.budget_us = 12_000;
    rig.drv.configure(.{ .histograms = true });
    _ = try rig.run_until_state(.measuring, 3_000_000);
    // The period is lengthened so a dump fits: ~4 Hz at 400 kHz.
    try std.testing.expect(rig.drv.period_ms >= 200 and rig.drv.period_ms <= 300);
    const sets0 = rig.drv.stats.hist_sets;
    try rig.run(2_000_000);
    // At least 3 sets a second.
    try std.testing.expect(rig.drv.stats.hist_sets - sets0 >= 6);
}

/// The HIST page as the badge ran it: histograms at 400 kHz on the
/// cart's 33 ms period, with a sensor that abandons a dump when the next
/// measurement falls due (Fault.hist_overrun).
fn hist_overrun_rig(rig: *Rig, hz: u32) !void {
    rig.init(hz);
    rig.model.fault.hist_overrun = true;
    rig.drv.budget_us = 12_000;
    rig.drv.configure(.{ .histograms = true, .period_ms = 33 });
    _ = try rig.run_until_state(.measuring, 3_000_000);
}

test "histograms on a sensor that overruns slow hosts: results and sets keep coming, no restarts" {
    for ([_]u32{ 400_000, 1_000_000, 100_000 }) |hz| {
        var rig: Rig = undefined;
        try hist_overrun_rig(&rig, hz);
        const f0 = rig.drv.stats.frames;
        const s0 = rig.drv.stats.hist_sets;
        const boots0 = rig.drv.stats.boots;
        try rig.run(10_000_000);
        errdefer std.debug.print("{d} Hz: frames {d} sets {d} boots {d} abandoned {d} err {s}\n", .{
            hz,                           rig.drv.stats.frames - f0,      rig.drv.stats.hist_sets - s0,
            rig.drv.stats.boots - boots0, rig.model.stats.hist_abandoned, rig.drv.err.code.name(),
        });
        try std.testing.expectEqual(tof.State.measuring, rig.drv.state);
        try std.testing.expectEqual(boots0, rig.drv.stats.boots);
        // A steady rate: 3+ a second from 400 kHz, ~0.6 at 100 kHz.
        const want: u32 = if (hz >= 400_000) 30 else 5;
        try std.testing.expect(rig.drv.stats.frames - f0 >= want);
        try std.testing.expect(rig.drv.stats.hist_sets - s0 >= want);
        try std.testing.expectEqual(@as(u32, 0), rig.model.stats.hist_abandoned);
    }
}

test "leaving the histogram pages mid-dump reconfigures cleanly (no bad_rid)" {
    var rig: Rig = undefined;
    try hist_overrun_rig(&rig, 400_000);
    var i: u32 = 0;
    while (i < 12) : (i += 1) {
        // The stopped measurement's result lands at a different moment
        // each time, over the page the driver is about to read.
        rig.model.fault.late_result_us = 300 + 1700 * (i % 6);
        // Partway into a dump, every time at a different point.
        try rig.run(40_000 + 23_000 * @as(u64, i));
        rig.drv.configure(.{ .histograms = i % 2 == 1, .period_ms = 33 });
        _ = try rig.run_until_state(.measuring, 2_000_000);
        try std.testing.expectEqual(tof.ErrCode.none, rig.drv.err.code);
    }
    try std.testing.expect(rig.model.stats.late_results > 0);
}

test "configure stops, reconfigures and restarts the sensor" {
    var rig: Rig = undefined;
    rig.init(400_000);
    _ = try rig.run_until_state(.measuring, 2_000_000);
    try rig.run_until_frames(10, 1_000_000);
    rig.drv.configure(.{ .spad_map = 6, .period_ms = 100, .iterations_k = 250 });
    try std.testing.expect(rig.drv.pending != null);
    try rig.run(300_000);
    try std.testing.expectEqual(tof.State.measuring, rig.drv.state);
    try std.testing.expectEqual(@as(u8, 6), rig.model.spad_map);
    try std.testing.expectEqual(@as(u16, 100), rig.model.period_ms);
    try std.testing.expectEqual(@as(u16, 250), rig.model.kiter);
    const f0 = rig.drv.stats.frames;
    try rig.run(1_000_000);
    const n = rig.drv.stats.frames - f0;
    try std.testing.expect(n >= 8 and n <= 11); // 10 Hz
    // An invalid configuration ends in an error, not a hang.
    rig.drv.configure(.{ .spad_map = 9 });
    try rig.run(300_000);
    try std.testing.expectEqual(tof.ErrCode.cmd_status, rig.drv.err.code);
    try std.testing.expectEqual(@as(u32, tof.cmd.write_config) << 8 | 2, rig.drv.err.raw);
    rig.drv.configure(.{});
    _ = try rig.run_until_state(.measuring, 3_000_000);
}

test "restart reuses the running application; reload downloads again" {
    var rig: Rig = undefined;
    rig.init(400_000);
    _ = try rig.run_until_state(.measuring, 2_000_000);
    rig.drv.restart();
    try std.testing.expect(rig.drv.state != .measuring);
    _ = try rig.run_until_state(.measuring, 1_000_000);
    try std.testing.expect(rig.drv.info.reused_app);
    try std.testing.expectEqual(@as(u32, 1), rig.drv.stats.downloads);
    rig.drv.reload();
    _ = try rig.run_until_state(.measuring, 2_000_000);
    try std.testing.expect(!rig.drv.info.reused_app);
    try std.testing.expectEqual(@as(u32, 2), rig.drv.stats.downloads);
    try std.testing.expectEqual(@as(u32, 2), rig.model.stats.remaps);
    try rig.run_until_frames(rig.drv.stats.frames + 5, 1_000_000);
}

test "short-range mode: switched where the firmware has it, ignored where not" {
    var rig: Rig = undefined;
    rig.init(400_000);
    rig.drv.configure(.{ .short_range = true });
    _ = try rig.run_until_state(.measuring, 2_000_000);
    try std.testing.expectEqual(@as(u8, tof.cmd.range_short), rig.model.active_range);
    try std.testing.expectEqual(@as(u8, tof.cmd.range_short), rig.drv.info.active_range);

    rig.init(400_000);
    rig.model.fault.no_range = true;
    rig.drv.configure(.{ .short_range = true });
    _ = try rig.run_until_state(.measuring, 2_000_000);
    try std.testing.expectEqual(@as(u8, 0), rig.drv.info.active_range);
}

test "no sensor: absent, cheap polls, then found when plugged in" {
    var rig: Rig = undefined;
    rig.init(400_000);
    rig.model.unplug();
    try rig.run(3_000_000);
    try std.testing.expectEqual(tof.State.absent, rig.drv.state);
    // One probe every 500 ms: about 6 transactions in 3 s.
    try std.testing.expect(rig.model.stats.transactions <= 8);
    rig.model.plug();
    _ = try rig.run_until_state(.measuring, 3_000_000);
    try rig.run_until_frames(3, 1_000_000);
}

test "unplugged while measuring: lost, absent, full reboot after replug" {
    var rig: Rig = undefined;
    rig.init(400_000);
    _ = try rig.run_until_state(.measuring, 2_000_000);
    try rig.run_until_frames(5, 1_000_000);
    rig.model.unplug();
    try rig.run(200_000);
    try std.testing.expectEqual(tof.State.absent, rig.drv.state);
    try std.testing.expectEqual(tof.ErrCode.lost, rig.drv.err.code);
    rig.model.plug();
    _ = try rig.run_until_state(.measuring, 3_000_000);
    try std.testing.expectEqual(@as(u32, 2), rig.drv.stats.downloads);
    const f = rig.drv.stats.frames;
    try rig.run_until_frames(f + 5, 1_000_000);
}

test "a silent power glitch while measuring is caught by the frame timeout" {
    var rig: Rig = undefined;
    rig.init(400_000);
    _ = try rig.run_until_state(.measuring, 2_000_000);
    rig.model.power_cycle();
    _ = try rig.run_until_state(.failed, 2_000_000);
    try std.testing.expectEqual(tof.ErrCode.frame_timeout, rig.drv.err.code);
    _ = try rig.run_until_state(.measuring, 3_000_000);
}

test "a NACK or bus timeout at any transaction of the boot fails cleanly and recovers" {
    // Count the transactions a clean boot takes.
    var rig: Rig = undefined;
    rig.init(1_000_000);
    _ = try rig.run_until_state(.measuring, 2_000_000);
    const boot_tx = rig.model.stats.transactions;
    try std.testing.expect(boot_tx > 30);

    for ([_]i2c.Error{ error.DataNack, error.Timeout, error.ArbLost, error.Abort }) |kind| {
        var n: u32 = 0;
        while (n < boot_tx) : (n += 3) {
            rig.init(1_000_000);
            rig.model.fault.fail_at = n;
            rig.model.fault.fail_kind = kind;
            _ = try rig.run_until_state(.measuring, 4_000_000);
            const want: tof.ErrCode = switch (kind) {
                error.DataNack => .nack_data,
                error.Timeout => .bus_timeout,
                error.ArbLost => .arb_lost,
                else => .bus_abort,
            };
            try std.testing.expectEqual(want, rig.drv.err.code);
            try std.testing.expect(rig.drv.stats.i2c_errors >= 1);
        }
    }
}

test "an address NACK mid-boot counts as a lost sensor and recovers" {
    var rig: Rig = undefined;
    var n: u32 = 2;
    while (n < 40) : (n += 5) {
        rig.init(400_000);
        rig.model.fault.fail_at = n;
        rig.model.fault.fail_kind = error.AddrNack;
        _ = try rig.run_until_state(.measuring, 4_000_000);
    }
}

test "stuck busy: bootloader busy timeout, recovers when it clears" {
    var rig: Rig = undefined;
    rig.init(400_000);
    rig.model.fault.stuck_busy = true;
    _ = try rig.run_until_state(.failed, 1_000_000);
    try std.testing.expectEqual(tof.ErrCode.bl_busy, rig.drv.err.code);
    try std.testing.expectEqual(tof.Step.bl_status, rig.drv.err.step);
    rig.model.fault.stuck_busy = false;
    _ = try rig.run_until_state(.measuring, 3_000_000);
}

test "stuck busy in the application: command busy timeout" {
    var rig: Rig = undefined;
    rig.init(400_000);
    _ = try rig.run_until_state(.measuring, 2_000_000);
    rig.model.fault.stuck_busy = true;
    rig.drv.configure(.{ .period_ms = 50 });
    _ = try rig.run_until_state(.failed, 1_000_000);
    try std.testing.expectEqual(tof.ErrCode.cmd_busy, rig.drv.err.code);
    rig.model.fault.stuck_busy = false;
    _ = try rig.run_until_state(.measuring, 3_000_000);
    try std.testing.expectEqual(@as(u8, 50), @as(u8, @intCast(rig.model.period_ms)));
}

test "the bootloader rejects a chunk: bl_status error with the status byte" {
    var rig: Rig = undefined;
    rig.init(400_000);
    rig.model.fault.bl_reject = true;
    _ = try rig.run_until_state(.failed, 1_000_000);
    try std.testing.expectEqual(tof.ErrCode.bl_status, rig.drv.err.code);
    try std.testing.expectEqual(@as(u32, 2), rig.drv.err.raw & 0xFF);
    rig.model.fault.bl_reject = false;
    _ = try rig.run_until_state(.measuring, 3_000_000);
}

test "the model rejects a bad bootloader checksum (so bl_bad == 0 proves the driver's)" {
    var model: virtual.Model = .{};
    var bus: virtual.Bus = .{ .model = &model };
    try bus.write(tof.address, &.{ tof.reg.enable, 0x01 });
    model.t_us += 10_000;
    var b: [3]u8 = undefined;
    try bus.write(tof.address, &.{ 0x08, tof.bl.addr_ram, 2, 0, 0, 0x55 });
    model.t_us += 1000;
    try bus.write_read(tof.address, &.{0x08}, &b);
    try std.testing.expectEqual(@as(u8, 0x02), b[0]);
    try std.testing.expectEqual(@as(u32, 1), model.stats.bl_bad);
    const good = tof.bl_checksum(&.{ tof.bl.addr_ram, 2, 0, 0 });
    try bus.write(tof.address, &.{ 0x08, tof.bl.addr_ram, 2, 0, 0, good });
    model.t_us += 1000;
    try bus.write_read(tof.address, &.{0x08}, &b);
    try std.testing.expectEqual(@as(u8, 0), b[0]);
    try std.testing.expectEqual(@as(u8, 0xFF), b[0] +% b[1] +% b[2]);
}

test "an image that does not start: app timeout, CPU reset, recovery" {
    var rig: Rig = undefined;
    rig.init(400_000);
    rig.model.fault.corrupt_ram = true;
    _ = try rig.run_until_state(.failed, 2_000_000);
    try std.testing.expectEqual(tof.ErrCode.app_timeout, rig.drv.err.code);
    try std.testing.expect(rig.drv.force_reset);
    rig.model.fault.corrupt_ram = false;
    _ = try rig.run_until_state(.measuring, 4_000_000);
    // Never with powerup_select = 2 (it survives resets: a badge hung).
    try std.testing.expectEqual(@as(u32, 0), rig.model.stats.remaps_ps2);
}

/// The chip as a badge left it: powerup_select 2 from an older driver,
/// the application running, and resets with 2 hanging (ENABLE 0x21).
fn leave_ps2(rig: *Rig) !void {
    _ = try rig.run_until_state(.measuring, 2_000_000);
    rig.model.fault.ps2_hang = true;
    rig.model.powerup_select = 2;
}

test "a chip left at powerup_select 2 recovers on a reload (CPU reset clears it)" {
    var rig: Rig = undefined;
    rig.init(400_000);
    try leave_ps2(&rig);
    rig.drv.reload();
    _ = try rig.run_until_state(.measuring, 3_000_000);
    try std.testing.expectEqual(@as(u2, 1), rig.model.powerup_select);
    try std.testing.expectEqual(@as(u32, 0), rig.model.stats.remaps_ps2);
}

test "a chip hung at powerup_select 2 (cpu_ready never) is rescued by a forced CPU reset" {
    var rig: Rig = undefined;
    rig.init(400_000);
    try leave_ps2(&rig);
    // Something else reset it with 2 set: hung, ENABLE 0x21, as on the badge.
    rig.model.write_reg(tof.reg.reset, 0x80);
    _ = try rig.run_until_state(.failed, 3_000_000); // the frame timeout notices
    try std.testing.expectEqual(tof.ErrCode.frame_timeout, rig.drv.first_err.code);
    _ = try rig.run_until_state(.measuring, 4_000_000);
    try std.testing.expectEqual(@as(u2, 1), rig.model.powerup_select);
    try std.testing.expectEqual(@as(u16, 0), rig.drv.fail_streak);
}

test "cpu_ready never comes after a plain power-on: forced CPU reset (PLL off first)" {
    var rig: Rig = undefined;
    rig.init(400_000);
    // Plugged in hung: PON on, powerup_select 2, CPU dead.
    rig.model.fault.ps2_hang = true;
    rig.model.fault.reset_needs_pll_off = true;
    rig.model.powerup_select = 2;
    rig.model.pon = true;
    rig.model.mode = .dead;
    _ = try rig.run_until_state(.measuring, 3_000_000);
    try std.testing.expectEqual(@as(u32, 1), rig.drv.stats.rescues);
    // Rescued inside the first attempt: no error at all.
    try std.testing.expectEqual(tof.ErrCode.none, rig.drv.err.code);
}

test "a reset without turning the PLL off would hang; the driver's never does" {
    var rig: Rig = undefined;
    rig.init(400_000);
    rig.model.fault.reset_needs_pll_off = true;
    _ = try rig.run_until_state(.measuring, 2_000_000);
    for (0..3) |_| {
        rig.drv.reload();
        _ = try rig.run_until_state(.measuring, 3_000_000);
    }
    try std.testing.expectEqual(@as(u32, 0), rig.drv.stats.rescues);
}

test "repeated failures of every kind while measuring always come back, never via powerup_select 2" {
    var rig: Rig = undefined;
    rig.init(400_000);
    _ = try rig.run_until_state(.measuring, 2_000_000);
    const kinds = [_]virtual.Error{ error.DataNack, error.Timeout, error.AddrNack, error.ArbLost };
    var i: u32 = 0;
    while (i < 24) : (i += 1) {
        rig.model.fault.fail_at = i % 7;
        rig.model.fault.fail_kind = kinds[i % kinds.len];
        if (i % 5 == 4) rig.drv.reload();
        // Long enough for the fault to fire, a 1 s retry and a reboot.
        try rig.run(300_000);
        try rig.run_until_frames(rig.drv.stats.frames + 3, 5_000_000);
        try std.testing.expectEqual(tof.State.measuring, rig.drv.state);
    }
    try std.testing.expectEqual(@as(u32, 0), rig.model.stats.remaps_ps2);
}

test "the bus scan finds the sensor and other devices" {
    var model: virtual.Model = .{};
    model.others = @as(u128, 1) << 0x29;
    var bus: virtual.Bus = .{ .model = &model };
    var s: i2c.Scan = .{};
    while (s.passes == 0) s.step(&bus, 16);
    try std.testing.expect(s.has(0x41) and s.has(0x29));
    try std.testing.expectEqual(@as(u8, 2), s.count());
    model.unplug();
    s.step(&bus, 112);
    try std.testing.expect(!s.has(0x41) and s.has(0x29));
}

test "the log records the boot and the first frame" {
    var rig: Rig = undefined;
    rig.init(400_000);
    _ = try rig.run_until_state(.measuring, 2_000_000);
    try rig.run_until_frames(1, 1_000_000);
    var buf: [tof.log_len]tof.LogEntry = undefined;
    const l = rig.drv.recent_log(&buf);
    try std.testing.expect(l.len >= 6);
    var saw_remap = false;
    var saw_first = false;
    var t_prev: u64 = 0;
    for (l) |e| {
        saw_remap = saw_remap or e.step == .bl_remap;
        saw_first = saw_first or e.step == .first_frame;
        try std.testing.expect(e.time_us >= t_prev);
        t_prev = e.time_us;
    }
    try std.testing.expect(saw_remap and saw_first);
}

test "orientation maps every screen cell to a distinct zone" {
    for (0..8) |k| {
        const o: types.Orientation = .{ .flip_x = k & 1 != 0, .flip_y = k & 2 != 0, .transpose = k & 4 != 0 };
        var seen: u16 = 0;
        for (0..3) |r| for (0..3) |c| {
            seen |= @as(u16, 1) << o.index(@intCast(c), @intCast(r));
        };
        try std.testing.expectEqual(@as(u16, 0x1FF), seen);
    }
}

// ---- user SPAD masks and the depth photo (M2) ----

const spad = tof.spad;
const scene = tof.scene;

fn run_until_mask(rig: *Rig, gen: u32, limit_us: u64) !void {
    const t0 = rig.now;
    while (rig.now - t0 < limit_us) {
        try rig.tick();
        if (rig.drv.frame_mask_gen == gen and rig.drv.stats.frames > 0) return;
    }
    std.debug.print("state {s} step {s} err {s} raw {x}\n", .{
        @tagName(rig.drv.state), rig.drv.step.name(), rig.drv.err.code.name(), rig.drv.err.raw,
    });
    return error.MaskNeverActive;
}

test "a user mask: written with spad_map_id 14, read back, results from the SPAD scene" {
    var rig: Rig = undefined;
    rig.init(400_000);
    _ = try rig.run_until_state(.measuring, 2_000_000);
    try rig.run_until_frames(5, 1_000_000);
    const shot = spad.shot(.coarse, 4);
    try std.testing.expectEqual(@as(?spad.Problem, null), rig.drv.set_user_mask(&shot.mask));
    const gen = rig.drv.mask_gen;
    try run_until_mask(&rig, gen, 1_000_000);
    try std.testing.expectEqual(spad.map_id, rig.model.spad_map);
    try std.testing.expectEqual(@as(u32, 1), rig.model.stats.spad_writes);
    try std.testing.expectEqual(@as(u32, 0), rig.model.stats.spad_rejects + rig.model.stats.spad_ignored);
    try std.testing.expectEqual(@as(u32, 1), rig.drv.stats.mask_writes);
    try std.testing.expectEqual(@as(u32, 0), rig.drv.stats.spad_mismatch);
    try std.testing.expectEqual(@as(?u16, null), spad.diff(&shot.mask, &rig.model.user_mask));
    try std.testing.expectEqual(tof.ErrCode.none, rig.drv.err.code);
    // Switch time: the request to the first frame with the mask, well
    // under a fifth of a second at 400 kHz on the 3 ms budget.
    try std.testing.expectEqual(@as(u32, 1), rig.drv.stats.mask_switches);
    try std.testing.expect(rig.drv.stats.mask_switch_us > 30_000 and rig.drv.stats.mask_switch_us < 200_000);
    // Frames decode to what the model measured, which is the SPAD scene
    // seen through the mask: each channel's pair, two objects on edges.
    var frames: u32 = 0;
    var last = rig.drv.stats.frames;
    while (frames < 20) {
        try rig.tick();
        if (rig.drv.stats.frames == last) continue;
        last = rig.drv.stats.frames;
        // By the device's result number: frame.seq counts frames across a
        // reconfiguration (results lost while stopped are not counted).
        const snap = &rig.model.history[rig.drv.last_num.? % 8];
        try std.testing.expectEqual(rig.drv.last_num.?, @as(u8, @truncate(snap.frame.seq)));
        var want: [9]types.Zone = undefined;
        scene.zone_results(snap.t_us, &shot.mask, &want);
        for (want, rig.drv.frame.zones) |w, g| {
            try std.testing.expectEqual(w.near, g.near);
            try std.testing.expectEqual(w.far, g.far);
        }
        frames += 1;
    }
    // Every channel of the shot sees something (no dead pair in shot 4).
    for (rig.drv.frame.zones) |z| try std.testing.expect(z.near.valid());
}

test "invalid masks are refused before anything is sent" {
    var rig: Rig = undefined;
    rig.init(400_000);
    _ = try rig.run_until_state(.measuring, 2_000_000);
    var bad = spad.shot(.coarse, 0).mask;
    bad.ch[0][1] = 0; // channel 1 down to one SPAD
    const gen = rig.drv.mask_gen;
    const p = rig.drv.set_user_mask(&bad) orelse return error.Accepted;
    try std.testing.expectEqual(spad.Kind.lonely, p.kind);
    try std.testing.expectEqual(gen, rig.drv.mask_gen);
    try std.testing.expectEqual(@as(u32, 1), rig.drv.stats.mask_rejects);
    try rig.run(300_000);
    try std.testing.expectEqual(@as(u8, 1), rig.model.spad_map);
    try std.testing.expectEqual(@as(u32, 0), rig.model.stats.spad_loads);
    try std.testing.expectEqual(tof.State.measuring, rig.drv.state);
}

/// Send an application command straight through the bus and wait for it.
fn raw_cmd(rig: *Rig, c: u8) !u8 {
    try rig.drv.bus.write(tof.address, &.{ tof.reg.cmd_stat, c });
    var b: [1]u8 = .{0x10};
    var n: u32 = 0;
    while (b[0] >= 0x10) : (n += 1) {
        if (n > 100) return error.Busy;
        try rig.drv.bus.write_read(tof.address, &.{tof.reg.cmd_stat}, &b);
    }
    return b[0];
}

test "the model checks the SPAD page: rejected if broken, ignored without map 14" {
    var rig: Rig = undefined;
    rig.init(400_000);
    _ = try rig.run_until_state(.measuring, 2_000_000);
    _ = try raw_cmd(&rig, tof.cmd.stop);
    rig.drv.state = .off; // keep the driver off the bus
    var page: [1 + spad.page_len]u8 = undefined;
    page[0] = spad.reg.enable;
    // A valid page while the common page has map 1: ignored (DS 0x0A).
    spad.encode(&spad.shot(.coarse, 0).mask, page[1..]);
    try std.testing.expectEqual(@as(u8, 0), try raw_cmd(&rig, spad.cmd_load));
    try rig.drv.bus.write(tof.address, &page);
    try std.testing.expectEqual(spad.stat_ignored, try raw_cmd(&rig, tof.cmd.write_config));
    try std.testing.expect(!rig.model.user_valid);
    // MEASURE on map 14 without a valid page fails.
    rig.model.spad_map = spad.map_id;
    try std.testing.expectEqual(@as(u8, 2), try raw_cmd(&rig, tof.cmd.measure));
    // A broken page on map 14: STAT_ERR_CONFIG, nothing kept.
    // (A row mixing channel 1 with 8 or 9 cannot even be encoded: with
    // the row's select bit set, 1 reads back as 9. The driver's validator
    // catches it before encoding.)
    var bad = spad.shot(.coarse, 0).mask;
    bad.ch[0][1] = 0; // channel 1 down to one SPAD
    spad.encode(&bad, page[1..]);
    _ = try raw_cmd(&rig, spad.cmd_load);
    try rig.drv.bus.write(tof.address, &page);
    try std.testing.expectEqual(@as(u8, 2), try raw_cmd(&rig, tof.cmd.write_config));
    try std.testing.expectEqual(@as(u32, 1), rig.model.stats.spad_rejects);
    // A good one is kept and reads back byte for byte.
    spad.encode(&spad.shot(.coarse, 0).mask, page[1..]);
    _ = try raw_cmd(&rig, spad.cmd_load);
    try rig.drv.bus.write(tof.address, &page);
    try std.testing.expectEqual(@as(u8, 0), try raw_cmd(&rig, tof.cmd.write_config));
    _ = try raw_cmd(&rig, spad.cmd_load);
    var back: [4 + spad.page_len]u8 = undefined;
    try rig.drv.bus.write_read(tof.address, &.{tof.reg.config_result}, &back);
    try std.testing.expectEqual(spad.cid, back[0]);
    try std.testing.expectEqualSlices(u8, page[1..], back[4..]);
}

test "a read-back that differs is counted and shown, not fatal" {
    var rig: Rig = undefined;
    rig.init(400_000);
    rig.model.fault.spad_corrupt = true;
    _ = try rig.run_until_state(.measuring, 2_000_000);
    const shot = spad.shot(.coarse, 0);
    try std.testing.expectEqual(@as(?spad.Problem, null), rig.drv.set_user_mask(&shot.mask));
    try run_until_mask(&rig, rig.drv.mask_gen, 1_000_000);
    try std.testing.expectEqual(@as(u32, 1), rig.drv.stats.spad_mismatch);
    try std.testing.expectEqual(@as(u16, 0x0000), rig.drv.stats.spad_diff); // row 0, column 0
    try std.testing.expectEqual(tof.State.measuring, rig.drv.state);
}

test "mask switches while measuring skip the common page; normal map comes back" {
    var rig: Rig = undefined;
    rig.init(400_000);
    _ = try rig.run_until_state(.measuring, 2_000_000);
    for (0..4) |k| {
        const shot = spad.shot(.fine, @intCast(k));
        try std.testing.expectEqual(@as(?spad.Problem, null), rig.drv.set_user_mask(&shot.mask));
        try run_until_mask(&rig, rig.drv.mask_gen, 1_000_000);
        try std.testing.expectEqual(@as(?u16, null), spad.diff(&shot.mask, &rig.model.user_mask));
    }
    try std.testing.expectEqual(@as(u32, 4), rig.drv.stats.mask_writes);
    // Mask-only switches are quicker than the first (no common page).
    try std.testing.expect(rig.drv.stats.mask_switch_us <= rig.drv.stats.mask_switch_max_us);
    try std.testing.expect(rig.drv.stats.mask_switch_us < 150_000);
    rig.drv.configure(.{});
    try rig.run(300_000);
    try std.testing.expectEqual(@as(u8, 1), rig.model.spad_map);
    try std.testing.expectEqual(@as(u32, 0), rig.drv.frame_mask_gen);
    try rig.run_until_frames(rig.drv.stats.frames + 3, 1_000_000);
    const snap = &rig.model.history[rig.drv.last_num.? % 8];
    for (rig.drv.frame.zones, snap.frame.zones) |got, want| try std.testing.expectEqual(want, got);
    // After a reload (fresh application, page gone) map 14 is rewritten.
    try std.testing.expectEqual(@as(?spad.Problem, null), rig.drv.set_user_mask(&spad.grid_3x3()));
    try run_until_mask(&rig, rig.drv.mask_gen, 1_000_000);
    rig.drv.reload();
    _ = try rig.run_until_state(.measuring, 2_000_000);
    try std.testing.expect(rig.model.user_valid);
    try rig.run_until_frames(rig.drv.stats.frames + 3, 1_000_000);
    try std.testing.expectEqual(rig.drv.mask_gen, rig.drv.frame_mask_gen);
}

/// The scene's first-object depth for image pixel (col, row) at `t_us`.
fn scene_pixel(t_us: u64, col: u8, row: u8) types.Target {
    var m: spad.Mask = .{};
    m.ch[row][col] = 1;
    m.ch[row][col + 1] = 1;
    var z: [9]types.Zone = undefined;
    scene.zone_results(t_us, &m, &z);
    return z[0].near;
}

test "a depth photo: 9x10 in 10 shots, then 17x10 with the fine pass, matching the scene" {
    for ([_]bool{ false, true }) |fine| {
        var rig: Rig = undefined;
        rig.init(400_000);
        rig.drv.budget_us = 6000;
        _ = try rig.run_until_state(.measuring, 2_000_000);
        var scan: tof.depth.Scan = .{ .fine = fine, .exposure = 2, .repeat = false };
        const t_start = rig.now;
        while (scan.phase != .done) {
            try rig.tick();
            scan.update(&rig.drv, rig.now);
            if (rig.now - t_start > 20_000_000) return error.ScanTooSlow;
            try std.testing.expect(scan.phase != .failed);
        }
        const t_end = rig.now;
        try std.testing.expectEqual(@as(u32, 1), scan.photos);
        try std.testing.expectEqual(@as(u32, if (fine) 20 else 10), rig.drv.stats.mask_writes);
        try std.testing.expectEqual(@as(u32, 0), rig.drv.stats.spad_mismatch);
        // Model numbers (docs/TOF.md): about 2 s a 9x10 photo at N = 2.
        try std.testing.expect(scan.last_photo_us < if (fine) @as(u32, 5_000_000) else 2_500_000);
        var ok: u32 = 0;
        var compared: u32 = 0;
        for (0..tof.depth.height) |r| for (0..tof.depth.width) |c| {
            const p = scan.img[r][c];
            const in_pass = fine or c % 2 == 0;
            if (!in_pass) {
                try std.testing.expectEqual(tof.depth.State.unset, p.state);
                continue;
            }
            try std.testing.expect(p.state != .unset);
            if (p.has_depth()) ok += 1;
            // The pixel is the scene's depth at that pair at some moment of
            // the scan, within the jitter, or between two frames 33 ms
            // apart (an exposure of 2 averages an edge the ball crosses).
            if (!p.has_depth()) continue;
            var t = t_start;
            var match = false;
            var prev: ?types.Target = null;
            while (t <= t_end and !match) : (t += 16_667) {
                const want = scene_pixel(t, @intCast(c), @intCast(r));
                if (!want.valid()) continue;
                match = @abs(@as(i32, p.mm) - want.mm) < 30;
                if (prev) |q| {
                    const lo = @min(q.mm, want.mm);
                    const hi = @max(q.mm, want.mm);
                    match = match or (p.mm + 30 > lo and p.mm < hi + 30);
                }
                if (t >= t_start + 33_333) prev = scene_pixel(t - 33_333, @intCast(c), @intCast(r));
            }
            if (!match) std.debug.print("pixel {d},{d}: {any}\n", .{ c, r, p });
            try std.testing.expect(match);
            compared += 1;
        };
        // The dead pair (SPADs 6 and 7 of physical row 4 = image row 3).
        try std.testing.expectEqual(tof.depth.State.missing, scan.img[3][6].state);
        try std.testing.expect(ok >= scan.pixels() - 4);
        try std.testing.expect(compared >= scan.pixels() * 2 / 3);
        // The box (700 mm) is in the right half, the floor (nearer than
        // the wall) in the bottom row.
        var box: u32 = 0;
        var floor: u32 = 0;
        for (0..tof.depth.height) |r| for (tof.depth.width / 2..tof.depth.width) |c| {
            if (scan.img[r][c].has_depth() and @abs(@as(i32, scan.img[r][c].mm) - 700) < 30) box += 1;
        };
        for (scan.img[9]) |p| floor += @intFromBool(p.has_depth() and p.mm < 700);
        try std.testing.expect(box >= 6);
        try std.testing.expect(floor >= 4);
    }
}
