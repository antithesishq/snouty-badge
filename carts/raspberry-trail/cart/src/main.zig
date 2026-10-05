//! The Raspberry Trail for the SYCL badge: the cart shell.
//!
//! start() sets 60 fps and full-frame redraws; update() reads the buttons
//! (or lets the autoplayer press them), steps the UI (ui/app.zig, which
//! drives the game module through G.init / G.start / G.answer) and redraws
//! every pixel (ui/render.zig). SPEC.md section 4.
const std = @import("std");
const cart = @import("cart-api");
const app_mod = @import("ui/app.zig");
const autoplay = @import("ui/autoplay.zig");
const draw = @import("ui/draw.zig");
const render = @import("ui/render.zig");
const G = @import("game");

comptime {
    cart.export_start_code();
}

var app: app_mod.App = .{};
var bot: autoplay.Bot = .{};

/// badge-bench hooks (firmware only; 0 on the badge):
/// `--poke raspberry_trail_seed=N` seeds the games (game k gets N + k)
/// instead of the clock; `--poke raspberry_trail_autoplay=V` lets the
/// autoplayer play from the title, game after game (V: pace in bits 0..1,
/// 1 human, 2 fast; policy in bits 4..5, 0 normal, 1 careful, 2 starve,
/// 3 hunter; ui/autoplay.zig).
var bench_seed: u32 = 0;
var bench_autoplay: u32 = 0;
comptime {
    if (!cart.is_wasm) {
        @export(&bench_seed, .{ .name = "raspberry_trail_seed" });
        @export(&bench_autoplay, .{ .name = "raspberry_trail_autoplay" });
    }
}

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    // update() redraws every pixel.
    cart.set_double_buffer_mode(.no_copy_full_frame);
    draw.init();
    app.init(&next_seed);
    if (bench_autoplay != 0) bot.set(bench_autoplay, 0x5EED0000 + @as(u64, bench_seed));
}

/// A new game's seed, taken when A starts it (SPEC 3.4). Badge: the
/// microsecond clock at that press, mixed (cart.rand() reads 0 on the
/// RP2350). Wasm: cart.rand(), so preview.mjs --seed reproduces a run.
fn next_seed() u64 {
    if (bench_seed != 0) return @as(u64, bench_seed) + app.games_started;
    if (cart.is_wasm) return @as(u64, cart.rand()) | (@as(u64, cart.rand()) << 32);
    return clock_mix(cart.micros_since_boot());
}

fn clock_mix(t: u64) u64 {
    var h: u64 = t ^ 0x9e3779b97f4a7c15;
    h ^= h >> 33;
    h *%= 0xff51afd7ed558ccd;
    h ^= h >> 33;
    h *%= 0xc4ceb9fe1a85ec53;
    h ^= h >> 33;
    return if (h == 0) 1 else h;
}

pub fn update() void {
    const c = read_controls();
    var b: app_mod.Buttons = .{
        .start = c.start,
        .select = c.select,
        .a = c.a,
        .b = c.b,
        .up = c.up,
        .down = c.down,
        .left = c.left,
        .right = c.right,
    };
    if (bot.pace != .off) {
        const auto = bot.step(&app);
        b = @bitCast(@as(u8, @bitCast(b)) | @as(u8, @bitCast(auto)));
    }
    app.update(b);
    render.frame(&app);
    if (cart.is_wasm) present_wasm();
}

// -- headless harness exports (wasm only) --------------------------------

comptime {
    if (cart.is_wasm) {
        @export(&debug_frame, .{ .name = "debug_frame" });
        @export(&debug_screen, .{ .name = "debug_screen" });
        @export(&debug_phase, .{ .name = "debug_phase" });
        @export(&debug_prompt_kind, .{ .name = "debug_prompt_kind" });
        @export(&debug_prompt_line, .{ .name = "debug_prompt_line" });
        @export(&debug_turn, .{ .name = "debug_turn" });
        @export(&debug_mileage, .{ .name = "debug_mileage" });
        @export(&debug_mileage_true, .{ .name = "debug_mileage_true" });
        @export(&debug_food, .{ .name = "debug_food" });
        @export(&debug_cash, .{ .name = "debug_cash" });
        @export(&debug_cursor, .{ .name = "debug_cursor" });
        @export(&debug_value, .{ .name = "debug_value" });
        @export(&debug_answers, .{ .name = "debug_answers" });
        @export(&debug_shots, .{ .name = "debug_shots" });
        @export(&debug_shots_hit, .{ .name = "debug_shots_hit" });
        @export(&debug_shots_wrong, .{ .name = "debug_shots_wrong" });
        @export(&debug_misfires, .{ .name = "debug_misfires" });
        @export(&debug_games_started, .{ .name = "debug_games_started" });
        @export(&debug_games_over, .{ .name = "debug_games_over" });
        @export(&debug_outcome, .{ .name = "debug_outcome" });
        @export(&debug_arrivals, .{ .name = "debug_arrivals" });
        @export(&debug_deaths, .{ .name = "debug_deaths" });
        @export(&debug_log_rows, .{ .name = "debug_log_rows" });
        @export(&debug_autoplay, .{ .name = "debug_autoplay" });
        @export(&cart_framebuffer_address, .{ .name = "cart_framebuffer_address" });
    }
}

fn debug_frame() callconv(.c) u32 {
    return app.frame;
}
/// 0 title, 1 game, 2 log history.
fn debug_screen() callconv(.c) u32 {
    return @backingInt(app.screen);
}
/// 0 paging (A: MORE), 1 prompt, 2 GET READY, 3 the cue, 4 the shot's result.
fn debug_phase() callconv(.c) u32 {
    return @backingInt(app.phase);
}
/// G.PromptKind: 0 yes_no, 1 number, 2 choice, 3 shoot, 4 game_over.
fn debug_prompt_kind() callconv(.c) u32 {
    return @backingInt(app.game.prompt.kind);
}
fn debug_prompt_line() callconv(.c) u32 {
    return app.game.prompt.line;
}
fn debug_turn() callconv(.c) u32 {
    return app.hud.turn;
}
fn debug_mileage() callconv(.c) i32 {
    return app.hud.mileage_shown;
}
fn debug_mileage_true() callconv(.c) i32 {
    return app.hud.mileage_true;
}
fn debug_food() callconv(.c) i32 {
    return app.hud.food;
}
fn debug_cash() callconv(.c) i32 {
    return app.hud.cash;
}
fn debug_cursor() callconv(.c) u32 {
    return app.cursor;
}
/// The number spinner's value.
fn debug_value() callconv(.c) i32 {
    return app.spin.value;
}
fn debug_answers() callconv(.c) u32 {
    return app.answers;
}
fn debug_shots() callconv(.c) u32 {
    return app.shots;
}
fn debug_shots_hit() callconv(.c) u32 {
    return app.shots_hit;
}
fn debug_shots_wrong() callconv(.c) u32 {
    return app.shots_wrong;
}
fn debug_misfires() callconv(.c) u32 {
    return app.misfires;
}
fn debug_games_started() callconv(.c) u32 {
    return app.games_started;
}
fn debug_games_over() callconv(.c) u32 {
    return app.games_over;
}
fn debug_arrivals() callconv(.c) u32 {
    return app.arrivals;
}
fn debug_deaths() callconv(.c) u32 {
    return app.deaths;
}
/// The last finished game's G.Outcome: 0 none (no game over yet), 1 arrived,
/// 2 starved, 3 no_doctor_money, 4 no_medicine, 5 pneumonia, 6 injuries,
/// 7 winter, 8 massacred, 9 snakebite.
fn debug_outcome() callconv(.c) u32 {
    return @backingInt(app.last_outcome);
}
fn debug_log_rows() callconv(.c) u32 {
    return app.log.total;
}
/// Turns the autoplayer on (V as for raspberry_trail_autoplay; 0 off).
fn debug_autoplay(v: u32) callconv(.c) u32 {
    bot.set(v, 0x5EED0000 ^ app.frame);
    return 1;
}
fn cart_framebuffer_address() callconv(.c) usize {
    return @intFromPtr(cart.framebuffer);
}

/// Button state. Upstream's platform_wasm.zig exposes `controls` but never
/// fills it from the simulator, which writes its button word (same bit
/// layout as cart.Controls) to linear address 0x04; read that directly on
/// wasm. Hardware gets the OS-maintained cart.controls.
fn read_controls() cart.Controls {
    if (cart.is_wasm) return @bitCast(@as(*const volatile u16, @ptrFromInt(0x04)).*);
    return cart.controls.*;
}

/// Simulator shim. Upstream's platform_wasm.zig never presents, and the web
/// simulator reads a legacy framebuffer at linear address 0x20 with red and
/// blue swapped. Copy our frame there, swapping them back. Hardware builds
/// do not compile any of this.
fn present_wasm() void {
    const sim_framebuffer: *cart.Framebuffer = @ptrFromInt(0x20);
    for (cart.framebuffer, sim_framebuffer) |*src_column, *dst_column| {
        for (src_column, dst_column) |src, *dst| {
            const col = src.to_color();
            dst.* = .from_color(.{ .r = col.b, .g = col.g, .b = col.r });
        }
    }
}
