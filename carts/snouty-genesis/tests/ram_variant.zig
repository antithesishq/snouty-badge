//! Host tests of the RAM cart's core (PLAN.md M5): `core` here is built
//! with `build_options.z80 = false` and `scrub = false`, as
//! `snouty-genesis.uf2` is (the Z80 stub of core/z80bus.zig, no undo
//! hooks), and `rom_ram` is that cart's embedded test ROM without its zero
//! padding (tools/trim_rom.zig). A test binary of its own
//! (`snouty-genesis-ram-tests`, run by `zig build test` and
//! `test-genesis`), since a module is built once per binary. The full
//! core's tests (tests/all.zig) and goldens are untouched by M5.
//!
//! Golden hashes, asserted: the test ROM's M1 run (`m1_play.json`, 300
//! frames) with the stub, from the trimmed and from the full ROM (the same
//! frames), and Miniplanets' 600-frame `golden-mini` script with the stub.
//! Both pictures equal the full core's goldens: with the stub the 68000
//! and the VDP do exactly what they do with the Z80 running.
//! Miniplanets must also keep playing: its sound engine hands commands
//! over through Z80 RAM and waits for a free slot, which the stub's
//! all-zero Z80 RAM always shows (with the old plain-memory "Z80 off" mode
//! the game froze at the first level).
const std = @import("std");
const core = @import("core");
const rom = @import("rom");
const rom_ram = @import("rom_ram");
const Md = core.Md;
const Pad = core.Pad;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

comptime {
    if (core.tunables.z80_enabled) @compileError("ram_variant.zig needs the core built with build_options.z80 = false");
    if (core.undo.enabled) @compileError("ram_variant.zig needs the core built with build_options.scrub = false");
}

/// The test ROM's M1 run with the Z80 stub: frame hashes at
/// `checkpoints` (empty: print only). The same as tests/golden.zig's with
/// the Z80: the test ROM's picture does not depend on its sound driver.
const golden_hashes = [_]u64{
    0x47D4BB45A56859D8, // frame 20
    0xB84A549DDF672C51, // frame 80
    0x38DCDECF549DF3DC, // frame 140
    0x10739FD1D602DE48, // frame 170
    0xF10A37C41544CE94, // frame 186
    0x6FC6BB307FC883E7, // frame 206
    0x21AF403195CA431B, // frame 230
    0x856E31A5493A6DE7, // frame 300
};
/// Miniplanets 600 frames with the stub: the frame hash over every
/// rendered row (the same as `golden-mini`'s with the Z80, 2026-10-04) and
/// the state hash at the end (this file's `state_hash`, without the Z80;
/// 0: print only).
const golden_mini_frames: u64 = 0x246F566FF41A43A4;
const golden_mini_state: u64 = 0x1E1A9DB657441517;

test {
    _ = @import("sound_synth.zig");
    _ = @import("mp_bomberman.zig");
}

test "ram: the variant has no Z80 core, no Z80 RAM and no scrubber" {
    try expectEqual(@as(usize, 0), core.z80_ram_size);
    try expect(@sizeOf(core.Z80) <= 4);
    std.debug.print("\nram: @sizeOf(Md) = {d} B, embedded test ROM {d} of {d} bytes\n", .{ @sizeOf(Md), rom_ram.data.len, rom.data.len });
}

test "ram: the trimmed test ROM is the full one less zero padding" {
    const full = rom.data;
    const cut = rom_ram.data;
    try expect(cut.len <= full.len);
    try expect(cut.len % 2 == 0);
    try std.testing.expectEqualSlices(u8, full[0..cut.len], cut);
    for (full[cut.len..]) |b| try expectEqual(@as(u8, 0), b);
    const src = core.RomSource.from_slice(cut);
    try expectEqual(core.rom.Refusal.ok, core.rom.check(&src));
}

// ---- The stub as the 68000 sees it ----

var tiny_rom: [0x400]u8 = undefined;

/// SSP FFFE00, PC 000200, `bra.s *` there.
fn make_rom(buf: []u8) void {
    @memset(buf, 0);
    std.mem.writeInt(u32, buf[0..4], 0x00FFFE00, .big);
    std.mem.writeInt(u32, buf[4..8], 0x00000200, .big);
    @memcpy(buf[0x100..][0..16], "SEGA GENESIS    ");
    buf[0x200] = 0x60;
    buf[0x201] = 0xFE;
}

test "ram: BUSREQ and RESET answer as on hardware, Z80 RAM reads 0" {
    make_rom(&tiny_rom);
    const md = try std.testing.allocator.create(Md);
    defer std.testing.allocator.destroy(md);
    md.init_in_place(core.RomSource.from_slice(&tiny_rom));
    var b = md.bus_for();
    // Power on: the Z80 owns its bus (BUSACK reads 1) and is held in reset.
    try expect(md.arbiter.z80_reset);
    try expectEqual(@as(u8, 1), b.read8(0xA11100) & 1);
    // The usual driver upload: request, wait for the grant, reset, copy,
    // release.
    b.write16(0xA11100, 0x0100);
    try expect(md.arbiter.busreq);
    try expectEqual(@as(u8, 0), b.read8(0xA11100) & 1);
    try expectEqual(@as(u16, 0), b.read16(0xA11100) & 0x100);
    b.write16(0xA11200, 0x0000);
    try expect(md.arbiter.z80_reset);
    for (0..64) |i| b.write8(@intCast(0xA00000 + i), @truncate(i + 1));
    b.write16(0xA11200, 0x0100);
    try expect(!md.arbiter.z80_reset);
    // Z80 RAM keeps nothing: every byte reads 0, as a command slot does
    // once the driver has taken the command (word reads too).
    try expectEqual(@as(u8, 0), b.read8(0xA00000));
    try expectEqual(@as(u8, 0), b.read8(0xA01FFF));
    try expectEqual(@as(u8, 0), b.read8(0xA02000));
    try expectEqual(@as(u16, 0), b.read16(0xA01FF4));
    // The bank window is not reachable from the 68000.
    try expectEqual(@as(u8, 0xFF), b.read8(0xA08000));
    // YM2612 at A04000: the status byte, never busy; timer A overflows
    // and its flag shows (the register model and timers are kept).
    try expectEqual(@as(u8, 0), b.read8(0xA04000) & 0x80);
    b.write8(0xA04000, 0x24);
    b.write8(0xA04001, 0xFF);
    b.write8(0xA04000, 0x25);
    b.write8(0xA04001, 0x03);
    b.write8(0xA04000, 0x27);
    b.write8(0xA04001, 0x05); // load and enable timer A
    b.write16(0xA11100, 0x0000);
    md.step_frame(0, false);
    b.write16(0xA11100, 0x0100);
    try expectEqual(@as(u8, 1), b.read8(0xA04000) & 0x81);
    // The bank register at A06000 takes its nine shifted bits.
    for (0..9) |_| b.write8(0xA06000, 1);
    try expectEqual(@as(u16, 0x1FF), md.z80_bank);
    // Release: the Z80 would run, the stub does not.
    b.write8(0xA11100, 0x00);
    try expectEqual(@as(u8, 1), b.read8(0xA11100) & 1);
    md.step_frame(0, false);
    try expectEqual(@as(u16, 0), md.z80.pc);
    try expectEqual(@as(?core.Tone, null), md.tone());
}

// ---- Golden runs ----

const Hasher = struct {
    rows: u32 = 0,
    /// Over every row since `init`.
    hash: u64 = 0,
    /// Over the rows since the caller last zeroed it.
    frame: u64 = 0,

    fn on_line(ctx: *anyopaque, row: u8, line: [*]const u8, width: u16, cram: *const [64]u16) void {
        const h: *Hasher = @ptrCast(@alignCast(ctx));
        h.rows += 1;
        var w = std.hash.Wyhash.init(h.hash);
        w.update(&.{row});
        w.update(line[0..width]);
        w.update(std.mem.sliceAsBytes(cram));
        h.hash = w.final();
        var v = std.hash.Wyhash.init(h.frame);
        v.update(&.{row});
        v.update(line[0..width]);
        v.update(std.mem.sliceAsBytes(cram));
        h.frame = v.final();
    }

    fn sink(h: *Hasher) core.LineSink {
        return .{ .ctx = h, .func = &on_line };
    }
};

const prefixes = [_][]const u8{ "", "carts/snouty-genesis/", "../", "../../" };

fn read_any(rel: []const u8, buf: []u8) ?[]u8 {
    for (prefixes) |pre| {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}{s}", .{ pre, rel }) catch continue;
        return std.Io.Dir.cwd().readFile(std.testing.io, path, buf) catch continue;
    }
    return null;
}

/// tests/golden.zig's run: 300 frames, 60/30, the checkpoints it checks.
const frames = 300;
const per_update = 2;
const updates = frames / per_update;
const checkpoints = [_]u32{ 20, 80, 140, 170, 186, 206, 230, 300 };
const tap_updates = 2;

const Hold = struct { from: u32, to: u32, hold: []const []const u8 };

fn button(name: []const u8) !u16 {
    const map = [_]struct { []const u8, u16 }{
        .{ "UP", Pad.up },       .{ "DOWN", Pad.down }, .{ "LEFT", Pad.left },
        .{ "RIGHT", Pad.right }, .{ "B", Pad.b },       .{ "A", Pad.c },
        .{ "START", Pad.start },
    };
    for (map) |m| if (std.mem.eql(u8, m[0], name)) return m[1];
    return error.UnknownButton;
}

/// Pad word per badge update from a preview/badge-bench script (as
/// tests/golden.zig reads it: a short Select hold is a Genesis A tap).
fn script_pads(json: []const u8, pads: *[updates]u16) !void {
    const parsed = try std.json.parseFromSlice([]const Hold, std.testing.allocator, json, .{});
    defer parsed.deinit();
    @memset(pads, 0);
    for (parsed.value) |h| {
        var bits: u16 = 0;
        var select = false;
        for (h.hold) |name| {
            if (std.mem.eql(u8, name, "SELECT")) select = true else bits |= try button(name);
        }
        var u = h.from;
        while (u <= h.to and u < updates) : (u += 1) pads[u] |= bits;
        if (select and h.to - h.from + 1 < 15) {
            u = h.to + 1;
            while (u <= h.to + tap_updates and u < updates) : (u += 1) pads[u] |= Pad.a;
        }
    }
}

var script_buf: [0x4000]u8 = undefined;

/// The M1 run of `data`: the frame hash at each checkpoint.
fn test_rom_run(data: []const u8, pads: *const [updates]u16) ![checkpoints.len]u64 {
    const md = try std.testing.allocator.create(Md);
    defer std.testing.allocator.destroy(md);
    md.init_in_place(core.RomSource.from_slice(data));
    var h: Hasher = .{};
    md.line_sink = h.sink();
    var out: [checkpoints.len]u64 = undefined;
    var u: u32 = 0;
    while (u < updates) : (u += 1) {
        h = .{};
        var f: u32 = 0;
        while (f < per_update) : (f += 1) md.step_frame(pads[u], f == per_update - 1);
        try expectEqual(@as(u32, core.out_h), h.rows);
        var w = std.hash.Wyhash.init(h.hash);
        w.update(std.mem.sliceAsBytes(&md.vdp.cram));
        for (checkpoints, 0..) |c, i| if (c / per_update - 1 == u) {
            out[i] = w.final();
        };
    }
    return out;
}

test "ram: test ROM golden run with the Z80 stub, trimmed and full alike" {
    var pads: [updates]u16 = undefined;
    const json = read_any("tools/scripts/m1_play.json", &script_buf) orelse return error.SkipZigTest;
    try script_pads(json, &pads);
    const trimmed = try test_rom_run(rom_ram.data, &pads);
    const full = try test_rom_run(rom.data, &pads);
    try std.testing.expectEqualSlices(u64, &full, &trimmed);
    if (golden_hashes.len == 0) {
        std.debug.print("\nram-golden: test ROM, stubbed Z80, frame hashes:\n", .{});
        for (checkpoints, trimmed) |c, g| std.debug.print("    0x{X:0>16}, // frame {d}\n", .{ g, c });
    } else {
        try std.testing.expectEqualSlices(u64, &golden_hashes, &trimmed);
    }
}

/// tests/golden_mini.zig's input: Start through the title and the menus,
/// then a walk.
fn mini_pad_at(u: u32) u16 {
    var p: u16 = 0;
    if ((u >= 100 and u <= 102) or (u >= 130 and u <= 132)) p |= Pad.start;
    if (u >= 180 and u <= 220) p |= Pad.right;
    if (u >= 200 and u <= 205) p |= Pad.b;
    if (u >= 225 and u <= 260) p |= Pad.left | Pad.c;
    if (u >= 265) p |= Pad.up;
    return p;
}

var mini_buf: [0x80000]u8 = undefined;

fn state_hash(md: *const Md) u64 {
    var w = std.hash.Wyhash.init(0);
    w.update(&md.work_ram);
    w.update(&md.vdp.vram);
    w.update(std.mem.sliceAsBytes(&md.vdp.cram));
    w.update(std.mem.sliceAsBytes(&md.vdp.vsram));
    w.update(&md.vdp.regs);
    w.update(std.mem.sliceAsBytes(&md.cpu.d));
    w.update(std.mem.sliceAsBytes(&md.cpu.a));
    const c = md.cpu;
    const words = [_]u32{
        c.pc,         c.get_sr(),     c.other_sp,    @intFromBool(c.stopped),
        md.z80_bank,  md.frame_count, md.m68k_carry, md.vdp.line,
        md.dma_stall,
    };
    w.update(std.mem.sliceAsBytes(&words));
    return w.final();
}

test "ram: Miniplanets 600 frames with the Z80 stub keep playing" {
    const data = read_any("roms/miniplanets.bin", &mini_buf) orelse return error.SkipZigTest;
    const md = try std.testing.allocator.create(Md);
    defer std.testing.allocator.destroy(md);
    md.init_in_place(core.RomSource.from_slice(data));
    var h: Hasher = .{};
    md.line_sink = h.sink();
    // Picture changes over the last 35 updates (Up held: the planet turns
    // under the walker); a frozen game repeats one frame.
    var last: u64 = 0;
    var changes: u32 = 0;
    const per = 2;
    var u: u32 = 0;
    while (u < 300) : (u += 1) {
        h.frame = 0;
        var f: u32 = 0;
        while (f < per) : (f += 1) md.step_frame(mini_pad_at(u), f == per - 1);
        if (u >= 265 and h.frame != last) changes += 1;
        last = h.frame;
    }
    try expectEqual(@as(u32, 300 * core.out_h), h.rows);
    std.debug.print("\nram-golden-mini: {d} of 35 updates in play changed the picture\n", .{changes});
    try expect(changes >= 20);
    const st = state_hash(md);
    if (golden_mini_frames == 0) {
        std.debug.print("\nram-golden-mini: frames 0x{X:0>16}, state 0x{X:0>16}, 68000 pc {X:0>6}\n", .{ h.hash, st, md.cpu.pc });
    } else {
        try expectEqual(golden_mini_frames, h.hash);
        try expectEqual(golden_mini_state, st);
    }
}
