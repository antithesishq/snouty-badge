//! Snouty Cycles: a top-down light-cycle arena (Tron). You ride a cycle
//! that leaves a wall; so do the programs. The screen is a function of the
//! grid, drawn incrementally into the OS's copy-forward framebuffer.
//! SPEC.md is the design, PLAN.md the current milestone, CLAUDE.md the
//! module map and interfaces.
const std = @import("std");
const cart = @import("cart-api");
const build_options = @import("build_options");
const sim = @import("sim.zig");
const game = @import("game.zig");
const render = @import("render.zig");
const levels = @import("levels.zig");
const link = @import("link");
const net = @import("net.zig");

comptime {
    cart.export_start_code();
}

/// Pixel sink for the renderer: the cart framebuffer plus the OS dirty rect.
///
/// While the round rewinds, the arena rows above `tint_end` (outside the
/// banner) are tinted. Every renderer primitive marks its rect right
/// after writing it, so `mark_dirty` tints the rect it is given in place:
/// `put` stays a plain store (a check per pixel there cost 2 ms on a full
/// repaint, it stops the renderer's cell loop from inlining). The only
/// pixels a mark covers that were not just written are a head sprite's
/// four corners, tinted twice for the frame the head is there.
const Screen = struct {
    pub inline fn put(x: u32, y: u32, c: u16) void {
        cart.framebuffer[x][y] = .from_color(@bitCast(c));
    }
    pub fn mark_dirty(r: render.Rect) void {
        if (r.is_empty()) return;
        if (r.y0 < tint_end and r.y1 > render.arena_y) tint_rect(r);
        cart.mark_dirty_rect(r.x0, r.y0, @as(i32, r.x1) - r.x0, @as(i32, r.y1) - r.y0);
    }
};

/// Tints the arena pixels of r above `tint_end`, outside the banner.
noinline fn tint_rect(r: render.Rect) void {
    const y_end = @min(@as(u32, r.y1), tint_end);
    var x: u32 = r.x0;
    while (x < r.x1) : (x += 1) {
        var y: u32 = @max(@as(u32, r.y0), render.arena_y);
        while (y < y_end) : (y += 1) {
            if (in_box(x, y)) continue;
            const px = &cart.framebuffer[x][y];
            px.* = .from_color(@bitCast(tint(@bitCast(px.to_color()), y)));
        }
    }
}
const R = render.Renderer(Screen);

/// Pixel rows above this are tinted (arena_y: none).
var tint_end: u32 = render.arena_y;
/// The bright line at the wipe's front, drawn last frame (erased by
/// repainting its cells).
var wipe_line: ?u8 = null;
const wipe_color = render.rgb(0xB8F4FF);
/// The banner's box: its text and dimmed arena are not tinted.
var tint_box: render.Rect = .empty;

inline fn in_box(x: u32, y: u32) bool {
    const r = tint_box;
    return x >= r.x0 and x < r.x1 and y >= r.y0 and y < r.y1;
}

/// The rewind's look: a cold navy cast (red down, darks lifted toward
/// blue) with every other row at half, like a tape running backwards;
/// the trails keep their hues. 565 bits in and out (r in the low 5).
fn tint(c: u16, y: u32) u16 {
    var cr: u32 = c & 31;
    var cg: u32 = (c >> 5) & 63;
    var cb: u32 = c >> 11;
    cr = cr * 12 / 16;
    cg = cg * 14 / 16 + 1;
    cb = @min(31, cb * 14 / 16 + 4);
    if (y & 1 != 0) {
        cr /= 2;
        cg /= 2;
        cb = cb * 9 / 16;
    }
    return @intCast(cr | (cg << 5) | (cb << 11));
}

/// 38 KB of World inside: a static, never on the stack.
var g: game.Game = undefined;
/// Reset in start(): its overlay stays out of .data.
var renderer: R = undefined;

var tick: u32 = 0;
var render_us: u32 = 0;
var seed: u32 = 0;
var autopilot: u8 = 0;
/// OPTIONS for headless runs and the bench (`levels.Options.bits`), kept
/// through reseeds like the autopilot.
var options_bits: u32 = 0;

/// -Ddebug_overlay builds show the render time in the HUD.
const debug_build = build_options.debug_overlay;

var prev: game.Buttons = .{};

/// LINK DUEL: the lockstep and the link it owns (PIO2 on the badge,
/// `.unavailable` in the simulator: NO LINK IN SIMULATOR).
const Net = net.Net(link.Badge);
var lnk: Net = undefined;
/// Simulator previews (`debug_link_view`): a made-up lockstep state shown
/// instead of the real one (0 off; else bits 0-7 the LinkStatus, bit 8
/// host, bit 16 set).
var link_view_fake: u32 = 0;

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    cart.set_double_buffer_mode(.copy_forward);
    renderer.reset();
    autopilot = @intCast(@min(bench_autopilot, 3));
    options_bits = bench_options;
    if (bench_seed != 0) {
        reseed(bench_seed);
    } else {
        reseed(if (clock_seeded) cart.rand() ^ clock_mix() else cart.rand());
    }
    // After the game's seed (the first cart.rand(), as before M3, so
    // preview --seed runs are unchanged). The link's search timing must
    // differ between two badges: the clock (cart.rand() reads 0 there).
    lnk = Net.init(link.Badge.init(.{}, net.app_id, cart.rand() ^ clock_mix()));
    if (bench_link == 1) {
        g.enter_link();
    } else if (bench_link == 2) {
        g.lk.layout = @intCast(bench_link_layout % 9);
        g.lk.opts = g.opts;
        g.duel_demo(seed);
    } else if (bench_skirmish != 0) {
        g.sk = .from_bits(bench_skirmish - 1);
        g.new_match();
    } else if (bench_level != 0) {
        g.new_game(bench_level);
    }
    g.crash_at = bench_crash_at;
}

/// badge-bench hooks (firmware only, 0 on the badge): `--poke
/// snouty_cycles_seed=N` starts from seed N (the seed the wasm build gets
/// when cart.rand() first returns N), `--poke snouty_cycles_autopilot=K`
/// lets the autopilot drive the player (1 T1, 2 T1 with slips, 3 T3),
/// `--poke snouty_cycles_level=N` skips the title and starts the ladder at
/// level N (badge-bench/carts/snouty-cycles.toml, tools/check.sh bench).
/// M2: `snouty_cycles_crash_at=T` derezzes you when a ladder round reaches
/// World tick T (once: the rewind's frames in the bench),
/// `snouty_cycles_options=B` sets OPTIONS (`levels.Options.from_bits`),
/// `snouty_cycles_skirmish=B+1` starts a SKIRMISH match
/// (`game.Skirmish.from_bits(B)`) instead of the ladder.
/// M3: `snouty_cycles_link=1` opens LINK DUEL's cable screen (no cable in
/// the bench: SEARCHING, the link's cost alone), `=2` a demo duel (you,
/// or the autopilot, against the T2 program in the partner's slot) in
/// arena `snouty_cycles_link_layout` with the OPTIONS poke's modifiers.
var bench_link: u32 = 0;
/// `snouty_cycles_link_off=1`: never touch the link (badge-bench measures
/// the link's cost as the difference; tools/check.sh link).
var bench_link_off: u32 = 0;
var bench_link_layout: u32 = 0;
var bench_seed: u32 = 0;
var bench_autopilot: u32 = 0;
var bench_level: u32 = 0;
var bench_crash_at: u32 = 0;
var bench_options: u32 = 0;
var bench_skirmish: u32 = 0;
comptime {
    if (!cart.is_wasm) {
        @export(&bench_seed, .{ .name = "snouty_cycles_seed" });
        @export(&bench_autopilot, .{ .name = "snouty_cycles_autopilot" });
        @export(&bench_level, .{ .name = "snouty_cycles_level" });
        @export(&bench_crash_at, .{ .name = "snouty_cycles_crash_at" });
        @export(&bench_options, .{ .name = "snouty_cycles_options" });
        @export(&bench_skirmish, .{ .name = "snouty_cycles_skirmish" });
        @export(&bench_link, .{ .name = "snouty_cycles_link" });
        @export(&bench_link_off, .{ .name = "snouty_cycles_link_off" });
        @export(&bench_link_layout, .{ .name = "snouty_cycles_link_layout" });
    }
}

/// Badge builds only: cart.rand() reads 0 on the RP2350, so the badge mixes
/// in the microsecond clock (as snouty-maze and snouty-pipes do). Wasm keeps
/// cart.rand() alone so preview.mjs --seed reproduces runs.
const clock_seeded = !cart.is_wasm;

fn clock_mix() u32 {
    const t = cart.micros_since_boot();
    var h: u32 = @as(u32, @truncate(t)) ^ @as(u32, @truncate(t >> 32)) ^ 0x9e3779b9;
    h ^= h >> 16;
    h *%= 0x85ebca6b;
    h ^= h >> 13;
    h *%= 0xc2b2ae35;
    h ^= h >> 16;
    return h;
}

/// A bright scanline across the arena at row y (outside the banner).
fn draw_wipe_line(y: u8) void {
    // Not through the banner's rows (stubs beside the box look broken).
    if (y >= tint_box.y0 and y < tint_box.y1) return;
    for (0..render.screen_w) |x| cart.framebuffer[x][y] = .from_color(@bitCast(wipe_color));
    cart.mark_dirty_rect(0, y, render.screen_w, 1);
    wipe_line = y;
}

fn reseed(s: u32) void {
    seed = s;
    g.init(s);
    g.autopilot = autopilot;
    g.opts = .from_bits(options_bits);
    renderer.invalidate();
    wipe_line = null;
}

fn buttons(c: cart.Controls) game.Buttons {
    return .{
        .up = c.up,
        .right = c.right,
        .down = c.down,
        .left = c.left,
        .a = c.a,
        .b = c.b,
        .start = c.start,
        .select = c.select,
    };
}

pub fn update() void {
    const frame_start = cart.micros_since_boot();
    const held = buttons(read_controls());
    const pressed: game.Buttons = @bitCast(@as(u8, @bitCast(held)) & ~@as(u8, @bitCast(prev)));
    prev = held;
    // The link runs in every mode (one poll a frame while searching), so
    // a session survives the menus; LINK DUEL reads it.
    const link_on = bench_link_off == 0;
    if (link_on) {
        lnk.begin(&g, frame_start);
    } else {
        // The same screens as with the link and no cable.
        g.lk.status = .searching;
    }
    if (link_view_fake != 0) fake_link_state();
    g.update(held, pressed);
    if (link_on) {
        lnk.end(&g, cart.micros_since_boot());
        // Between the sim and the render (the 8-byte receive FIFO).
        lnk.pump(cart.micros_since_boot());
    }

    const t0 = cart.micros_since_boot();
    // A rewind's replay frames run on a World the screen must not follow:
    // the last retraction frame stays up (copy_forward keeps it).
    if (!g.hold_frame) {
        if (g.repaint) {
            renderer.invalidate();
            g.repaint = false;
        }
        var v = g.view();
        if (debug_build) {
            var buf: [20]u8 = undefined;
            const n = game.decimal(&buf, render_us, 4);
            @memcpy(buf[n..][0..2], "us");
            v.hud.right = .of(buf[0 .. n + 2], 1, game.colors.warn);
        }
        tint_box = if (v.banner) |b| b.rect() else .empty;
        // The tint wiping down: repaint the rows it reached this frame
        // (and last frame's bright front line).
        const end = render.arena_y + @as(u32, g.tinted());
        if (wipe_line) |y| {
            renderer.repaint_rect(&g.world, .{ .x0 = 0, .y0 = y, .x1 = render.screen_w, .y1 = y + 1 });
            wipe_line = null;
        }
        if (end > tint_end) {
            const from: u8 = @intCast(tint_end);
            tint_end = end;
            renderer.repaint_rect(&g.world, .{ .x0 = 0, .y0 = from, .x1 = render.screen_w, .y1 = @intCast(end) });
        } else {
            // Taking it off comes with a full repaint (the game's repaint).
            tint_end = end;
        }
        renderer.frame(&g.world, v);
        if (g.state == .rewind and tint_end < render.screen_h and tint_end > render.arena_y) draw_wipe_line(@intCast(tint_end - 1));
    }
    render_us = @truncate(cart.micros_since_boot() - t0);

    // After the render: once, and while racing until 14 ms into the frame
    // (pumping and retrying a step this frame missed). With no partner
    // `busy` is false and this is a single pump.
    if (link_on) lnk.pump(cart.micros_since_boot());
    if (link_on and lnk.busy(&g)) {
        while (true) {
            const now = cart.micros_since_boot();
            if (now -% frame_start >= net.pump_until_us) break;
            lnk.retry(&g, now);
        }
    }

    tick +%= 1;
    if (cart.is_wasm) present_wasm();
}

// Debug exports for the headless harness (wasm only). docs/RUNNING.md
// section 6 lists them; tools/check.sh depends on their names.
comptime {
    if (cart.is_wasm) {
        @export(&debug_tick, .{ .name = "debug_tick" });
        @export(&debug_state, .{ .name = "debug_state" });
        @export(&debug_round, .{ .name = "debug_round" });
        @export(&debug_alive_mask, .{ .name = "debug_alive_mask" });
        @export(&debug_player_x, .{ .name = "debug_player_x" });
        @export(&debug_player_y, .{ .name = "debug_player_y" });
        @export(&debug_player_dir, .{ .name = "debug_player_dir" });
        @export(&debug_render_us, .{ .name = "debug_render_us" });
        @export(&debug_pixel_checksum, .{ .name = "debug_pixel_checksum" });
        @export(&debug_set_seed, .{ .name = "debug_set_seed" });
        @export(&debug_autopilot, .{ .name = "debug_autopilot" });
        @export(&debug_score, .{ .name = "debug_score" });
        @export(&debug_wins, .{ .name = "debug_wins" });
        @export(&debug_losses, .{ .name = "debug_losses" });
        @export(&debug_level, .{ .name = "debug_level" });
        @export(&debug_lives, .{ .name = "debug_lives" });
        @export(&debug_high, .{ .name = "debug_high" });
        @export(&debug_set_level, .{ .name = "debug_set_level" });
        @export(&debug_sudden_death_ring, .{ .name = "debug_sudden_death_ring" });
        @export(&debug_world_tick, .{ .name = "debug_world_tick" });
        @export(&debug_world_hash, .{ .name = "debug_world_hash" });
        @export(&debug_snapshots, .{ .name = "debug_snapshots" });
        @export(&debug_rewinds, .{ .name = "debug_rewinds" });
        @export(&debug_force_crash, .{ .name = "debug_force_crash" });
        @export(&debug_crash_at, .{ .name = "debug_crash_at" });
        @export(&debug_options, .{ .name = "debug_options" });
        @export(&debug_skirmish, .{ .name = "debug_skirmish" });
        @export(&debug_mode, .{ .name = "debug_mode" });
        @export(&debug_match, .{ .name = "debug_match" });
        @export(&debug_rewind_target, .{ .name = "debug_rewind_target" });
        @export(&debug_link_view, .{ .name = "debug_link_view" });
        @export(&debug_link_demo, .{ .name = "debug_link_demo" });
        @export(&debug_link_round, .{ .name = "debug_link_round" });
        @export(&debug_link_wins, .{ .name = "debug_link_wins" });
        @export(&debug_link_status, .{ .name = "debug_link_status" });
    }
}

fn debug_tick() callconv(.c) u32 {
    return tick;
}
/// game.State: 0 title, 1 menu, 2 howto, 3 intro, 4 countdown, 5 play,
/// 6 derez, 7 clear, 8 game over, 9 paused, 10 frozen (your derez, a
/// snapshot left), 11 rewind, 12 options, 13 SKIRMISH setup, 14 round
/// over, 15 match over.
fn debug_state() callconv(.c) u32 {
    return @backingInt(g.state);
}
/// Worlds started this game (attempts at levels; 0 on the title).
fn debug_round() callconv(.c) u32 {
    return g.rounds;
}
/// Ladder position (1-based, 13 = BASIC on the second loop; 0 off the ladder).
fn debug_level() callconv(.c) u32 {
    return g.level;
}
/// Snapshots left (M1's lives; the ladder bot reads this name).
fn debug_lives() callconv(.c) u32 {
    return g.snapshots;
}
fn debug_snapshots() callconv(.c) u32 {
    return g.snapshots;
}
/// Rewinds this game.
fn debug_rewinds() callconv(.c) u32 {
    return g.rewinds;
}
/// Derezzes you now if a ladder round is in play (a rewind follows when a
/// snapshot is left). Returns 1 if it did.
fn debug_force_crash() callconv(.c) u32 {
    const before = g.state;
    g.force_crash();
    return @intFromBool(g.state != before);
}
/// Derezzes you when the World reaches tick t in play (once; 0 off).
fn debug_crash_at(t: u32) callconv(.c) u32 {
    g.crash_at = t;
    return t;
}
/// Sets OPTIONS (`levels.Options.from_bits`: bits 0-1 speed 0 normal,
/// 1 slow, 2 fast; 2 SNAKE, 3 GAPS, 4 WRAP, 5 HARDCORE), kept through
/// reseeds; applies from the next round. Returns the bits.
fn debug_options(bits: u32) callconv(.c) u32 {
    options_bits = bits;
    g.opts = .from_bits(bits);
    return g.opts.bits();
}
/// Starts a SKIRMISH match (`game.Skirmish.from_bits`: bits 0-1
/// programs - 1, 2-3 tier, 4-7 arena). Returns the programs.
fn debug_skirmish(bits: u32) callconv(.c) u32 {
    g.sk = .from_bits(bits);
    g.new_match();
    return g.sk.programs;
}
/// 0 ladder, 1 SKIRMISH, 2 LINK DUEL.
fn debug_mode() callconv(.c) u32 {
    return @backingInt(g.mode);
}
/// SKIRMISH: round wins, 4 bits per cycle (cycle 0 lowest), and your
/// points above bit 16.
fn debug_match() callconv(.c) u32 {
    var v: u32 = 0;
    for (g.sk.wins, 0..) |w, i| v |= @as(u32, w & 15) << @intCast(4 * i);
    return v | @as(u32, g.sk.points[0]) << 16;
}
/// Simulator previews of LINK DUEL's screens with no partner: shows
/// lockstep state `v & 0xFF` (game.LinkStatus: 1 searching, 2 wrong cart,
/// 3 wrong version, 4 lobby, 6 waiting) from now on instead of the real
/// one, as the host when bit 8 is set (the guest sees the host's setup),
/// opening LINK DUEL if needed. 0 stops faking. Returns v.
fn debug_link_view(v: u32) callconv(.c) u32 {
    link_view_fake = if (v & 0xFF == 0) 0 else v | 0x10000;
    if (link_view_fake != 0 and g.mode != .link) g.enter_link();
    return v;
}
/// A demo duel (you, or the autopilot, against the T2 program in the
/// partner's slot) in arena `layout` with the current OPTIONS modifiers.
fn debug_link_demo(layout: u32) callconv(.c) u32 {
    link_view_fake = 0;
    g.lk.layout = @intCast(layout % 9);
    g.lk.opts = g.opts;
    g.duel_demo(seed);
    return 1;
}
/// The lockstep's state as LINK DUEL sees it (game.LinkStatus: 0 offline
/// = no link hardware, the simulator; 1 searching, 2 wrong cart, 3 lobby,
/// 4 racing, 5 waiting, 6 peer left, 7 desync).
fn debug_link_status() callconv(.c) u32 {
    return @backingInt(g.lk.status);
}
/// LINK DUEL: the round of the match (0 off).
fn debug_link_round() callconv(.c) u32 {
    return if (g.mode == .link) g.lk.round else 0;
}
/// LINK DUEL: your wins (bits 0-3) and the partner's (bits 4-7).
fn debug_link_wins() callconv(.c) u32 {
    return @as(u32, g.lk.wins[g.lk.slot]) | @as(u32, g.lk.wins[g.lk.slot ^ 1]) << 4;
}

fn fake_link_state() void {
    const lk = &g.lk;
    lk.status = @fromBackingInt(@intCast(link_view_fake & 0xFF));
    lk.host = link_view_fake & 0x100 != 0;
    lk.partner_name = "SNOUTY GC";
    lk.can_go = true;
    lk.heard = if (lk.host) null else lk.rules();
}

/// The World tick the last rewind went back to.
fn debug_rewind_target() callconv(.c) u32 {
    return g.history.target;
}
/// Session high score.
fn debug_high() callconv(.c) u32 {
    return g.high;
}
/// Starts a new ladder game at position n (3 snapshots, score 0), skipping
/// the title. Returns n.
fn debug_set_level(n: u32) callconv(.c) u32 {
    g.new_game(n);
    return g.level;
}
fn debug_sudden_death_ring() callconv(.c) u32 {
    return g.world.sudden_death_ring;
}
/// Bit i set while cycle i is alive (cycle 0 is the player).
fn debug_alive_mask() callconv(.c) u32 {
    return g.world.alive_mask();
}
fn debug_player_x() callconv(.c) u32 {
    return g.world.cycles[0].x;
}
fn debug_player_y() callconv(.c) u32 {
    return g.world.cycles[0].y;
}
/// sim.Dir: 0 up, 1 right, 2 down, 3 left.
fn debug_player_dir() callconv(.c) u32 {
    return @backingInt(g.world.cycles[0].dir);
}
fn debug_render_us() callconv(.c) u32 {
    return render_us;
}
/// Sum of all framebuffer words, for render regression tests.
fn debug_pixel_checksum() callconv(.c) u32 {
    var sum: u32 = 0;
    for (cart.framebuffer) |*column| {
        for (column) |px| sum +%= @as(u16, @bitCast(px));
    }
    return sum;
}
/// Reseeds and restarts on the title.
fn debug_set_seed(s: u32) callconv(.c) void {
    reseed(s);
}
/// 1: T1 drives the player, 2: T1 with random slips (rounds end sooner),
/// 3: T3 SEARCH (the ladder bot); 0 off. Kept through reseeds. Returns
/// the new value.
fn debug_autopilot(level: u32) callconv(.c) u32 {
    autopilot = @intCast(@min(level, 3));
    g.autopilot = autopilot;
    return autopilot;
}
fn debug_score() callconv(.c) u32 {
    return g.score;
}
/// Levels cleared this game.
fn debug_wins() callconv(.c) u32 {
    return g.clears;
}
/// Lives lost this game.
fn debug_losses() callconv(.c) u32 {
    return g.deaths;
}
/// Ticks into the current World (round or attract round).
fn debug_world_tick() callconv(.c) u32 {
    return g.world.tick;
}
/// sim.World.hash of the current World (determinism checks).
fn debug_world_hash() callconv(.c) u32 {
    return g.world.hash();
}

/// Button state. Upstream's platform_wasm.zig never fills `controls` from
/// the simulator, which writes its button word to linear address 0x04.
pub fn read_controls() cart.Controls {
    if (cart.is_wasm) return @bitCast(@as(*const volatile u16, @ptrFromInt(0x04)).*);
    return cart.controls.*;
}

/// Simulator shim (see snouty-bugs/CLAUDE.md): upstream's wasm platform
/// never presents, and the web simulator reads a legacy framebuffer at 0x20
/// with red and blue swapped. Hardware builds compile none of this.
fn present_wasm() void {
    const sim_framebuffer: *cart.Framebuffer = @ptrFromInt(0x20);
    for (cart.framebuffer, sim_framebuffer) |*src_column, *dst_column| {
        for (src_column, dst_column) |src, *dst| {
            const c = src.to_color();
            dst.* = .from_color(.{ .r = c.b, .g = c.g, .b = c.r });
        }
    }
}
