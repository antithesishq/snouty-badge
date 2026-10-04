//! Snouty on the Water: real-time ray-traced sunset lake (trace.zig). See
//! SPEC.md for the design, PLAN.md for the M1 contract, CLAUDE.md for the
//! toolchain.
const cart = @import("cart-api");
const input = @import("input.zig");
const dither = @import("dither.zig");
const overlay = @import("overlay.zig");
const app = @import("app.zig");
const variant = @import("variant.zig");
const build_options = @import("build_options");

const trace = @import("trace.zig");
const pt = @import("pt.zig");
const arena = @import("arena.zig");
const music = @import("music.zig");

comptime {
    cart.export_start_code();
}

/// Updates since start().
var frame: u32 = 0;
/// What the last update drew (debug_frame_kind).
var last_kind: app.FrameKind = .realtime;
/// Microseconds spent in the last render (hardware timer; 0 on wasm).
var render_us: u32 = 0;

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / @as(comptime_float, variant.fps));
    cart.set_double_buffer_mode(.no_copy_full_frame);
    dither.init();
    trace.init();
    // Off unless built with -Dsound=true (root docs/SOUND.md); Start in
    // attract toggles it.
    music.enabled = variant.music and build_options.sound;
    if (cart.is_wasm and variant.music) music.on_note = &sim_note;
}

pub fn update() void {
    // PLAN.md M4 "App": the path tracer's slice is measured from here.
    const t_update = cart.micros_since_boot();
    input.update(read_controls());
    app.handle_input();
    // After the toggle, and inside the path tracer's slice (t_update).
    if (variant.music) {
        if (cart.is_wasm) music.sim_update() else music.update();
    }

    const view = app.view();
    const kind = app.frame_kind();
    last_kind = kind;
    const t0 = cart.micros_since_boot();
    // Bayer parity from scene time, not the update count: a frame is a pure
    // function of (view, dither mode), so frozen and debug_set_view frames
    // repeat exactly and view t = f matches M2.2's frame f.
    dither.begin_frame(view.t);
    switch (kind) {
        .realtime, .pt_begin => {
            // The real-time tracer owns the arena again (no-op when pt is
            // not active).
            pt.release();
            trace.render_frame(view);
            dither.end_frame();
            if (kind == .pt_begin) pt.begin(view);
        },
        .pt_step => {
            pt.step(t_update + pt.slice_us);
            pt.display();
            dither.end_frame();
        },
    }
    render_us = @truncate(cart.micros_since_boot() - t0);
    if (build_options.debug_overlay) overlay.draw(render_us);
    if (app.toast_frames > 0) {
        app.toast_frames -= 1;
        draw_toast();
    }

    app.advance();
    frame +%= 1;
    if (cart.is_wasm) present_wasm();
}

/// "MUSIC ON" / "MUSIC OFF" after a Start in attract, bottom left in the
/// OS font (the only text this cart draws outside the debug overlay).
fn draw_toast() void {
    cart.text(.{
        .str = if (music.enabled) "MUSIC ON" else "MUSIC OFF",
        .x = 2,
        .y = 118,
        .text_color = .{ .r = 31, .g = 63, .b = 31 },
        .background_color = .{ .r = 0, .g = 0, .b = 0 },
    });
}

/// The simulator has no streaming audio: the lead, its echo and the bass
/// go to the WASM-4 APU's two pulse channels and its triangle (`tone`
/// directly: attack/decay/sustain/release frames packed in the duration
/// word, volumes sustain | peak << 8, flags channel | duty << 2). The
/// chords have no channel left and stay silent there.
fn sim_note(n: music.Note) void {
    if (!cart.is_wasm) return;
    const channel: u32 = switch (n.voice) {
        0 => 0,
        1 => 1,
        else => if (n.bass == 1) 2 else return,
    };
    const frames: u32 = @as(u32, n.dur) * music.step_samples * 60 / music.rate;
    const base: u32 = switch (channel) {
        0 => 30,
        1 => 12,
        else => 40,
    };
    const peak = base * (5 + @as(u32, n.vel)) / 8;
    const attack: u32 = 1;
    const decay: u32 = 6;
    const release: u32 = 12;
    const sustain: u32 = @min(frames -| (attack + decay), 255);
    struct {
        extern fn tone(frequency: u32, duration: u32, volume: u32, flags: u32) void;
    }.tone(music.hz_of(n.pitch), attack << 24 | decay << 16 | release << 8 | sustain, peak * 2 / 3 | peak << 8, channel | 1 << 2);
}

// Debug exports for the headless harness (wasm only).
comptime {
    if (cart.is_wasm) {
        @export(&debug_frame, .{ .name = "debug_frame" });
        @export(&debug_render_us, .{ .name = "debug_render_us" });
        @export(&debug_pixel_checksum, .{ .name = "debug_pixel_checksum" });
        @export(&debug_dither_mode, .{ .name = "debug_dither_mode" });
        @export(&debug_set_dither_mode, .{ .name = "debug_set_dither_mode" });
        @export(&debug_set_view, .{ .name = "debug_set_view" });
        @export(&debug_preset, .{ .name = "debug_preset" });
        @export(&debug_state, .{ .name = "debug_state" });
        @export(&debug_t, .{ .name = "debug_t" });
        @export(&debug_orbit, .{ .name = "debug_orbit" });
        @export(&debug_height_mm, .{ .name = "debug_height_mm" });
        @export(&debug_set_pt, .{ .name = "debug_set_pt" });
        @export(&debug_pt_run, .{ .name = "debug_pt_run" });
        @export(&debug_pt_passes, .{ .name = "debug_pt_passes" });
        @export(&debug_pt_accum, .{ .name = "debug_pt_accum" });
        @export(&debug_pt_restart, .{ .name = "debug_pt_restart" });
        @export(&debug_frame_kind, .{ .name = "debug_frame_kind" });
    }
}

fn debug_frame() callconv(.c) u32 {
    return frame;
}
fn debug_render_us() callconv(.c) u32 {
    return render_us;
}
fn debug_dither_mode() callconv(.c) u32 {
    return @backingInt(dither.mode);
}
/// Set the dither mode (dither.Mode values; out of range is ignored).
fn debug_set_dither_mode(mode: u32) callconv(.c) void {
    if (mode < @typeInfo(dither.Mode).@"enum".field_names.len) dither.set_mode(@fromBackingInt(@intCast(mode)));
}
/// Freeze and set the view: preset index, scene time in frames, orbit index,
/// eye height in mm (PLAN.md M3; for check_render). Takes effect on the next
/// update().
fn debug_set_view(preset: u32, t: u32, orbit: u32, height_mm: i32) callconv(.c) void {
    app.set_view(preset, t, orbit, height_mm);
}
fn debug_preset() callconv(.c) u32 {
    return @backingInt(app.preset);
}
/// 0 attract, 1 free camera, 2 frozen.
fn debug_state() callconv(.c) u32 {
    return app.state_code();
}
fn debug_t() callconv(.c) u32 {
    return app.t;
}
fn debug_orbit() callconv(.c) u32 {
    return app.orbit;
}
fn debug_height_mm() callconv(.c) i32 {
    return app.height_mm;
}
/// 0: M3 behaviour (a frozen view shows the real-time frame, the path
/// tracer never begins); anything else (the default): the path tracer runs
/// while frozen. Takes effect on the next update().
fn debug_set_pt(on: u32) callconv(.c) void {
    app.set_pt(on != 0);
}
/// Run n whole passes of the path tracer now. When the view is frozen with
/// the path tracer on but it has not begun (right after debug_set_view or
/// debug_pt_restart), the real-time frame is drawn and pt.begin runs first,
/// as the next update() would. Then the frame is displayed (and copied for
/// the simulator), so the framebuffer shows exactly those passes. Does
/// nothing unless frozen with the path tracer on.
fn debug_pt_run(n: u32) callconv(.c) void {
    if (!app.frozen or !app.pt_enabled) return;
    const view = app.view();
    dither.begin_frame(view.t);
    if (!pt.active()) {
        trace.render_frame(view);
        dither.end_frame();
        pt.begin(view);
    }
    pt.run_passes(n);
    pt.display();
    dither.end_frame();
    present_wasm();
}
/// Completed passes (0 when the path tracer is not active).
fn debug_pt_passes() callconv(.c) u32 {
    return if (pt.active()) pt.passes() else 0;
}
/// Byte address of arena.words (the accumulator) in wasm memory.
fn debug_pt_accum() callconv(.c) u32 {
    return @intCast(@intFromPtr(&arena.words));
}
/// Drop the accumulation: the next frozen update() begins a new one.
fn debug_pt_restart() callconv(.c) void {
    app.restart_pt();
}
/// What the last update drew: 0 the real-time frame, 1 the real-time frame
/// and then pt.begin (a new accumulation), 2 a path-tracer step.
fn debug_frame_kind() callconv(.c) u32 {
    return @backingInt(last_kind);
}
/// Sum of all framebuffer words, for render regression tests.
fn debug_pixel_checksum() callconv(.c) u32 {
    var sum: u32 = 0;
    for (cart.framebuffer) |*column| {
        for (column) |px| sum +%= @as(u16, @bitCast(px));
    }
    return sum;
}

/// Button state. Upstream's platform_wasm.zig exposes `controls` but never
/// fills it from the simulator, which writes its button word (same bit
/// layout as cart.Controls) to linear address 0x04; read that directly on
/// wasm. Hardware gets the OS-maintained cart.controls.
pub fn read_controls() cart.Controls {
    if (cart.is_wasm) return @bitCast(@as(*const volatile u16, @ptrFromInt(0x04)).*);
    return cart.controls.*;
}

/// Simulator shim, copied from snouty-bugs (see its CLAUDE.md for the full
/// story): upstream's wasm platform never presents, and the web simulator
/// reads a legacy framebuffer at 0x20 with red and blue swapped relative to
/// DisplayColor. Hardware builds compile none of this.
const sim_swap_rb = true;

fn present_wasm() void {
    const sim_framebuffer: *cart.Framebuffer = @ptrFromInt(0x20);
    if (sim_swap_rb) {
        for (cart.framebuffer, sim_framebuffer) |*src_column, *dst_column| {
            for (src_column, dst_column) |src, *dst| {
                const c = src.to_color();
                dst.* = .from_color(.{ .r = c.b, .g = c.g, .b = c.r });
            }
        }
    } else {
        sim_framebuffer.* = cart.framebuffer.*;
    }
}
