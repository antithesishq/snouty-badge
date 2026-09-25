//! Snouty running badge (v4: jumps on A). See PLAN.md for layout and motion.
const cart = @import("cart-api");
const gfx = @import("gfx");

comptime {
    cart.export_start_code();
}

// Panel colors from the Antithesis brand guide.
const anti_black = cart.DisplayColor.rgb(0x16031B);
const anti_white = cart.DisplayColor.rgb(0xFCFBF9);
const coral = cart.DisplayColor.rgb(0xF18271);

// Screen layout (PLAN.md "Screen layout").
const ground_y = 96;
const ground_height = gfx.ghz_ground.height; // 12
const panel_y = ground_y + ground_height; // 108
const panel_height = cart.screen_height - panel_y; // 20
const name_y = 110;
const company_y = 119;
const name = "Adrian Hatch";
const company = "Antithesis";

// Iris marks at both ends of the panel (PLAN.md v2). The text is centered in
// the 112 px between them.
const iris_y = 110;
const iris_left_x = 8;
const iris_size = gfx.iris_spin.height; // 16, square cells
const iris_right_x = cart.screen_width - iris_left_x - iris_size; // 136

// Iris coin spin: the strip holds one full 360-degree turn in 24 frames
// (front face white, back face grey, widths follow |cos|). Both marks spin in
// step at the run cycle's pace, then rest on the front face.
const iris_spin_frames = gfx.iris_spin.width / iris_size; // 24
const iris_ticks_per_frame = ticks_per_frame; // 4: same pacing as the run
const iris_spin_ticks = iris_spin_frames * iris_ticks_per_frame; // 96 = 1.6 s
const iris_pause_ticks = 120; // 2 s on the front face
const iris_cycle_ticks = iris_spin_ticks + iris_pause_ticks;

// Animated Green Hill Zone backdrop behind Snouty (y 0..95, full width). The
// four images are palette-cycle frames of the same picture; the original game
// advances its waterfall cycle every 6 ticks (100 ms at 60 Hz).
const bg_height = ground_y; // 96
const bg_ticks_per_frame = 6;

// Run cycle strip: 16 cells of 96x96 side by side. The cell's origin is
// (48, 88): x centered, y on the ground baseline. Putting the baseline on the
// top row of the ground strip gives a cell top of ground_y - 88 = 8.
const cell_size = 96;
const cell_baseline = 88;
const cell_y = ground_y - cell_baseline;
const strip_width = gfx.snouty_run.width;
comptime {
    if (strip_width != cell_size * frame_count) @compileError("unexpected run strip width");
    if (gfx.snouty_run.height != cell_size) @compileError("unexpected run strip height");
    if (gfx.snouty_jump.width != cell_size * jump_frame_count) @compileError("unexpected jump strip width");
    if (gfx.snouty_jump.height != cell_size) @compileError("unexpected jump strip height");
}

// Lowest opaque row of each cell (printed by tools/prepare_assets.py). A
// cell drawn with its top at ground_y - feet_row has its feet on screen row
// ground_y, the first grass row. The run cycle keeps its fixed cell_y (the
// baseline 88 is the max of run_feet_rows, so its up-and-down bob is part of
// the art); jump frames are placed per frame from jump_feet_rows.
const run_feet_rows = [frame_count]u8{ 88, 88, 88, 88, 88, 88, 85, 87, 88, 88, 88, 88, 88, 88, 85, 87 };
const jump_feet_rows = [jump_frame_count]u8{ 93, 93, 93, 93, 93, 87, 72, 77, 85, 88, 88, 88 };
comptime {
    var max_feet: u8 = 0;
    for (run_feet_rows) |r| max_feet = @max(max_feet, r);
    if (max_feet != cell_baseline) @compileError("run_feet_rows disagree with cell_baseline");
}

// Jump (PLAN.md v4). The feet follow arc(t) = 4*h*t*(T-t)/T^2 for t in
// [0, T] ticks airborne; the pose is chosen from the phase t/T, then two
// grounded poses (landing, recovery) before the run cycle resumes at frame 0.
const jump_frame_count = 12;
const jump_height_px = 40;
const jump_air_ticks = 40;
const land_ticks = 6;
const recover_ticks = 6;
const land_frame = 10;
const recover_frame = 11;

const Phase = struct { end_tick: u32, frame: u8 };
/// Airborne poses: the pose `frame` is shown for t < end_tick. End ticks are
/// fractions (percent) of jump_air_ticks so the table survives retiming.
const air_phases = blk: {
    const table = [_]struct { end_pct: u32, frame: u8 }{
        .{ .end_pct = 10, .frame = 4 }, // takeoff
        .{ .end_pct = 35, .frame = 5 }, // fast rise
        .{ .end_pct = 55, .frame = 6 }, // apex hang
        .{ .end_pct = 70, .frame = 7 }, // late apex
        .{ .end_pct = 88, .frame = 8 }, // descent
        .{ .end_pct = 100, .frame = 9 }, // pre-landing reach
    };
    var phases: [table.len]Phase = undefined;
    for (table, &phases) |e, *ph| ph.* = .{ .end_tick = jump_air_ticks * e.end_pct / 100, .frame = e.frame };
    if (phases[phases.len - 1].end_tick != jump_air_ticks) @compileError("last phase must end at jump_air_ticks");
    break :blk phases;
};

fn air_frame(t: u32) u8 {
    for (air_phases) |ph| {
        if (t < ph.end_tick) return ph.frame;
    }
    return air_phases[air_phases.len - 1].frame;
}

/// Height of the feet above the ground after t airborne ticks, t in [0, T].
fn arc(t: u32) u32 {
    const T: u32 = jump_air_ticks;
    return 4 * jump_height_px * t * (T - t) / (T * T);
}

// Motion. The planted toe travels 6 px per animation frame, so x must advance
// exactly step_px per frame or the feet slide. Speed is set by ticks_per_frame
// only: at 60 Hz, 4 ticks/frame = 15 fps = 90 px/s.
const ticks_per_frame = 4;
const step_px = 6;
const pause_ticks = 60;
const frame_count = 16;
const start_x = -cell_size; // -96: fully off-screen left
const end_x = cart.screen_width; // 160: fully off-screen right

const State = enum { running, airborne, landing, recovering, paused };

var state: State = .running;
/// Ticks within the current step (0..ticks_per_frame-1). Every non-paused
/// state advances x by step_px when it wraps, so speed is continuous.
var tick: u32 = 0;
/// Run cycle frame; only advances while running.
var frame: u32 = 0;
/// Ticks spent in the current airborne/landing/recovering/paused state.
var state_t: u32 = 0;
var snouty_x: i32 = start_x;
var prev_a: bool = false;
/// Ticks since boot. Unlike `tick` it never resets; drives the backdrop's
/// palette cycle. Wraps after ~2.3 years at 60 Hz (2^32 is not a multiple of
/// 24, so the cycle skips a step once on wrap, harmlessly).
var tick_total: u32 = 0;

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    // update() redraws every pixel (backdrop rows 0..95, ground 96..107,
    // panel 108..127), so neither a clear nor a copy-forward is needed.
    cart.set_double_buffer_mode(.no_copy_full_frame);
}

pub fn update() void {
    // Select the comptime sprite once per update; each arm is a separate
    // instantiation of draw_background with its own tight loop.
    switch ((tick_total / bg_ticks_per_frame) % 4) {
        0 => draw_background(gfx.ghz_bg_0),
        1 => draw_background(gfx.ghz_bg_1),
        2 => draw_background(gfx.ghz_bg_2),
        else => draw_background(gfx.ghz_bg_3),
    }
    draw_ground();
    draw_panel();
    const a = read_controls().a;
    if (a and !prev_a and state == .running) {
        state = .airborne;
        state_t = 0;
    }
    prev_a = a;
    draw_snouty();
    advance();
    if (cart.is_wasm) present_wasm();
}

/// Button state. Upstream's platform_wasm.zig exposes `controls` but never
/// fills it from the simulator, which writes its button word (same bit
/// layout as cart.Controls) to linear address 0x04; read that directly on
/// wasm. Hardware gets the OS-maintained cart.controls.
fn read_controls() cart.Controls {
    if (cart.is_wasm) return @bitCast(@as(*const volatile u16, @ptrFromInt(0x04)).*);
    return cart.controls.*;
}

fn draw_snouty() void {
    if (snouty_x >= end_x) return;
    switch (state) {
        .paused => {},
        .running => draw_cell(gfx.snouty_run, frame, snouty_x, cell_y),
        .airborne => draw_jump_frame(air_frame(state_t), arc(state_t)),
        .landing => draw_jump_frame(land_frame, 0),
        .recovering => draw_jump_frame(recover_frame, 0),
    }
}

/// Places a jump cell so its feet row sits `lift` px above ground_y (the
/// first grass row, where the run cycle's feet land at cell_y 8).
fn draw_jump_frame(index: u8, lift: u32) void {
    const pos_y = @as(i32, ground_y) - jump_feet_rows[index] - @as(i32, @intCast(lift));
    draw_cell(gfx.snouty_jump, index, snouty_x, pos_y);
}

fn advance() void {
    tick_total +%= 1;
    if (state == .paused) {
        state_t += 1;
        if (state_t == pause_ticks) {
            state = .running;
            snouty_x = start_x;
            frame = 0;
            tick = 0;
        }
        return;
    }

    if (state != .running) state_t += 1;
    switch (state) {
        .running, .paused => {},
        .airborne => if (state_t == jump_air_ticks) {
            state = .landing;
            state_t = 0;
        },
        .landing => if (state_t == land_ticks) {
            state = .recovering;
            state_t = 0;
        },
        // Back into the run cycle at frame 0. `tick` keeps counting so the
        // x steps stay evenly spaced; frame 0 is shown until the next step,
        // where frame and x advance together as always.
        .recovering => if (state_t == recover_ticks) {
            state = .running;
            frame = 0;
        },
    }

    tick += 1;
    if (tick < ticks_per_frame) return;
    tick = 0;
    if (state == .running) frame = (frame + 1) % frame_count;
    snouty_x += step_px;
    if (snouty_x >= end_x) {
        // Leaving the screen cancels any jump in progress.
        state = .paused;
        state_t = 0;
    }
}

/// Copies a full-width, bg_height-tall opaque sprite into rows 0..bg_height-1.
/// The palette is converted to Pixels at comptime, so the inner loop is an
/// index fetch plus a table lookup.
fn draw_background(comptime sprite: type) void {
    comptime {
        if (sprite.width != cart.screen_width or sprite.height != bg_height)
            @compileError("draw_background: sprite must be 160x96");
    }
    const palette = comptime blk: {
        var p: [sprite.colors.len]cart.Pixel = undefined;
        for (sprite.colors, &p) |c, *px| px.* = .from_color(c);
        break :blk p;
    };
    for (0..sprite.width) |x| {
        const column = &cart.framebuffer[x];
        for (0..sprite.height) |y| {
            column[y] = palette[sprite.indices.get(y * sprite.width + x)];
        }
    }
}

/// Tiles the ground image across the full width at y = ground_y.
fn draw_ground() void {
    const tile = gfx.ghz_ground;
    for (0..cart.screen_width) |x| {
        const tx = x % tile.width;
        for (0..tile.height) |ty| {
            const color = tile.colors[tile.indices.get(ty * tile.width + tx)];
            cart.framebuffer[x][ground_y + ty] = .from_color(color);
        }
    }
}

fn draw_panel() void {
    cart.rect(.{
        .x = 0,
        .y = panel_y,
        .width = cart.screen_width,
        .height = panel_height,
        .fill_color = anti_black,
    });
    const t = tick_total % iris_cycle_ticks;
    const iris_frame: u32 = if (t < iris_spin_ticks) t / iris_ticks_per_frame else 0;
    draw_cell(gfx.iris_spin, iris_frame, iris_left_x, iris_y);
    draw_cell(gfx.iris_spin, iris_frame, iris_right_x, iris_y);
    draw_centered_text(name, name_y, anti_white);
    draw_centered_text(company, company_y, coral);
}

fn draw_centered_text(comptime str: []const u8, y: i32, color: cart.DisplayColor) void {
    const x = (cart.screen_width - str.len * cart.font_width) / 2;
    cart.text(.{ .str = str, .x = x, .y = y, .text_color = color });
}

/// Draws cell `index` of a horizontal strip of square cells (side = height) with its
/// top-left at (pos_x, pos_y), skipping palette index 0 (transparent) and
/// clipping to the screen on all sides. The visible column and row ranges
/// are computed once per cell.
fn draw_cell(comptime sprite: type, index: u32, pos_x: i32, pos_y: i32) void {
    const cell: usize = sprite.height;
    const src_x: usize = index * cell;
    const col_begin: usize = @intCast(@max(0, -pos_x));
    const col_end: usize = @intCast(@max(0, @min(cell, @as(i32, cart.screen_width) - pos_x)));
    const row_begin: usize = @intCast(@max(0, -pos_y));
    const row_end: usize = @intCast(@max(0, @min(cell, @as(i32, cart.screen_height) - pos_y)));
    if (col_begin >= col_end or row_begin >= row_end) return;
    const dst_y0: usize = @intCast(pos_y + @as(i32, @intCast(row_begin)));
    var col = col_begin;
    while (col < col_end) : (col += 1) {
        const dst_x: usize = @intCast(pos_x + @as(i32, @intCast(col)));
        const column = cart.framebuffer[dst_x][dst_y0..];
        for (row_begin..row_end, 0..) |row, dy| {
            const idx = sprite.indices.get(row * sprite.width + src_x + col);
            if (idx == 0) continue;
            column[dy] = .from_color(sprite.colors[idx]);
        }
    }
}

/// Simulator shim. Upstream's platform_wasm.zig never presents (its
/// present_and_acquire is a TODO and update() is exported without calling
/// present()), so on wasm the framebuffer is never cleared, and the web
/// simulator reads a legacy framebuffer at linear address 0x20 (see
/// simulator/src/constants.ts ADDR_FRAMEBUFFER; add_os_cart reserves it via
/// global_base). Copy our frame there.
///
/// The simulator's compositor (compositor.ts) also un-swaps the bytes and
/// uploads the u16 as GL RGB565 with red in the high bits, but DisplayColor
/// keeps red in the low bits (the legacy badge-v1 API had blue there, which
/// is what the simulator was written for). Swap r and b in the copy so the
/// browser shows the colors the hardware will. Hardware builds do not compile
/// any of this.
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
    // No re-clear: like .no_copy_full_frame on hardware, the next update()
    // overwrites every pixel of cart.framebuffer before it is presented.
}
