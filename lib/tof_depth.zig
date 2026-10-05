//! The slow-scan depth photo (docs/TOF.md M2, snouty-sense DEPTH): the
//! TMF8820 measures nine zones at a time, but a user SPAD mask can make
//! each zone a pair of SPADs anywhere on the 18x10 array. Cycling through
//! masks that tile the array (lib/tof_spad.zig `shot`) and keeping N
//! frames of each builds a 9x10 image in 10 shots, or 17x10 in 20 with
//! the fine pass (pairs shifted one SPAD). Host-side only: the sensor sees
//! ordinary mask switches (`Tof.set_user_mask`).
//!
//! `Scan.update(drv, now_us)` once per update, after `drv.poll`: it sets
//! the next shot's mask, waits for frames measured with it
//! (`drv.frame_mask_gen`), averages each zone's first object over
//! `exposure` frames (weighted by confidence) into the pixel the shot's
//! channel covers, and moves on; with `repeat` the photo starts over when
//! done, overwriting pixels as it goes (a live slow-scan).
//!
//! Pixels: `missing` when no frame of the exposure saw an object in that
//! pair (out of range, or dead SPADs), `low` when the mean confidence is
//! under `low_conf`.
const std = @import("std");
const types = @import("tof_types.zig");
const spad = @import("tof_spad.zig");

pub const width = 17;
pub const height = spad.rows;
pub const max_exposure = 16;
/// Mean confidence below this marks a pixel `low`.
pub const low_conf: u8 = 24;

pub const State = enum(u2) { unset, ok, low, missing };

pub const Px = struct {
    mm: u16 = 0,
    conf: u8 = 0,
    state: State = .unset,

    pub fn has_depth(p: Px) bool {
        return p.state == .ok or p.state == .low;
    }
};

pub const Phase = enum(u2) { idle, running, done, failed };

pub const Scan = struct {
    /// Add the fine pass (17 columns, 20 shots).
    fine: bool = false,
    /// Frames averaged per shot.
    exposure: u8 = 2,
    /// Frames dropped after each switch before averaging (0: the model
    /// needs none; raise it if the hardware's first frame after a switch
    /// is off).
    settle: u8 = 0,
    /// Start over when the photo is done.
    repeat: bool = true,

    phase: Phase = .idle,
    shot_i: u8 = 0,
    cur: spad.Shot = .{},
    gen: u32 = 0,
    seen_frames: u32 = 0,
    got: u8 = 0,
    skipped: u8 = 0,
    acc_mm: [9]u64 = @splat(0),
    acc_w: [9]u32 = @splat(0),
    acc_n: [9]u8 = @splat(0),
    img: [height][width]Px = @splat(@splat(.{})),

    photo_t0: u64 = 0,
    shot_t0: u64 = 0,
    /// Times of the last finished shot and photo (us), photos finished.
    last_shot_us: u32 = 0,
    last_photo_us: u32 = 0,
    photos: u32 = 0,
    /// The validator refused a layout (a bug in tof_spad if ever set).
    problem: ?spad.Problem = null,

    pub fn shots(s: *const Scan) u8 {
        return if (s.fine) 2 * spad.shots_per_pass else spad.shots_per_pass;
    }

    /// Pixels a whole photo fills.
    pub fn pixels(s: *const Scan) u32 {
        return if (s.fine) 9 * height + 8 * height else 9 * height;
    }

    /// Clear the image and start from the first shot on the next update.
    pub fn restart(s: *Scan) void {
        s.phase = .idle;
        s.img = @splat(@splat(.{}));
        s.problem = null;
    }

    /// Progress through the photo in 1/1000.
    pub fn progress(s: *const Scan) u32 {
        if (s.phase == .done) return 1000;
        if (s.phase != .running) return 0;
        const per: u32 = @as(u32, s.exposure) + s.settle;
        const done: u32 = @as(u32, s.shot_i) * per + s.got + s.skipped;
        return done * 1000 / (@as(u32, s.shots()) * per);
    }

    pub fn update(s: *Scan, drv: anytype, now_us: u64) void {
        switch (s.phase) {
            .idle => s.begin(drv, 0, now_us),
            .running => s.take(drv, now_us),
            .done, .failed => {},
        }
    }

    fn begin(s: *Scan, drv: anytype, i: u8, now_us: u64) void {
        s.shot_i = i;
        s.cur = if (i < spad.shots_per_pass) spad.shot(.coarse, i) else spad.shot(.fine, i - spad.shots_per_pass);
        if (drv.set_user_mask(&s.cur.mask)) |p| {
            s.problem = p;
            s.phase = .failed;
            return;
        }
        s.gen = drv.mask_gen;
        s.got = 0;
        s.skipped = 0;
        s.acc_mm = @splat(0);
        s.acc_w = @splat(0);
        s.acc_n = @splat(0);
        s.seen_frames = drv.stats.frames;
        s.shot_t0 = now_us;
        if (i == 0) s.photo_t0 = now_us;
        s.phase = .running;
    }

    fn take(s: *Scan, drv: anytype, now_us: u64) void {
        if (drv.stats.frames == s.seen_frames) return;
        s.seen_frames = drv.stats.frames;
        if (drv.frame_mask_gen != s.gen) return;
        const f: *const types.Frame = drv.latest() orelse return;
        if (s.skipped < s.settle) {
            s.skipped += 1;
            return;
        }
        for (s.cur.px, 0..) |px, c| if (px != null) {
            const t = f.zones[c].near;
            if (!t.valid()) continue;
            s.acc_mm[c] += @as(u64, t.mm) * t.confidence;
            s.acc_w[c] += t.confidence;
            s.acc_n[c] += 1;
        };
        s.got += 1;
        if (s.got < s.exposure) return;
        s.finish_shot(now_us);
        if (s.shot_i + 1 < s.shots()) {
            s.begin(drv, s.shot_i + 1, now_us);
            return;
        }
        s.last_photo_us = @intCast(@min(now_us -| s.photo_t0, std.math.maxInt(u32)));
        s.photos += 1;
        if (s.repeat) s.begin(drv, 0, now_us) else s.phase = .done;
    }

    fn finish_shot(s: *Scan, now_us: u64) void {
        for (s.cur.px, 0..) |px, c| if (px) |p| {
            const out = &s.img[p.row][p.col];
            if (s.acc_n[c] == 0) {
                out.* = .{ .state = .missing };
                continue;
            }
            const conf: u8 = @intCast(s.acc_w[c] / s.acc_n[c]);
            out.* = .{
                .mm = @intCast(s.acc_mm[c] / s.acc_w[c]),
                .conf = conf,
                .state = if (conf < low_conf) .low else .ok,
            };
        };
        s.last_shot_us = @intCast(@min(now_us -| s.shot_t0, std.math.maxInt(u32)));
    }

    /// Pixel (col, row) of the 17-wide grid, or for a pixel without depth
    /// the mean of its neighbours that have one (same pass: +-2 columns
    /// and +-1 row; 0 if none). For display only.
    pub fn depth_or_fill(s: *const Scan, col: usize, row: usize) u16 {
        const p = s.img[row][col];
        if (p.has_depth()) return p.mm;
        var sum: u32 = 0;
        var n: u32 = 0;
        const offs = [_][2]i32{ .{ -2, 0 }, .{ 2, 0 }, .{ 0, -1 }, .{ 0, 1 } };
        for (offs) |o| {
            const c = @as(i32, @intCast(col)) + o[0];
            const r = @as(i32, @intCast(row)) + o[1];
            if (c < 0 or c >= width or r < 0 or r >= height) continue;
            const q = s.img[@intCast(r)][@intCast(c)];
            if (!q.has_depth()) continue;
            sum += q.mm;
            n += 1;
        }
        return if (n == 0) 0 else @intCast(sum / n);
    }
};
