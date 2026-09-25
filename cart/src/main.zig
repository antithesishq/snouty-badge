//! Snouty running badge (v1). See PLAN.md for layout and motion.
const cart = @import("cart-api");
const gfx = @import("gfx");

comptime {
    cart.export_start_code();
}

// Colors. Sky is a Green Hill Zone style blue; the panel colors come from the
// Antithesis brand guide.
const sky = cart.DisplayColor.rgb(0x2468F0);
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

var tick: u32 = 0;
var frame: u32 = 0;
var snouty_x: i32 = start_x;
var pause_left: u32 = 0;

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    cart.set_double_buffer_mode(.{ .clear_full_frame = sky });
    // clear_full_frame clears the *next* back buffer inside present(), so the
    // very first frame would otherwise start from uninitialised memory.
    for (cart.framebuffer) |*column| @memset(column, .from_color(sky));
}

pub fn update() void {
    draw_ground();
    draw_panel();
    if (snouty_x < end_x) draw_snouty(frame, snouty_x, cell_y);
    advance();
    if (cart.is_wasm) present_wasm();
}

fn advance() void {
    if (pause_left > 0) {
        pause_left -= 1;
        if (pause_left == 0) {
            snouty_x = start_x;
            frame = 0;
            tick = 0;
        }
        return;
    }
    tick += 1;
    if (tick < ticks_per_frame) return;
    tick = 0;
    frame = (frame + 1) % frame_count;
    snouty_x += step_px;
    if (snouty_x >= end_x) pause_left = pause_ticks;
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
    draw_centered_text(name, name_y, anti_white);
    draw_centered_text(company, company_y, coral);
}

fn draw_centered_text(comptime str: []const u8, y: i32, color: cart.DisplayColor) void {
    const x = (cart.screen_width - str.len * cart.font_width) / 2;
    cart.text(.{ .str = str, .x = x, .y = y, .text_color = color });
}

/// Draws cell `index` of the run strip with its top-left at (pos_x, pos_y),
/// skipping palette index 0 (transparent) and clipping to the screen
/// horizontally. The cell always fits vertically (rows 8..103).
fn draw_snouty(index: u32, pos_x: i32, pos_y: comptime_int) void {
    const sprite = gfx.snouty_run;
    const src_x: usize = index * cell_size;
    const col_begin: usize = @intCast(@max(0, -pos_x));
    const col_end: usize = @intCast(@min(cell_size, @as(i32, cart.screen_width) - pos_x));
    var col = col_begin;
    while (col < col_end) : (col += 1) {
        const dst_x: usize = @intCast(pos_x + @as(i32, @intCast(col)));
        const column = &cart.framebuffer[dst_x];
        for (0..cell_size) |row| {
            const idx = sprite.indices.get(row * strip_width + src_x + col);
            if (idx == 0) continue;
            column[pos_y + row] = .from_color(sprite.colors[idx]);
        }
    }
}

/// Simulator shim. Upstream's platform_wasm.zig never presents (its
/// present_and_acquire is a TODO and update() is exported without calling
/// present()), so on wasm the framebuffer is never cleared, and the web
/// simulator reads a legacy framebuffer at linear address 0x20 (see
/// simulator/src/constants.ts ADDR_FRAMEBUFFER; add_os_cart reserves it via
/// global_base). Copy our frame there and emulate clear_full_frame.
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
    for (cart.framebuffer) |*column| @memset(column, .from_color(sky));
}
