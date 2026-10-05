//! Hand pose from the TMF8820's 3x3 zones (docs/TOF.md; design and honest
//! limits in carts/snouty-morph/SPEC.md section 2). Pure: no hardware, no
//! cart API, no allocation; f32 only (the M33 FPU is single precision)
//! and no libm, so it builds into a cart unchanged. Runs once per sensor
//! frame (30 Hz), roughly ten microseconds.
//!
//!     var est: tof_pose.Estimator = .{};            // .{ .config = ... }
//!     const pose = est.update(&frame, hist_or_null, orientation);
//!
//! What it does per frame:
//! 1. Background model per zone: learned while the zone sees no hand
//!    (farther or vanished targets push it back at once, matching ones
//!    nudge it, a nearer target that stays perfectly still for
//!    `absorb_frames` becomes background). Nothing beyond `max_mm` is ever
//!    a hand.
//! 2. Hand zones and their covered fraction (histogram peak areas when
//!    available, confidences otherwise).
//! 3. Coverage centroid with a sub-zone shift for partly covered zones
//!    (x, y), weighted mean distance with outlier rejection (z), a ridge
//!    least-squares plane through the hand points (pitch, roll, each with
//!    a confidence from the points' spread), second moments of the blob
//!    (yaw, confidence from its elongation).
//! 4. One Euro filters per DoF (steady when still, quick when moving),
//!    velocities from their derivative stage, presence with hysteresis.
//!
//! Coordinates: screen cells after the orientation (col 0 left, row 0
//! top); x right, y up, z from the sensor toward the hand.
const std = @import("std");
pub const types = @import("tof_types.zig");
/// Synthetic frames from a hand scene (tests, snouty-morph's ghost hand).
pub const synth = @import("tof_synth.zig");

const Frame = types.Frame;
const Histograms = types.Histograms;
const Orientation = types.Orientation;

pub const FilterParams = struct {
    /// Hz: the cutoff while still (lower = steadier).
    min_cutoff: f32,
    /// Cutoff added per unit/s of speed (higher = less lag when moving).
    beta: f32,
    /// Hz: cutoff of the derivative (the reported velocity).
    d_cutoff: f32 = 2.0,
};

pub const Config = struct {
    /// Field of view (SPAD map 1: 33 x 32 degrees).
    fov_x_deg: f32 = 33,
    fov_y_deg: f32 = 32,
    /// Hand range along the zone ray.
    min_mm: f32 = 15,
    max_mm: f32 = 600,
    /// Targets below this confidence are ignored.
    min_confidence: u8 = 6,
    /// A target nearer than background - max(margin_mm, margin_frac * bg)
    /// is a hand candidate.
    bg_margin_mm: f32 = 50,
    bg_margin_frac: f32 = 0.08,
    /// Frames of farther-or-missing targets before the background moves back.
    bg_push_frames: u8 = 3,
    /// EMA weight of a measurement matching the background.
    bg_ema: f32 = 0.1,
    /// A candidate that stays within still_mm for absorb_frames (8 s at
    /// 30 Hz) becomes background.
    still_mm: f32 = 6,
    absorb_frames: u16 = 240,
    /// Zones this far from the first distance estimate are dropped.
    outlier_mm: f32 = 120,
    /// Covered fraction clamp for a hand zone.
    min_coverage: f32 = 0.15,
    /// Total coverage (sum over zones) for a frame to count as "hand seen".
    present_coverage: f32 = 0.15,
    /// Consecutive frames with a hand before the pose reports present (a
    /// one-frame blip in one zone is not a hand).
    appear_frames: u8 = 2,
    /// Frames without a hand before the pose reports absent (holds meanwhile).
    lost_frames: u8 = 4,
    /// Histogram bin width and the bin of distance 0.
    hist_bin_mm: f32 = 57,
    hist_offset_bins: f32 = 0,
    /// dt when frame timestamps are missing or non-increasing.
    default_dt: f32 = 1.0 / 30.0,
    /// Filters: x, y in fractions of the half field of view; z in mm;
    /// angles in radians.
    xy_filter: FilterParams = .{ .min_cutoff = 1.2, .beta = 1.5 },
    z_filter: FilterParams = .{ .min_cutoff = 1.0, .beta = 0.02 },
    tilt_filter: FilterParams = .{ .min_cutoff = 0.8, .beta = 0.6 },
    yaw_filter: FilterParams = .{ .min_cutoff = 0.6, .beta = 0.4 },
    /// Cutoff (Hz) of the fast z velocity used for punches.
    punch_cutoff_hz: f32 = 8,
    /// Per-frame factor pulling an unmeasured tilt or yaw toward 0.
    relax: f32 = 0.95,
};

pub const Pose = struct {
    /// A hand is being tracked (true for `lost_frames` after the last sighting).
    present: bool = false,
    /// This frame saw the hand (false while holding through a dropout).
    seen: bool = false,
    /// Hand zones this frame.
    zones: u8 = 0,
    /// Covered fraction per screen cell (row-major, row 0 top), 0 = not hand.
    coverage: [types.zones]f32 = @splat(0),
    /// Lateral position, -1..1: +-1 at the outer cells' centres.
    x: f32 = 0,
    y: f32 = 0,
    x_mm: f32 = 0,
    y_mm: f32 = 0,
    /// Perpendicular distance from the sensor.
    z_mm: f32 = 0,
    /// Radians. pitch > 0: top farther; roll > 0: right side farther; yaw
    /// > 0: long axis turned counter-clockwise from vertical. yaw is
    /// continuous (unwrapped), not limited to +-pi/2.
    pitch: f32 = 0,
    roll: f32 = 0,
    yaw: f32 = 0,
    /// 0..1 per DoF; the cart scales each effect by it.
    conf_xy: f32 = 0,
    conf_z: f32 = 0,
    conf_pitch: f32 = 0,
    conf_roll: f32 = 0,
    conf_yaw: f32 = 0,
    /// Per second: x, y in their units, z in mm, angles in radians.
    vx: f32 = 0,
    vy: f32 = 0,
    vz_mm_s: f32 = 0,
    /// Lightly filtered z velocity (punch detection: strongly negative =
    /// fast approach).
    vz_fast_mm_s: f32 = 0,
    vpitch: f32 = 0,
    vroll: f32 = 0,
    vyaw: f32 = 0,
    /// Angular momentum of the centroid about the grid centre, x vy - y vx
    /// (positive = counter-clockwise circling).
    swirl: f32 = 0,
    /// Sequence number of the frame this pose came from.
    seq: u32 = 0,
};

/// One Euro filter (Casiez, Roussel, Vogel 2012): an adaptive low-pass
/// whose cutoff rises with speed.
pub const OneEuro = struct {
    x: f32 = 0,
    dx: f32 = 0,
    primed: bool = false,

    pub fn reset(f: *OneEuro, x: f32) void {
        f.* = .{ .x = x, .dx = 0, .primed = true };
    }

    pub fn step(f: *OneEuro, x: f32, dt: f32, p: FilterParams) f32 {
        if (!f.primed) {
            f.reset(x);
            return x;
        }
        const raw_dx = (x - f.x) / dt;
        f.dx += alpha(p.d_cutoff, dt) * (raw_dx - f.dx);
        const cutoff = p.min_cutoff + p.beta * @abs(f.dx);
        f.x += alpha(cutoff, dt) * (x - f.x);
        return f.x;
    }

    fn alpha(cutoff: f32, dt: f32) f32 {
        const tau = 1.0 / (2.0 * std.math.pi * cutoff);
        return 1.0 / (1.0 + tau / dt);
    }
};

const Cell = struct {
    /// Background distance along the ray, 0 = nothing within range.
    bg: f32 = 0,
    far_count: u8 = 0,
    still_count: u16 = 0,
    last: f32 = 0,
};

pub const Estimator = struct {
    config: Config = .{},
    cells: [types.zones]Cell = @splat(.{}),
    pose: Pose = .{},
    absent: u8 = 0,
    seen_run: u8 = 0,
    last_time_us: u64 = 0,
    last_z: f32 = 0,
    f_x: OneEuro = .{},
    f_y: OneEuro = .{},
    f_z: OneEuro = .{},
    f_pitch: OneEuro = .{},
    f_roll: OneEuro = .{},
    f_yaw: OneEuro = .{},

    /// Takes `frame` as the background (every zone's near target, or
    /// nothing), e.g. while the user holds a button with no hand in view.
    pub fn relearn(e: *Estimator, frame: *const Frame, orient: Orientation) void {
        for (0..types.zones) |ci| {
            const z = frame.zones[orient.index(@intCast(ci % 3), @intCast(ci / 3))];
            e.cells[ci] = .{ .bg = if (usable(z.near, e.config.min_confidence)) @floatFromInt(z.near.mm) else 0 };
        }
    }

    /// The pose after `frame` (and its histograms, if the driver dumps them).
    pub fn update(e: *Estimator, frame: *const Frame, hist: ?*const Histograms, orient: Orientation) Pose {
        const cfg = &e.config;
        var dt = cfg.default_dt;
        if (e.last_time_us != 0 and frame.time_us > e.last_time_us) {
            dt = @as(f32, @floatFromInt(@min(frame.time_us - e.last_time_us, 1_000_000))) * 1e-6;
        }
        dt = std.math.clamp(dt, 0.004, 0.25);
        e.last_time_us = frame.time_us;

        // 1-2. Background model, hand zones and their coverage.
        const cell_x = tan_deg(cfg.fov_x_deg / 3.0);
        const cell_y = tan_deg(cfg.fov_y_deg / 3.0);
        var hand: [types.zones]bool = @splat(false);
        var cov: [types.zones]f32 = @splat(0);
        var dist: [types.zones]f32 = @splat(0);
        var conf: [types.zones]f32 = @splat(0);
        var amp: [types.zones]f32 = @splat(0);
        var amp_far: [types.zones]f32 = @splat(-1);
        var max_conf: f32 = 1;
        var max_amp: f32 = 1e-6;
        for (0..types.zones) |ci| {
            const zi = orient.index(@intCast(ci % 3), @intCast(ci / 3));
            const z = frame.zones[zi];
            if (!e.classify(ci, z)) continue;
            hand[ci] = true;
            dist[ci] = @floatFromInt(z.near.mm);
            conf[ci] = @floatFromInt(z.near.confidence);
            max_conf = @max(max_conf, conf[ci]);
            if (hist) |h| {
                amp[ci] = peak_area(&h.bins[zi + 1], dist[ci], cfg) * dist[ci] * dist[ci];
                max_amp = @max(max_amp, amp[ci]);
                if (usable(z.far, cfg.min_confidence)) {
                    const fm: f32 = @floatFromInt(z.far.mm);
                    amp_far[ci] = peak_area(&h.bins[zi + 1], fm, cfg) * fm * fm;
                }
            }
        }
        var n: u8 = 0;
        var total: f32 = 0;
        for (0..types.zones) |ci| {
            if (!hand[ci]) continue;
            const zi = orient.index(@intCast(ci % 3), @intCast(ci / 3));
            const z = frame.zones[zi];
            var c: f32 = 1;
            if (hist != null) {
                c = if (amp_far[ci] >= 0) amp[ci] / @max(amp[ci] + amp_far[ci], 1e-6) else amp[ci] / max_amp;
            } else if (usable(z.far, cfg.min_confidence) and e.far_is_background(ci, z)) {
                // Confidence grows with the returned signal, which falls as
                // 1/d^2: compensate both before comparing.
                const cf: f32 = @floatFromInt(z.far.confidence);
                const fm: f32 = @floatFromInt(z.far.mm);
                const an = conf[ci] * dist[ci] * dist[ci];
                c = an / (an + cf * fm * fm);
            } else {
                c = conf[ci] / max_conf;
            }
            cov[ci] = std.math.clamp(c, cfg.min_coverage, 1.0);
            n += 1;
            total += cov[ci];
        }

        var p = e.pose;
        p.seq = frame.seq;
        p.zones = n;
        p.coverage = cov;
        const seen = total >= cfg.present_coverage;
        p.seen = seen;
        if (seen) e.seen_run +|= 1 else e.seen_run = 0;
        if (!p.present and e.seen_run < cfg.appear_frames) {
            e.pose = p;
            return p;
        }
        if (!seen) {
            if (e.absent < 255) e.absent += 1;
            if (e.absent >= cfg.lost_frames) {
                p.present = false;
                p.conf_xy = 0;
                p.conf_z = 0;
                p.conf_pitch = 0;
                p.conf_roll = 0;
                p.conf_yaw = 0;
                p.vx = 0;
                p.vy = 0;
                p.vz_mm_s = 0;
                p.vz_fast_mm_s = 0;
                p.vpitch = 0;
                p.vroll = 0;
                p.vyaw = 0;
                p.swirl = 0;
            }
            e.pose = p;
            return p;
        }
        e.absent = 0;
        const fresh = !p.present;
        p.present = true;

        // 3a. Centroid in tangent space, then the sub-zone shift.
        var tx: [types.zones]f32 = undefined;
        var ty: [types.zones]f32 = undefined;
        for (0..types.zones) |ci| {
            tx[ci] = (@as(f32, @floatFromInt(ci % 3)) - 1.0) * cell_x;
            ty[ci] = (1.0 - @as(f32, @floatFromInt(ci / 3))) * cell_y;
        }
        var c0 = centroid(&hand, &cov, &tx, &ty);
        for (0..types.zones) |ci| {
            if (!hand[ci] or cov[ci] >= 0.95) continue;
            const ox = c0[0] - tx[ci];
            const oy = c0[1] - ty[ci];
            const k = (1.0 - cov[ci]) * 0.5;
            if (@abs(ox) > 0.25 * cell_x) tx[ci] += std.math.sign(ox) * k * cell_x;
            if (@abs(oy) > 0.25 * cell_y) ty[ci] += std.math.sign(oy) * k * cell_y;
        }
        c0 = centroid(&hand, &cov, &tx, &ty);

        // 3b. Distance: weighted mean of perpendicular depths, outliers dropped.
        var depth: [types.zones]f32 = undefined;
        var w: [types.zones]f32 = undefined;
        for (0..types.zones) |ci| {
            depth[ci] = dist[ci] / @sqrt(1.0 + tx[ci] * tx[ci] + ty[ci] * ty[ci]);
            w[ci] = if (hand[ci]) cov[ci] * @max(conf[ci], 1.0) / 255.0 else 0;
        }
        var z0 = weighted_mean(&w, &depth);
        var kept: u8 = 0;
        for (0..types.zones) |ci| {
            if (w[ci] > 0 and @abs(depth[ci] - z0) > cfg.outlier_mm) w[ci] = 0;
            if (w[ci] > 0) kept += 1;
        }
        if (kept > 0) z0 = weighted_mean(&w, &depth);

        // 3c. Tilt: ridge least squares z = a + b x + c y over the hand
        // points (mm), centred on their weighted mean.
        var sw: f32 = 0;
        var mx: f32 = 0;
        var my: f32 = 0;
        for (0..types.zones) |ci| {
            sw += w[ci];
            mx += w[ci] * tx[ci] * depth[ci];
            my += w[ci] * ty[ci] * depth[ci];
        }
        var raw_pitch: f32 = 0;
        var raw_roll: f32 = 0;
        var conf_pitch: f32 = 0;
        var conf_roll: f32 = 0;
        if (sw > 0) {
            mx /= sw;
            my /= sw;
            var sxx: f32 = 0;
            var syy: f32 = 0;
            var sxy: f32 = 0;
            var sxz: f32 = 0;
            var syz: f32 = 0;
            for (0..types.zones) |ci| {
                if (w[ci] == 0) continue;
                const px = tx[ci] * depth[ci] - mx;
                const py = ty[ci] * depth[ci] - my;
                const pz = depth[ci] - z0;
                sxx += w[ci] * px * px;
                syy += w[ci] * py * py;
                sxy += w[ci] * px * py;
                sxz += w[ci] * px * pz;
                syz += w[ci] * py * pz;
            }
            // Cell spacing on the hand (mm) sets the scale of "spread".
            const sx_mm = cell_x * z0;
            const sy_mm = cell_y * z0;
            const lx = 0.01 * sx_mm * sx_mm * sw;
            const ly = 0.01 * sy_mm * sy_mm * sw;
            const a11 = sxx + lx;
            const a22 = syy + ly;
            const det = a11 * a22 - sxy * sxy;
            if (det > 0) {
                const b = (sxz * a22 - syz * sxy) / det;
                const c = (syz * a11 - sxz * sxy) / det;
                raw_roll = atan(b);
                raw_pitch = atan(c);
            }
            // Spread (standard deviation in cells) to confidence.
            const spread_x = @sqrt(sxx / sw) / sx_mm;
            const spread_y = @sqrt(syy / sw) / sy_mm;
            conf_roll = std.math.clamp((spread_x - 0.25) / 0.35, 0.0, 1.0);
            conf_pitch = std.math.clamp((spread_y - 0.25) / 0.35, 0.0, 1.0);
        }

        // 3d. Yaw from the blob's second moments (cell units; each zone
        // adds its own extent so a single zone is round).
        var sum_c: f32 = 0;
        var bx: f32 = 0;
        var by: f32 = 0;
        for (0..types.zones) |ci| {
            if (!hand[ci]) continue;
            sum_c += cov[ci];
            bx += cov[ci] * tx[ci] / cell_x;
            by += cov[ci] * ty[ci] / cell_y;
        }
        bx /= sum_c;
        by /= sum_c;
        var mxx: f32 = 0;
        var myy: f32 = 0;
        var mxy: f32 = 0;
        for (0..types.zones) |ci| {
            if (!hand[ci]) continue;
            const dx = tx[ci] / cell_x - bx;
            const dy = ty[ci] / cell_y - by;
            // A partly covered zone is a strip: thinner across its shift.
            mxx += cov[ci] * (dx * dx + cov[ci] * cov[ci] / 12.0);
            myy += cov[ci] * (dy * dy + cov[ci] * cov[ci] / 12.0);
            mxy += cov[ci] * dx * dy;
        }
        const tr = mxx + myy;
        const elong = if (tr > 0) @sqrt((mxx - myy) * (mxx - myy) + 4.0 * mxy * mxy) / tr else 0;
        // Long axis angle from +x, then from vertical.
        const theta = 0.5 * atan2(2.0 * mxy, mxx - myy);
        var raw_yaw = wrap_half_pi(theta - std.math.pi / 2.0);
        const conf_yaw: f32 = if (n >= 3) std.math.clamp((elong - 0.15) / 0.45, 0.0, 1.0) else 0;

        // 4. Filters.
        const half_x = cell_x; // x = +-1 at the outer cells' centres
        const half_y = cell_y;
        const raw_x = c0[0] / half_x;
        const raw_y = c0[1] / half_y;
        if (fresh) {
            e.f_x.reset(raw_x);
            e.f_y.reset(raw_y);
            e.f_z.reset(z0);
            e.f_pitch.reset(raw_pitch * conf_pitch);
            e.f_roll.reset(raw_roll * conf_roll);
            e.f_yaw.reset(if (conf_yaw > 0) raw_yaw else 0);
            e.last_z = z0;
            p.vz_fast_mm_s = 0;
        }
        p.x = e.f_x.step(raw_x, dt, cfg.xy_filter);
        p.y = e.f_y.step(raw_y, dt, cfg.xy_filter);
        p.z_mm = e.f_z.step(z0, dt, cfg.z_filter);
        // Unmeasured angles relax toward 0 instead of sticking.
        const pitch_in = blend(e.f_pitch.x * cfg.relax, raw_pitch, conf_pitch);
        const roll_in = blend(e.f_roll.x * cfg.relax, raw_roll, conf_roll);
        p.pitch = e.f_pitch.step(pitch_in, dt, cfg.tilt_filter);
        p.roll = e.f_roll.step(roll_in, dt, cfg.tilt_filter);
        // Yaw is mod pi: take the branch nearest the current estimate.
        const prev_yaw = e.f_yaw.x;
        raw_yaw += std.math.pi * @round((prev_yaw - raw_yaw) / std.math.pi);
        p.yaw = e.f_yaw.step(blend(prev_yaw, raw_yaw, conf_yaw), dt, cfg.yaw_filter);

        const tan_x = p.x * half_x;
        const tan_y = p.y * half_y;
        p.x_mm = tan_x * p.z_mm;
        p.y_mm = tan_y * p.z_mm;
        p.vx = e.f_x.dx;
        p.vy = e.f_y.dx;
        p.vz_mm_s = e.f_z.dx;
        p.vpitch = e.f_pitch.dx;
        p.vroll = e.f_roll.dx;
        p.vyaw = e.f_yaw.dx;
        p.swirl = p.x * p.vy - p.y * p.vx;
        if (!fresh) {
            const raw_vz = (z0 - e.last_z) / dt;
            const a = OneEuro.alpha(cfg.punch_cutoff_hz, dt);
            p.vz_fast_mm_s += a * (raw_vz - p.vz_fast_mm_s);
        }
        e.last_z = z0;

        p.conf_z = @min(1.0, total / 1.0);
        p.conf_xy = @min(1.0, total / 1.5);
        p.conf_pitch = conf_pitch;
        p.conf_roll = conf_roll;
        p.conf_yaw = conf_yaw;
        e.pose = p;
        return p;
    }

    /// Updates zone `ci`'s background from its targets; true if the near
    /// target is a hand.
    fn classify(e: *Estimator, ci: usize, z: types.Zone) bool {
        const cfg = &e.config;
        const cell = &e.cells[ci];
        if (!usable(z.near, cfg.min_confidence)) {
            cell.still_count = 0;
            if (cell.bg != 0) {
                cell.far_count +|= 1;
                if (cell.far_count >= cfg.bg_push_frames) {
                    cell.bg = 0;
                    cell.far_count = 0;
                }
            }
            return false;
        }
        const m: f32 = @floatFromInt(z.near.mm);
        defer cell.last = m;
        const margin = @max(cfg.bg_margin_mm, cfg.bg_margin_frac * cell.bg);
        if (cell.bg != 0 and m > cell.bg + margin) {
            // Farther than the background: the background was wrong.
            cell.still_count = 0;
            cell.far_count +|= 1;
            if (cell.far_count >= cfg.bg_push_frames) {
                cell.bg = m;
                cell.far_count = 0;
            }
            return false;
        }
        cell.far_count = 0;
        if (cell.bg != 0 and m >= cell.bg - margin) {
            cell.bg += cfg.bg_ema * (m - cell.bg);
            cell.still_count = 0;
            return false;
        }
        if (m > cfg.max_mm) {
            // Out of hand range and in front of no background: it is one.
            cell.bg = m;
            cell.still_count = 0;
            return false;
        }
        if (m < cfg.min_mm) return false;
        // A hand candidate. The background behind it keeps learning from
        // the far target when that matches.
        if (cell.bg != 0 and usable(z.far, cfg.min_confidence)) {
            const f: f32 = @floatFromInt(z.far.mm);
            if (@abs(f - cell.bg) <= margin) cell.bg += cfg.bg_ema * (f - cell.bg);
        }
        if (@abs(m - cell.last) < cfg.still_mm) {
            cell.still_count +|= 1;
            if (cell.still_count >= cfg.absorb_frames) {
                cell.bg = m;
                cell.still_count = 0;
                return false;
            }
        } else {
            cell.still_count = 0;
        }
        return true;
    }

    fn far_is_background(e: *const Estimator, ci: usize, z: types.Zone) bool {
        const bg = e.cells[ci].bg;
        const f: f32 = @floatFromInt(z.far.mm);
        const nm: f32 = @floatFromInt(z.near.mm);
        if (bg != 0 and @abs(f - bg) <= @max(e.config.bg_margin_mm, e.config.bg_margin_frac * bg)) return true;
        return f > nm + 150.0;
    }
};

fn usable(t: types.Target, min_conf: u8) bool {
    return t.valid() and t.confidence >= min_conf;
}

fn centroid(hand: *const [types.zones]bool, cov: *const [types.zones]f32, tx: *const [types.zones]f32, ty: *const [types.zones]f32) [2]f32 {
    var s: f32 = 0;
    var x: f32 = 0;
    var y: f32 = 0;
    for (0..types.zones) |ci| {
        if (!hand[ci]) continue;
        s += cov[ci];
        x += cov[ci] * tx[ci];
        y += cov[ci] * ty[ci];
    }
    if (s == 0) return .{ 0, 0 };
    return .{ x / s, y / s };
}

fn weighted_mean(w: *const [types.zones]f32, v: *const [types.zones]f32) f32 {
    var s: f32 = 0;
    var a: f32 = 0;
    for (w, v) |wi, vi| {
        s += wi;
        a += wi * vi;
    }
    return if (s > 0) a / s else 0;
}

fn blend(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

/// Area of the peak at `mm` in one histogram channel, above the
/// channel's floor (bins b-1..b+1).
fn peak_area(ch: *const [types.hist_bins]u32, mm: f32, cfg: *const Config) f32 {
    var floor: u32 = std.math.maxInt(u32);
    for (ch) |v| floor = @min(floor, v);
    const bin = mm / cfg.hist_bin_mm + cfg.hist_offset_bins;
    const centre: i32 = @intFromFloat(@floor(bin + 0.5));
    var sum: f32 = 0;
    var b = centre - 1;
    while (b <= centre + 1) : (b += 1) {
        if (b < 0 or b >= types.hist_bins) continue;
        sum += @floatFromInt(ch[@intCast(b)] - floor);
    }
    return sum;
}

fn tan_deg(d: f32) f32 {
    return synth.tan(synth.deg_to_rad(d));
}

/// Wraps to (-pi/2, pi/2].
fn wrap_half_pi(a: f32) f32 {
    return a - std.math.pi * @ceil(a / std.math.pi - 0.5);
}

/// atan to ~1e-5 rad without libm: a 9th-order minimax on [-1, 1] and the
/// reciprocal identity outside.
pub fn atan(x: f32) f32 {
    const ax = @abs(x);
    const inv = ax > 1.0;
    const t = if (inv) 1.0 / ax else ax;
    const t2 = t * t;
    var r = t * (0.99997726 + t2 * (-0.33262347 + t2 * (0.19354346 + t2 * (-0.11643287 + t2 * (0.05265332 + t2 * -0.01172120)))));
    if (inv) r = std.math.pi / 2.0 - r;
    return if (x < 0) -r else r;
}

pub fn atan2(y: f32, x: f32) f32 {
    if (x == 0) {
        if (y > 0) return std.math.pi / 2.0;
        if (y < 0) return -std.math.pi / 2.0;
        return 0;
    }
    const a = atan(y / x);
    if (x > 0) return a;
    return if (y >= 0) a + std.math.pi else a - std.math.pi;
}

// ---------------------------------------------------------------------------
// Host tests: synthetic hands from tof_synth, recovered by the estimator.

const testing = std.testing;
const deg = synth.deg_to_rad;

/// Runs `frames` frames of `scene` through `est` at 30 Hz; returns the last pose.
fn run(est: *Estimator, scene: *const synth.Scene, frames: u32, hist: bool, orient: Orientation, t_us: *u64, seed: *u32) Pose {
    var frame: Frame = .{};
    var h: Histograms = .{};
    var pose: Pose = .{};
    for (0..frames) |_| {
        t_us.* += 33_333;
        frame.seq +%= 1;
        frame.time_us = t_us.*;
        synth.render(scene, orient, &frame, if (hist) &h else null, seed);
        pose = est.update(&frame, if (hist) &h else null, orient);
    }
    return pose;
}

fn to_deg(r: f32) f32 {
    return r * (180.0 / std.math.pi);
}

test "pose: atan and atan2 without libm" {
    var x: f32 = -20;
    while (x < 20) : (x += 0.37) {
        try testing.expectApproxEqAbs(std.math.atan(x), atan(x), 2e-5);
    }
    try testing.expectApproxEqAbs(@as(f32, 3.0 * std.math.pi / 4.0), atan2(1, -1), 1e-5);
    try testing.expectApproxEqAbs(@as(f32, -std.math.pi / 4.0), atan2(-1, 1), 1e-5);
}

test "pose: no hand, nothing in range" {
    var est: Estimator = .{};
    var t: u64 = 0;
    var seed: u32 = 1;
    var scene: synth.Scene = .{ .hand = null };
    scene.background_mm = @splat(1500);
    const p = run(&est, &scene, 10, false, .{}, &t, &seed);
    try testing.expect(!p.present);
    try testing.expectEqual(@as(u8, 0), p.zones);
}

test "pose: distance within 3 percent from 100 to 500 mm" {
    var worst: f32 = 0;
    var z: f32 = 100;
    while (z <= 500) : (z += 25) {
        var est: Estimator = .{};
        var t: u64 = 0;
        var seed: u32 = 7;
        const scene: synth.Scene = .{ .hand = .{ .z_mm = z, .half_w = 45, .half_h = 90 } };
        const p = run(&est, &scene, 20, false, .{}, &t, &seed);
        try testing.expect(p.present);
        worst = @max(worst, @abs(p.z_mm - z) / z);
    }
    try testing.expect(worst < 0.03);
}

test "pose: lateral position is continuous across cells" {
    for ([_]bool{ false, true }) |hist| {
        var prev: f32 = -10;
        var worst_mm: f32 = 0;
        // Within the outer cells' centres (58 mm at 300 mm): beyond them a
        // hand is partly outside the field of view.
        var xm: f32 = -55;
        while (xm <= 55) : (xm += 5) {
            var est: Estimator = .{};
            var t: u64 = 0;
            var seed: u32 = 3;
            var scene: synth.Scene = .{ .hand = .{ .x_mm = xm, .z_mm = 300, .half_w = 35, .half_h = 160 } };
            scene.background_mm = @splat(900);
            const p = run(&est, &scene, 15, hist, .{}, &t, &seed);
            try testing.expect(p.present);
            // Monotonic (allowing 0.02 of jitter) and close to the truth.
            try testing.expect(p.x >= prev - 0.02);
            prev = p.x;
            worst_mm = @max(worst_mm, @abs(p.x_mm - xm));
        }
        // A cell is 58 mm wide at 300 mm.
        try testing.expect(worst_mm < if (hist) @as(f32, 6) else 8);
    }
}

test "pose: pitch and roll of a hand covering the grid" {
    const angles = [_]f32{ -30, -15, 0, 15, 30 };
    var worst: f32 = 0;
    for (angles) |a| {
        for ([_]bool{ false, true }) |pitch_axis| {
            var est: Estimator = .{};
            var t: u64 = 0;
            var seed: u32 = 5;
            var hand: synth.Hand = .{ .z_mm = 200, .half_w = 200, .half_h = 200 };
            if (pitch_axis) hand.pitch = deg(a) else hand.roll = deg(a);
            const scene: synth.Scene = .{ .hand = hand };
            const p = run(&est, &scene, 40, false, .{}, &t, &seed);
            const got = if (pitch_axis) p.pitch else p.roll;
            const other = if (pitch_axis) p.roll else p.pitch;
            worst = @max(worst, @abs(to_deg(got) - a));
            try testing.expect(@abs(to_deg(other)) < 3);
            try testing.expect(p.conf_pitch > 0.9 and p.conf_roll > 0.9);
        }
    }
    try testing.expect(worst < 6);
}

test "pose: yaw of an elongated hand, none for a round blob" {
    const angles = [_]f32{ -60, -30, 0, 30, 60, 90 };
    var worst: f32 = 0;
    for (angles) |a| {
        var est: Estimator = .{};
        var t: u64 = 0;
        var seed: u32 = 9;
        var scene: synth.Scene = .{ .hand = .{ .z_mm = 250, .half_w = 22, .half_h = 110, .yaw = deg(a) } };
        scene.background_mm = @splat(900);
        const p = run(&est, &scene, 40, true, .{}, &t, &seed);
        try testing.expect(p.conf_yaw > 0.3);
        // Mod 180: 90 and -90 are the same axis.
        var err = @abs(to_deg(p.yaw) - a);
        err = @min(err, @abs(err - 180));
        worst = @max(worst, err);
    }
    try testing.expect(worst < 20);
    // A hand over all nine zones has no long axis.
    var est: Estimator = .{};
    var t: u64 = 0;
    var seed: u32 = 9;
    const scene: synth.Scene = .{ .hand = .{ .z_mm = 120, .half_w = 150, .half_h = 150 } };
    const p = run(&est, &scene, 10, false, .{}, &t, &seed);
    try testing.expect(p.conf_yaw < 0.1);
}

test "pose: a single-zone hand gives position and distance only" {
    var est: Estimator = .{};
    var t: u64 = 0;
    var seed: u32 = 11;
    var scene: synth.Scene = .{ .hand = .{ .x_mm = -58, .y_mm = 56, .z_mm = 300, .half_w = 20, .half_h = 20 } };
    scene.background_mm = @splat(1000);
    const p = run(&est, &scene, 15, false, .{}, &t, &seed);
    try testing.expect(p.present);
    try testing.expectEqual(@as(u8, 1), p.zones);
    try testing.expect(p.x < -0.8 and p.y > 0.8);
    try testing.expectEqual(@as(f32, 0), p.conf_pitch);
    try testing.expectEqual(@as(f32, 0), p.conf_roll);
    try testing.expectEqual(@as(f32, 0), p.conf_yaw);
}

test "pose: background learning, relearn, absorb and push back" {
    var est: Estimator = .{};
    var t: u64 = 0;
    var seed: u32 = 13;
    // A desk 350 mm away under the bottom row only: before learning it
    // reads as a hand.
    var empty: synth.Scene = .{ .hand = null };
    empty.background_mm = .{ 0, 0, 0, 0, 0, 0, 350, 350, 350 };
    var p = run(&est, &empty, 3, false, .{}, &t, &seed);
    try testing.expect(p.present);
    // relearn() takes it as background.
    var frame: Frame = .{};
    synth.render(&empty, .{}, &frame, null, &seed);
    est.relearn(&frame, .{});
    p = run(&est, &empty, 6, false, .{}, &t, &seed);
    try testing.expect(!p.present);
    // A hand in front of the desk is seen, and the desk zones without the
    // hand stay background.
    var scene = empty;
    scene.hand = .{ .y_mm = 40, .z_mm = 180, .half_w = 30, .half_h = 30 };
    p = run(&est, &scene, 6, false, .{}, &t, &seed);
    try testing.expect(p.present);
    try testing.expectEqual(@as(f32, 0), p.coverage[6]);
    try testing.expect(p.y > 0.3);
    // The desk is moved away: the background follows within a few frames.
    var gone: synth.Scene = .{ .hand = null };
    gone.background_mm = @splat(0);
    _ = run(&est, &gone, 4, false, .{}, &t, &seed);
    try testing.expectEqual(@as(f32, 0), est.cells[7].bg);
    // A box parked 250 mm away, perfectly still, is absorbed after
    // absorb_frames and stops being a hand.
    var box: synth.Scene = .{ .hand = .{ .z_mm = 250, .half_w = 200, .half_h = 200 } };
    box.noise_mm = 0;
    p = run(&est, &box, 10, false, .{}, &t, &seed);
    try testing.expect(p.present);
    p = run(&est, &box, est.config.absorb_frames + est.config.lost_frames, false, .{}, &t, &seed);
    try testing.expect(!p.present);
}

test "pose: One Euro is steady when still and quick on a step, punches show" {
    var est: Estimator = .{};
    var t: u64 = 0;
    var seed: u32 = 17;
    var scene: synth.Scene = .{ .hand = .{ .z_mm = 200, .half_w = 60, .half_h = 100 }, .noise_mm = 4 };
    _ = run(&est, &scene, 30, false, .{}, &t, &seed);
    // Still hand with +-4 mm noise: the output wanders far less.
    var lo: f32 = 1e9;
    var hi: f32 = -1e9;
    for (0..60) |_| {
        const p = run(&est, &scene, 1, false, .{}, &t, &seed);
        lo = @min(lo, p.z_mm);
        hi = @max(hi, p.z_mm);
    }
    try testing.expect(hi - lo < 3.0);
    // A 200 -> 120 mm step: 90 % of the way within 10 frames (333 ms).
    scene.hand.?.z_mm = 120;
    const p = run(&est, &scene, 10, false, .{}, &t, &seed);
    try testing.expect(@abs(p.z_mm - 120) < 8);
    // A punch: 1.5 m/s toward the sensor.
    scene.noise_mm = 0;
    scene.hand.?.z_mm = 400;
    _ = run(&est, &scene, 30, false, .{}, &t, &seed);
    var vmin: f32 = 0;
    for (0..6) |_| {
        scene.hand.?.z_mm -= 50; // 50 mm per 33 ms
        const q = run(&est, &scene, 1, false, .{}, &t, &seed);
        vmin = @min(vmin, q.vz_fast_mm_s);
    }
    try testing.expect(vmin < -800);
}

test "pose: presence holds through a short dropout and resets after" {
    var est: Estimator = .{};
    var t: u64 = 0;
    var seed: u32 = 19;
    var scene: synth.Scene = .{ .hand = .{ .z_mm = 200 } };
    _ = run(&est, &scene, 5, false, .{}, &t, &seed);
    scene.hand = null;
    var p = run(&est, &scene, 2, false, .{}, &t, &seed);
    try testing.expect(p.present and !p.seen);
    try testing.expectApproxEqAbs(@as(f32, 200), p.z_mm, 5);
    p = run(&est, &scene, 3, false, .{}, &t, &seed);
    try testing.expect(!p.present);
    // A new hand needs appear_frames sightings, then starts from its own
    // measurement, not the old one.
    scene.hand = .{ .z_mm = 400 };
    p = run(&est, &scene, 1, false, .{}, &t, &seed);
    try testing.expect(!p.present);
    p = run(&est, &scene, 1, false, .{}, &t, &seed);
    try testing.expect(p.present);
    try testing.expectApproxEqAbs(@as(f32, 400), p.z_mm, 12);
}

test "pose: orientation maps device zones to the screen" {
    const orient: Orientation = .{ .flip_x = true, .transpose = true };
    var a: Estimator = .{};
    var b: Estimator = .{};
    var ta: u64 = 0;
    var tb: u64 = 0;
    var sa: u32 = 23;
    var sb: u32 = 23;
    var scene: synth.Scene = .{ .hand = .{ .x_mm = 40, .y_mm = -20, .z_mm = 220, .half_w = 30, .half_h = 70, .roll = deg(10) } };
    scene.background_mm = @splat(800);
    const pa = run(&a, &scene, 20, false, .{}, &ta, &sa);
    const pb = run(&b, &scene, 20, false, orient, &tb, &sb);
    try testing.expectApproxEqAbs(pa.x, pb.x, 1e-4);
    try testing.expectApproxEqAbs(pa.y, pb.y, 1e-4);
    try testing.expectApproxEqAbs(pa.z_mm, pb.z_mm, 1e-3);
    try testing.expect(pa.x > 0.3 and pa.y < 0);
}

test "pose: swirl follows circling" {
    var est: Estimator = .{};
    var t: u64 = 0;
    var seed: u32 = 29;
    var scene: synth.Scene = .{ .hand = .{ .z_mm = 280, .half_w = 30, .half_h = 30 } };
    scene.background_mm = @splat(900);
    var acc: f32 = 0;
    for (0..90) |i| {
        const a = @as(f32, @floatFromInt(i)) * (2.0 * std.math.pi / 45.0); // 1.5 s per turn, CCW
        scene.hand.?.x_mm = 45 * synth.cos(a);
        scene.hand.?.y_mm = 45 * synth.sin(a);
        const p = run(&est, &scene, 1, true, .{}, &t, &seed);
        if (i > 30) acc += p.swirl;
    }
    try testing.expect(acc > 0);
}
