//! Snouty Theremin (docs/TOF.md M1, SPEC.md): a theremin played by hand
//! distance over the TMF8820 time-of-flight sensor, or by the stick when
//! there is no sensor.
//!
//! update(): buttons (nothing while Start and Select are held together,
//! the OS's chord; Start and Select act on release so the chord never
//! opens the menu or mutes), then the input source (input.zig: the sensor
//! integration point, or the stick), the player (play.zig: pitch, snap,
//! glide, fade), the voice into the audio ring (voice.zig, audio.zig),
//! and the screen (screen.zig).
//!
//! Sound boots ON (an instrument; docs/TOF.md deferred question 1, flip
//! `muted`'s initial value); Select mutes. On the badge the voice streams
//! through lib/stream_audio.zig (never `cart.tone2`); in the wasm
//! simulator, which has no streaming audio, the simulator's `tone` import
//! is re-struck every update at the voice's pitch (docs/RUNNING.md).
const cart = @import("cart-api");
const tof = @import("tof");
const tof_types = tof.types;
const tof_pose = tof.pose;
const pitch = @import("pitch.zig");
const hands = @import("hands.zig");
const play = @import("play.zig");
const voice = @import("voice.zig");
const audio = @import("audio.zig");
const input = @import("input.zig");
const screen = @import("screen.zig");
const sensor = @import("sensor.zig");

comptime {
    cart.export_start_code();
}

var settings: play.Settings = .{};
var player: play.Player = .{};
var v: voice.Voice = .{};
var feeder: audio.Feeder = .{};
var in: input.Input = .{};
var last_hands: hands.Hands = .{};
/// The breakout's mounting (docs/TOF.md deferred question 2); the MIRROR
/// menu row flips it left/right.
fn orientation() tof_types.Orientation {
    return .{ .flip_x = settings.mirror };
}
/// The hand's place over the grid (hands.Track) from lib/tof_pose.zig,
/// with the wide map's (spad_map 6) field of view and hands.Config's
/// distance window.
const pose_config: tof_pose.Config = .{ .fov_x_deg = 41, .fov_y_deg = 52, .max_mm = 650, .min_confidence = 8 };
var pose_est: tof_pose.Estimator = .{ .config = pose_config };
var track: hands.Track = .{};
/// The geometries frames are read through, per layout (rebuilt when MIRROR
/// changes the orientation).
var geom_grid: tof.zones.Geometry = .{};
var geom_stripes: tof.zones.Geometry = .{};

var muted = false;
var menu_open = false;
var menu_row: u8 = 0;
var tick: u32 = 0;
var prev: cart.Controls = .{ .start = false, .select = false, .a = false, .b = false, .click = false, .up = false, .down = false, .left = false, .right = false };
/// Start+Select were held together since both were last up: ignore buttons.
var chord = false;

/// badge-bench pokes: `snouty_theremin_fake=N` runs the demo hand (1 one
/// hand, 2 two hands in the two-hand layout) instead of the empty sensor.
var bench_fake: u32 = 0;
/// badge-bench poke `snouty_theremin_zones=N`: 1 GRID, 2 STRIPES (0 keeps
/// the default, STRIPES), applied before the sensor starts.
var bench_zones: u32 = 0;
comptime {
    if (!cart.is_wasm) {
        @export(&bench_fake, .{ .name = "snouty_theremin_fake" });
        @export(&bench_zones, .{ .name = "snouty_theremin_zones" });
    }
}

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    cart.set_double_buffer_mode(.no_copy_full_frame);
    set_geometry();
    set_zones(settings.zones);
}

pub fn update() void {
    if (bench_zones != 0) {
        set_zones(if (bench_zones == 1) .grid else .stripes);
        bench_zones = 0;
    }
    if (bench_fake != 0 and in.fake == 0) set_fake(bench_fake);
    const c = read_controls();
    buttons(c);

    if (in.poll(cart.micros_since_boot(), tick)) |f| {
        // Each frame through its own layout (frames in flight around a
        // ZONES switch carry the old one; the pose ignores those).
        const g = if (f.layout == .stripes) &geom_stripes else &geom_grid;
        last_hands = hands.read_with(&f, .{ .layout = settings.layout, .orientation = orientation(), .pitch_left = settings.pitch_left }, g);
        const p = pose_est.update(&f, null, orientation());
        if (f.layout == pose_est.layout) track = hands.track(track, p.present, p.x, p.y, pose_est.geometry(orientation()));
        player.sensor(last_hands, settings);
    }
    if (in.source == .stick) {
        const live = !menu_open and !chord;
        const dir: i2 = if (live and c.up and !c.down) 1 else if (live and c.down and !c.up) -1 else 0;
        player.stick(dir, live and (c.left or c.right), settings);
    }
    const out = player.tick(settings);
    v.set_wave(settings.wave);
    v.set(pitch.inc_for(out.cents), out.level, out.release);
    if (out.jump) v.jump();

    if (cart.is_wasm) {
        feeder.render_only(&v);
        sim_tone(out);
    } else {
        feeder.feed(&v, muted);
    }

    screen.draw(.{
        .settings = settings,
        .out = out,
        .v = &v,
        .hands = last_hands,
        .track = track,
        .source = in.source,
        .muted = muted,
        .stick_mm = player.map.distance(settings.low(), out.cents),
        .menu_open = menu_open,
        .menu_row = menu_row,
        .tick = tick,
    });
    tick +%= 1;
    if (cart.is_wasm) present_wasm();
}

/// ZONES: the sensor's layout, the pose's (which starts afresh: its
/// zones look elsewhere now) and the demo hand's.
fn set_zones(z: hands.Zones) void {
    settings.zones = z;
    sensor.set_layout(z.layout());
    pose_est.set_layout(z.layout());
    in.zones = z;
    track = .{};
}

fn set_geometry() void {
    geom_grid = hands.geometry(.grid, orientation());
    geom_stripes = hands.geometry(.stripes, orientation());
}

fn set_fake(mode: u32) void {
    in.set_fake(@intCast(@min(mode, 2)), tick);
    if (mode == 2) settings.layout = .two_hand;
}

// ---- Buttons (SPEC section 2) ----

fn buttons(c: cart.Controls) void {
    defer prev = c;
    if (c.start and c.select) chord = true;
    if (chord) {
        if (!c.start and !c.select) chord = false;
        return;
    }
    // Start and Select act on release (so the chord can never fire them).
    if (prev.start and !c.start) {
        menu_open = !menu_open;
        return;
    }
    if (prev.select and !c.select) muted = !muted;

    const a = c.a and !prev.a;
    const b = c.b and !prev.b;
    const up = c.up and !prev.up;
    const down = c.down and !prev.down;
    const left = c.left and !prev.left;
    const right = c.right and !prev.right;

    if (menu_open) {
        if (b) menu_open = false;
        if (up) menu_row = if (menu_row == 0) screen.menu_rows.len - 1 else menu_row - 1;
        if (down) menu_row = if (menu_row + 1 == screen.menu_rows.len) 0 else menu_row + 1;
        if (right or a) change(menu_row, 1);
        if (left) change(menu_row, -1);
        return;
    }
    if (a) change(1, 1);
    if (b) change(2, 1);
    // With a sensor the stick is free: Up/Down octave, Left/Right layout.
    // Without one it plays (update()).
    if (in.source == .sensor) {
        if (up) change(5, 1);
        if (down) change(5, -1);
        if (left) settings.layout = .one_hand;
        if (right) settings.layout = .two_hand;
    }
}

/// Next/previous value of a settings enum (each fills its tag type:
/// u1 or u2, so the count is a power of two).
fn cycle(comptime E: type, e: E, d: i2) E {
    const n = 1 << @bitSizeOf(E);
    const i: i32 = @backingInt(e);
    return @fromBackingInt(@intCast(@mod(i + d, n)));
}

/// Step menu row `row` by `d` (screen.menu_rows order).
fn change(row: u8, d: i2) void {
    switch (row) {
        0 => settings.layout = cycle(hands.Layout, settings.layout, d),
        1 => settings.wave = cycle(voice.Wave, settings.wave, d),
        2 => settings.scale = cycle(pitch.Scale, settings.scale, d),
        3 => settings.snap = cycle(pitch.Snap, settings.snap, d),
        4 => settings.root = @intCast(@mod(@as(i32, settings.root) + d, 12)),
        5 => {
            const o: i32 = @as(i32, settings.octave) + d;
            settings.octave = @intCast(@min(@max(o, play.Settings.min_octave), play.Settings.max_octave));
        },
        6 => settings.pitch_left = !settings.pitch_left,
        7 => {
            settings.mirror = !settings.mirror;
            // The pose's background is per device zone and survives; the
            // highlight's cell is a screen cell: start it over.
            set_geometry();
            track = .{};
        },
        else => set_zones(if (settings.zones == .grid) .stripes else .grid),
    }
}

// ---- Simulator audio ----

/// The web simulator has no streaming audio: re-strike its `tone` import
/// every update for 3 frames at the voice's pitch (finite tones only; an
/// infinite one is inaudible there, docs/SOUND.md), so it follows the
/// hand or the stick. Sine and triangle use its triangle channel (2), saw
/// and square its pulse channel 0 at 25% and 50% duty.
const sim_shim = struct {
    extern fn tone(frequency: u32, duration: u32, volume: u32, flags: u32) void;
};

fn sim_tone(out: play.Output) void {
    if (muted or out.level < 1024) return;
    const hz = pitch.hz_of(pitch.inc_for(out.cents));
    const volume: u32 = @intCast(@divTrunc(out.level * 70, voice.full));
    const flags: u32 = switch (settings.wave) {
        .sine, .triangle => 2,
        .saw => 0 | (1 << 2),
        .square => 0 | (2 << 2),
    };
    sim_shim.tone(hz, 3, volume, flags);
}

// ---- Debug exports (wasm only; docs/RUNNING.md) ----

fn debug_set_fake_sensor(mode: u32) callconv(.c) u32 {
    set_fake(mode);
    return in.fake;
}
fn debug_note() callconv(.c) i32 {
    return player.out.cents;
}
fn debug_level() callconv(.c) i32 {
    return v.level;
}
fn debug_source() callconv(.c) u32 {
    return @backingInt(in.source);
}
fn debug_muted() callconv(.c) u32 {
    return @intFromBool(muted);
}
fn debug_menu() callconv(.c) u32 {
    return @intFromBool(menu_open);
}
fn debug_wave() callconv(.c) u32 {
    return @backingInt(settings.wave);
}
fn debug_scale() callconv(.c) u32 {
    return @backingInt(settings.scale);
}
fn debug_zones() callconv(.c) u32 {
    return @backingInt(settings.zones);
}
// The setters return the new value (preview.mjs --call-at wants a result).
/// 0 GRID, 1 STRIPES.
fn debug_set_zones(z: u32) callconv(.c) u32 {
    set_zones(if (z & 1 == 0) .grid else .stripes);
    return @backingInt(settings.zones);
}
fn debug_set_scale(s: u32) callconv(.c) u32 {
    settings.scale = @fromBackingInt(@intCast(@as(u2, @intCast(s & 3))));
    return @backingInt(settings.scale);
}
fn debug_set_snap(s: u32) callconv(.c) u32 {
    settings.snap = @fromBackingInt(@intCast(@as(u1, @intCast(s & 1))));
    return @backingInt(settings.snap);
}
fn debug_set_wave(s: u32) callconv(.c) u32 {
    settings.wave = @fromBackingInt(@intCast(@as(u2, @intCast(s & 3))));
    return @backingInt(settings.wave);
}
comptime {
    if (cart.is_wasm) {
        @export(&debug_set_fake_sensor, .{ .name = "debug_set_fake_sensor" });
        @export(&debug_note, .{ .name = "debug_note" });
        @export(&debug_level, .{ .name = "debug_level" });
        @export(&debug_source, .{ .name = "debug_source" });
        @export(&debug_muted, .{ .name = "debug_muted" });
        @export(&debug_menu, .{ .name = "debug_menu" });
        @export(&debug_wave, .{ .name = "debug_wave" });
        @export(&debug_scale, .{ .name = "debug_scale" });
        @export(&debug_set_scale, .{ .name = "debug_set_scale" });
        @export(&debug_set_snap, .{ .name = "debug_set_snap" });
        @export(&debug_set_wave, .{ .name = "debug_set_wave" });
        @export(&debug_zones, .{ .name = "debug_zones" });
        @export(&debug_set_zones, .{ .name = "debug_set_zones" });
    }
}

// ---- Simulator shims (every cart has them; CLAUDE.md) ----

/// Button state. Upstream's platform_wasm.zig never fills `controls` from
/// the simulator, which writes its button word (same bit layout as
/// cart.Controls) to linear address 0x04; read that on wasm.
fn read_controls() cart.Controls {
    if (cart.is_wasm) return @bitCast(@as(*const volatile u16, @ptrFromInt(0x04)).*);
    return cart.controls.*;
}

/// Upstream's wasm platform never presents, and the web simulator reads a
/// legacy framebuffer at 0x20 with red and blue swapped.
fn present_wasm() void {
    const sim_framebuffer: *cart.Framebuffer = @ptrFromInt(0x20);
    for (cart.framebuffer, sim_framebuffer) |*src_column, *dst_column| {
        for (src_column, dst_column) |src, *dst| {
            const col = src.to_color();
            dst.* = .from_color(.{ .r = col.b, .g = col.g, .b = col.r });
        }
    }
}
