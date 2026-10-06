//! Snouty Trombone (SPEC.md): a slide trombone played by hand over the
//! TMF8820 time-of-flight sensor (height = the slide, side to side = the
//! embouchure), or by the stick when there is no sensor.
//!
//! update(): buttons (nothing while Start and Select are held together,
//! the OS's chord; Start and Select act on release so the chord never
//! opens the menu or mutes), then the input source (input.zig: the sensor
//! integration point, the demo hand, or the stick), the hand (hand.zig on
//! lib/tof_pose.zig), the player (play.zig: slide, lip, partials,
//! blowing), the voice into the audio ring (voice.zig, audio.zig), and
//! the screen (screen.zig).
//!
//! Sound boots ON (an instrument, like the theremin; flip `muted`'s initial
//! value); Select mutes. On the badge the voice streams through
//! lib/stream_audio.zig (never `cart.tone2`); in the wasm simulator, which
//! has no streaming audio, the simulator's `tone` import is re-struck
//! every update at the voice's pitch (docs/RUNNING.md).
const cart = @import("cart-api");
const tof_types = @import("tof").types;
const tof_pose = @import("tof").pose;
const horn = @import("horn.zig");
const hand = @import("hand.zig");
const play = @import("play.zig");
const voice = @import("voice.zig");
const audio = @import("audio.zig");
const input = @import("input.zig");
const screen = @import("screen.zig");

comptime {
    cart.export_start_code();
}

var settings: play.Settings = .{};
var player: play.Player = .{};
var v: voice.Voice = .{};
var feeder: audio.Feeder = .{};
var in: input.Input = .{};
var pose_est: tof_pose.Estimator = .{ .config = hand.pose_config };
var reading: hand.Reading = .{};

/// The breakout's mounting (docs/TOF.md deferred question 2); the MIRROR
/// menu row flips it left/right.
fn orientation() tof_types.Orientation {
    return .{ .flip_x = settings.mirror };
}

var muted = false;
var menu_open = false;
var menu_row: u8 = 0;
var tick: u32 = 0;
var prev: cart.Controls = .{ .start = false, .select = false, .a = false, .b = false, .click = false, .up = false, .down = false, .left = false, .right = false };
var prev_a = false;
/// B closed the menu: it is not the plunger until it is let go.
var b_block = false;
/// Start+Select were held together since both were last up: ignore buttons.
var chord = false;

/// badge-bench poke: `snouty_trombone_fake=1` runs the demo hand instead
/// of the empty sensor.
var bench_fake: u32 = 0;
comptime {
    if (!cart.is_wasm) @export(&bench_fake, .{ .name = "snouty_trombone_fake" });
}

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    cart.set_double_buffer_mode(.no_copy_full_frame);
}

pub fn update() void {
    if (bench_fake != 0 and !in.fake) set_demo(true);
    const c = read_controls();
    buttons(c);

    if (in.poll(cart.micros_since_boot(), tick)) |f| {
        const p = pose_est.update(&f, null, orientation());
        reading = hand.read(&f, &p, .{ .orientation = orientation() });
        player.sensor(reading.height_mm, reading.lip_t, settings);
    }
    const live = !menu_open and !chord;
    const demo = in.fake_buttons(tick);
    const a = (live and c.a) or demo.a;
    if (!c.b) b_block = false;
    const b = (live and c.b and !b_block) or demo.b;
    if (in.source == .stick) {
        const dir: i2 = if (live and c.up and !c.down) 1 else if (live and c.down and !c.up) -1 else 0;
        const lr: i2 = if (live and c.right and !c.left) 1 else if (live and c.left and !c.right) -1 else 0;
        player.stick(dir, lr, settings);
    }
    const out = player.tick(settings, .{ .a = a, .a_press = a and !prev_a, .b = b });
    prev_a = a;

    v.bright = settings.tone == .bright;
    v.set(horn.inc_for(out.cents), out.level, out.release);
    if (out.jump) v.jump();
    if (out.crack_from != null) v.crack();
    if (out.tongue) v.attack();
    v.set_mute(out.mute);

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
        .reading = reading,
        .source = in.source,
        .demo = in.fake,
        .muted = muted,
        .menu_open = menu_open,
        .menu_row = menu_row,
        .tick = tick,
    });
    tick +%= 1;
    if (cart.is_wasm) present_wasm();
}

fn set_demo(on: bool) void {
    in.set_fake(on, tick);
    settings.demo = on;
}

// ---- Buttons (SPEC section 4) ----

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
    if (!menu_open) return;

    const a = c.a and !prev.a;
    const b = c.b and !prev.b;
    const up = c.up and !prev.up;
    const down = c.down and !prev.down;
    const left = c.left and !prev.left;
    const right = c.right and !prev.right;
    if (b) {
        menu_open = false;
        b_block = true;
    }
    if (up) menu_row = if (menu_row == 0) screen.menu_rows.len - 1 else menu_row - 1;
    if (down) menu_row = if (menu_row + 1 == screen.menu_rows.len) 0 else menu_row + 1;
    if (right or left or a) change(menu_row);
}

/// Flip menu row `row` (screen.menu_rows order; every row has two values).
fn change(row: u8) void {
    switch (row) {
        0 => settings.blow = if (settings.blow == .auto) .a else .auto,
        1 => settings.snap = if (settings.snap == .off) .soft else .off,
        2 => {
            settings.mirror = !settings.mirror;
            // The background it learned is per screen cell: start over.
            pose_est = .{ .config = hand.pose_config };
        },
        3 => settings.pedal = !settings.pedal,
        4 => settings.tone = if (settings.tone == .bright) .mellow else .bright,
        else => set_demo(!settings.demo),
    }
}

// ---- Simulator audio ----

/// The web simulator has no streaming audio: re-strike its `tone` import
/// every update for 3 frames at the voice's pitch (finite tones only; an
/// infinite one is inaudible there, docs/SOUND.md), on its pulse channel
/// at 25% duty (brassy), 50% with the plunger shut.
const sim_shim = struct {
    extern fn tone(frequency: u32, duration: u32, volume: u32, flags: u32) void;
};

fn sim_tone(out: play.Output) void {
    if (muted or v.level < 1024) return;
    const hz = horn.hz_of(horn.inc_for(out.cents));
    const volume: u32 = @intCast(@divTrunc(v.level * 60, voice.full));
    const flags: u32 = if (out.mute) 0 | (2 << 2) else 0 | (1 << 2);
    sim_shim.tone(hz, 3, volume, flags);
}

// ---- Debug exports (wasm only; docs/RUNNING.md) ----

fn debug_set_fake_sensor(mode: u32) callconv(.c) u32 {
    set_demo(mode != 0);
    return @intFromBool(in.fake);
}
fn debug_note() callconv(.c) i32 {
    return player.out.cents;
}
fn debug_partial() callconv(.c) u32 {
    return player.out.partial;
}
fn debug_slide() callconv(.c) i32 {
    return player.out.slide;
}
fn debug_level() callconv(.c) i32 {
    return v.level;
}
fn debug_mute() callconv(.c) u32 {
    return @intFromBool(player.out.mute);
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
comptime {
    if (cart.is_wasm) {
        @export(&debug_set_fake_sensor, .{ .name = "debug_set_fake_sensor" });
        @export(&debug_note, .{ .name = "debug_note" });
        @export(&debug_partial, .{ .name = "debug_partial" });
        @export(&debug_slide, .{ .name = "debug_slide" });
        @export(&debug_level, .{ .name = "debug_level" });
        @export(&debug_mute, .{ .name = "debug_mute" });
        @export(&debug_source, .{ .name = "debug_source" });
        @export(&debug_muted, .{ .name = "debug_muted" });
        @export(&debug_menu, .{ .name = "debug_menu" });
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
