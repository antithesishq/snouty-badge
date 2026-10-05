//! DEPTH (SPEC section 2): the slow-scan depth photo from user SPAD masks
//! (lib/tof_depth.zig drives the scan; this file draws it).
//!
//! Views (A cycles):
//! - PHOTO: the image in false colour (LIVE's colours), 9x10 or 17x10,
//!   oriented like LIVE; missing pixels hatched (filled from neighbours
//!   when they have depth), low-confidence ones dotted; the cell being
//!   measured outlined. Right: shot, progress, last photo time, pixels per
//!   second, exposure, pass, a colour key, and MODEL when the numbers come
//!   from the virtual sensor.
//! - CLOUD: the same pixels as 3D points (each pixel's ray times its
//!   depth), spinning slowly about the vertical axis, nearest drawn last;
//!   the sensor is the white mark.
//! - MASK: the diagnostics to photograph: the shot's SPAD mask (18x10,
//!   one colour per channel), the driver's mask counters (writes, switch
//!   time last / worst, read-back mismatches and the first difference,
//!   refusals), the zone results of the latest frame per channel.
const std = @import("std");
const cart = @import("cart-api");
const tof = @import("tof");
const ui = @import("ui.zig");

const types = tof.types;
const depth = tof.depth;
const spad = tof.spad;

pub const View = enum(u2) { photo, cloud, mask };

/// tan of each 17-wide image column's centre ((k - 8) * 2.4 deg) and of
/// each row's ((r - 4.5) * 5.6 deg), Q10.
const tan_col = [depth.width]i32{ -357, -309, -263, -218, -173, -129, -86, -43, 0, 43, 86, 129, 173, 218, 263, 309, 357 };
const tan_row = [depth.height]i32{ -482, -365, -255, -151, -50, 50, 151, 255, 365, 482 };
/// sin of 64 steps of a turn, Q10.
const sin64 = [64]i32{ 0, 100, 200, 297, 392, 483, 569, 650, 724, 792, 851, 903, 946, 980, 1004, 1019, 1024, 1019, 1004, 980, 946, 903, 851, 792, 724, 650, 569, 483, 392, 297, 200, 100, 0, -100, -200, -297, -392, -483, -569, -650, -724, -792, -851, -903, -946, -980, -1004, -1019, -1024, -1019, -1004, -980, -946, -903, -851, -792, -724, -650, -569, -483, -392, -297, -200, -100 };

const chan_rgb = [10]u24{ 0x000000, 0xFF4040, 0xFF9020, 0xF0E040, 0x60E060, 0x40E0E0, 0x4080FF, 0xA060FF, 0xFF60C0, 0xE0E0E0 };

pub const Ctx = struct {
    scan: *const depth.Scan,
    orient: types.Orientation,
    model: bool,
    ticks: u64,
};

/// Image size after the orientation (columns, rows) and the image pixel
/// at oriented cell (gx, gy).
fn grid(c: Ctx) struct { w: u32, h: u32 } {
    const w: u32 = if (c.scan.fine) depth.width else 9;
    return if (c.orient.transpose) .{ .w = depth.height, .h = w } else .{ .w = w, .h = depth.height };
}

fn image_at(c: Ctx, gx: u32, gy: u32) struct { col: u32, row: u32 } {
    const g = grid(c);
    var x = gx;
    var y = gy;
    if (c.orient.flip_x) x = g.w - 1 - x;
    if (c.orient.flip_y) y = g.h - 1 - y;
    if (c.orient.transpose) {
        const t = x;
        x = y;
        y = t;
    }
    const step: u32 = if (c.scan.fine) 1 else 2;
    return .{ .col = x * step, .row = y };
}

pub fn draw_photo(c: Ctx) void {
    const g = grid(c);
    const area_w = 104;
    const area_h = 108;
    const cw: u32 = area_w / g.w;
    const ch: u32 = area_h / g.h;
    const x0: i32 = 1;
    const y0: i32 = 10;
    const s = c.scan;
    for (0..g.h) |gy| for (0..g.w) |gx| {
        const p = image_at(c, @intCast(gx), @intCast(gy));
        const px = s.img[p.row][p.col];
        const x = x0 + @as(i32, @intCast(gx * cw));
        const y = y0 + @as(i32, @intCast(gy * ch));
        switch (px.state) {
            .unset => cart.rect(.{ .x = x, .y = y, .width = cw - 1, .height = ch - 1, .fill_color = ui.panel }),
            .ok => cart.rect(.{ .x = x, .y = y, .width = cw, .height = ch, .fill_color = ui.heat(px.mm) }),
            .low => {
                cart.rect(.{ .x = x, .y = y, .width = cw, .height = ch, .fill_color = ui.heat(px.mm) });
                dots(x, y, cw, ch, ui.black);
            },
            .missing => {
                const fill = s.depth_or_fill(p.col, p.row);
                cart.rect(.{ .x = x, .y = y, .width = cw, .height = ch, .fill_color = if (fill > 0) ui.heat(fill) else ui.black });
                hatch(x, y, cw, ch);
            },
        }
    };
    // The pixels being measured now.
    if (s.phase == .running) for (s.cur.px) |pp| if (pp) |p| {
        if (!s.fine and p.col % 2 != 0) continue;
        if (cell_of(c, p.col, p.row)) |cell|
            cart.rect(.{ .x = x0 + @as(i32, @intCast(cell[0] * cw)), .y = y0 + @as(i32, @intCast(cell[1] * ch)), .width = cw, .height = ch, .stroke_color = ui.white });
    };
    side_panel(c);
}

/// The oriented cell of image pixel (col, row), if shown.
fn cell_of(c: Ctx, col: u32, row: u32) ?[2]u32 {
    const g = grid(c);
    const step: u32 = if (c.scan.fine) 1 else 2;
    var x = col / step;
    var y = row;
    if (c.orient.transpose) {
        const t = x;
        x = y;
        y = t;
    }
    if (c.orient.flip_x) x = g.w - 1 - x;
    if (c.orient.flip_y) y = g.h - 1 - y;
    if (x >= g.w or y >= g.h) return null;
    return .{ x, y };
}

/// An X over the cell (pixels directly: the pinned API's `line` does not
/// compile).
fn hatch(x: i32, y: i32, w: u32, h: u32) void {
    const px = cart.Pixel.from_color(ui.dim);
    const n = @min(w, h);
    for (0..n) |i| {
        const ii: i32 = @intCast(i);
        put(x + ii, y + ii, px);
        put(x + @as(i32, @intCast(n)) - 1 - ii, y + ii, px);
    }
}

fn put(x: i32, y: i32, px: cart.Pixel) void {
    if (x >= 0 and x < 160 and y >= 0 and y < 128) cart.framebuffer[@intCast(x)][@intCast(y)] = px;
}

fn dots(x: i32, y: i32, w: u32, h: u32, color: cart.DisplayColor) void {
    const px = cart.Pixel.from_color(color);
    var j: u32 = 0;
    while (j < h) : (j += 2) {
        var i: u32 = (j / 2) % 2;
        while (i < w) : (i += 2) {
            put(x + @as(i32, @intCast(i)), y + @as(i32, @intCast(j)), px);
        }
    }
}

fn side_panel(c: Ctx) void {
    var buf: [24]u8 = undefined;
    const s = c.scan;
    const x = 108;
    ui.say_px(x, 10, ui.fmt(&buf, "SHOT {d}", .{@as(u32, s.shot_i) + 1}), ui.fg);
    ui.say_px(x, 18, ui.fmt(&buf, "OF {d}", .{s.shots()}), ui.dim);
    ui.bar(x, 28, 50, 6, s.progress(), ui.accent);
    if (s.photos > 0) {
        ui.say_px(x, 38, ui.fmt(&buf, "{d}.{d:0>2}S", .{ s.last_photo_us / 1_000_000, s.last_photo_us / 10_000 % 100 }), ui.fg);
        const pps = @as(u64, s.pixels()) * 1_000_000 / @max(s.last_photo_us, 1);
        ui.say_px(x, 46, ui.fmt(&buf, "{d}PX/S", .{pps}), ui.fg);
    } else {
        ui.say_px(x, 38, "-.--S", ui.dim);
        ui.say_px(x, 46, "--PX/S", ui.dim);
    }
    ui.say_px(x, 56, ui.fmt(&buf, "N {d}", .{s.exposure}), ui.warn);
    ui.say_px(x, 64, if (s.fine) "17X10" else "9X10", ui.fg);
    // Colour key 0.2 .. 2 m.
    for (0..50) |i| {
        const mm: u16 = @intCast(200 + i * 1800 / 49);
        cart.vline(.{ .x = x + @as(i32, @intCast(i)), .y = 76, .len = 5, .color = ui.heat(mm) });
    }
    ui.say_px(x, 83, ".2  2M", ui.dim);
    if (c.model) ui.say_px(x, 94, "MODEL", ui.warn);
    if (s.phase == .failed) ui.say_px(x, 102, "BADMASK", ui.bad);
}

// ---- CLOUD ----

const Pt = struct { x: i32, y: i32, z: i32, mm: u16 };

pub fn draw_cloud(c: Ctx) void {
    const s = c.scan;
    var pts: [depth.width * depth.height]Pt = undefined;
    var n: usize = 0;
    // Yaw: a turn every 16 s (1024 steps of 1/16 of a sin64 step).
    const a: u32 = @intCast((c.ticks * 1024 / 960) % 1024);
    const sy = sin_q10(a);
    const cy = sin_q10((a + 256) % 1024);
    // A fixed 14 deg look down.
    const sp: i32 = 248;
    const cp: i32 = 994;
    const zc: i32 = 900;
    const cam: i32 = 1500;
    const f: i32 = 260;
    for (0..depth.height) |r| for (0..depth.width) |col| {
        const p = s.img[r][col];
        if (!p.has_depth()) continue;
        const mm: i32 = p.mm;
        var x: i32 = @divTrunc(mm * tan_col[col], 1024);
        var y: i32 = @divTrunc(mm * tan_row[r], 1024);
        if (c.orient.transpose) {
            const t = x;
            x = y;
            y = t;
        }
        if (c.orient.flip_x) x = -x;
        if (c.orient.flip_y) y = -y;
        const pr = project(x, y, mm, sy, cy, sp, cp, zc, cam, f) orelse continue;
        pts[n] = .{ .x = pr[0], .y = pr[1], .z = pr[2], .mm = p.mm };
        n += 1;
    };
    // Far to near.
    std.sort.insertion(Pt, pts[0..n], {}, struct {
        fn far_first(_: void, l: Pt, r: Pt) bool {
            return l.z > r.z;
        }
    }.far_first);
    for (pts[0..n]) |p| {
        const size: u32 = if (p.z < cam + zc - 200) 3 else 2;
        cart.rect(.{ .x = p.x - 1, .y = p.y - 1, .width = size, .height = size, .fill_color = ui.heat(p.mm) });
    }
    // The sensor.
    if (project(0, 0, 0, sy, cy, sp, cp, zc, cam, f)) |o| {
        cart.rect(.{ .x = o[0] - 2, .y = o[1] - 1, .width = 5, .height = 3, .fill_color = ui.white });
    }
    var buf: [24]u8 = undefined;
    ui.say_px(0, 110, ui.fmt(&buf, "{d} PTS", .{n}), ui.dim);
    if (c.model) ui.say_px(120, 110, "MODEL", ui.warn);
}

fn project(x: i32, y: i32, z: i32, sy: i32, cy: i32, sp: i32, cp: i32, zc: i32, cam: i32, f: i32) ?[3]i32 {
    const dz = z - zc;
    const xr = @divTrunc(x * cy + dz * sy, 1024);
    const zr = @divTrunc(-x * sy + dz * cy, 1024);
    const yr = @divTrunc(y * cp - zr * sp, 1024);
    const zz = @divTrunc(y * sp + zr * cp, 1024) + zc + cam;
    if (zz < 200) return null;
    const px = 80 + @divTrunc(xr * f, zz);
    const py = 63 + @divTrunc(yr * f, zz);
    if (px < 1 or px > 158 or py < 10 or py > 117) return null;
    return .{ px, py, zz };
}

/// sin of a/1024 of a turn, Q10, interpolated from the 64-step table.
fn sin_q10(a: u32) i32 {
    const i = a / 16;
    const fr: i32 = @intCast(a % 16);
    const p0 = sin64[i % 64];
    const p1 = sin64[(i + 1) % 64];
    return p0 + @divTrunc((p1 - p0) * fr, 16);
}

// ---- MASK (diagnostics) ----

pub fn draw_mask(c: Ctx, drv: anytype) void {
    var buf: [28]u8 = undefined;
    const m = &drv.mask;
    // The SPAD array: 18 x 10, 5 x 8 px each.
    const x0 = 1;
    const y0 = 10;
    for (0..spad.rows) |r| for (0..spad.cols) |x| {
        const ch = m.at(x, r);
        const color = if (ch == 0) ui.panel else cart.DisplayColor.rgb(chan_rgb[@min(ch, 9)]);
        cart.rect(.{ .x = x0 + @as(i32, @intCast(x * 5)), .y = y0 + @as(i32, @intCast(r * 8)), .width = 4, .height = 7, .fill_color = color });
    };
    const st = &drv.stats;
    const x = 94;
    ui.say_px(x, 10, ui.fmt(&buf, "G{d}/{d}", .{ drv.frame_mask_gen % 1000, drv.mask_gen % 1000 }), if (drv.frame_mask_gen == drv.mask_gen) ui.good else ui.warn);
    ui.say_px(x, 18, ui.fmt(&buf, "WR{d}", .{st.mask_writes}), ui.fg);
    ui.say_px(x, 26, ui.fmt(&buf, "SW{d}MS", .{st.mask_switch_us / 1000}), ui.fg);
    ui.say_px(x, 34, ui.fmt(&buf, "MX{d}MS", .{st.mask_switch_max_us / 1000}), ui.fg);
    ui.say_px(x, 42, ui.fmt(&buf, "RB{d}", .{st.spad_mismatch}), if (st.spad_mismatch == 0) ui.fg else ui.bad);
    if (st.spad_mismatch > 0) ui.say_px(x, 50, ui.fmt(&buf, "D{X:0>4}", .{st.spad_diff}), ui.bad);
    ui.say_px(x, 58, ui.fmt(&buf, "RJ{d}", .{st.mask_rejects}), if (st.mask_rejects == 0) ui.fg else ui.bad);
    ui.say_px(x, 66, ui.fmt(&buf, "ST{d}MS", .{c.scan.last_shot_us / 1000}), ui.dim);
    // The latest frame per channel: mm (or ----) and confidence.
    const f = drv.latest();
    for (0..9) |z| {
        const col: i32 = @intCast(z % 3);
        const row: i32 = @intCast(z / 3);
        const xx = col * 54;
        const yy = 92 + row * 9;
        cart.rect(.{ .x = xx, .y = yy + 1, .width = 3, .height = 6, .fill_color = cart.DisplayColor.rgb(chan_rgb[z + 1]) });
        if (f) |fr| {
            const t = fr.zones[z].near;
            if (t.valid()) {
                ui.say_px(xx + 5, yy, ui.fmt(&buf, "{d}", .{t.mm}), if (t.confidence < depth.low_conf) ui.dim else ui.fg);
            } else ui.say_px(xx + 5, yy, "----", ui.dim);
        }
    }
    if (drv.err.code != .none) ui.say_px(94, 74, ui.trim(drv.err.code.name(), 8), ui.bad);
    if (c.model) ui.say_px(94, 82, "MODEL", ui.warn);
}
