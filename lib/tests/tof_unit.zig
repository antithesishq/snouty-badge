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
    rig.drv.budget_us = 6000;
    rig.drv.configure(.{ .histograms = true });
    _ = try rig.run_until_state(.measuring, 3_000_000);
    const sets0 = rig.drv.stats.hist_sets;
    try rig.run(2_000_000);
    // At least 3 sets a second.
    try std.testing.expect(rig.drv.stats.hist_sets - sets0 >= 6);
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
    // The second attempt also tried DS000693's powerup_select = 2 variant.
    try std.testing.expect(rig.model.stats.remaps_ps2 >= 1);
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
