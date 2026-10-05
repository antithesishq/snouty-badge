//! Snouty Pong: the smallest two-badge game, written as an example of
//! `lib/lockstep.zig` over the link cable (docs/LOCKSTEP.md). README.md
//! walks through it.
//!
//! The split to copy:
//! - pong.zig is the game: a World and a pure `simulate`. It is also the
//!   `G` the lockstep takes.
//! - this file is the cart: it pumps the link, runs the lobby, turns
//!   buttons into an input byte, and draws. It never writes the World
//!   during a match; only `ls.step` does, on both badges alike.
//!
//! Without a cable (or in the simulator) A starts a practice game against
//! the CPU, using the same World and `simulate`.
const std = @import("std");
const cart = @import("cart-api");
const link = @import("link");
const lockstep = @import("lockstep");
const pong = @import("pong.zig");

comptime {
    cart.export_start_code();
}

/// Lockstep over the badge's link cable, with pong.zig as the game.
const Lockstep = lockstep.Lockstep(link.Badge, pong);

/// After drawing, keep pumping the link until this far into the frame: its
/// receive buffer holds only 8 bytes (docs/LOCKSTEP.md section 3.1).
const pump_until_us = 14_000;

const bg = cart.DisplayColor.rgb(0x101820);
const fg = cart.DisplayColor.rgb(0xE0E8F0);
const dim = cart.DisplayColor.rgb(0x60707C);
const accent = cart.DisplayColor.rgb(0xF0C040);

var ls: Lockstep = undefined;
var world: pong.World = undefined;
var mode: enum { menu, practice, match } = .menu;
/// Host only: the points to win it offers in the lobby.
var target: u8 = 5;
var ready = false;
/// This frame's `ls.step` ran (the late pump loop retries it until then).
var ticked = false;
/// No buttons (cart.Controls has no field defaults).
const none: cart.Controls = @bitCast(@as(u16, 0));
var held = none;

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    cart.set_double_buffer_mode(.no_copy_full_frame);
    // The nonce decides who hosts, so it must differ between the two
    // badges; cart.rand() reads 0 on the badge, the clock does not.
    const nonce = cart.rand() ^ @as(u32, @truncate(cart.micros_since_boot()));
    ls = .init(link.Badge.init(.{}, lockstep.apps.pong, nonce));
}

pub fn update() void {
    const frame_start = cart.micros_since_boot();
    const pad = read_controls();
    const pressed = presses(held, pad);
    held = pad;

    ls.pump(frame_start);
    ticked = false;
    switch (mode) {
        .menu => menu(frame_start, pressed),
        .practice => practice(pad, pressed),
        .match => match(frame_start, pad, pressed),
    }
    draw();

    // The vsync wait is the one stretch where nothing reads the link, so
    // pump through most of it while a match runs, retrying a stalled step.
    while (ls.wants_pump() and cart.micros_since_boot() - frame_start < pump_until_us) {
        ls.pump(cart.micros_since_boot());
        if (mode == .match and !ticked) ticked = ls.step(&world);
    }

    if (cart.is_wasm) present_wasm();
}

/// The link screens and the lobby. A match starts on both badges in the
/// same frame `take_started` says so.
fn menu(now: u64, pressed: cart.Controls) void {
    if (ls.take_started()) {
        world = .init(ls.seed(), ls.rules().?[0]);
        ready = false;
        mode = .match;
        return;
    }
    if (ls.state() != .lobby) {
        if (pressed.a) {
            world = .init(cart.rand() ^ @as(u32, @truncate(now)), target);
            world.cpu[1] = true;
            mode = .practice;
        }
        return;
    }
    if (ls.role == .host) {
        if (pressed.up and target < 11) target += 2;
        if (pressed.down and target > 3) target -= 2;
        ls.set_rules(.{target});
    }
    if (pressed.a) ready = !ready;
    ls.set_pick(0, ready);
    if (ls.role == .host and ls.can_go()) _ = ls.go(now);
}

fn practice(pad: cart.Controls, pressed: cart.Controls) void {
    if (pressed.b or (world.winner() != null and pressed.a)) {
        mode = .menu;
        return;
    }
    pong.simulate(&world, .{ input_byte(pad), 0 });
}

/// One input byte in, at most one tick out. The World moves only here.
fn match(now: u64, pad: cart.Controls, pressed: cart.Controls) void {
    const over = world.winner() != null or ls.state() == .desync;
    if (pressed.b or (over and pressed.a)) {
        ls.leave(now); // the partner hears QUIT and its CPU takes our paddle
        mode = .menu;
        return;
    }
    ls.submit(now, input_byte(pad));
    ticked = ls.step(&world);
}

fn input_byte(pad: cart.Controls) u8 {
    return @bitCast(pong.Input{ .up = pad.up, .down = pad.down });
}

/// Buttons down now that were up last frame, ignoring the OS's
/// Start+Select chord.
fn presses(before: cart.Controls, after: cart.Controls) cart.Controls {
    if (after.start and after.select) return none;
    return @bitCast(@as(u16, @bitCast(after)) & ~@as(u16, @bitCast(before)));
}

// ---- drawing -------------------------------------------------------------------

fn draw() void {
    cart.rect(.{ .x = 0, .y = 0, .width = pong.width, .height = pong.height, .fill_color = bg });
    switch (mode) {
        .menu => draw_menu(),
        .practice => {
            draw_court();
            if (world.winner()) |w| banner(if (w == 0) "YOU WIN" else "CPU WINS", "A: MENU");
        },
        .match => {
            draw_court();
            const me = ls.local_slot();
            if (ls.state() == .desync) {
                banner("DESYNC", "A: LOBBY");
            } else if (world.winner()) |w| {
                banner(if (w == me) "YOU WIN" else "YOU LOSE", "A: LOBBY");
            } else switch (ls.state()) {
                .waiting => banner("WAITING FOR PEER", ""),
                .peer_left => say(116, "PEER LEFT, CPU PLAYS", dim),
                else => {},
            }
        },
    }
}

fn draw_court() void {
    var y: i32 = 0;
    while (y < pong.height) : (y += 8) {
        cart.rect(.{ .x = pong.width / 2 - 1, .y = y, .width = 2, .height = 4, .fill_color = dim });
    }
    for (pong.paddle_x, world.paddle_y) |x, y_sub| {
        cart.rect(.{ .x = x, .y = @divFloor(y_sub, pong.sub), .width = pong.paddle_w, .height = pong.paddle_h, .fill_color = fg });
    }
    if (world.serve_in == 0 or world.serve_in % 8 < 4) {
        cart.rect(.{
            .x = @divFloor(world.ball_x, pong.sub),
            .y = @divFloor(world.ball_y, pong.sub),
            .width = pong.ball_size,
            .height = pong.ball_size,
            .fill_color = accent,
        });
    }
    var buf: [4]u8 = undefined;
    cart.text(.{ .str = fmt(&buf, "{d}", .{world.score[0]}), .x = 56, .y = 4, .text_color = fg });
    cart.text(.{ .str = fmt(&buf, "{d}", .{world.score[1]}), .x = 96, .y = 4, .text_color = fg });
}

/// The shared link screens of docs/LOCKSTEP.md section 6, then the lobby.
fn draw_menu() void {
    var buf: [24]u8 = undefined;
    say(16, "SNOUTY PONG", accent);
    switch (ls.state()) {
        .offline => {
            say(48, "NO LINK IN SIMULATOR", dim);
            say(72, "A: PRACTICE", fg);
        },
        .searching => {
            say(48, "PLUG IN THE CABLE", dim);
            say(72, "A: PRACTICE", fg);
        },
        .wrong_cart => {
            say(48, "WRONG CART:", dim);
            say(60, ls.partner_name(), fg);
        },
        .wrong_version => {
            say(48, "WRONG VERSION:", dim);
            say(60, "UPDATE BOTH BADGES", fg);
        },
        .lobby => {
            const host = ls.role == .host;
            say(40, if (host) "YOU ARE LEFT (HOST)" else "YOU ARE RIGHT", dim);
            if (ls.rules()) |r| say(56, fmt(&buf, "FIRST TO {d}", .{r[0]}), fg);
            if (host) say(68, "UP/DOWN: POINTS", dim);
            say(88, if (ready) "READY!" else "A: READY", if (ready) accent else fg);
            say(104, if (ls.peer_ready()) "PEER READY" else "PEER NOT READY", dim);
        },
        // Busy states only last until `menu` sees take_started.
        .racing, .waiting, .peer_left, .desync => {},
    }
}

fn banner(title: []const u8, hint: []const u8) void {
    cart.rect(.{ .x = 0, .y = 48, .width = pong.width, .height = 32, .fill_color = bg });
    say(52, title, accent);
    say(68, hint, fg);
}

/// Text centred on the screen (8x8 font).
fn say(y: i32, str: []const u8, color: cart.DisplayColor) void {
    const x = (pong.width -| str.len * 8) / 2;
    cart.text(.{ .str = str, .x = @intCast(x), .y = y, .text_color = color });
}

fn fmt(buf: []u8, comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, f, args) catch "?";
}

// ---- simulator shims (CLAUDE.md "Simulator and headless preview") ---------------

/// The web simulator writes its buttons to address 0x04; the badge's OS
/// keeps `cart.controls`.
fn read_controls() cart.Controls {
    if (cart.is_wasm) return @bitCast(@as(*const volatile u16, @ptrFromInt(0x04)).*);
    return cart.controls.*;
}

/// The web simulator reads a legacy framebuffer at 0x20 with red and blue
/// swapped. Badge builds compile none of this.
fn present_wasm() void {
    const sim_framebuffer: *cart.Framebuffer = @ptrFromInt(0x20);
    for (cart.framebuffer, sim_framebuffer) |*src_column, *dst_column| {
        for (src_column, dst_column) |src, *dst| {
            const c = src.to_color();
            dst.* = .from_color(.{ .r = c.b, .g = c.g, .b = c.r });
        }
    }
}
