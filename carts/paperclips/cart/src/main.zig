//! Universal Paperclips for the SYCL badge: the cart shell.
//!
//! start() sets 60 fps and full-frame redraws; update() reads the buttons,
//! steps the UI and the game (ui/app.zig: the game's virtual clock moves
//! 17, 17, 16 ms per frame, SPEC section 5) and redraws every pixel
//! (ui/render.zig). The game itself is the `game` module (cart/src/game/),
//! a port of the original JavaScript that knows nothing of the screen.
const std = @import("std");
const cart = @import("cart-api");
const app_mod = @import("ui/app.zig");
const draw = @import("ui/draw.zig");
const render = @import("ui/render.zig");
const G = @import("game");

comptime {
    cart.export_start_code();
}

var app: app_mod.App = .{};

/// badge-bench hook (firmware only, 0 on the badge): `--poke
/// paperclips_bench=N` starts in a prepared game instead of the title
/// (see bench_setup) so a run measures the late stage-1 pages.
var bench: u32 = 0;
/// `--poke paperclips_seed=N`: the game's seed (else the clock's).
var bench_seed: u32 = 0;
/// `--poke paperclips_bench_flags=1`: the game clock stands still (times
/// the UI alone).
var bench_flags: u32 = 0;
comptime {
    if (!cart.is_wasm) {
        @export(&bench, .{ .name = "paperclips_bench" });
        @export(&bench_seed, .{ .name = "paperclips_seed" });
        @export(&bench_flags, .{ .name = "paperclips_bench_flags" });
    }
}

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    // update() redraws every pixel.
    cart.set_double_buffer_mode(.no_copy_full_frame);
    draw.init();
    const seed: u64 = if (bench_seed != 0) bench_seed else if (cart.is_wasm) cart.rand() else clock_mix();
    app.init(seed);
    if (bench != 0) bench_setup(bench);
    app.frozen = bench_flags & 1 != 0;
}

/// Badge builds: cart.rand() reads 0 on the RP2350, so the seed comes
/// from the microsecond clock (as snouty-maze and snouty-pipes do). Wasm
/// keeps cart.rand() so preview.mjs --seed reproduces a run.
fn clock_mix() u64 {
    const t = cart.micros_since_boot();
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
    app.update(.{
        .start = c.start,
        .select = c.select,
        .a = c.a,
        .b = c.b,
        .up = c.up,
        .down = c.down,
        .left = c.left,
        .right = c.right,
    });
    render.frame(&app);
    if (cart.is_wasm) present_wasm();
}

/// A prepared game for timing runs: the title skipped, the cheats used to
/// unlock the stage-1 panels, the clock run forward. `n` picks the page.
fn bench_setup(n: u32) void {
    app.cheats = true;
    app.new_game();
    debug_prepare(40, 100);
    app.update(.{}); // the first tick: the pages exist from here
    var page: u32 = 1;
    while (page < n) : (page += 1) app.switch_page(1);
}

/// Shared by bench_setup and the wasm debug export: a late stage-1 game in
/// few virtual seconds. Each step takes the cheats (money, trust,
/// operations, creativity, yomi), buys wire, the first affordable project
/// and the machines, then runs the clock `step_ms`. The bench runs this in
/// start(), on the emulated badge, under its 1 s limit: keep it short.
fn debug_prepare(steps: u32, step_ms: u32) void {
    var k: u32 = 0;
    while (k < steps) : (k += 1) {
        inline for (.{ .cheat_money, .cheat_trust, .cheat_ops, .cheat_creat, .cheat_yomi }) |act| G.act(app.game, act);
        while (app.game.wire < 2000 and G.enabled(app.game, .buy_wire)) G.act(app.game, .buy_wire);
        for (app.game.active[0..app.game.active_len]) |p| {
            // Not the HypnoDrones: the bench wants stage 1.
            if (p == @intFromEnum(G.P.p35)) continue;
            if (G.enabled(app.game, .{ .buy_project = p })) {
                G.act(app.game, .{ .buy_project = p });
                break;
            }
        }
        inline for (.{ .make_clipper, .make_mega_clipper, .add_proc, .add_mem, .buy_ads }) |act| {
            if (G.enabled(app.game, act)) G.act(app.game, act);
        }
        G.advance_ms(app.game, step_ms);
    }
    app.rebuild();
}

// -- headless harness exports (wasm only) --------------------------------

comptime {
    if (cart.is_wasm) {
        @export(&debug_frame, .{ .name = "debug_frame" });
        @export(&debug_screen, .{ .name = "debug_screen" });
        @export(&debug_page, .{ .name = "debug_page" });
        @export(&debug_cursor, .{ .name = "debug_cursor" });
        @export(&debug_rows, .{ .name = "debug_rows" });
        @export(&debug_clips, .{ .name = "debug_clips" });
        @export(&debug_funds_cents, .{ .name = "debug_funds_cents" });
        @export(&debug_presses, .{ .name = "debug_presses" });
        @export(&debug_msgs, .{ .name = "debug_msgs" });
        @export(&debug_news, .{ .name = "debug_news" });
        @export(&debug_cheats, .{ .name = "debug_cheats" });
        @export(&debug_human, .{ .name = "debug_human" });
        @export(&debug_prepare_export, .{ .name = "debug_prepare" });
        @export(&debug_unlock_cheats, .{ .name = "debug_unlock_cheats" });
        @export(&debug_advance, .{ .name = "debug_advance" });
        @export(&debug_go_page, .{ .name = "debug_go_page" });
        @export(&debug_cheat, .{ .name = "debug_cheat" });
        @export(&cart_framebuffer_address, .{ .name = "cart_framebuffer_address" });
    }
}

fn debug_frame() callconv(.c) u32 {
    return app.frame;
}
fn debug_screen() callconv(.c) u32 {
    return @intFromEnum(app.screen);
}
fn debug_page() callconv(.c) u32 {
    return @intFromEnum(app.page);
}
fn debug_cursor() callconv(.c) u32 {
    return app.cursor_ix[@intFromEnum(app.page)];
}
fn debug_rows() callconv(.c) u32 {
    return @intCast(app.rows.n);
}
fn debug_clips() callconv(.c) u32 {
    if (!app.playing) return 0;
    return @intFromFloat(@min(4.0e9, @max(0, @ceil(app.game.clips))));
}
fn debug_funds_cents() callconv(.c) u32 {
    if (!app.playing) return 0;
    return @intFromFloat(@min(4.0e9, @max(0, @round(app.game.funds * 100))));
}
fn debug_presses() callconv(.c) u32 {
    return app.presses;
}
fn debug_msgs() callconv(.c) u32 {
    if (!app.playing) return 0;
    return app_mod.msg_count(app.game);
}
/// Bit i set: page i has a news mark.
fn debug_news() callconv(.c) u32 {
    var m: u32 = 0;
    for (app.news, 0..) |n, i| if (n) {
        m |= @as(u32, 1) << @intCast(i);
    };
    return m;
}
fn debug_cheats() callconv(.c) u32 {
    return @intFromBool(app.cheats);
}
fn debug_human() callconv(.c) u32 {
    if (!app.playing) return 1;
    return app.game.human_flag;
}
/// Starts a game (if none) and runs debug_prepare: a late stage-1 state.
fn debug_prepare_export() callconv(.c) u32 {
    if (!app.playing) app.new_game();
    debug_prepare(120, 1000);
    return 1;
}
fn debug_unlock_cheats() callconv(.c) u32 {
    app.cheats = true;
    return 1;
}
/// Runs the game clock `ms` forward (fast forward for previews).
fn debug_advance(ms: u32) callconv(.c) u32 {
    if (!app.playing) app.new_game();
    var left = ms;
    while (left > 0) {
        const step = @min(left, 1000);
        G.advance_ms(app.game, step);
        left -= step;
    }
    app.rebuild();
    return 1;
}
fn debug_go_page(p: u32) callconv(.c) u32 {
    if (p >= app_mod.pages_count) return 0;
    app.page = @enumFromInt(@as(u8, @intCast(p)));
    app.rebuild();
    return 1;
}
/// Presses cheat `n` (0 clips, 1 money, 2 trust, 3 ops, 4 creativity, 5 yomi).
fn debug_cheat(n: u32) callconv(.c) u32 {
    if (!app.playing) app.new_game();
    const acts = [_]G.Action{ .cheat_clips, .cheat_money, .cheat_trust, .cheat_ops, .cheat_creat, .cheat_yomi };
    if (n >= acts.len) return 0;
    G.act(app.game, acts[n]);
    app.rebuild();
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

/// Simulator shim. Upstream's platform_wasm.zig never presents (its
/// present_and_acquire is a TODO and update() is exported without calling
/// present()), and the web simulator reads a legacy framebuffer at linear
/// address 0x20 (add_os_cart reserves it via global_base). Copy our frame
/// there, swapping red and blue: the simulator's compositor was written for
/// the legacy API that kept blue in the low bits, while DisplayColor keeps
/// red there. Hardware builds do not compile any of this.
fn present_wasm() void {
    const sim_framebuffer: *cart.Framebuffer = @ptrFromInt(0x20);
    for (cart.framebuffer, sim_framebuffer) |*src_column, *dst_column| {
        for (src_column, dst_column) |src, *dst| {
            const col = src.to_color();
            dst.* = .from_color(.{ .r = col.b, .g = col.g, .b = col.r });
        }
    }
}
