//! The Sonic 1 DAC fake (core/s1dac.zig, PLAN.md "Sonic 1 DAC fake"):
//! the RAM cart's core built with `build_options.s1dac` and the trace probe
//! (`snouty-genesis-s1dac-tests`). It runs every RAM-cart test too
//! (tests/ram_variant.zig: the goldens of the test ROM and Miniplanets, the
//! synthesis, link play), which the fake must leave alone, then its own,
//! named `s1dac:`, on a synthetic ROM that passes the detection and a
//! made-up driver image in Z80 RAM (not Sonic 1's data): detection, the
//! Z80 RAM, the handshake, the DPCM values and spacing, a cut, the SEGA
//! path, BUSREQ pauses, and that the console state never depends on the
//! rendering. The last test runs Sonic 1 itself from
//! `~/roms/genesis/sonic1.bin` (local only, never in the repository) and
//! skips without it.
const std = @import("std");
const core = @import("core");
const Md = core.Md;
const s1dac = core.s1dac;
const sound = core.sound;
const probe = core.probe;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

comptime {
    if (!s1dac.enabled or !probe.enabled) @compileError("s1dac_unit.zig needs the core built with build_options.s1dac and probe");
}

test {
    _ = @import("ram_variant.zig");
}

// ---- A synthetic Sonic 1 ----

var rom_buf: [0x80000]u8 = undefined;

const serial01 = "GM 00004049-01";
const serial00 = "GM 00001009-00";

/// 512 KB: SSP FFFE00, PC 000200 with `bra.s *` there, the header serial
/// and checksum word, the three `$A01FFF` writers at their addresses (what
/// `s1dac.detect` checks), and a ramp at the top for the SEGA path.
fn make_rom(serial: []const u8, sum: u16) void {
    const b = &rom_buf;
    @memset(b, 0);
    std.mem.writeInt(u32, b[0..4], 0x00FFFE00, .big);
    std.mem.writeInt(u32, b[4..8], 0x00000200, .big);
    @memcpy(b[0x100..][0..16], "SEGA MEGA DRIVE ");
    @memcpy(b[0x180..][0..14], serial);
    std.mem.writeInt(u16, b[0x18E..][0..2], sum, .big);
    b[0x200] = 0x60;
    b[0x201] = 0xFE;
    put_words(0x71CA4, &.{ 0x13C0, 0x00A0, 0x1FFF });
    put_words(0x71CB4, &.{ 0x13C0, 0x00A0, 0x00EA, 0x13FC, 0x0083, 0x00A0, 0x1FFF });
    put_words(0x71FAC, &.{ 0x13FC, 0x0088, 0x00A0, 0x1FFF });
    for (0x7FC00..0x80000) |i| b[i] = @truncate(i *% 7);
}

fn put_words(at: usize, words: []const u16) void {
    for (words, 0..) |w, i| std.mem.writeInt(u16, rom_buf[at + 2 * i ..][0..2], w, .big);
}

// ---- A made-up driver image (Z80 RAM) ----

const deltas = [16]u8{ 0x00, 0x03, 0x07, 0x0B, 0x10, 0x15, 0x21, 0x31, 0x81, 0xFD, 0xF9, 0xF5, 0xF0, 0xEB, 0xDF, 0xCF };

/// The DPCM entries: id $81 short, $82 shorter at count 1, $83 long.
const Entry = struct { ptr: u16, len: u16, count: u8 };
const entries = [3]Entry{
    .{ .ptr = 0x0400, .len = 4, .count = 0x10 },
    .{ .ptr = 0x0500, .len = 3, .count = 1 },
    .{ .ptr = 0x0600, .len = 200, .count = 0x40 },
};
/// SEGA: 1,024 bytes from window FC00 (ROM 0x7FC00 under the driver's
/// bank), 11 counts per sample (220 T-states).
const sega_de: u16 = 0xFC00;
const sega_len: u16 = 0x400;
const sega_b: u8 = 11;

fn sample_byte(e: usize, i: usize) u8 {
    return @truncate(0x1F + 0x35 * e + 0x47 * i);
}

const Rig = struct {
    md: Md,
    snd: sound.Sound,
    buf: [sound.max_samples]u8,
};

/// A console on the synthetic Sonic 1, rendering (or not), after the
/// game's boot sequence: bus requested, RESET released, the driver image
/// written through the bus, RESET pulsed, the bus released.
fn rig(render: bool) !*Rig {
    make_rom(serial01, 0xAFC7);
    const r = try std.testing.allocator.create(Rig);
    r.md.init_in_place(core.RomSource.from_slice(&rom_buf));
    r.snd.init();
    r.md.snd = &r.snd;
    r.snd.set_render(&r.md, render);
    var b = r.md.bus_for();
    b.write16(0xA11100, 0x0100);
    b.write16(0xA11200, 0x0100);
    for (deltas, 0..) |d, i| b.write8(@intCast(0xA00022 + i), d);
    for (entries, 0..) |e, k| {
        const at: u24 = @intCast(0xA000D6 + 8 * k);
        b.write8(at, @truncate(e.ptr));
        b.write8(at + 1, @truncate(e.ptr >> 8));
        b.write8(at + 2, @truncate(e.len));
        b.write8(at + 3, @truncate(e.len >> 8));
        b.write8(at + 4, e.count);
        for (0..e.len) |i| b.write8(@intCast(0xA00000 + @as(u32, e.ptr) + i), sample_byte(k, i));
    }
    b.write8(0xA000BA, @truncate(sega_de));
    b.write8(0xA000BB, @truncate(sega_de >> 8));
    b.write8(0xA000BD, @truncate(sega_len));
    b.write8(0xA000BE, @truncate(sega_len >> 8));
    b.write8(0xA000C9, sega_b);
    b.write16(0xA11200, 0x0000);
    b.write16(0xA11200, 0x0100);
    b.write16(0xA11100, 0x0000);
    return r;
}

/// The values a DPCM entry plays.
fn decode(k: usize, out: []u8) []u8 {
    var acc: u8 = 0x80;
    var n: usize = 0;
    for (0..entries[k].len) |i| {
        const b = sample_byte(k, i);
        for ([2]u8{ b >> 4, b & 0xF }) |nib| {
            acc +%= deltas[nib];
            out[n] = acc;
            n += 1;
        }
    }
    return out[0..n];
}

// ---- The probe: every DAC write and take, in Z80 T-states ----

const Ev = struct { t: f64, v: u8, take: bool };
var evs: [200000]Ev = undefined;
var n_evs: usize = 0;

/// Master clocks per frame.
const frame_mclk: f64 = 262 * 3420;

fn on_event(ev: probe.Event, frame: u32, t: u32, a: u32, v: u32) void {
    _ = a;
    const take = switch (ev) {
        .fake_dac => false,
        .fake_take => true,
        else => return,
    };
    if (n_evs == evs.len) return;
    evs[n_evs] = .{ .t = (@as(f64, @floatFromInt(frame)) * frame_mclk + @as(f64, @floatFromInt(t))) / 15.0, .v = @truncate(v), .take = take };
    n_evs += 1;
}

fn start_probe() void {
    n_evs = 0;
    probe.hook = &on_event;
}

/// The console's time now in T-states (the 68000's position, as the
/// fake sees a write).
fn now_t(md: *const Md) f64 {
    return (@as(f64, @floatFromInt(md.frame_count)) * frame_mclk + @as(f64, @floatFromInt(sound.now(md)))) / 15.0;
}

fn frames(r: *Rig, n: u32) void {
    for (0..n) |_| {
        r.snd.begin_update(&r.buf);
        r.md.step_frame(0, false);
        _ = r.snd.take();
    }
}

/// Send a command as the SMPS does: bus requested, `$1FFF`, released.
/// Returns the release time.
fn send(r: *Rig, id: u8) f64 {
    var b = r.md.bus_for();
    b.write16(0xA11100, 0x0100);
    b.write8(0xA01FFF, id);
    const t = now_t(&r.md);
    b.write16(0xA11100, 0x0000);
    return t;
}

/// The DAC writes after the `nth` take (0-based): up to the next take.
fn run_of(nth: usize) []const Ev {
    var seen: usize = 0;
    var i: usize = 0;
    while (i < n_evs) : (i += 1) {
        if (!evs[i].take) continue;
        if (seen == nth) {
            var j = i + 1;
            while (j < n_evs and !evs[j].take) j += 1;
            return evs[i + 1 .. j];
        }
        seen += 1;
    }
    return evs[0..0];
}

fn near(got: f64, want: f64, tol: f64) !void {
    if (@abs(got - want) > tol) {
        std.debug.print("\n  got {d:.1}, want {d:.1} +- {d}\n", .{ got, want, tol });
        return error.TestExpectedApproxEq;
    }
}

// ---- Tests ----

test "s1dac: detection needs REV01's header, its checksum and the 68000 code" {
    const md = try std.testing.allocator.create(Md);
    defer std.testing.allocator.destroy(md);
    make_rom(serial01, 0xAFC7);
    md.init_in_place(core.RomSource.from_slice(&rom_buf));
    try expect(md.s1dac_on);
    // REV00 (never run against the oracle), a wrong checksum, the serial
    // and checksum of different revisions, one code word changed, too
    // short: off.
    make_rom(serial00, 0x264A);
    md.init_in_place(core.RomSource.from_slice(&rom_buf));
    try expect(!md.s1dac_on);
    make_rom(serial01, 0xAFC6);
    md.init_in_place(core.RomSource.from_slice(&rom_buf));
    try expect(!md.s1dac_on);
    make_rom(serial01, 0x264A);
    md.init_in_place(core.RomSource.from_slice(&rom_buf));
    try expect(!md.s1dac_on);
    make_rom(serial01, 0xAFC7);
    put_words(0x71FAE, &.{0x0089});
    md.init_in_place(core.RomSource.from_slice(&rom_buf));
    try expect(!md.s1dac_on);
    make_rom(serial01, 0xAFC7);
    md.init_in_place(core.RomSource.from_slice(rom_buf[0..0x7FFFE]));
    try expect(!md.s1dac_on);
    // Off, Z80 RAM is the stub's: writes dropped, reads 0.
    var b = md.bus_for();
    b.write8(0xA01234, 0x56);
    try expectEqual(@as(u8, 0), b.read8(0xA01234));
}

test "s1dac: Z80 RAM keeps the 68000's writes, mirrored at 2000" {
    const r = try rig(false);
    defer std.testing.allocator.destroy(r);
    var b = r.md.bus_for();
    b.write8(0xA01234, 0x56);
    try expectEqual(@as(u8, 0x56), b.read8(0xA01234));
    try expectEqual(@as(u8, 0x56), b.read8(0xA03234));
    try expectEqual(@as(u16, 0x5656), b.read16(0xA01234));
    try expectEqual(@as(u8, 0x07), b.read8(0xA00023 + 1));
    // The YM2612 and the bank window are as before.
    try expectEqual(@as(u8, 0), b.read8(0xA04000) & 0x80);
    try expectEqual(@as(u8, 0xFF), b.read8(0xA08000));
}

test "s1dac: a Z80 RESET runs the driver's init" {
    const r = try rig(false);
    defer std.testing.allocator.destroy(r);
    var b = r.md.bus_for();
    b.write16(0xA11100, 0x0100);
    b.write8(0xA01FFD, 0x99);
    b.write8(0xA01FFF, 0x55);
    for (0..9) |_| b.write8(0xA06000, 0);
    try expectEqual(@as(u8, 0x55), b.read8(0xA01FFF));
    // Done at the assertion (on hardware the Z80 runs it after the
    // release; Sonic 1 writes nothing in between).
    b.write16(0xA11200, 0x0000);
    try expectEqual(@as(u8, 0), b.read8(0xA01FFD));
    try expectEqual(@as(u8, 0), b.read8(0xA01FFF));
    try expectEqual(@as(u16, 0x00F), r.md.z80_bank);
    b.write16(0xA11200, 0x0100);
    try expectEqual(@as(u8, 0), b.read8(0xA01FFF));
}

test "s1dac: a command is taken when the Z80 runs, as the driver takes it" {
    const r = try rig(false);
    defer std.testing.allocator.destroy(r);
    var b = r.md.bus_for();
    b.write16(0xA11100, 0x0100);
    b.write8(0xA01FFF, 0x81);
    // The bus is held: the Z80 has not seen it.
    try expectEqual(@as(u8, 0x81), b.read8(0xA01FFF));
    try expect(!r.md.ym.dac_enabled());
    b.write16(0xA11100, 0x0000);
    b.write16(0xA11100, 0x0100);
    try expectEqual(@as(u8, 0x00), b.read8(0xA01FFF));
    try expectEqual(@as(u8, 0x1F), b.read8(0xA01FFD));
    try expect(r.md.ym.dac_enabled());
    try expectEqual(@as(u8, 0x2A), r.md.ym.addr[0]);
    // SEGA ($88): id - $81, 2B and the busy flag left alone.
    r.md.ym.write_addr(0, 0x2B);
    r.md.ym.write_data(0, 0);
    b.write8(0xA01FFD, 0);
    b.write8(0xA01FFF, 0x88);
    b.write16(0xA11100, 0x0000);
    try expectEqual(@as(u8, 0x07), b.read8(0xA01FFF));
    try expectEqual(@as(u8, 0), b.read8(0xA01FFD));
    try expect(!r.md.ym.dac_enabled());
    // Bit 7 clear: not a command. Written while the Z80 runs: taken at once.
    b.write8(0xA01FFF, 0x42);
    try expectEqual(@as(u8, 0x42), b.read8(0xA01FFF));
    b.write8(0xA01FFF, 0x82);
    try expectEqual(@as(u8, 0x01), b.read8(0xA01FFF));
}

test "s1dac: DPCM values and write spacing" {
    const r = try rig(true);
    defer std.testing.allocator.destroy(r);
    start_probe();
    defer probe.hook = null;
    frames(r, 1);
    const t0 = send(r, 0x81);
    frames(r, 1);
    const t1 = send(r, 0x82);
    frames(r, 2);
    var want: [512]u8 = undefined;
    for ([2]f64{ t0, t1 }, 0..) |tc, k| {
        const run = run_of(k);
        const exp = decode(k, &want);
        try expectEqual(exp.len, run.len);
        for (run, exp) |e, v| try expectEqual(v, e.v);
        // First write: the poll's average wait and the 398 T-states to it,
        // within one output sample (81 T-states) of the command.
        try near(run[0].t - tc, 10 + 398, 82);
        const c: f64 = @floatFromInt(entries[k].count);
        for (run[0 .. run.len - 1], run[1..], 0..) |a, b, i| {
            try near(b.t - a.t, if (i % 2 == 0) 99 + 13 * c else 176 + 13 * c, 2);
        }
    }
}

test "s1dac: a new command cuts a sample after the byte's low nibble" {
    const r = try rig(true);
    defer std.testing.allocator.destroy(r);
    start_probe();
    defer probe.hook = null;
    frames(r, 1);
    _ = send(r, 0x83);
    frames(r, 2);
    _ = send(r, 0x81);
    frames(r, 1);
    const long = run_of(0);
    const short = run_of(1);
    try expect(long.len < 2 * entries[2].len);
    try expect(long.len % 2 == 0);
    try expectEqual(@as(usize, 2 * entries[0].len), short.len);
    // The check (29 + 13c after the low nibble), then 41 + 398 to the
    // first write of the new sample.
    const c: f64 = @floatFromInt(entries[2].count);
    try near(short[0].t - long[long.len - 1].t, 29 + 13 * c + 41 + 398, 2);
}

test "s1dac: a command during a sample's start waits for its first byte" {
    const r = try rig(true);
    defer std.testing.allocator.destroy(r);
    start_probe();
    defer probe.hook = null;
    frames(r, 1);
    // Two commands at the same moment: the second arrives while the first
    // is still starting (408 T-states), so the first plays one byte.
    _ = send(r, 0x83);
    _ = send(r, 0x81);
    frames(r, 2);
    const first = run_of(0);
    const second = run_of(1);
    try expectEqual(@as(usize, 2), first.len);
    try expectEqual(@as(usize, 2 * entries[0].len), second.len);
    const c: f64 = @floatFromInt(entries[2].count);
    try near(second[0].t - first[1].t, 29 + 13 * c + 41 + 398, 2);
}

test "s1dac: SEGA plays the bank window to the end, never cut" {
    const r = try rig(true);
    defer std.testing.allocator.destroy(r);
    start_probe();
    defer probe.hook = null;
    frames(r, 1);
    const t0 = send(r, 0x88);
    frames(r, 1);
    _ = send(r, 0x81);
    frames(r, 4);
    const sega = run_of(0);
    try expectEqual(@as(usize, sega_len), sega.len);
    for (sega, 0..) |e, i| try expectEqual(rom_buf[0x78000 + @as(usize, sega_de) - 0x8000 + i], e.v);
    try near(sega[0].t - t0, 10 + 107, 82);
    for (sega[0 .. sega.len - 1], sega[1..]) |a, b| try near(b.t - a.t, 77 + 13 * @as(f64, sega_b), 2);
    // The waiting kick starts once the chant is over.
    const kick = run_of(1);
    try expectEqual(@as(usize, 2 * entries[0].len), kick.len);
    try near(kick[0].t - sega[sega.len - 1].t, 214 + 398, 2);
}

test "s1dac: the DAC stops while the 68000 holds the bus" {
    const r = try rig(true);
    defer std.testing.allocator.destroy(r);
    start_probe();
    defer probe.hook = null;
    frames(r, 1);
    _ = send(r, 0x83);
    frames(r, 1);
    var b = r.md.bus_for();
    b.write16(0xA11100, 0x0100);
    const held = now_t(&r.md);
    frames(r, 1);
    const freed = now_t(&r.md);
    b.write16(0xA11100, 0x0000);
    frames(r, 7);
    const run = run_of(0);
    try expectEqual(@as(usize, 2 * entries[2].len), run.len);
    // Every spacing is the driver's but one, which also spans the hold.
    const c: f64 = @floatFromInt(entries[2].count);
    var longest: f64 = 0;
    for (run[0 .. run.len - 1], run[1..], 0..) |x, y, i| {
        const d = y.t - x.t;
        const normal = if (i % 2 == 0) 99 + 13 * c else 176 + 13 * c;
        if (d > normal + 2) {
            try expectEqual(@as(f64, 0), longest);
            longest = d - normal;
        }
    }
    try near(longest, freed - held, 82);
}

test "s1dac: the console state does not depend on the rendering" {
    var hashes: [2]u32 = undefined;
    for ([2]bool{ true, false }, &hashes) |render, *h| {
        const r = try rig(render);
        defer std.testing.allocator.destroy(r);
        frames(r, 1);
        _ = send(r, 0x83);
        frames(r, 1);
        _ = send(r, 0x88);
        frames(r, 2);
        _ = send(r, 0x81);
        frames(r, 3);
        h.* = r.md.state_hash();
    }
    try expectEqual(hashes[0], hashes[1]);
}

var sonic_buf: [0x80000]u8 = undefined;

test "s1dac: Sonic 1's SEGA chant and drums" {
    // `~/roms/genesis/sonic1.bin` (local only, never in the repository),
    // skipped when missing. What it plays is checked against the ROM and
    // the driver the game uploaded, read here at run time.
    const home = std.testing.environ.getPosix("HOME") orelse return error.SkipZigTest;
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/roms/genesis/sonic1.bin", .{home});
    const rom = std.Io.Dir.cwd().readFile(std.testing.io, path, &sonic_buf) catch return error.SkipZigTest;
    const r = try std.testing.allocator.create(Rig);
    defer std.testing.allocator.destroy(r);
    r.md.init_in_place(core.RomSource.from_slice(rom));
    if (!r.md.s1dac_on) return error.SkipZigTest; // another revision
    r.snd.init();
    r.md.snd = &r.snd;
    r.snd.set_render(&r.md, true);
    start_probe();
    defer probe.hook = null;
    // The SEGA screen and the title music (its first drums by ~420).
    for (0..700) |_| {
        r.snd.begin_update(&r.buf);
        r.md.step_frame(0, false);
        _ = r.snd.take();
    }
    // The chant: 27,000 bytes of the ROM from 0x79688, 220 T-states apart.
    const sega = run_of(0);
    try expectEqual(@as(usize, 27000), sega.len);
    for (sega, 0..) |e, i| try expectEqual(rom[0x79688 + i], e.v);
    for (sega[0 .. sega.len - 1], sega[1..]) |a, b| try near(b.t - a.t, 220, 2);
    // Then the title's drums: each one decodes from the uploaded driver's
    // table (Z80 RAM, in `md.sram`).
    var n: usize = 1;
    var drums: usize = 0;
    while (true) : (n += 1) {
        const run = run_of(n);
        if (run.len == 0) break;
        drums += 1;
    }
    try expect(drums >= 4);
    const z = &r.md.sram;
    var i: usize = 0;
    var takes: usize = 0;
    while (i < n_evs) : (i += 1) {
        if (!evs[i].take) continue;
        takes += 1;
        if (takes == 1) continue;
        // Which entry: match the first value against each.
        const run = run_of(takes - 1);
        var matched = false;
        for (0..3) |k| {
            const e = 0xD6 + 8 * k;
            const ptr = @as(u16, z[e]) | @as(u16, z[e + 1]) << 8;
            var acc: u8 = 0x80;
            var ok = true;
            for (run, 0..) |ev, j| {
                const byte = z[(ptr + j / 2) & 0x1FFF];
                acc +%= z[0x22 + (if (j % 2 == 0) byte >> 4 else byte & 0xF)];
                if (acc != ev.v) {
                    ok = false;
                    break;
                }
            }
            matched = matched or ok;
        }
        try expect(matched);
    }
}
