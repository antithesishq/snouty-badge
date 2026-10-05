//! The Raspberry Trail's pictures (SPEC 5): a tiny draw API over the data
//! that tools/gen_art.py paints and writes to gen/ (ASSETS.md lists every
//! picture). No cart API here: `draw` writes colours through a sink the
//! caller supplies, so the UI decides how pixels reach the screen and the
//! host tests can run.
//!
//! A sink is any value (or pointer) with
//!     pub fn put(self, x: i32, y: i32, c: art.Color) void
//! and optionally, for horizontal runs (x1 exclusive, already clipped),
//!     pub fn span(self, x0: i32, x1: i32, y: i32, c: art.Color) void
//! Every call is already clipped, so the sink need not bounds-check.
//! `art.Color` has the bit layout of cart-api's `DisplayColor`, so
//! `@bitCast(c)` turns one into the other for free.

const std = @import("std");
const gen = @import("gen/art_data.zig");

pub const Pic = gen.Pic;
pub const Rect = gen.Rect;
/// Placement hints generated with the pictures (see gen/art_data.zig):
/// title_bg at (0, 0), title_wagon and title_logo at their rects, the menu
/// in title_menu; shoot_cue and tomb_text are relative to their picture.
pub const layout = gen.layout;

/// RGB565 in cart-api `DisplayColor` order: r in bits 0-4, g 5-10, b 11-15.
pub const Color = packed struct(u16) {
    r: u5,
    g: u6,
    b: u5,

    /// 0xRRGGBB, the colour the badge shows (each channel's top bits).
    pub fn rgb888(c: Color) u32 {
        const r: u32 = @as(u32, c.r) << 3 | @as(u32, c.r) >> 2;
        const g: u32 = @as(u32, c.g) << 2 | @as(u32, c.g) >> 4;
        const b: u32 = @as(u32, c.b) << 3 | @as(u32, c.b) >> 2;
        return r << 16 | g << 8 | b;
    }
};

pub const Size = struct { w: u16, h: u16 };

pub const screen: Rect = .{ .x = 0, .y = 0, .w = 160, .h = 128 };

pub fn size(p: Pic) Size {
    const inf = gen.infos[@backingInt(p)];
    return .{ .w = inf.w, .h = inf.h };
}

/// Number of frames; `draw` takes any frame number and wraps it.
pub fn frames(p: Pic) u8 {
    return gen.infos[@backingInt(p)].frames;
}

/// Draws picture `p` with its top-left at (x, y), clipped to the screen.
/// Transparent pixels are skipped. `frame` wraps (pass a tick counter
/// divided down to the animation speed).
pub fn draw(p: Pic, x: i32, y: i32, frame: u32, sink: anytype) void {
    drawClipped(p, x, y, frame, screen, sink);
}

/// `draw` with an explicit clip rectangle (screen coordinates), e.g. a
/// vignette inside the log area.
pub fn drawClipped(p: Pic, x: i32, y: i32, frame: u32, clip: Rect, sink: anytype) void {
    const inf = gen.infos[@backingInt(p)];
    const fr = gen.frames[inf.frame + frame % inf.frames];
    const pal = gen.palette[inf.pal..][0..inf.colors];
    const w: i32 = inf.w;
    const h: i32 = inf.h;
    const cx0: i32 = @max(clip.x, 0);
    const cy0: i32 = @max(clip.y, 0);
    const cx1: i32 = @as(i32, clip.x) + clip.w;
    const cy1: i32 = @as(i32, clip.y) + clip.h;
    if (x >= cx1 or y >= cy1 or x + w <= cx0 or y + h <= cy0) return;
    const bytes = gen.data[fr.off..][0..fr.len];
    if (fr.rle) {
        drawRle(bytes, pal, w, x, y, .{ cx0, cy0, cx1, cy1 }, sink);
    } else {
        drawRaw(bytes, pal, w, h, x, y, .{ cx0, cy0, cx1, cy1 }, sink);
    }
}

/// The colour of one pixel of a picture (null = transparent or outside).
/// Decodes from the start of the frame: for tests and hit checks, not for
/// drawing.
pub fn pixel(p: Pic, frame: u32, px: i32, py: i32) ?Color {
    const sz = size(p);
    if (px < 0 or py < 0 or px >= sz.w or py >= sz.h) return null;
    var probe: Probe = .{};
    drawClipped(p, -px, -py, frame, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, &probe);
    return probe.c;
}

const Probe = struct {
    c: ?Color = null,
    fn put(self: *Probe, x: i32, y: i32, c: Color) void {
        if (x == 0 and y == 0) self.c = c;
    }
};

inline fn emit(sink: anytype, x0: i32, x1: i32, y: i32, c: Color) void {
    const S = @TypeOf(sink);
    const T = switch (@typeInfo(S)) {
        .pointer => |ptr| ptr.child,
        else => S,
    };
    if (comptime @hasDecl(T, "span")) {
        sink.span(x0, x1, y, c);
    } else {
        var x = x0;
        while (x < x1) : (x += 1) sink.put(x, y, c);
    }
}

fn drawRle(bytes: []const u8, pal: []const u16, w: i32, x: i32, y: i32, clip: [4]i32, sink: anytype) void {
    const cx0, const cy0, const cx1, const cy1 = clip;
    var i: usize = 0;
    var px: i32 = 0;
    var py: i32 = 0;
    while (i < bytes.len) {
        const b = bytes[i];
        i += 1;
        var n: i32 = (b >> 4) + 1;
        if (b >> 4 == 15) {
            n = 16 + @as(i32, bytes[i]);
            i += 1;
        }
        const idx = b & 15;
        while (n > 0) {
            const seg = @min(n, w - px);
            if (idx != 0) {
                const sy = y + py;
                if (sy >= cy0) {
                    const sx0 = @max(x + px, cx0);
                    const sx1 = @min(x + px + seg, cx1);
                    if (sx0 < sx1) emit(sink, sx0, sx1, sy, @bitCast(pal[idx]));
                }
            }
            px += seg;
            n -= seg;
            if (px == w) {
                px = 0;
                py += 1;
                if (y + py >= cy1) return;
            }
        }
    }
}

fn drawRaw(bytes: []const u8, pal: []const u16, w: i32, h: i32, x: i32, y: i32, clip: [4]i32, sink: anytype) void {
    const cx0, const cy0, const cx1, const cy1 = clip;
    const py0 = @max(0, cy0 - y);
    const py1 = @min(h, cy1 - y);
    const px0 = @max(0, cx0 - x);
    const px1 = @min(w, cx1 - x);
    var py = py0;
    while (py < py1) : (py += 1) {
        var k: usize = @intCast(py * w + px0);
        var px = px0;
        while (px < px1) : ({
            px += 1;
            k += 1;
        }) {
            const idx = (bytes[k >> 1] >> @intCast((k & 1) * 4)) & 15;
            if (idx != 0) sink.put(x + px, y + py, @as(Color, @bitCast(pal[idx])));
        }
    }
}

// ------------------------------------------------------------- mapping
// Lookups by tag *name* so this module never imports the game: pass the
// game's enum values straight in (`art.vignette(line.tag)`); ASSETS.md has
// the table.

const NamePic = struct { []const u8, Pic };

const vignette_names = [_]NamePic{
    .{ "wagon_breaks", .v_wagon_breaks },
    .{ "ox_injured", .v_ox_injured },
    .{ "daughter_arm", .v_daughter_arm },
    .{ "ox_wanders", .v_ox_wanders },
    .{ "son_lost", .v_son_lost },
    .{ "bad_water", .v_bad_water },
    .{ "heavy_rain", .v_heavy_rain },
    .{ "bandits", .v_bandits },
    .{ "fire", .v_fire },
    .{ "fog", .v_fog },
    .{ "snake", .v_snake },
    .{ "river", .v_river },
    .{ "wild_animals", .v_wild_animals },
    .{ "cold", .v_cold },
    .{ "hail", .v_hail },
    .{ "illness", .v_illness },
    .{ "helpful_food", .v_helpful_food },
    .{ "riders", .v_riders },
    .{ "hunt_result", .v_hunt_result },
    .{ "fort", .v_fort },
    .{ "mountains", .v_mountains },
    .{ "blizzard", .v_blizzard },
    .{ "south_pass", .v_south_pass },
};

/// The vignette for a game `Tag` (by name), or null for tags without one.
pub fn vignette(tag: anytype) ?Pic {
    return vignetteByName(@tagName(tag));
}

pub fn vignetteByName(name: []const u8) ?Pic {
    for (vignette_names) |e| {
        if (std.mem.eql(u8, e[0], name)) return e[1];
    }
    return null;
}

/// `vignette`, plus the doctor's bag for the `warning` line
/// "DOCTOR'S BILL IS $20" (warnings share one tag, so it looks at the text).
pub fn vignetteForLine(tag: anytype, text: []const u8) ?Pic {
    if (std.mem.eql(u8, @tagName(tag), "warning") and std.mem.startsWith(u8, text, "DOCTOR")) return .v_doctor;
    return vignette(tag);
}

/// The background for a game `ShotReason` (hunt, riders, bandits, animals).
pub fn shootScene(reason: anytype) Pic {
    const n = @tagName(reason);
    if (std.mem.eql(u8, n, "riders")) return .shoot_riders;
    if (std.mem.eql(u8, n, "bandits")) return .shoot_bandits;
    if (std.mem.eql(u8, n, "animals")) return .shoot_animals;
    return .shoot_hunt;
}

/// The end picture for a game `Outcome`: arrival for `arrived`, the
/// tombstone for every death, null for `none`.
pub fn endScene(outcome: anytype) ?Pic {
    const n = @tagName(outcome);
    if (std.mem.eql(u8, n, "none")) return null;
    if (std.mem.eql(u8, n, "arrived")) return .arrival;
    return .tombstone;
}

pub const Button = enum { up, down, left, right, a, b };

/// Frames of a button glyph.
pub const ButtonState = enum(u8) { normal = 0, highlighted = 1, done = 2 };

/// The 14x14 glyph for a cue button; draw it with `@intFromEnum(state)` as
/// the frame. Takes `art.Button` or any enum with those names.
pub fn button(b: anytype) Pic {
    const n = @tagName(b);
    const table = [_]NamePic{
        .{ "up", .btn_up },       .{ "down", .btn_down }, .{ "left", .btn_left },
        .{ "right", .btn_right }, .{ "a", .btn_a },       .{ "b", .btn_b },
    };
    for (table) |e| {
        if (std.mem.eql(u8, e[0], n)) return e[1];
    }
    return .btn_a;
}

/// Trail strip markers in trail order with their mileage (SPEC 5).
pub const Marker = struct { pic: Pic, mile: u16 };
pub const markers = [_]Marker{
    .{ .pic = .mark_start, .mile = 0 },
    .{ .pic = .mark_pass, .mile = 950 },
    .{ .pic = .mark_mountains, .mile = 1700 },
    .{ .pic = .mark_city, .mile = 2040 },
};
