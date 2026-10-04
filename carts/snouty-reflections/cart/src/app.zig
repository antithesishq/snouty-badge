//! App state (PLAN.md M3 "App state", M4 "App", SPEC.md section 3): attract
//! orbit or free camera, a frozen flag on top of either, the preset cycle
//! with its fade, and the View handed to the tracer each frame.
//!
//! Per update, main.zig calls `handle_input()` (after input.update), asks
//! `frame_kind()` what to draw, draws `view()`, then calls `advance()`. So
//! update #f of an untouched run renders t = f, orbit = f % orbit_frames,
//! sunset, default height, fade 1 until the first fade-out: M2.2's frame f
//! (the legacy identity).
//!
//! Controls (never the joystick click; Start+Select is the OS's):
//!   stick     attract: enter free camera. free (frozen or not): Left/Right
//!             orbit -3/+3 frames per frame, Up/Down height +-0.05 per frame
//!   A         toggle frozen (t, orbit and the preset cycle stop)
//!   B         next dither mode
//!   Select    next preset at once, no fade; restarts the attract cycle
//!   Start     back to attract, unfrozen; in attract (unfrozen), music
//!             on/off (music.zig) with a `toast_frames` note on screen
//! Start and Select do nothing while both are held: the newer OS firmware
//! opens its settings box on that chord.
//! Free camera returns to attract after `free_timeout_frames` updates with
//! no input, but not while frozen. In attract (unfrozen) the height eases
//! back to the default by 0.05 per frame.
//!
//! Frozen (M4, SPEC.md section 5b): the update that freezes draws the
//! real-time frame and then starts the path tracer on it (`pt.begin`);
//! later frozen updates step and display the path tracer. While the stick
//! is held the path tracer is released and the real-time tracer draws the
//! moving (time-stopped) view; the first update without the stick restarts
//! accumulation there. Select while frozen restarts it on the next preset;
//! B keeps it. A unfreezes and Start unfreezes into attract, both releasing
//! the path tracer. Once the image has converged (`pt.done()`),
//! `frozen_resume_s` seconds without input act as Start.
//!
//! "Restart" is always `pt.release()`: a frozen update without the stick
//! whose path tracer is not active begins a new accumulation.
//!
//! Heights are kept in integer millimetres so the 0.05 steps never drift:
//! 1600 mm converts to exactly `camera.default_height` (1.6 as f32), which
//! the tracer's identity path compares against.
const std = @import("std");
const input = @import("input.zig");
const dither = @import("dither.zig");
const variant = @import("variant.zig");
const build_options = @import("build_options");

const scene = @import("scene.zig");
const camera = @import("camera.zig");
const trace = @import("trace.zig");
const pt = @import("pt.zig");
const music = @import("music.zig");

pub const State = enum(u32) { attract = 0, free = 1 };

const fps: u32 = variant.fps;
const orbit_frames: u32 = camera.orbit_frames;
const preset_count: u32 = @typeInfo(scene.Preset).@"enum".field_names.len;

/// Knobs.
pub const free_timeout_frames: u32 = 20 * fps;
/// Fade out over the last 0.5 s before an attract preset switch, in over the
/// first 0.5 s after it.
pub const fade_frames: u32 = fps / 2;
/// Free-camera orbit speed: 3 orbit frames per update (36 deg/s at 20 fps).
pub const orbit_step: u32 = 3;
pub const height_step_mm: i32 = 50;
/// M4 auto-resume (SPEC.md section 17 question 8): a converged frozen image
/// returns to attract after this long without input.
pub const frozen_resume_s: u32 = 60;
pub const frozen_resume_frames: u32 = frozen_resume_s * fps;

fn to_mm(comptime h: f32) i32 {
    return @intFromFloat(@round(h * 1000.0));
}
pub const default_height_mm: i32 = to_mm(camera.default_height);
pub const min_height_mm: i32 = to_mm(camera.min_height);
pub const max_height_mm: i32 = to_mm(camera.max_height);

comptime {
    if (height_from_mm(default_height_mm) != camera.default_height)
        @compileError("default_height is not a whole number of mm");
    if (@mod(default_height_mm - min_height_mm, height_step_mm) != 0 or
        @mod(max_height_mm - default_height_mm, height_step_mm) != 0)
        @compileError("height range is not a whole number of steps from the default");
    if (fade_frames == 0 or 2 * fade_frames >= orbit_frames) @compileError("bad fade_frames");
}

fn height_from_mm(mm: i32) f32 {
    return @as(f32, @floatFromInt(mm)) / 1000.0;
}

/// Bench-only build option (Track A's build.zig, PLAN.md M3 "Budget and
/// bench" row 3): `-Dreflections_bench=height` sweeps the attract height
/// 1.0 -> 3.0 -> 1.0 continuously so the tracer rebuilds its height tables
/// every frame. Absent option (or any other value): normal attract.
const bench_height: bool = blk: {
    if (!@hasDecl(build_options, "reflections_bench")) break :blk false;
    const v = build_options.reflections_bench;
    break :blk switch (@typeInfo(@TypeOf(v))) {
        .@"enum" => std.mem.eql(u8, @tagName(v), "height"),
        .pointer, .array => std.mem.eql(u8, v, "height"),
        else => false,
    };
};

pub var state: State = .attract;
pub var frozen: bool = false;
pub var preset: scene.Preset = .sunset;
/// Scene time in frames; stops while frozen.
pub var t: u32 = 0;
/// Camera angle, [0, orbit_frames).
pub var orbit: u32 = 0;
pub var height_mm: i32 = default_height_mm;
/// Unfrozen attract frames since the last preset switch, [0, orbit_frames).
var cycle: u32 = 0;
/// The first fade_frames of cycle ramp up from black (after an attract
/// switch only; boot, Select and debug_set_view start at full).
var fading_in: bool = false;
/// Updates in free camera without input.
var idle: u32 = 0;
/// Height sweep direction for bench_height.
var bench_dir: i32 = 1;
/// Updates without input since the frozen image converged (auto-resume).
var frozen_idle: u32 = 0;
/// The stick was held this update (a frozen view then draws in real time).
var stick_held: bool = false;
/// debug_set_pt: false keeps the M3 behaviour (a frozen view shows the
/// real-time frame and the path tracer never begins).
pub var pt_enabled: bool = true;

/// What main.zig draws this update.
pub const FrameKind = enum(u32) {
    /// The real-time tracer (the path tracer released first).
    realtime = 0,
    /// The real-time frame, then pt.begin on it: a new accumulation.
    pt_begin = 1,
    /// pt.step, pt.display.
    pt_step = 2,
};

/// 0 attract, 1 free, 2 frozen (either), as debug_state reports it.
pub fn state_code() u32 {
    return if (frozen) 2 else @backingInt(state);
}

pub fn view() trace.View {
    return .{
        .preset = preset,
        .t = t,
        .orbit = orbit,
        .height = height_from_mm(height_mm),
        .fade = fade(),
    };
}

fn running_attract() bool {
    return state == .attract and !frozen;
}

fn fade() f32 {
    if (!running_attract()) return 1.0;
    const f: f32 = @floatFromInt(fade_frames);
    if (fading_in) return @as(f32, @floatFromInt(cycle)) / f;
    if (cycle + fade_frames >= orbit_frames) return @as(f32, @floatFromInt(orbit_frames - cycle)) / f;
    return 1.0;
}

/// Called when the attract cycle pauses (free camera or freeze), so that it
/// resumes at full brightness rather than mid-fade: a fade-in is dropped, a
/// fade-out restarts from its first (full) frame.
fn pause_cycle() void {
    if (!running_attract()) return;
    fading_in = false;
    if (cycle + fade_frames >= orbit_frames) cycle = orbit_frames - fade_frames;
}

/// After handle_input(): what to draw for view().
pub fn frame_kind() FrameKind {
    if (!frozen or !pt_enabled or stick_held) return .realtime;
    return if (pt.active()) .pt_step else .pt_begin;
}

/// Start: back to attract, unfrozen.
fn go_attract() void {
    pt.release();
    state = .attract;
    frozen = false;
}

fn next_preset() void {
    preset = @fromBackingInt(@intCast((@backingInt(preset) + 1) % preset_count));
}

/// Updates the "MUSIC ON/OFF" note stays up after a toggle (main.zig).
pub const toast_length: u32 = fps * 3 / 2;
pub var toast_frames: u32 = 0;

/// Buttons for this update (input.update already called).
pub fn handle_input() void {
    var any = false;
    const chord = input.held(.start) and input.held(.select);

    if (input.pressed(.start) and !chord) {
        any = true;
        if (variant.music and state == .attract and !frozen) {
            music.toggle();
            toast_frames = toast_length;
        } else go_attract();
    }
    if (input.pressed(.a)) {
        any = true;
        if (!frozen) pause_cycle();
        // Freezing: pt is not active, so this update begins. Unfreezing:
        // time resumes where it stopped.
        pt.release();
        frozen = !frozen;
    }
    if (input.pressed(.b)) {
        any = true;
        // Accumulation kept: display() quantises in the new mode.
        dither.next_mode();
    }
    if (input.pressed(.select) and !chord) {
        any = true;
        next_preset();
        cycle = 0;
        fading_in = false;
        // Frozen: restart accumulation on the new preset.
        pt.release();
    }

    const left = input.held(.left);
    const right = input.held(.right);
    const up = input.held(.up);
    const down = input.held(.down);
    stick_held = left or right or up or down;
    if (stick_held) {
        any = true;
        if (state == .attract) {
            pause_cycle();
            state = .free;
        }
        if (left) orbit = (orbit + orbit_frames - orbit_step) % orbit_frames;
        if (right) orbit = (orbit + orbit_step) % orbit_frames;
        if (up) height_mm = @min(height_mm + height_step_mm, max_height_mm);
        if (down) height_mm = @max(height_mm - height_step_mm, min_height_mm);
    }

    if (any) {
        idle = 0;
        frozen_idle = 0;
    } else if (state == .free and !frozen) {
        idle += 1;
        if (idle >= free_timeout_frames) {
            state = .attract;
            idle = 0;
        }
    } else if (frozen and pt_enabled and pt.active() and pt.done()) {
        frozen_idle += 1;
        if (frozen_idle >= frozen_resume_frames) {
            frozen_idle = 0;
            go_attract();
        }
    }
}

/// debug_pt_restart: the next frozen update begins a new accumulation.
pub fn restart_pt() void {
    pt.release();
}

/// debug_set_pt.
pub fn set_pt(on: bool) void {
    pt_enabled = on;
    if (!on) pt.release();
}

/// End of the update: move time on.
pub fn advance() void {
    if (frozen) return;
    t +%= 1;
    if (state != .attract) return;

    orbit = (orbit + 1) % orbit_frames;
    if (bench_height) {
        if (height_mm + bench_dir * height_step_mm > max_height_mm or
            height_mm + bench_dir * height_step_mm < min_height_mm) bench_dir = -bench_dir;
        height_mm += bench_dir * height_step_mm;
    } else if (height_mm > default_height_mm) {
        height_mm = @max(height_mm - height_step_mm, default_height_mm);
    } else if (height_mm < default_height_mm) {
        height_mm = @min(height_mm + height_step_mm, default_height_mm);
    }

    cycle += 1;
    if (fading_in and cycle >= fade_frames) fading_in = false;
    if (cycle >= orbit_frames) {
        next_preset();
        cycle = 0;
        fading_in = true;
    }
}

/// debug_set_view: freeze and set the view (check_render). Out-of-range
/// values are wrapped (preset, orbit) or clamped (height).
pub fn set_view(preset_index: u32, t_frames: u32, orbit_index: u32, h_mm: i32) void {
    pause_cycle();
    frozen = true;
    // With the path tracer on, the next update starts accumulating here.
    pt.release();
    frozen_idle = 0;
    preset = @fromBackingInt(@intCast(preset_index % preset_count));
    t = t_frames;
    orbit = orbit_index % orbit_frames;
    height_mm = std.math.clamp(h_mm, min_height_mm, max_height_mm);
}
