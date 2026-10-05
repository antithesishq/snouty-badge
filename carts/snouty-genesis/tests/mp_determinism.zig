//! Lockstep determinism (docs/MULTIPLAYER.md "Determinism"): the console
//! state after a frame must be a function of the state before it and of
//! the frame's pads only. Two consoles run the same ROM with the same
//! multi-pad script but with everything else a badge may do differently:
//! memory filled with different garbage before `init_in_place`, the ROM
//! contiguous on one and scattered over 512-byte drive clusters on the
//! other, one rendering every second frame in squeeze/sharp and the other
//! every frame in crop/Smooth H40, a poll hook on one only. With
//! `setup.lockstep` set, `Md.state_hash` must agree after every frame.
//!
//! ROMs: the shipped test ROM and Miniplanets (always), Sonic 1
//! (`~/roms/genesis/sonic1.bin`) and Mega Bomberman
//! (`tests/roms/genesis/MegaBomberman.md` or `~/roms/genesis/`), local
//! only, skipped when absent. Never committed.
const std = @import("std");
const core = @import("core");
const Md = core.Md;
const Pads = core.Pads;
const expectEqual = std.testing.expectEqual;

/// Pad `i`'s word at `frame`: a fixed pseudo-random 3-button pad per
/// player, held for 8 frames at a time, with Start pressed now and then
/// (so menus advance).
pub fn script_pad(frame: u32, i: u32) u16 {
    var x: u32 = (frame / 8) *% 0x9E3779B1 ^ (i + 1) *% 0x85EBCA6B;
    x ^= x >> 15;
    x *%= 0x2C1B3C6D;
    x ^= x >> 12;
    var p: u16 = @truncate(x & 0x7F);
    // Not both Up and Down, nor both Left and Right.
    if (p & 3 == 3) p &= ~@as(u16, 2);
    if (p & 12 == 12) p &= ~@as(u16, 8);
    if ((frame / 8) % 16 == 5) p |= core.Pad.start;
    return p;
}

fn script(frame: u32) Pads {
    var p: Pads = undefined;
    for (&p, 0..) |*w, i| w.* = script_pad(frame, @intCast(i));
    return p;
}

const Sink = struct {
    rows: u32 = 0,
    fn on_line(ctx: *anyopaque, _: u8, _: [*]const u8, _: u16, _: *const [64]u16) void {
        const s: *Sink = @ptrCast(@alignCast(ctx));
        s.rows += 1;
    }
};

const Poll = struct {
    calls: u32 = 0,
    fn on_poll(ctx: *anyopaque) void {
        const p: *Poll = @ptrCast(@alignCast(ctx));
        p.calls += 1;
    }
};

/// `rom` spread over 512-byte clusters in a scattered order (every cluster
/// its own run): the drive's worst fragmentation.
const Scattered = struct {
    clusters: []u16,
    volume: []u8,

    fn init(a: std.mem.Allocator, rom: []const u8) !Scattered {
        const n = (rom.len + 511) / 512;
        const clusters = try a.alloc(u16, n);
        const volume = try a.alloc(u8, n * 512);
        @memset(volume, 0xFF);
        // A stride coprime with n scatters the clusters.
        var stride: usize = 389;
        while (std.math.gcd(stride, n) != 1) stride += 2;
        for (0..n) |k| {
            const c = (k * stride) % n;
            clusters[k] = @intCast(2 + c);
            const len = @min(512, rom.len - k * 512);
            @memcpy(volume[c * 512 ..][0..len], rom[k * 512 ..][0..len]);
        }
        return .{ .clusters = clusters, .volume = volume };
    }

    fn source(s: *const Scattered, size: usize) core.RomSource {
        return .{ .size = @intCast(size), .clusters = s.clusters, .data_base = s.volume.ptr };
    }

    fn deinit(s: *Scattered, a: std.mem.Allocator) void {
        a.free(s.clusters);
        a.free(s.volume);
    }
};

/// A console in an allocation filled with `fill` before `init_in_place`.
fn console(a: std.mem.Allocator, fill: u8, src: core.RomSource) !*Md {
    const m = try a.create(Md);
    @memset(std.mem.asBytes(m), fill);
    m.init_in_place(src);
    m.setup.lockstep = true;
    return m;
}

/// The two-console run described at the top; returns the frames checked.
pub fn run(rom: []const u8, frames: u32) !u32 {
    const a = std.testing.allocator;
    var sc = try Scattered.init(a, rom);
    defer sc.deinit(a);
    const x = try console(a, 0x00, core.RomSource.from_slice(rom));
    defer a.destroy(x);
    const y = try console(a, 0xA5, sc.source(rom.len));
    defer a.destroy(y);
    try expectEqual(x.setup.cfg, y.setup.cfg);
    try expectEqual(x.state_hash(), y.state_hash());

    var sx: Sink = .{};
    var sy: Sink = .{};
    var poll: Poll = .{};
    x.line_sink = .{ .ctx = &sx, .func = &Sink.on_line };
    y.line_sink = .{ .ctx = &sy, .func = &Sink.on_line };
    y.vdp.line_mode = .crop;
    y.vdp.h_mode = .smooth;
    y.setup.poll_hook = .{ .ctx = &poll, .func = &Poll.on_poll };

    var f: u32 = 0;
    while (f < frames) : (f += 1) {
        const p = script(f);
        x.step_frame_pads(&p, f % 2 == 1);
        y.step_frame_pads(&p, true);
        const hx = x.state_hash();
        const hy = y.state_hash();
        if (hx != hy) {
            std.debug.print("\nmp-determinism: state hashes differ after frame {d}\n", .{f});
            return error.TestExpectedEqual;
        }
    }
    try expectEqual(@as(u32, frames * 5), poll.calls);
    try std.testing.expect(sy.rows > sx.rows);
    return frames;
}

const prefixes = [_][]const u8{ "", "carts/snouty-genesis/", "../", "../../" };

/// A ROM from the cart's directory (`rel`) or `~/roms/genesis/<home>`.
pub fn load(a: std.mem.Allocator, rel: []const u8, home: ?[]const u8) ?[]u8 {
    var buf: [512]u8 = undefined;
    for (prefixes) |pre| {
        const path = std.fmt.bufPrint(&buf, "{s}{s}", .{ pre, rel }) catch continue;
        if (std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(4 << 20))) |d| return d else |_| {}
    }
    const name = home orelse return null;
    const h = std.testing.environ.getPosix("HOME") orelse return null;
    const path = std.fmt.bufPrint(&buf, "{s}/roms/genesis/{s}", .{ h, name }) catch return null;
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(4 << 20)) catch null;
}

fn check(rel: []const u8, home: ?[]const u8, frames: u32) !void {
    const a = std.testing.allocator;
    const rom = load(a, rel, home) orelse return error.SkipZigTest;
    defer a.free(rom);
    const n = try run(rom, frames);
    std.debug.print("\nmp-determinism: {s}: {d} frames, hashes equal every frame\n", .{ rel, n });
}

test "mp-determinism: test ROM, two differently set up consoles, 600 frames" {
    try check("roms/snouty-test.bin", null, 600);
}

test "mp-determinism: Miniplanets, 900 frames" {
    try check("roms/miniplanets.bin", null, 900);
}

test "mp-determinism: Sonic 1, 2400 frames (local ROM)" {
    try check("tests/roms/genesis/sonic1.bin", "sonic1.bin", 2400);
}

test "mp-determinism: Mega Bomberman with its Team Player, 2400 frames (local ROM)" {
    try check("tests/roms/genesis/MegaBomberman.md", "MegaBomberman.md", 2400);
}

test "mp-determinism: the state hash sees a one-byte change in each region" {
    const a = std.testing.allocator;
    const m = try a.create(Md);
    defer a.destroy(m);
    const rom = load(a, "roms/snouty-test.bin", null) orelse return error.SkipZigTest;
    defer a.free(rom);
    m.init_in_place(core.RomSource.from_slice(rom));
    var f: u32 = 0;
    while (f < 60) : (f += 1) m.step_frame(0, false);
    const h0 = m.state_hash();
    m.work_ram[0x1234] ^= 1;
    try std.testing.expect(m.state_hash() != h0);
    m.work_ram[0x1234] ^= 1;
    m.vdp.vram[0x4321] ^= 1;
    try std.testing.expect(m.state_hash() != h0);
    m.vdp.vram[0x4321] ^= 1;
    m.cpu.d[3] +%= 1;
    try std.testing.expect(m.state_hash() != h0);
    m.cpu.d[3] -%= 1;
    m.ports.pads[3] = 1;
    try std.testing.expect(m.state_hash() != h0);
    m.ports.pads[3] = 0;
    // Not state: the fetch window and the sprite cache.
    m.cpu.win_len = 0;
    m.vdp.spr_dirty = true;
    try expectEqual(h0, m.state_hash());
}

test "mp-determinism: without lockstep, rendering changes the sprite status bits (the leak lockstep closes)" {
    // Print only: whether this ROM ever reads a sticky bit the two render
    // patterns set differently. Sonic 1 has sprites in play.
    const a = std.testing.allocator;
    const rom = load(a, "tests/roms/genesis/sonic1.bin", "sonic1.bin") orelse return error.SkipZigTest;
    defer a.free(rom);
    const x = try a.create(Md);
    defer a.destroy(x);
    const y = try a.create(Md);
    defer a.destroy(y);
    x.init_in_place(core.RomSource.from_slice(rom));
    y.init_in_place(core.RomSource.from_slice(rom));
    var sx: Sink = .{};
    var sy: Sink = .{};
    x.line_sink = .{ .ctx = &sx, .func = &Sink.on_line };
    y.line_sink = .{ .ctx = &sy, .func = &Sink.on_line };
    y.vdp.line_mode = .crop;
    var diverged: ?u32 = null;
    var f: u32 = 0;
    while (f < 2400) : (f += 1) {
        const p = script(f);
        x.step_frame_pads(&p, f % 2 == 1);
        y.step_frame_pads(&p, true);
        if (diverged == null and x.state_hash() != y.state_hash()) diverged = f;
    }
    if (diverged) |d|
        std.debug.print("\nmp-determinism: lockstep off, Sonic 1: render pattern changed the state at frame {d}\n", .{d})
    else
        std.debug.print("\nmp-determinism: lockstep off, Sonic 1: no divergence in 2400 frames\n", .{});
}
