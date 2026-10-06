//! Hand pose from the TMF8820's zones (docs/TOF.md; design and honest
//! limits in carts/snouty-morph/SPEC.md section 2, M5 in docs/TOF.md).
//! Pure: no hardware, no cart API, no allocation; f32 only (the M33 FPU
//! is single precision) and no libm, so it builds into a cart unchanged.
//! Runs once per sensor frame (30 Hz), roughly ten microseconds.
//!
//!     var est: tof_pose.Estimator = .{};            // .{ .config = ... }
//!     est.set_layout(.stripes);                     // GRID by default
//!     const pose = est.update(&frame, hist_or_null, orientation);
//!
//! Any zone layout of lib/tof_zones.zig (the 3x3 grid, the 8 stripes):
//! the estimator works from each zone's screen tangents, so one code path
//! serves both. Frames measured with another layout than the estimator's
//! (the ones in flight around a switch) are ignored.
//!
//! What it does per frame:
//! 1. Background model per zone: learned while the zone sees no hand
//!    (farther or vanished targets push it back at once, matching ones
//!    nudge it, a nearer target that stays perfectly still for
//!    `absorb_frames` becomes background). Nothing beyond `max_mm` is ever
//!    a hand.
//! 2. Hand zones and their covered fraction (histogram peak areas when
//!    available, the near/far signal ratio or confidences otherwise).
//! 3. Arm rejection (M5): each hand zone's distance as a perpendicular
//!    height; the near cluster (within `cluster_mm` of the nearest) gives
//!    the lateral position and `height_mm`, the hand body (within
//!    `body_mm`) the distance, tilt and yaw. A finger pointing down
//!    tracks the fingertip; a forearm sloping in from one side does not
//!    drag x.
//! 4. Coverage centroid with a sub-zone shift for partly covered zones
//!    (x, y) over the near cluster, weighted mean distance with outlier
//!    rejection (z), a ridge least-squares plane through the hand points
//!    (pitch, roll, each with a confidence from the points' spread),
//!    second moments of the blob (yaw, confidence from its elongation).
//!    An axis the layout does not resolve (y for STRIPES) stays 0 with
//!    zero confidence for the angles that need it.
//! 5. One Euro filters per DoF (steady when still, quick when moving),
//!    velocities from their derivative stage, presence with hysteresis.
//!
//! Coordinates: screen cells after the orientation (col 0 left, row 0
//! top); x right, y up, z from the sensor toward the hand.
const std = @import("std");
pub const types = @import("tof_types.zig");
/// Synthetic frames from a hand scene (tests, snouty-morph's ghost hand).
pub const synth = @import("tof_synth.zig");

/// Zone layouts and their geometry.
pub const zones = @import("tof_zones.zig");

const Frame = types.Frame;
const Layout = types.Layout;
const Geometry = zones.Geometry;
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
    /// GRID's field of view (SPAD map 1: 33 x 32 degrees; map 6: 41 x 52).
    /// STRIPES takes its geometry from the SPAD array (lib/tof_zones.zig).
    fov_x_deg: f32 = 33,
    fov_y_deg: f32 = 32,
    /// Hand range along the zone ray.
    min_mm: f32 = 15,
    /// STRIPES' near limit: a user SPAD mask has no crosstalk calibration,
    /// so very near returns may be the package's own (docs/TOF.md M5).
    min_mm_stripes: f32 = 40,
    max_mm: f32 = 600,
    /// Arm rejection (docs/TOF.md M5), perpendicular heights: hand zones
    /// within `cluster_mm` of the nearest give x, y and `height_mm`;
    /// within `body_mm` the distance, tilt and yaw.
    cluster_mm: f32 = 40,
    body_mm: f32 = 100,
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
    /// The layout and its screen cells (`coverage`, `depth_mm`, `cluster`
    /// are row-major over `cols` x `rows`: GRID 3x3, STRIPES 8x1, or 1x8
    /// when the orientation transposes).
    layout: Layout = .grid,
    cols: u8 = 3,
    rows: u8 = 3,
    /// The layout resolves this screen axis (STRIPES: x only, or y only
    /// when transposed); an unresolved x or y stays 0.
    has_x: bool = true,
    has_y: bool = true,
    /// Covered fraction per screen cell (row-major, row 0 top), 0 = not hand.
    coverage: [types.zones]f32 = @splat(0),
    /// Perpendicular height per screen cell this frame, 0 = not hand.
    depth_mm: [types.zones]f32 = @splat(0),
    /// Screen cells in the near cluster (bit per cell): what x and y and
    /// `height_mm` came from.
    cluster: u16 = 0,
    /// Lateral position, -1..1: +-1 at the outer zones' centres.
    x: f32 = 0,
    y: f32 = 0,
    x_mm: f32 = 0,
    y_mm: f32 = 0,
    /// Perpendicular distance from the sensor (the hand body, filtered).
    z_mm: f32 = 0,
    /// This frame's nearest hand point and the near cluster's mean height
    /// (perpendicular, unfiltered; 0 when no hand was seen): what an
    /// instrument plays, steadier than any one zone.
    near_mm: f32 = 0,
    height_mm: f32 = 0,
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
    /// The layout this estimator reads (`set_layout`).
    layout: Layout = .grid,
    /// Background per device zone (frame.zones index).
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
    geom: Geometry = .{},
    geom_ok: bool = false,

    /// Read `layout` from now on: everything learned is dropped (zone i
    /// looks elsewhere now), the configuration is kept.
    pub fn set_layout(e: *Estimator, layout: Layout) void {
        if (layout == e.layout) return;
        e.* = .{ .config = e.config, .layout = layout };
    }

    /// The geometry for `orient` (cached).
    pub fn geometry(e: *Estimator, orient: Orientation) *const Geometry {
        if (!e.geom_ok or !std.meta.eql(e.geom.orient, orient) or e.geom.layout != e.layout) {
            e.geom = Geometry.init(e.layout, orient, e.config.fov_x_deg, e.config.fov_y_deg);
            e.geom_ok = true;
        }
        return &e.geom;
    }

    /// Takes `frame` as the background (every zone's near target, or
    /// nothing), e.g. while the user holds a button with no hand in view.
    pub fn relearn(e: *Estimator, frame: *const Frame, orient: Orientation) void {
        _ = orient;
        if (frame.layout != e.layout) return;
        for (frame.zones, 0..) |z, zi| {
            e.cells[zi] = .{ .bg = if (usable(z.near, e.config.min_confidence)) @floatFromInt(z.near.mm) else 0 };
        }
    }

    /// The pose after `frame` (and its histograms, if the driver dumps
    /// them). A frame of another layout is ignored (the last pose returned).
    pub fn update(e: *Estimator, frame: *const Frame, hist: ?*const Histograms, orient: Orientation) Pose {
        if (frame.layout != e.layout) return e.pose;
        const cfg = &e.config;
        const g = e.geometry(orient);
        const nz: usize = g.n;
        var dt = cfg.default_dt;
        if (e.last_time_us != 0 and frame.time_us > e.last_time_us) {
            dt = @as(f32, @floatFromInt(@min(frame.time_us - e.last_time_us, 1_000_000))) * 1e-6;
        }
        dt = std.math.clamp(dt, 0.004, 0.25);
        e.last_time_us = frame.time_us;

        // 1-2. Background model, hand zones and their coverage (by screen cell).
        var hand: [types.zones]bool = @splat(false);
        var cov: [types.zones]f32 = @splat(0);
        var dist: [types.zones]f32 = @splat(0);
        var conf: [types.zones]f32 = @splat(0);
        var amp: [types.zones]f32 = @splat(0);
        var amp_far: [types.zones]f32 = @splat(-1);
        var max_conf: f32 = 1;
        var max_amp: f32 = 1e-6;
        for (0..nz) |ci| {
            const zi = g.zones[ci].dev;
            const z = frame.zones[zi];
            if (!e.classify(zi, z)) continue;
            hand[ci] = true;
            dist[ci] = @floatFromInt(z.near.mm);
            conf[ci] = @floatFromInt(z.near.confidence);
            max_conf = @max(max_conf, conf[ci]);
            if (hist) |h| {
                amp[ci] = peak_area(&h.bins[@as(usize, zi) + 1], dist[ci], cfg) * dist[ci] * dist[ci];
                max_amp = @max(max_amp, amp[ci]);
                if (usable(z.far, cfg.min_confidence)) {
                    const fm: f32 = @floatFromInt(z.far.mm);
                    amp_far[ci] = peak_area(&h.bins[@as(usize, zi) + 1], fm, cfg) * fm * fm;
                }
            }
        }
        var n: u8 = 0;
        var total: f32 = 0;
        for (0..nz) |ci| {
            if (!hand[ci]) continue;
            const zi = g.zones[ci].dev;
            const z = frame.zones[zi];
            var c: f32 = 1;
            if (hist != null) {
                c = if (amp_far[ci] >= 0) amp[ci] / @max(amp[ci] + amp_far[ci], 1e-6) else amp[ci] / max_amp;
            } else if (usable(z.far, cfg.min_confidence) and e.far_is_background(zi, z)) {
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
        p.layout = g.layout;
        p.cols = g.cols;
        p.rows = g.rows;
        p.has_x = g.has_x;
        p.has_y = g.has_y;
        p.coverage = cov;
        p.depth_mm = @splat(0);
        p.cluster = 0;
        p.near_mm = 0;
        p.height_mm = 0;
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

        // 3. Arm rejection: perpendicular heights from the zone centres'
        // tangents; the near cluster and the hand body.
        var tx: [types.zones]f32 = @splat(0);
        var ty: [types.zones]f32 = @splat(0);
        var lat: [types.zones]bool = @splat(false);
        var body: [types.zones]bool = @splat(false);
        var near: f32 = std.math.floatMax(f32);
        for (0..nz) |ci| {
            tx[ci] = g.zones[ci].tx;
            ty[ci] = g.zones[ci].ty;
            if (!hand[ci]) continue;
            p.depth_mm[ci] = dist[ci] / @sqrt(1.0 + tx[ci] * tx[ci] + ty[ci] * ty[ci]);
            near = @min(near, p.depth_mm[ci]);
        }
        var h_sum: f32 = 0;
        var h_n: f32 = 0;
        for (0..nz) |ci| {
            if (!hand[ci]) continue;
            lat[ci] = p.depth_mm[ci] <= near + cfg.cluster_mm;
            body[ci] = p.depth_mm[ci] <= near + cfg.body_mm;
            if (lat[ci]) {
                p.cluster |= @as(u16, 1) << @intCast(ci);
                h_sum += p.depth_mm[ci];
                h_n += 1;
            }
        }
        p.near_mm = near;
        p.height_mm = h_sum / h_n;

        // 4a. Centroid of the near cluster in tangent space, then the
        // sub-zone shift: a partly covered zone's centre moves toward the
        // blob by (1 - coverage) / 2 of its width (exactly the covered
        // part's centre for a straight edge), on the axes the layout resolves.
        // A stripe is never wholly covered (it spans the field's height),
        // so on a 1-D layout the across-stripe fraction is the coverage
        // relative to the best-covered stripe of the cluster.
        var lc = cov;
        if (!(g.has_x and g.has_y)) {
            var top: f32 = 0;
            for (0..nz) |ci| if (lat[ci]) {
                top = @max(top, cov[ci]);
            };
            for (0..nz) |ci| lc[ci] = if (lat[ci]) std.math.clamp(cov[ci] / top, cfg.min_coverage, 1.0) else 0;
        }
        var c0 = centroid(&lat, &lc, &tx, &ty);
        for (0..nz) |ci| {
            if (!lat[ci] or lc[ci] >= 0.95) continue;
            const wx = g.zones[ci].wx;
            const wy = g.zones[ci].wy;
            const ox = c0[0] - tx[ci];
            const oy = c0[1] - ty[ci];
            const k = (1.0 - lc[ci]) * 0.5;
            if (g.has_x and @abs(ox) > 0.25 * wx) tx[ci] += std.math.sign(ox) * k * wx;
            if (g.has_y and @abs(oy) > 0.25 * wy) ty[ci] += std.math.sign(oy) * k * wy;
        }
        c0 = centroid(&lat, &lc, &tx, &ty);

        // 4b. Distance: weighted mean of the hand body's perpendicular
        // depths, outliers dropped.
        var depth: [types.zones]f32 = @splat(0);
        var w: [types.zones]f32 = @splat(0);
        for (0..nz) |ci| {
            depth[ci] = dist[ci] / @sqrt(1.0 + tx[ci] * tx[ci] + ty[ci] * ty[ci]);
            w[ci] = if (body[ci]) cov[ci] * @max(conf[ci], 1.0) / 255.0 else 0;
        }
        var z0 = weighted_mean(&w, &depth);
        var kept: u8 = 0;
        for (0..nz) |ci| {
            if (w[ci] > 0 and @abs(depth[ci] - z0) > cfg.outlier_mm) w[ci] = 0;
            if (w[ci] > 0) kept += 1;
        }
        if (kept > 0) z0 = weighted_mean(&w, &depth);

        // 4c. Tilt: ridge least squares z = a + b x + c y over the hand
        // body's points (mm), centred on their weighted mean.
        var sw: f32 = 0;
        var mx: f32 = 0;
        var my: f32 = 0;
        for (0..nz) |ci| {
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
            for (0..nz) |ci| {
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
            // GRID cell spacing on the hand (mm) sets the scale of
            // "spread" in every layout.
            const sx_mm = g.ref_x * z0;
            const sy_mm = g.ref_y * z0;
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
            if (g.has_x) conf_roll = std.math.clamp((spread_x - 0.25) / 0.35, 0.0, 1.0);
            if (g.has_y) conf_pitch = std.math.clamp((spread_y - 0.25) / 0.35, 0.0, 1.0);
        }

        // 4d. Yaw from the hand body's second moments (GRID cell units;
        // each zone adds its own extent so a single zone is round). Needs
        // both axes: none for STRIPES.
        var sum_c: f32 = 0;
        var bx: f32 = 0;
        var by: f32 = 0;
        for (0..nz) |ci| {
            if (!body[ci]) continue;
            sum_c += cov[ci];
            bx += cov[ci] * tx[ci] / g.ref_x;
            by += cov[ci] * ty[ci] / g.ref_y;
        }
        bx /= sum_c;
        by /= sum_c;
        var mxx: f32 = 0;
        var myy: f32 = 0;
        var mxy: f32 = 0;
        for (0..nz) |ci| {
            if (!body[ci]) continue;
            const dx = tx[ci] / g.ref_x - bx;
            const dy = ty[ci] / g.ref_y - by;
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
        const conf_yaw: f32 = if (n >= 3 and g.has_x and g.has_y) std.math.clamp((elong - 0.15) / 0.45, 0.0, 1.0) else 0;

        // 5. Filters.
        const half_x = g.half_x; // x = +-1 at the outer zones' centres
        const half_y = g.half_y;
        const raw_x = if (g.has_x) c0[0] / half_x else 0;
        const raw_y = if (g.has_y) c0[1] / half_y else 0;
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

    /// Updates device zone `ci`'s background from its targets; true if
    /// the near target is a hand.
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
        if (m < (if (e.layout == .stripes) cfg.min_mm_stripes else cfg.min_mm)) return false;
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

// ---------------------------------------------------------------------------
// M5: stripes and arm rejection (docs/TOF.md M5).

/// A hand sweeping sideways in 2 mm steps, each position settled with a
/// fresh estimator: how finely and how truly x follows it.
const Sweep = struct {
    /// Largest jump of x_mm between neighbouring positions (truth: 2 mm).
    max_step_mm: f32 = 0,
    /// Worst |x_mm - truth|.
    worst_mm: f32 = 0,
    /// Positions where x_mm moved by more than 0.5 mm: distinct readings.
    steps: u32 = 0,
    /// x never went backwards by more than 0.5 mm.
    monotonic: bool = true,
};

/// The hands swept: a flat palm 25 cm up, a fingertip pointing down 15 cm up.
const palm: synth.Hand = .{ .z_mm = 250, .half_w = 40, .half_h = 90 };
const fingertip: synth.Hand = .{ .z_mm = 150, .half_w = 9, .half_h = 12 };

fn sweep(layout: Layout, saturate: bool, hand: synth.Hand) Sweep {
    var out: Sweep = .{};
    var prev: ?f32 = null;
    // Over the middle of the field: +-60 mm at 25 cm, +-36 mm at 15 cm.
    const span = 0.24 * hand.z_mm;
    var xm: f32 = -span;
    while (xm <= span + 0.01) : (xm += 2) {
        var est: Estimator = .{ .config = .{ .fov_x_deg = 41, .fov_y_deg = 52, .max_mm = 650 } };
        est.set_layout(layout);
        var t: u64 = 0;
        var seed: u32 = 3;
        var h = hand;
        h.x_mm = xm;
        var scene: synth.Scene = .{ .layout = layout, .saturate = saturate, .fov_x_deg = 41, .fov_y_deg = 52, .hand = h };
        scene.background_mm = @splat(1300);
        const p = run(&est, &scene, 12, false, .{}, &t, &seed);
        if (!p.present) {
            out.monotonic = false;
            continue;
        }
        out.worst_mm = @max(out.worst_mm, @abs(p.x_mm - xm));
        if (prev) |q| {
            out.max_step_mm = @max(out.max_step_mm, @abs(p.x_mm - q));
            if (@abs(p.x_mm - q) > 0.5) out.steps += 1;
            if (p.x_mm < q - 0.5) out.monotonic = false;
        }
        prev = p.x_mm;
    }
    return out;
}

test "pose M5: stripes follow a sideways sweep far more finely than the grid" {
    // Confidence that tracks coverage (the synthetic model's), then the
    // pessimistic case where every target reports 255 (the hardware may
    // saturate): sub-zone interpolation then has only zone membership.
    for ([_]bool{ false, true }) |sat| {
        const g = sweep(.grid, sat, palm);
        const s = sweep(.stripes, sat, palm);
        const gf = sweep(.grid, sat, fingertip);
        const sf = sweep(.stripes, sat, fingertip);
        try testing.expect(s.monotonic and g.monotonic);
        if (!sat) {
            // Coverage-tracking confidence: both interpolate; the stripes
            // with smaller steps and more distinct readings.
            try testing.expect(s.worst_mm < 7);
            try testing.expect(s.max_step_mm < 8 and s.max_step_mm < g.max_step_mm);
            try testing.expect(s.steps > g.steps);
        } else {
            // Saturated: stripe membership alone gives half-stripe steps
            // (an inner stripe is 21 mm wide at 250 mm); the grid steps
            // between whole-cell answers (its rows give a few more).
            try testing.expect(s.max_step_mm < 13 and s.worst_mm < 12);
            try testing.expect(g.worst_mm > 15 and s.worst_mm * 1.5 < g.worst_mm);
            try testing.expect(s.max_step_mm < g.max_step_mm);
        }
        // A fingertip: one cell of the grid, one or two stripes. Either
        // confidence model (the tip covers too little for it to matter).
        try testing.expect(sf.monotonic and gf.monotonic);
        try testing.expect(sf.max_step_mm < 8 and sf.worst_mm < 6);
        try testing.expect(gf.max_step_mm > 15 and gf.worst_mm > 10);
        try testing.expect(sf.steps >= 2 * gf.steps);
    }
}

/// A hand with an optional forearm: x_mm and height of the settled pose.
fn arm_pose(layout: Layout, hand: synth.Hand, arm: ?synth.Arm, cfg: Config) Pose {
    var est: Estimator = .{ .config = cfg };
    est.set_layout(layout);
    var t: u64 = 0;
    var seed: u32 = 5;
    var scene: synth.Scene = .{ .layout = layout, .fov_x_deg = 41, .fov_y_deg = 52, .hand = hand, .arm = arm, .noise_mm = 1.5 };
    scene.background_mm = @splat(1300);
    return run(&est, &scene, 15, false, .{}, &t, &seed);
}

test "pose M5: a forearm sloping in from the left does not drag x" {
    const base: Config = .{ .fov_x_deg = 41, .fov_y_deg = 52, .max_mm = 650 };
    var off = base;
    off.cluster_mm = 1e4;
    off.body_mm = 1e4;
    off.outlier_mm = 1e4;
    const hand: synth.Hand = .{ .x_mm = 30, .z_mm = 220, .half_w = 40, .half_h = 80 };
    const arm: synth.Arm = .{ .dir = std.math.pi, .slope = 0.6 };
    for ([_]Layout{ .grid, .stripes }) |l| {
        const alone = arm_pose(l, hand, null, base);
        const with = arm_pose(l, hand, arm, base);
        const naive = arm_pose(l, hand, arm, off);
        // Without rejection the arm pulls x left (by ~25 mm); with it the
        // stripes stay put and the height is the hand's. A grid zone
        // holding both the hand and the arm's first part cannot be split:
        // GRID keeps about half the drag.
        const drag = alone.x_mm - naive.x_mm;
        try testing.expect(drag > 15);
        if (l == .stripes) {
            try testing.expect(@abs(with.x_mm - alone.x_mm) < 3);
        } else {
            try testing.expect(@abs(with.x_mm - alone.x_mm) < 0.6 * drag);
        }
        try testing.expect(@abs(with.height_mm - 220) < 8);
        try testing.expect(@abs(with.z_mm - alone.z_mm) < 16);
    }
}

test "pose M5: a finger pointing down tracks the fingertip" {
    const cfg: Config = .{ .fov_x_deg = 41, .fov_y_deg = 52, .max_mm = 650 };
    var off = cfg;
    off.cluster_mm = 1e4;
    // The fingertip 15 cm up, the hand and forearm rising steeply behind
    // it toward the upper left.
    const tip: synth.Hand = .{ .x_mm = 25, .z_mm = 150, .half_w = 9, .half_h = 12 };
    const arm: synth.Arm = .{ .dir = 2.6, .slope = 2.0, .half_w = 30, .length = 250 };
    for ([_]Layout{ .grid, .stripes }) |l| {
        const p = arm_pose(l, tip, arm, cfg);
        const naive = arm_pose(l, tip, arm, off);
        try testing.expect(p.present);
        try testing.expect(naive.x_mm < p.x_mm - 8);
        // The stripes holding the tip also hold the arm just above it
        // (the synthetic zone reports their mean): the height reads a
        // little high, far less than without the cluster.
        try testing.expect(@abs(p.height_mm - 150) < 25 and p.height_mm < naive.height_mm - 20);
        if (l == .stripes) {
            // One or two 13 mm stripes at 15 cm: within a stripe of the tip.
            try testing.expect(@abs(p.x_mm - 25) < 8);
        } else {
            // A 37 mm cell: the tip's side of the grid, not the arm's.
            try testing.expect(p.x_mm > 10);
        }
    }
}

test "pose M5: tilt survives the arm, roll is measured in stripes, pitch and yaw are not" {
    const cfg: Config = .{ .fov_x_deg = 41, .fov_y_deg = 52, .max_mm = 650 };
    // A palm rolled 25 deg (right side away) over most of the field, the
    // forearm coming in from below.
    const hand: synth.Hand = .{ .z_mm = 200, .half_w = 110, .half_h = 110, .roll = deg(25) };
    const arm: synth.Arm = .{ .dir = -std.math.pi / 2.0, .slope = 0.8, .half_w = 35 };
    const g = arm_pose(.grid, hand, arm, cfg);
    try testing.expect(@abs(to_deg(g.roll) - 25) < 8);
    try testing.expect(g.conf_roll > 0.5);
    // The body window keeps a palm tilted 45 deg; the near cluster alone
    // would drop its far half and lose the tilt.
    var tight = cfg;
    tight.body_mm = cfg.cluster_mm;
    const steep: synth.Hand = .{ .z_mm = 200, .half_w = 100, .half_h = 100, .pitch = deg(45) };
    const t = arm_pose(.grid, steep, null, tight);
    const b = arm_pose(.grid, steep, null, cfg);
    try testing.expect(@abs(to_deg(b.pitch) - 45) < 8 and b.conf_pitch > 0.8);
    try testing.expect(@abs(to_deg(t.pitch) - 45) > 20);
    const s = arm_pose(.stripes, hand, arm, cfg);
    try testing.expect(@abs(to_deg(s.roll) - 25) < 8);
    try testing.expect(s.conf_roll > 0.5);
    try testing.expectEqual(@as(f32, 0), s.conf_pitch);
    try testing.expectEqual(@as(f32, 0), s.conf_yaw);
    try testing.expectEqual(@as(f32, 0), s.y);
    try testing.expect(!s.has_y and s.has_x);
}

test "pose M5: frames of the other layout are ignored, switching starts afresh" {
    var est: Estimator = .{ .config = .{ .fov_x_deg = 41, .fov_y_deg = 52, .max_mm = 650 } };
    var t: u64 = 0;
    var seed: u32 = 31;
    var scene: synth.Scene = .{ .fov_x_deg = 41, .fov_y_deg = 52, .hand = .{ .x_mm = -40, .z_mm = 250 } };
    scene.background_mm = @splat(1300);
    const p = run(&est, &scene, 10, false, .{}, &t, &seed);
    try testing.expect(p.present and p.layout == .grid);
    // A stripes frame in flight changes nothing.
    var stripes = scene;
    stripes.layout = .stripes;
    const q = run(&est, &stripes, 3, false, .{}, &t, &seed);
    try testing.expectEqual(p.seq, q.seq);
    // Switching drops the background and the filters; stripes frames then work.
    est.set_layout(.stripes);
    try testing.expect(!est.pose.present);
    try testing.expectEqual(@as(f32, 0), est.cells[4].bg);
    const r = run(&est, &stripes, 10, false, .{}, &t, &seed);
    try testing.expect(r.present and r.layout == .stripes and r.cols == 8 and r.rows == 1);
    try testing.expect(@abs(r.x_mm + 40) < 6);
    // The grid frames now in flight are ignored in turn.
    const u = run(&est, &scene, 2, false, .{}, &t, &seed);
    try testing.expectEqual(r.seq, u.seq);
}

test "pose M5: stripes under MIRROR and transpose" {
    const cfg: Config = .{ .fov_x_deg = 41, .fov_y_deg = 52, .max_mm = 650 };
    var scene: synth.Scene = .{ .layout = .stripes, .fov_x_deg = 41, .fov_y_deg = 52, .hand = .{ .x_mm = 35, .y_mm = -20, .z_mm = 240, .half_w = 35, .half_h = 70 } };
    scene.background_mm = @splat(1300);
    // The scene is in screen space: any flip gives the same pose.
    var a: Estimator = .{ .config = cfg };
    var b: Estimator = .{ .config = cfg };
    a.set_layout(.stripes);
    b.set_layout(.stripes);
    var ta: u64 = 0;
    var tb: u64 = 0;
    var sa: u32 = 41;
    var sb: u32 = 41;
    const pa = run(&a, &scene, 12, false, .{}, &ta, &sa);
    const pb = run(&b, &scene, 12, false, .{ .flip_x = true, .flip_y = true }, &tb, &sb);
    try testing.expectApproxEqAbs(pa.x, pb.x, 1e-4);
    try testing.expect(pa.x_mm > 28 and pa.x_mm < 42);
    // Transposed, the stripes run across the screen: y is measured, x is not.
    var c: Estimator = .{ .config = cfg };
    c.set_layout(.stripes);
    var tc: u64 = 0;
    var sc: u32 = 41;
    const pc = run(&c, &scene, 12, false, .{ .transpose = true }, &tc, &sc);
    try testing.expect(pc.present and !pc.has_x and pc.has_y);
    try testing.expectEqual(@as(f32, 0), pc.x);
    try testing.expect(pc.y_mm < -12 and pc.y_mm > -28);
    try testing.expect(pc.cols == 1 and pc.rows == 8);
}
