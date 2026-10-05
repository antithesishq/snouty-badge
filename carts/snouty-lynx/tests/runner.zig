//! Headless runner core shared by `tools/run_rom.zig` (`zig build run-lynx`)
//! and `tests/golden.zig`: the preview/badge-bench input script, the
//! frontend's input model (cart/src/main.zig + frontend/input.zig and the
//! splash), frame hashes and PPM images. No file I/O here (the callers read
//! the ROM and the script), no cart-api.
//!
//! Script: `[{"from": T1, "to": T2, "hold": ["A", "UP"]}]`, inclusive
//! ranges of badge updates (tools/preview.mjs), button names A B START
//! SELECT UP DOWN LEFT RIGHT (any case). The controls word per update uses
//! the cart.Controls bits preview.mjs writes (start 0, select 1, a 2, b 3,
//! up 5, down 6, left 7, right 8) and goes through the same steps as the
//! cart:
//!
//! - Splash: the core does not step until a button is newly pressed (or the
//!   72-update splash ends); the buttons held at that moment are ignored
//!   until released, and the core steps once in that same update.
//! - Then each update steps one Lynx frame with the pad word: d-pad, A ->
//!   A (outer), B -> B (inner), START -> Pause; a SELECT press released
//!   before 30 updates is Option 1 for 3 frames once the 12-update
//!   fast-forward window after the release runs out with no second press
//!   (a second press drops it: the double tap, whose fast forward this
//!   model does not step, one frame per update as ever); a longer hold
//!   would open the menu (ignored here).
const std = @import("std");
const core = @import("core");
const Pad = core.Pad;

/// cart.Controls bits as preview.mjs writes them.
pub const Btn = struct {
    pub const start: u16 = 1 << 0;
    pub const select: u16 = 1 << 1;
    pub const a: u16 = 1 << 2;
    pub const b: u16 = 1 << 3;
    pub const up: u16 = 1 << 5;
    pub const down: u16 = 1 << 6;
    pub const left: u16 = 1 << 7;
    pub const right: u16 = 1 << 8;
    pub const all: u16 = start | select | a | b | up | down | left | right;
};

/// frontend/splash.zig `frames`; frontend/input.zig `hold_frames`,
/// `tap_frames`; frontend/tuning.zig `ff_tap_window`.
pub const splash_frames = 72;
pub const hold_frames = 30;
pub const tap_frames = 3;
pub const ff_tap_window = 12;

pub fn button_bit(name: []const u8) ?u16 {
    const map = [_]struct { []const u8, u16 }{
        .{ "START", Btn.start }, .{ "SELECT", Btn.select }, .{ "A", Btn.a },       .{ "B", Btn.b },
        .{ "UP", Btn.up },       .{ "DOWN", Btn.down },     .{ "LEFT", Btn.left }, .{ "RIGHT", Btn.right },
    };
    var up_buf: [16]u8 = undefined;
    if (name.len > up_buf.len) return null;
    const up = std.ascii.upperString(&up_buf, name);
    for (map) |m| if (std.mem.eql(u8, m[0], up)) return m[1];
    return null;
}

const Hold = struct { from: u32, to: u32, hold: []const []const u8 };

pub const ScriptError = error{ UnknownButton, BadRange } || std.json.ParseError(std.json.Scanner);

/// Controls word per update, `controls[i]` before update i, from a script.
pub fn parse_script(gpa: std.mem.Allocator, json: []const u8, controls: []u16) ScriptError!void {
    @memset(controls, 0);
    const parsed = try std.json.parseFromSlice([]const Hold, gpa, json, .{});
    defer parsed.deinit();
    for (parsed.value) |h| {
        if (h.to < h.from) return error.BadRange;
        var bits: u16 = 0;
        for (h.hold) |name| bits |= button_bit(name) orelse return error.UnknownButton;
        var u = h.from;
        while (u <= h.to and u < controls.len) : (u += 1) controls[u] |= bits;
    }
}

/// The cart's input path (main.zig, input.zig, splash.zig) without the
/// cart API.
pub const Frontend = struct {
    prev: u16 = 0,
    cur: u16 = 0,
    running: bool = false,
    splash_frame: u32 = 0,
    suppress: u16 = 0,
    holding: bool = false,
    held_frames: u16 = 0,
    opt1_left: u8 = 0,
    tap_window: u8 = 0,
    fast: bool = false,
    /// Select holds that would have opened the menu (M2).
    menu_requests: u32 = 0,

    /// One badge update with controls `c`: the pad word to step the core
    /// with, or null while the splash shows.
    pub fn update(f: *Frontend, c: u16) ?u16 {
        f.prev = f.cur;
        f.cur = c;
        f.suppress &= f.cur;
        if (!f.running) {
            const any = f.cur & ~f.prev & Btn.all != 0;
            if (!any and f.splash_frame < splash_frames) {
                f.splash_frame += 1;
                return null;
            }
            f.suppress = f.cur;
            f.holding = false;
            f.held_frames = 0;
            f.opt1_left = 0;
            f.tap_window = 0;
            f.fast = false;
            f.running = true;
        }
        return f.game_frame();
    }

    fn game_frame(f: *Frontend) u16 {
        const live = f.cur & ~f.suppress;
        var pad: u16 = 0;
        if (live & Btn.up != 0) pad |= Pad.up;
        if (live & Btn.down != 0) pad |= Pad.down;
        if (live & Btn.left != 0) pad |= Pad.left;
        if (live & Btn.right != 0) pad |= Pad.right;
        if (live & Btn.a != 0) pad |= Pad.a;
        if (live & Btn.b != 0) pad |= Pad.b;
        if (live & Btn.start != 0) pad |= Pad.pause;
        const pressed_select = live & Btn.select != 0 and f.cur & ~f.prev & Btn.select != 0;
        if (f.fast) {
            if (f.cur & Btn.start != 0 or f.cur & Btn.select == 0) f.fast = false;
        } else if (f.tap_window != 0) {
            if (f.cur & Btn.start != 0) {
                f.tap_window = 0;
            } else if (pressed_select) {
                f.tap_window = 0;
                f.fast = true;
            } else {
                f.tap_window -= 1;
                if (f.tap_window == 0) f.opt1_left = tap_frames;
            }
        }
        if (!f.fast and pressed_select) {
            f.holding = true;
            f.held_frames = 0;
        }
        if (f.holding) {
            if (f.cur & Btn.start != 0) {
                f.holding = false;
            } else if (f.cur & Btn.select != 0) {
                f.held_frames +|= 1;
                if (f.held_frames >= hold_frames) {
                    f.holding = false;
                    f.menu_requests += 1;
                }
            } else {
                f.holding = false;
                f.tap_window = ff_tap_window;
            }
        }
        if (f.opt1_left > 0) {
            f.opt1_left -= 1;
            pad |= Pad.opt1;
        }
        return pad;
    }
};

/// Hash of what the frontend shows: the displayed pixels and palette.
pub fn frame_hash(f: core.Frame) u64 {
    var w = std.hash.Wyhash.init(0);
    w.update(f.pixels);
    w.update(f.green);
    w.update(f.bluered);
    return w.final();
}

/// One step of a run: what happened in update `update`.
pub const Step = struct {
    update: u32,
    /// The core stepped (false during the splash).
    stepped: bool,
    pad: u16,
    hash: u64,
};

/// A scripted run over a console the caller owns (a static: ~75 KB).
pub const Run = struct {
    lynx: *core.Lynx,
    controls: []const u16,
    fe: Frontend = .{},
    update_index: u32 = 0,

    pub fn init(l: *core.Lynx, c: core.Cart, controls: []const u16) Run {
        l.init_in_place(c);
        return .{ .lynx = l, .controls = controls };
    }

    pub fn done(r: *const Run) bool {
        return r.update_index >= r.controls.len;
    }

    pub fn step(r: *Run) Step {
        const u = r.update_index;
        r.update_index += 1;
        const c = if (u < r.controls.len) r.controls[u] else 0;
        const pad = r.fe.update(c);
        if (pad) |p| r.lynx.step_frame(p);
        return .{ .update = u, .stepped = pad != null, .pad = pad orelse 0, .hash = frame_hash(r.lynx.frame()) };
    }
};

/// A cart from a whole file (headered `.lnx` or a headerless dump), or the
/// parser's refusal.
pub fn cart_from_file(file: []const u8) union(enum) { ok: core.Cart, refused: core.cart.Refusal } {
    const lay = core.cart.parse(file, @intCast(file.len));
    if (lay.verdict != .ok) return .{ .refused = lay.verdict };
    return .{ .ok = core.Cart.from_slice(&lay, file) };
}

/// PPM (P6) image of a frame: 160x102, the 12-bit palette widened to 8 bits.
pub const ppm_header = "P6\n160 102\n255\n";
pub const ppm_size = ppm_header.len + core.screen_w * core.screen_h * 3;

pub fn ppm(f: core.Frame, out: *[ppm_size]u8) void {
    @memcpy(out[0..ppm_header.len], ppm_header);
    var i: usize = ppm_header.len;
    for (f.pixels) |b| {
        for ([2]u8{ b >> 4, b & 0xF }) |idx| {
            out[i] = (f.bluered[idx] & 0xF) * 17;
            out[i + 1] = (f.green[idx] & 0xF) * 17;
            out[i + 2] = (f.bluered[idx] >> 4) * 17;
            i += 3;
        }
    }
}

test "golden: runner input model (splash skip, suppress, Select tap)" {
    var fe: Frontend = .{};
    try std.testing.expectEqual(@as(?u16, null), fe.update(0));
    // A newly pressed skips the splash; it is suppressed until released.
    try std.testing.expectEqual(@as(?u16, 0), fe.update(Btn.a));
    try std.testing.expectEqual(@as(?u16, 0), fe.update(Btn.a));
    try std.testing.expectEqual(@as(?u16, 0), fe.update(0));
    try std.testing.expectEqual(@as(?u16, Pad.up | Pad.b), fe.update(Btn.up | Btn.b));
    try std.testing.expectEqual(@as(?u16, Pad.pause), fe.update(Btn.start));
    // Select tap: Option 1 for three frames once the fast-forward window
    // after the release (12 updates) runs out.
    try std.testing.expectEqual(@as(?u16, 0), fe.update(Btn.select));
    for (0..ff_tap_window) |_| try std.testing.expectEqual(@as(?u16, 0), fe.update(0));
    try std.testing.expectEqual(@as(?u16, Pad.opt1), fe.update(0));
    try std.testing.expectEqual(@as(?u16, Pad.opt1), fe.update(0));
    try std.testing.expectEqual(@as(?u16, Pad.opt1), fe.update(0));
    try std.testing.expectEqual(@as(?u16, 0), fe.update(0));
    // A double tap drops it (the second press held is fast forward).
    try std.testing.expectEqual(@as(?u16, 0), fe.update(Btn.select));
    try std.testing.expectEqual(@as(?u16, 0), fe.update(0));
    for (0..2 * hold_frames) |_| try std.testing.expectEqual(@as(?u16, Pad.up), fe.update(Btn.select | Btn.up));
    for (0..2 * ff_tap_window) |_| try std.testing.expectEqual(@as(?u16, 0), fe.update(0));
    try std.testing.expectEqual(@as(u32, 0), fe.menu_requests);
    // The splash also ends by itself.
    var fe2: Frontend = .{};
    var n: u32 = 0;
    while (fe2.update(0) == null) n += 1;
    try std.testing.expectEqual(@as(u32, splash_frames), n);
}

test "golden: script parsing (inclusive ranges, names, errors)" {
    var c: [10]u16 = undefined;
    try parse_script(std.testing.allocator,
        \\[{"from": 2, "to": 3, "hold": ["a", "UP"]}, {"from": 3, "to": 20, "hold": ["SELECT"]}]
    , &c);
    try std.testing.expectEqual(@as(u16, 0), c[1]);
    try std.testing.expectEqual(Btn.a | Btn.up, c[2]);
    try std.testing.expectEqual(Btn.a | Btn.up | Btn.select, c[3]);
    try std.testing.expectEqual(Btn.select, c[9]);
    try std.testing.expectError(error.UnknownButton, parse_script(std.testing.allocator,
        \\[{"from": 0, "to": 1, "hold": ["CLICK"]}]
    , &c));
}
