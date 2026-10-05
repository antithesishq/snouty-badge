//! Snouty Flyover (Memory Lane): a voxel heightfield flight through data
//! structures. SPEC.md is the design, PLAN.md the milestone contract.
const cart = @import("cart-api");
const build_options = @import("build_options");
const input = @import("input.zig");
const fixed = @import("fixed.zig");
const world = @import("world.zig");
const palette = @import("palette.zig");
const camera = @import("camera.zig");
const render = @import("render.zig");
const text = @import("text.zig");
const model = @import("model.zig");
const sort = @import("districts/sort.zig");
const stack = @import("districts/stack.zig");
const pipeline = @import("districts/pipeline.zig");
const bus = @import("districts/bus.zig");

comptime {
    cart.export_start_code();
}

/// Frames since start(); one frame is one update() at the vsync lock.
var frame: u32 = 0;
/// Microseconds spent in the last frame's world + render (hardware timer; 0 on wasm).
var render_us: u32 = 0;

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / @as(comptime_float, build_options.flyover_fps));
    cart.set_double_buffer_mode(.no_copy_full_frame);
    render.init();
    model.init();
    world.advance_to(camera.cam_row());
    camera.init();
    text.show_card3("MEMORY LANE", "generated on badge", text.fps_line);
}

pub fn update() void {
    input.update(read_controls());
    if (skipping == 0 and input.pressed(.select)) start_skip();
    if (skipping > 0) {
        skip_frame();
    } else {
        fly();
    }
    if (build_options.debug_overlay) draw_overlay();

    frame +%= 1;
    if (cart.is_wasm) present_wasm();
}

/// One normal frame: pilot, flight, world, render, sprite, text.
fn fly() void {
    const stick = camera.pilot(frame);
    camera.update(stick, frame);

    const t0 = cart.micros_since_boot();
    const cam_row = camera.cam_row();
    world.advance_to(cam_row);
    world.tick(frame, cam_row, stick.verb);
    if (world.entered_segment()) |seg| show_segment_card(seg);
    text.set_caption(world.caption());
    if (stick.verb != .none) text.flash_caption();
    palette.begin_frame(frame);
    render.draw(frame);
    model.draw();
    text.draw(frame);
    render_us = @truncate(cart.micros_since_boot() - t0);
}

// --- Select skip (PLAN.md M3 "Skip") -----------------------------------------

/// Transition frames (black with the card) and the ring rows generated per
/// frame: a pair is 256 rows and the window 256, so three frames refill it.
const skip_frames: u8 = 3;
const skip_rows: u32 = 96;

/// Skip frames left; the last one repeats until the ring is complete.
var skipping: u8 = 0;
/// Skips since start() (debug_skips).
var skips: u32 = 0;

/// Select (edge): jump to the next Bus, keeping x and altitude (and the
/// autopilot flag), show its card, and spread the ring refill over the
/// transition frames. noinline (with skip_frame): inlined into update() the
/// two ring-generation paths grew the cart's _start by about 11 KB of .text.
noinline fn start_skip() void {
    const target = world.next_bus_row(camera.cam_row());
    camera.jump_to(target);
    world.skip_reset(target);
    // A short jump keeps the old district's last rows (target - keep_behind
    // .. target) in the ring, with its dynamic edits: put them back.
    var y = target - world.keep_behind;
    while (y < target) : (y += 1) world.regen_row(y);
    skipping = skip_frames;
    skips += 1;
    show_segment_card(world.segment_at(target));
    text.set_caption("");
}

/// A transition frame: generate up to skip_rows rows toward the new window
/// and draw black with the card; no flight, no district tick, no march.
noinline fn skip_frame() void {
    const t0 = cart.micros_since_boot();
    const done = world.advance_partial(camera.cam_row(), skip_rows);
    if (skipping > 1 or done) skipping -= 1;
    const black: cart.Pixel = .from_color(.{ .r = 0, .g = 0, .b = 0 });
    for (cart.framebuffer) |*column| @memset(column, black);
    text.draw(frame);
    render_us = @truncate(cart.micros_since_boot() - t0);
}

/// Title card for a segment the camera enters (or skips to); a Bus card's
/// third line names the district after it.
fn show_segment_card(seg: world.Segment) void {
    const d = world.info(seg.kind);
    if (seg.kind != .bus) return text.show_card(d.title, d.gloss);
    const next = world.info(world.segment_at(seg.y0 + world.bus_len).kind).title;
    const n = @min(next.len, next_buf.len - next_prefix.len);
    @memcpy(next_buf[0..next_prefix.len], next_prefix);
    @memcpy(next_buf[next_prefix.len..][0..n], next[0..n]);
    text.show_card3(d.title, d.gloss, next_buf[0 .. next_prefix.len + n]);
}

/// The Bus card's third line; the card keeps a slice of it until the next card.
const next_prefix = "next: ";
var next_buf: [next_prefix.len + 16]u8 = undefined;

/// -Ddebug_overlay=true: "uuuuuus fffps" top-right, plus the camera cell row.
fn draw_overlay() void {
    var buf: [21]u8 = "      us    fps      ".*;
    put_uint(buf[0..6], @min(render_us, 999_999));
    const fps: u32 = if (render_us == 0) 999 else @min(1_000_000 / render_us, 999);
    put_uint(buf[9..12], fps);
    put_uint(buf[15..21], @intCast(@max(camera.cam_row(), 0)));
    cart.text(.{
        .str = &buf,
        .x = 160 - 8 * @as(i32, buf.len),
        .y = 0,
        .text_color = .{ .r = 31, .g = 63, .b = 31 },
        .background_color = .{ .r = 0, .g = 0, .b = 0 },
    });
}

/// Right-aligned decimal into `out`, space-padded. `v` must fit.
fn put_uint(out: []u8, v: u32) void {
    var n = v;
    var i = out.len;
    while (i > 0) {
        i -= 1;
        out[i] = @intCast('0' + n % 10);
        n /= 10;
        if (n == 0) break;
    }
}

// Debug exports for the headless harness (wasm only).
comptime {
    if (cart.is_wasm) {
        @export(&debug_frame, .{ .name = "debug_frame" });
        @export(&debug_render_us, .{ .name = "debug_render_us" });
        @export(&debug_pixel_checksum, .{ .name = "debug_pixel_checksum" });
        @export(&debug_cam_y, .{ .name = "debug_cam_y" });
        @export(&debug_cam_x, .{ .name = "debug_cam_x" });
        @export(&debug_cam_alt, .{ .name = "debug_cam_alt" });
        @export(&debug_cam_yaw, .{ .name = "debug_cam_yaw" });
        @export(&debug_cam_roll, .{ .name = "debug_cam_roll" });
        @export(&debug_horizon, .{ .name = "debug_horizon" });
        @export(&debug_world_check, .{ .name = "debug_world_check" });
        @export(&debug_map_height, .{ .name = "debug_map_height" });
        @export(&debug_map_colour, .{ .name = "debug_map_colour" });
        @export(&debug_segment_kind, .{ .name = "debug_segment_kind" });
        @export(&debug_segment_index, .{ .name = "debug_segment_index" });
        @export(&debug_live_kind, .{ .name = "debug_live_kind" });
        @export(&debug_autopilot, .{ .name = "debug_autopilot" });
        @export(&debug_cam_ground, .{ .name = "debug_cam_ground" });
        @export(&debug_cam_clear, .{ .name = "debug_cam_clear" });
        @export(&debug_sort_max_bars, .{ .name = "debug_sort_max_bars" });
        @export(&debug_sort_state, .{ .name = "debug_sort_state" });
        @export(&debug_water_cols, .{ .name = "debug_water_cols" });
        @export(&debug_stack_depth, .{ .name = "debug_stack_depth" });
        @export(&debug_pipe_state, .{ .name = "debug_pipe_state" });
        @export(&debug_verb_max_cells, .{ .name = "debug_verb_max_cells" });
        @export(&debug_b_last, .{ .name = "debug_b_last" });
        @export(&debug_sky_flash, .{ .name = "debug_sky_flash" });
        @export(&debug_skips, .{ .name = "debug_skips" });
        @export(&debug_bus_packets, .{ .name = "debug_bus_packets" });
    }
}

/// Segment under the camera: kind (0 bus, 1 heap, 2 sort, ...) and index.
fn debug_segment_kind() callconv(.c) u32 {
    return @backingInt(world.segment_at(camera.cam_row()).kind);
}
fn debug_segment_index() callconv(.c) u32 {
    return world.segment_at(camera.cam_row()).index;
}
fn debug_live_kind() callconv(.c) u32 {
    return @backingInt(world.live().kind);
}
fn debug_autopilot() callconv(.c) u32 {
    return @intFromBool(camera.autopilot);
}
/// Terrain height under the camera; a script asserts debug_cam_alt > this.
fn debug_cam_ground() callconv(.c) u32 {
    return camera.ground_under();
}
/// Camera altitude minus the terrain under it, cells (negative = inside it).
fn debug_cam_clear() callconv(.c) u32 {
    return @bitCast((camera.cam.alt >> fixed.Q) - @as(i32, camera.ground_under()));
}
/// Live Sort: running band (255 none) + 256 * sorted bands + 65536 if fast (after B).
fn debug_sort_state() callconv(.c) u32 {
    return sort.debug_state();
}
/// Most Sort bars (7 rows x 4 cells each) rewritten in one frame since boot:
/// the tick alone in the low 16 bits, with a shuffle (B) in the high 16.
fn debug_sort_max_bars() callconv(.c) u32 {
    return sort.max_tick_bars | sort.max_frame_bars << 16;
}

/// Columns that ran the reflection pass (render.zig pass 2) last frame.
fn debug_water_cols() callconv(.c) u32 {
    return render.water_cols;
}
/// Pushes made in the live STACK this visit (the frames pushed on top of
/// the static canyon), 0 when the live district is not the Stack.
fn debug_stack_depth() callconv(.c) u32 {
    return if (world.live().kind == .stack) stack.push_count() else 0;
}
/// Live PIPELINE burst: phase (0 idle, 1 sink, 2 hold, 3 restore) + 256 *
/// frames into the phase; 0 when the live district is not the Pipeline.
fn debug_pipe_state() callconv(.c) u32 {
    return if (world.live().kind == .pipeline) pipeline.debug_state() else 0;
}
/// Most cells (height + colour pairs) one frame of a verb wrote since boot:
/// STACK push waves in the low 16 bits, PIPELINE bursts in the high 16.
fn debug_verb_max_cells() callconv(.c) u32 {
    return @min(stack.max_frame_cells, 0xFFFF) | @as(u32, @min(pipeline.max_frame_cells, 0xFFFF)) << 16;
}
/// The player's last B press: presses so far << 16 | district kind << 8 |
/// 1 when the district took it (world.count).
fn debug_b_last() callconv(.c) u32 {
    return world.b_last;
}
/// Frames of white sky left (render.sky_flash, set by a STACK overflow).
fn debug_sky_flash() callconv(.c) u32 {
    return render.sky_flash;
}

/// Select skips since start().
fn debug_skips() callconv(.c) u32 {
    return skips;
}

/// Bus packets launched since start() (B on a Bus, or the autopilot's).
fn debug_bus_packets() callconv(.c) u32 {
    return bus.sent();
}

fn debug_frame() callconv(.c) u32 {
    return frame;
}
fn debug_render_us() callconv(.c) u32 {
    return render_us;
}
fn debug_cam_y() callconv(.c) u32 {
    return @bitCast(camera.cam_row());
}
fn debug_cam_x() callconv(.c) u32 {
    return @bitCast(camera.cam.x >> fixed.Q);
}
fn debug_cam_alt() callconv(.c) u32 {
    return @bitCast(camera.cam.alt >> fixed.Q);
}
fn debug_cam_yaw() callconv(.c) u32 {
    return @bitCast(camera.cam.yaw);
}
/// Roll in rows of shear (rounded toward zero); negative = banked right.
fn debug_cam_roll() callconv(.c) u32 {
    return @bitCast(@divTrunc(camera.cam.roll, fixed.one));
}
fn debug_horizon() callconv(.c) u32 {
    return @bitCast(camera.cam.horizon);
}
/// Ring consistency around the camera (world.check): cells that differ from
/// gen_row outside the live district and the Bus under the camera, plus
/// 1000000 per row in the window that is not in the ring; 0 = consistent.
fn debug_world_check() callconv(.c) u32 {
    return world.check(camera.cam_row());
}
/// Ring cell at world (x, y), or 0xFFFF if row y is not in the ring.
fn debug_map_height(x: i32, y: i32) callconv(.c) u32 {
    if (!world.generated_row(y)) return 0xFFFF;
    return world.height[@intCast(y & (world.DEPTH - 1))][@intCast(x & (world.W - 1))];
}
fn debug_map_colour(x: i32, y: i32) callconv(.c) u32 {
    if (!world.generated_row(y)) return 0xFFFF;
    return world.colour[@intCast(y & (world.DEPTH - 1))][@intCast(x & (world.W - 1))];
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

/// Simulator shim (see snouty-bugs CLAUDE.md): upstream's wasm platform never
/// presents, and the web simulator reads a legacy framebuffer at 0x20 with
/// red and blue swapped relative to DisplayColor. Hardware compiles none of this.
fn present_wasm() void {
    const sim_framebuffer: *cart.Framebuffer = @ptrFromInt(0x20);
    for (cart.framebuffer, sim_framebuffer) |*src_column, *dst_column| {
        for (src_column, dst_column) |src, *dst| {
            const c = src.to_color();
            dst.* = .from_color(.{ .r = c.b, .g = c.g, .b = c.r });
        }
    }
}
