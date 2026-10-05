//! Snouty Sense: the time-of-flight probe cart (docs/TOF.md, SPEC.md).
//! A SparkFun Qwiic Mini dToF Imager (ams TMF8820) on the badge's Qwiic
//! port, driven by lib/tof.zig over I2C0 (lib/i2c_rp2350.zig). The
//! simulator and `-Dtof-fake=true` badge builds use the virtual sensor
//! (lib/tof_virtual.zig) instead.
//!
//! Pages (Left / Right):
//! - LIVE: the 3x3 zones in false colour (near = warm) with distance,
//!   confidence and the second object, frame rate, temperature, ambient.
//!   A flips X, B flips Y, Up transposes (how the breakout faces), Down
//!   switches the SPAD map between normal (1) and wide (6).
//! - HIST: one channel's raw histogram (Up / Down: channel 0 = the
//!   reference SPAD, 1..9 the zones) with the detected objects marked; A
//!   switches linear / log. Histogram dumps are on only on this page.
//! - DIAG: driver state, last error with its raw status, sensor IDs and
//!   versions, download time, I2C speed and line levels, bus scan,
//!   counters and the driver's step log: one photo of it tells what failed
//!   on real hardware. A cycles the I2C speed (100 / 400 / 1000 kHz) and
//!   restarts, B restarts with a CPU reset and a fresh firmware download.
//! With no sensor, LIVE and HIST show what to plug where, and the scan.
//! Input is ignored while Start and Select are both held (the OS's).
//! No sound.
const std = @import("std");
const cart = @import("cart-api");
const tof = @import("tof");
const build_options = @import("build_options");

const types = tof.types;
const i2c = tof.i2c;

comptime {
    cart.export_start_code();
}

const fake = build_options.tof_fake;
const Sensor = tof.Sensor(fake);

/// Bus time per update: 3 ms (a whole result at 400 kHz), 6 ms on HIST
/// (histogram subpackets; a few sets a second at 400 kHz).
const budget_live_us = 3000;
const budget_hist_us = 6000;
/// Bus scan addresses per update while the scan is on screen (a NACKed
/// address costs ~40 us at 400 kHz).
const scan_per_update = 8;
const frame_us: u64 = 16_667;
const default_speed = 1; // i2c.speeds[1] = 400 kHz

const Page = enum(u8) { live, hist, diag };

const bg = cart.DisplayColor.rgb(0x101820);
const panel = cart.DisplayColor.rgb(0x202830);
const fg = cart.DisplayColor.rgb(0xE0E8F0);
const dim = cart.DisplayColor.rgb(0x60707C);
const good = cart.DisplayColor.rgb(0x40E070);
const warn = cart.DisplayColor.rgb(0xF0C040);
const bad = cart.DisplayColor.rgb(0xF05050);
const accent = cart.DisplayColor.rgb(0x40C0F0);
const black = cart.DisplayColor.rgb(0x000000);
const white = cart.DisplayColor.rgb(0xFFFFFF);

var sensor: Sensor = undefined;
var scan: i2c.Scan = .{};
var page: Page = .live;
var orient: types.Orientation = .{};
var hist_ch: u8 = 5;
var hist_log = false;
var speed_i: usize = default_speed;
var spad_wide = false;
var ticks: u64 = 0;
var prev_bits: u16 = 0;

/// Frame and histogram rates over the last second, in tenths of Hz.
var rate_t0: u64 = 0;
var rate_frames0: u32 = 0;
var rate_sets0: u32 = 0;
var frame_hz10: u32 = 0;
var hist_hz10: u32 = 0;
/// Measured poll time (badge), last and worst over the last second.
var poll_us: u32 = 0;
var poll_max_us: u32 = 0;
var poll_max_window: u32 = 0;

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    cart.set_double_buffer_mode(.no_copy_full_frame);
    sensor = tof.open(fake, i2c.speeds[speed_i]);
    apply_config();
}

pub fn update() void {
    const now = now_us();
    handle_input(read_controls());

    const t0 = if (cart.is_wasm) 0 else cart.micros_since_boot();
    sensor.poll(now);
    if (!cart.is_wasm) {
        // On the badge (the fake sensor too: its bus waits out each
        // transfer's wire time) the poll's real duration.
        poll_us = @intCast(@min(cart.micros_since_boot() - t0, 999_999));
    } else poll_us = sensor.stats.last_spent_us;
    poll_max_window = @max(poll_max_window, poll_us);

    if (page == .diag or sensor.state == .absent) scan.step(&sensor.bus, scan_per_update);
    update_rates(now);

    switch (page) {
        .live => if (show_status_screen()) draw_status() else draw_live(),
        .hist => if (show_status_screen()) draw_status() else draw_hist(),
        .diag => draw_diag(),
    }
    draw_page_dots();
    ticks += 1;

    if (cart.is_wasm) present_wasm();
}

fn now_us() u64 {
    // The wasm platform's clock moves 1 ms per call, and badge-bench's
    // clock stops while the cart waits for vsync: the virtual sensor runs
    // on the frame count (60 Hz), the real one on the badge's clock.
    if (cart.is_wasm or fake) return 1_000_000 + ticks * frame_us;
    return cart.micros_since_boot();
}

/// The status screen instead of LIVE / HIST: no sensor, an error, or
/// (re)booting; a reconfiguration of a running sensor keeps the page.
fn show_status_screen() bool {
    return switch (sensor.state) {
        .measuring => false,
        .configuring => sensor.stats.frames == 0,
        else => true,
    };
}

fn apply_config() void {
    const hz = i2c.speeds[speed_i];
    sensor.budget_us = if (page == .hist) budget_hist_us else budget_live_us;
    sensor.configure(.{
        .spad_map = if (spad_wide) 6 else 1,
        // At 100 kHz a result read spans several updates; a 33 ms period
        // would overwrite it mid-read.
        .period_ms = if (hz < 400_000) 100 else 33,
        .histograms = page == .hist,
    });
}

fn handle_input(c: cart.Controls) void {
    const bits: u16 = @bitCast(c);
    defer prev_bits = bits;
    // The OS owns Start+Select: react to nothing while both are held.
    if (c.start and c.select) return;
    const pressed: cart.Controls = @bitCast(bits & ~prev_bits);

    if (pressed.left or pressed.right) {
        const n = std.enums.values(Page).len;
        const i: u8 = @backingInt(page);
        page = @fromBackingInt(@intCast(if (pressed.right) (i + 1) % n else (i + n - 1) % n));
        apply_config();
        return;
    }
    switch (page) {
        .live => {
            if (pressed.a) orient.flip_x = !orient.flip_x;
            if (pressed.b) orient.flip_y = !orient.flip_y;
            if (pressed.up) orient.transpose = !orient.transpose;
            if (pressed.down) {
                spad_wide = !spad_wide;
                apply_config();
            }
        },
        .hist => {
            if (pressed.up) hist_ch = (hist_ch + types.hist_channels - 1) % types.hist_channels;
            if (pressed.down) hist_ch = (hist_ch + 1) % types.hist_channels;
            if (pressed.a) hist_log = !hist_log;
        },
        .diag => {
            if (pressed.a) {
                speed_i = (speed_i + 1) % i2c.speeds.len;
                sensor.bus.set_speed(i2c.speeds[speed_i]);
                apply_config();
                sensor.restart();
            }
            if (pressed.b) sensor.reload();
        },
    }
}

fn update_rates(now: u64) void {
    if (now - rate_t0 < 1_000_000) return;
    const dt = now - rate_t0;
    frame_hz10 = @intCast((sensor.stats.frames -% rate_frames0) * @as(u64, 10_000_000) / dt);
    hist_hz10 = @intCast((sensor.stats.hist_sets -% rate_sets0) * @as(u64, 10_000_000) / dt);
    rate_t0 = now;
    rate_frames0 = sensor.stats.frames;
    rate_sets0 = sensor.stats.hist_sets;
    poll_max_us = poll_max_window;
    poll_max_window = 0;
}

// ---- LIVE ----

const cell_w = 52;
const cell_h = 32;
const grid_x = 2;
const grid_y = 10;

fn draw_live() void {
    clear();
    var buf: [24]u8 = undefined;
    say(0, 0, "LIVE", warn);
    const f = sensor.latest();
    say(5, 0, fmt(&buf, "{d}.{d}HZ", .{ frame_hz10 / 10, frame_hz10 % 10 }), fg);
    if (f) |fr| say(12, 0, fmt(&buf, "{d}C", .{fr.temperature_c}), fg);
    say(16, 0, if (spad_wide) "W" else "N", dim);

    for (0..3) |r| for (0..3) |c| {
        const zi = orient.index(@intCast(c), @intCast(r));
        const x: i32 = grid_x + @as(i32, @intCast(c)) * cell_w;
        const y: i32 = grid_y + @as(i32, @intCast(r)) * cell_h;
        draw_cell(x, y, zi, if (f) |fr| fr.zones[zi] else .{});
    };

    if (f) |fr| {
        say_px(0, 108, fmt(&buf, "AMB {d}", .{fr.ambient}), dim);
        say_px(80, 108, fmt(&buf, "PH {d}", .{fr.photons}), dim);
    }
    // Orientation: A flip X, B flip Y, Up transpose, Down wide map.
    const y = 119;
    say_px(0, y, "A:FX", if (orient.flip_x) good else dim);
    say_px(40, y, "B:FY", if (orient.flip_y) good else dim);
    say_px(80, y, "U:T", if (orient.transpose) good else dim);
    say_px(112, y, "D:WIDE", if (spad_wide) good else dim);
}

fn draw_cell(x: i32, y: i32, zi: u4, z: types.Zone) void {
    var buf: [12]u8 = undefined;
    const fill = if (z.near.valid()) heat(z.near.mm) else panel;
    cart.rect(.{ .x = x, .y = y, .width = cell_w - 2, .height = cell_h - 2, .fill_color = fill });
    const ink = if (z.near.valid()) ink_on(fill) else dim;
    cart.text(.{ .str = fmt(&buf, "{d}", .{@as(u8, zi) + 1}), .x = x + 1, .y = y + 1, .text_color = if (z.near.valid()) ink else dim });
    if (z.near.valid()) {
        cart.text(.{ .str = fmt(&buf, "{d: >4}", .{z.near.mm}), .x = x + 11, .y = y + 3, .text_color = ink });
        cart.text(.{ .str = fmt(&buf, "C{d}", .{z.near.confidence}), .x = x + 11, .y = y + 12, .text_color = ink });
    } else {
        cart.text(.{ .str = "----", .x = x + 11, .y = y + 3, .text_color = dim });
    }
    if (z.far.valid()) {
        // The second object: its colour in the corner, its distance below.
        cart.rect(.{ .x = x + 43, .y = y + 1, .width = 6, .height = 6, .fill_color = heat(z.far.mm), .stroke_color = ink });
        cart.text(.{ .str = fmt(&buf, "+{d}", .{z.far.mm}), .x = x + 3, .y = y + 21, .text_color = ink });
    }
}

/// False colour by distance: red (near) through orange, yellow, green,
/// blue to purple (2 m and beyond).
fn heat(mm: u16) cart.DisplayColor {
    const stops = [_]struct { mm: u32, rgb: u24 }{
        .{ .mm = 0, .rgb = 0xFF2828 },
        .{ .mm = 300, .rgb = 0xFF8C00 },
        .{ .mm = 600, .rgb = 0xFFE600 },
        .{ .mm = 900, .rgb = 0x3CC85A },
        .{ .mm = 1300, .rgb = 0x28A0E6 },
        .{ .mm = 2000, .rgb = 0x5A3CC8 },
    };
    const d: u32 = mm;
    var i: usize = 0;
    while (i + 2 < stops.len and d >= stops[i + 1].mm) i += 1;
    const a = stops[i];
    const b = stops[i + 1];
    const t: u32 = @min(256, (@min(d, b.mm) -| a.mm) * 256 / (b.mm - a.mm));
    return cart.DisplayColor.rgb(lerp_rgb(a.rgb, b.rgb, t));
}

fn lerp_rgb(a: u24, b: u24, t: u32) u24 {
    var out: u24 = 0;
    inline for (.{ 16, 8, 0 }) |s| {
        const ca: u32 = (a >> s) & 0xFF;
        const cb: u32 = (b >> s) & 0xFF;
        const c = (ca * (256 - t) + cb * t) / 256;
        out |= @as(u24, @intCast(c)) << s;
    }
    return out;
}

fn ink_on(c: cart.DisplayColor) cart.DisplayColor {
    const lum = @as(u32, c.r) * 2 * 3 + @as(u32, c.g) * 6 + @as(u32, c.b) * 2;
    return if (lum > 330) black else white;
}

// ---- HIST ----

const plot_x = 16;
const plot_top = 11;
const plot_bot = 93;

fn draw_hist() void {
    clear();
    var buf: [24]u8 = undefined;
    say(0, 0, "HIST", warn);
    if (hist_ch == 0) say(5, 0, "CH0 REF", fg) else say(5, 0, fmt(&buf, "CH{d} Z{d}", .{ hist_ch, hist_ch }), fg);
    say(13, 0, "U/D", dim);

    const h = sensor.histograms() orelse {
        say(0, 3, "WAITING FOR THE", fg);
        say(0, 4, "HISTOGRAM DUMP", fg);
        say(0, 6, fmt(&buf, "PACKETS {d}/30", .{@popCount(sensor.hist_mask)}), dim);
        say(0, 7, fmt(&buf, "SETS {d} ERR {d}", .{ sensor.stats.hist_sets, sensor.stats.hist_errors }), dim);
        return;
    };
    const bins = &h.bins[hist_ch];
    var max: u32 = 1;
    for (bins) |v| max = @max(max, v);

    const height: u32 = plot_bot - plot_top;
    const lmax = log2_fix(max);
    for (bins, 0..) |v, b| {
        const hpx: u32 = if (hist_log)
            (if (lmax == 0) 0 else log2_fix(v) * height / lmax)
        else
            @intCast(@as(u64, v) * height / max);
        if (hpx > 0) cart.vline(.{ .x = plot_x + @as(i32, @intCast(b)), .y = plot_bot - @as(i32, @intCast(hpx)), .len = hpx, .color = accent });
    }
    // Axis with a tick per metre (DS000693's ~57 mm bins, zero near bin 15).
    cart.hline(.{ .x = plot_x, .y = plot_bot, .len = types.hist_bins, .color = dim });
    var m: u32 = 0;
    while (m <= 6) : (m += 1) {
        const b = tof.bin_of_mm(m * 1000);
        if (b >= types.hist_bins) break;
        const x = plot_x + @as(i32, @intCast(b));
        cart.vline(.{ .x = x, .y = plot_bot, .len = 3, .color = dim });
        cart.text(.{ .str = fmt(&buf, "{d}", .{m}), .x = x - 3, .y = plot_bot + 3, .text_color = dim });
    }
    cart.text(.{ .str = "M", .x = 150, .y = plot_bot + 3, .text_color = dim });

    // The latest frame's objects in this zone.
    if (hist_ch > 0) if (sensor.latest()) |f| {
        const z = f.zones[hist_ch - 1];
        mark_target(z.near, good, 0, 104, "N");
        mark_target(z.far, warn, 0, 112, "F");
    };
    say_px(0, 120, fmt(&buf, "M{d} {d}.{d}/S A:{s}", .{ max, hist_hz10 / 10, hist_hz10 % 10, if (hist_log) "LOG" else "LIN" }), dim);
}

fn mark_target(t: types.Target, color: cart.DisplayColor, x: i32, y: i32, label: []const u8) void {
    var buf: [24]u8 = undefined;
    if (!t.valid()) {
        say_px(x, y, fmt(&buf, "{s} -", .{label}), dim);
        return;
    }
    const b = tof.bin_of_mm(t.mm);
    if (b < types.hist_bins) {
        const px = plot_x + @as(i32, @intCast(b));
        cart.vline(.{ .x = px, .y = plot_top, .len = 6, .color = color });
        cart.rect(.{ .x = px - 1, .y = plot_top, .width = 3, .height = 2, .fill_color = color });
    }
    say_px(x, y, fmt(&buf, "{s} {d}MM C{d} B{d}", .{ label, t.mm, t.confidence, b }), color);
}

/// log2 in 1/16 steps (0 for 0).
fn log2_fix(v: u32) u32 {
    if (v == 0) return 0;
    const e: u32 = 31 - @clz(v);
    const frac: u32 = if (e >= 4) (v >> @intCast(e - 4)) & 0xF else (v << @intCast(4 - e)) & 0xF;
    return e * 16 + frac + 1;
}

// ---- DIAG ----

fn draw_diag() void {
    clear();
    var buf: [32]u8 = undefined;
    const d = &sensor;
    say(0, 0, "DIAG", warn);
    say(5, 0, @tagName(d.state), state_color());

    const e = d.err;
    say(0, 1, fmt(&buf, "ERR {s}", .{e.code.name()}), if (e.code == .none) dim else bad);
    if (e.code != .none) {
        say(0, 2, fmt(&buf, "@{s}", .{trim(e.step.name(), 10)}), bad);
        say(12, 2, fmt(&buf, "R{X:0>4}", .{e.raw & 0xFFFF}), bad);
    } else say(0, 2, fmt(&buf, "STEP {s}", .{trim(d.step.name(), 13)}), dim);

    const in = d.info;
    say(0, 3, fmt(&buf, "ID{X:0>2} R{d} A{X:0>2} V{d}.{d}.{d}", .{ in.id, in.revid, in.appid, in.app_version[0], in.app_version[1], in.app_version[2] }), fg);
    say(0, 4, fmt(&buf, "BL{X:0>2} SN{X:0>2}{X:0>2}{X:0>2}{X:0>2} AR{X:0>2}", .{
        in.bl_version, in.serial[3], in.serial[2], in.serial[1], in.serial[0], in.active_range,
    }), fg);
    say(0, 5, fmt(&buf, "FW{d}MS D{d}{s} S{X:0>2} M{X:0>2}", .{
        d.download_us / 1000, d.stats.downloads, if (in.reused_app) "R" else "", in.app_status, in.measure_status,
    }), fg);

    const ln = d.bus.lines();
    const st = &d.bus.stats;
    say(0, 6, fmt(&buf, "I2C{d}K SDA{d} SCL{d} E{d}", .{
        i2c.speeds[speed_i] / 1000, @intFromBool(ln.sda), @intFromBool(ln.scl), d.stats.i2c_errors,
    }), if (ln.sda and ln.scl) fg else bad);
    say(0, 7, fmt(&buf, "AB{X:0>8} TO{d} RC{d}", .{ st.last_abort, st.timeouts, st.recoveries }), fg);
    draw_scan(0, 8);
    say(0, 9, fmt(&buf, "FR{d} MS{d} TN{d} CK{d}", .{ d.stats.frames, d.stats.missed, d.stats.torn, d.stats.bl_csum_mismatch }), fg);
    say(0, 10, fmt(&buf, "POLL{d}.{d}/{d}.{d}MS MT{d}", .{
        poll_us / 1000, poll_us / 100 % 10, poll_max_us / 1000, poll_max_us / 100 % 10, d.stats.mid_triplets,
    }), fg);

    var log_buf: [4]tof.LogEntry = undefined;
    for (d.recent_log(&log_buf), 0..) |l, i| {
        const ms = l.time_us / 1000 % 100_000;
        say(0, 11 + @as(i32, @intCast(i)), fmt(&buf, "{d:0>5} {s: <9} {X:0>4}", .{ ms, trim(l.step.name(), 9), l.status }), if (l.status & 0x8000 != 0) bad else dim);
    }
    say(0, 15, "A:SPEED B:RELOAD", dim);
}

fn draw_scan(col: i32, row: i32) void {
    var buf: [32]u8 = undefined;
    if (scan.passes == 0) {
        say(col, row, "SCAN ...", dim);
        return;
    }
    var addrs: [5]u7 = undefined;
    const l = scan.list(&addrs);
    if (l.len == 0) {
        say(col, row, "SCAN NONE", bad);
        return;
    }
    var w: usize = 0;
    w += (fmt(buf[w..], "SCAN", .{})).len;
    for (l) |a| w += (fmt(buf[w..], " {X:0>2}", .{a})).len;
    if (scan.count() > l.len) w += (fmt(buf[w..], " +{d}", .{scan.count() - l.len})).len;
    say(col, row, buf[0..w], if (scan.has(tof.address)) good else warn);
}

fn state_color() cart.DisplayColor {
    return switch (sensor.state) {
        .measuring => good,
        .failed, .absent => bad,
        else => warn,
    };
}

// ---- no sensor / starting ----

fn draw_status() void {
    clear();
    var buf: [32]u8 = undefined;
    if (sensor.state == .absent) {
        say(0, 0, "NO SENSOR", bad);
        say(0, 2, "Plug the SparkFun", fg);
        say(0, 3, "dToF imager", fg);
        say(0, 4, "(TMF8820) into the", fg);
        say(0, 5, "badge's Qwiic port", fg);
        say(0, 6, "with a Qwiic cable.", fg);
        say(0, 8, "SYCL badge rev r2", warn);
        say(0, 9, "only: r1 boards have", warn);
        say(0, 10, "SDA/SCL swapped.", warn);
        draw_scan(0, 12);
        const ln = sensor.bus.lines();
        say(0, 13, fmt(&buf, "SDA {s} SCL {s} {d}K", .{ hl(ln.sda), hl(ln.scl), i2c.speeds[speed_i] / 1000 }), if (ln.sda and ln.scl) dim else bad);
        say(0, 15, "</>: PAGES  DIAG", dim);
        return;
    }
    say(0, 0, "STARTING SENSOR", warn);
    say(0, 2, @tagName(sensor.state), state_color());
    say(0, 3, fmt(&buf, "STEP {s}", .{trim(sensor.step.name(), 13)}), dim);
    if (sensor.state == .downloading or sensor.download_progress() > 0) {
        const done: u32 = sensor.download_progress();
        const total: u32 = @intCast(tof.firmware.len);
        say(0, 5, fmt(&buf, "FIRMWARE {d}/{d}", .{ done, total }), fg);
        cart.rect(.{ .x = 0, .y = 56, .width = 160, .height = 8, .stroke_color = dim });
        cart.rect(.{ .x = 1, .y = 57, .width = @max(1, done * 158 / total), .height = 6, .fill_color = accent });
    }
    if (sensor.err.code != .none) {
        say(0, 9, fmt(&buf, "ERR {s}", .{sensor.err.code.name()}), bad);
        say(0, 10, fmt(&buf, "@{s} R{X:0>4}", .{ trim(sensor.err.step.name(), 10), sensor.err.raw & 0xFFFF }), bad);
        if (sensor.state == .failed) say(0, 11, "RETRYING...", warn);
    }
    say(0, 15, "</>: PAGES  DIAG", dim);
}

fn draw_page_dots() void {
    for (0..3) |i| {
        const on = @backingInt(page) == i;
        cart.rect(.{ .x = 142 + @as(i32, @intCast(i)) * 6, .y = 2, .width = 4, .height = 4, .fill_color = if (on) warn else dim });
    }
}

// ---- helpers ----

fn clear() void {
    cart.rect(.{ .x = 0, .y = 0, .width = 160, .height = 128, .fill_color = bg });
}

fn say(col: i32, row: i32, str: []const u8, color: cart.DisplayColor) void {
    cart.text(.{ .str = str, .x = col * 8, .y = row * 8, .text_color = color });
}

fn say_px(x: i32, y: i32, str: []const u8, color: cart.DisplayColor) void {
    cart.text(.{ .str = str, .x = x, .y = y, .text_color = color });
}

fn hl(high: bool) []const u8 {
    return if (high) "HI" else "LO";
}

fn trim(s: []const u8, n: usize) []const u8 {
    return s[0..@min(s.len, n)];
}

fn fmt(buf: []u8, comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, f, args) catch "?";
}

/// Button state. Upstream's platform_wasm.zig exposes `controls` but never
/// fills it from the simulator, which writes its button word (same bit
/// layout as cart.Controls) to linear address 0x04; read that directly on
/// wasm. Hardware gets the OS-maintained cart.controls. (From demosnout.)
fn read_controls() cart.Controls {
    if (cart.is_wasm) return @bitCast(@as(*const volatile u16, @ptrFromInt(0x04)).*);
    return cart.controls.*;
}

/// Simulator shim (see snouty-bugs/CLAUDE.md): upstream's wasm platform
/// never presents, and the web simulator reads a legacy framebuffer at 0x20
/// with red and blue swapped. Hardware builds compile none of this.
fn present_wasm() void {
    const sim_framebuffer: *cart.Framebuffer = @ptrFromInt(0x20);
    for (cart.framebuffer, sim_framebuffer) |*src_column, *dst_column| {
        for (src_column, dst_column) |src, *dst| {
            const c = src.to_color();
            dst.* = .from_color(.{ .r = c.b, .g = c.g, .b = c.r });
        }
    }
}
