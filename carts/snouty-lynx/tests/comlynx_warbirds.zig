//! comlynx: Warbirds (Atari 1990, up to 4 players over ComLynx) on the
//! virtual bus (docs/COMLYNX.md section 5). Needs Adrian's local dump
//! `~/roms/lynx/Warbirds.lnx` (never in the repository; skipped when
//! absent). Each console is switched on 7 frames after the one before and
//! runs tools/scripts/warbirds_link.json (A at 500 leaves the title, A at
//! 600 accepts the options board). Passing means: every console's title
//! says "N PLAYERS" for the right N (Warbirds found the others over the
//! wire) and every console reaches the cockpit (the networked game).
//! tools/comlynx_sweep.py is the latency sweep over the same probes.
const std = @import("std");
const core = @import("core");
const files = @import("testfiles.zig");
const runner = @import("runner.zig");
const virt = core.comlynx_virtual;
const Lynx = core.Lynx;
const expect = std.testing.expect;

var rom_buf: [512 * 1024 + 64]u8 = undefined;
var script_buf: [4096]u8 = undefined;
var lay: core.cart.Layout = undefined;
var consoles: [4]Lynx = undefined;
var bus: virt.VirtualBus = undefined;

/// The RGB (4 bits each) of pixel (x, y) of the shown frame.
fn rgb(l: *const Lynx, x: usize, y: usize) [3]u8 {
    const f = l.frame();
    const b = f.pixels[y * 80 + x / 2];
    const pen = if (x & 1 == 0) b >> 4 else b & 0xF;
    return .{ f.bluered[pen] & 0xF, f.green[pen] & 0xF, f.bluered[pen] >> 4 };
}

/// The cockpit: the top wing (rows 0-3) is red (13, 0, 0) at both edges.
fn cockpit(l: *const Lynx) bool {
    const w = [3]u8{ 13, 0, 0 };
    return std.mem.eql(u8, &rgb(l, 0, 1), &w) and std.mem.eql(u8, &rgb(l, 159, 1), &w);
}

/// The title's "N PLAYERS" (orange, (15, 4, 0)) in the bottom right: the
/// pixel count of its first glyph (the digit), or 0 when absent.
fn players_glyph(l: *const Lynx) u32 {
    const o = [3]u8{ 15, 4, 0 };
    var x0: usize = 160;
    for (88..102) |y| for (90..160) |x| {
        if (std.mem.eql(u8, &rgb(l, x, y), &o)) x0 = @min(x0, x);
    };
    if (x0 == 160) return 0;
    var n: u32 = 0;
    for (88..102) |y| for (x0..@min(x0 + 7, 160)) |x| {
        if (std.mem.eql(u8, &rgb(l, x, y), &o)) n += 1;
    };
    return n;
}

const Outcome = struct {
    glyph: [4]u32 = @splat(0),
    cockpit_at: [4]?u32 = @splat(null),
};

fn play(n: usize, cfg: virt.Config, frames: u32) !Outcome {
    const file = files.read_home_file("roms/lynx/Warbirds.lnx", &rom_buf) orelse return error.SkipZigTest;
    lay = core.cart.parse(file, @intCast(file.len));
    const json = files.read_cart_file("tools/scripts/warbirds_link.json", &script_buf) orelse return error.FileNotFound;
    var controls: [4][]u16 = undefined;
    var fes: [4]runner.Frontend = @splat(.{ .running = true });
    var ptrs: [4]*Lynx = undefined;
    for (0..n) |i| {
        consoles[i].init_in_place(core.Cart.from_slice(&lay, file));
        ptrs[i] = &consoles[i];
        controls[i] = try std.testing.allocator.alloc(u16, frames);
        try runner.parse_script(std.testing.allocator, json, controls[i]);
    }
    defer for (0..n) |i| std.testing.allocator.free(controls[i]);
    bus.init(cfg, ptrs[0..n]);
    defer bus.deinit();
    const stagger = 7;
    for (0..n) |i| bus.power_on_at(i, @intCast(stagger * i));
    var out: Outcome = .{};
    var pads: [4]u16 = @splat(0);
    for (0..frames) |u| {
        for (0..n) |i| {
            const k = stagger * i;
            if (u < k) continue;
            pads[i] = fes[i].update(controls[i][u - k]) orelse 0;
        }
        bus.step_frame(pads[0..n]);
        if (u % 30 != 0) continue;
        for (0..n) |i| {
            const g = players_glyph(&consoles[i]);
            if (g != 0) out.glyph[i] = g;
            if (out.cockpit_at[i] == null and cockpit(&consoles[i])) out.cockpit_at[i] = @intCast(u);
        }
    }
    return out;
}

fn check(n: usize, o: Outcome, want_glyph: u32) !void {
    for (0..n) |i| {
        try std.testing.expectEqual(want_glyph, o.glyph[i]);
        try expect(o.cockpit_at[i] != null);
    }
}

test "comlynx: Warbirds (local dump) finds 2 and 4 players and starts the networked game" {
    // Glyph pixel counts of the title's digit (2, 3, 4), from these runs.
    const glyph2 = try play(2, .{ .mode = .wire }, 1000);
    std.debug.print("\nwarbirds: 2 consoles, wire: glyph {d} {d}, cockpit at {?d} {?d}\n", .{ glyph2.glyph[0], glyph2.glyph[1], glyph2.cockpit_at[0], glyph2.cockpit_at[1] });
    try check(2, glyph2, glyph2.glyph[0]);
    const g2 = glyph2.glyph[0];
    try expect(g2 != 0);
    // Over the relay model with 16 ms one way, the echo local (docs/COMLYNX.md).
    const relay2 = try play(2, .{ .mode = .relay, .latency = 16 * 16_000, .batch = .burst, .echo = .local }, 1200);
    try check(2, relay2, g2);
    const four = try play(4, .{ .mode = .wire }, 1000);
    std.debug.print("warbirds: 4 consoles, wire: glyph {d} {d} {d} {d}, cockpit at {?d} {?d} {?d} {?d}\n", .{
        four.glyph[0], four.glyph[1], four.glyph[2], four.glyph[3], four.cockpit_at[0], four.cockpit_at[1], four.cockpit_at[2], four.cockpit_at[3],
    });
    try expect(four.glyph[0] != g2);
    try check(4, four, four.glyph[0]);
    // The echo through the bus (lobby self-echo) at 1 ms: Warbirds never
    // sees its own frame in time and plays alone (the finding the
    // transport requirements rest on).
    const echoed = try play(2, .{ .mode = .relay, .latency = 16_000, .batch = .slice }, 1000);
    try expect(echoed.cockpit_at[0] == null or echoed.cockpit_at[1] == null or echoed.glyph[0] != g2);
}
