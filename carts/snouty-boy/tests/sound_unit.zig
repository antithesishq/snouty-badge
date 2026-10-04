//! Sample generation tests (core/apu.zig "Sample generation",
//! docs/EMU_SOUND.md at the root). Most build a `Gb` around a zeroed
//! 32 KB ROM (the CPU runs NOPs, the LCD is on, so every frame is 70,224
//! dots) and set the APU up through `gb.write8`, as a game would.
const std = @import("std");
const core = @import("core");
const Gb = core.Gb;
const apu = core.apu;
const Pad = core.Pad;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const zero_rom: [0x8000]u8 = @splat(0);

var snd_a: apu.Snd = .{};
var snd_b: apu.Snd = .{};

fn fresh(snd: *apu.Snd) Gb {
    var gb = Gb.init_slice(&zero_rom, .dmg, &.{});
    gb.snd = snd;
    apu.set_render(&gb, true);
    gb.write8(0xFF26, 0x00); // power cycle: clean registers
    gb.write8(0xFF26, 0x80);
    gb.write8(0xFF24, 0x77); // NR50: both sides at 8
    return gb;
}

/// Rising crossings of 128 over `frames` frames (one per cycle of a tone).
fn crossings(gb: *Gb, frames: u32, total: *u32) u32 {
    var n: u32 = 0;
    var prev: u8 = 128;
    total.* = 0;
    for (0..frames) |_| {
        gb.step_frame(0);
        for (apu.samples(gb)) |v| {
            if (prev < 128 and v >= 128) n += 1;
            prev = v;
        }
        total.* += gb.audio_len;
    }
    return n;
}

/// Tone frequency in Hz x 10 from crossings over `total` samples.
fn hz10(n: u32, total: u32) u32 {
    return @intCast(@as(u64, n) * 441_000 / total);
}

test "sound: frames carry the fraction, 738 or 739 samples each" {
    var gb = fresh(&snd_a);
    gb.step_frame(0); // the first frame starts mid-frame
    var total: u64 = 0;
    for (0..200) |_| {
        gb.step_frame(0);
        try expect(gb.audio_len == 738 or gb.audio_len == 739);
        total += gb.audio_len;
    }
    // 200 x 70,224 dots at 44,100 / 4,194,304 = 147,673.6 samples.
    try expect(total >= 147_669 and total <= 147_678);
    // Nothing playing: silence.
    for (apu.samples(&gb)) |v| try expectEqual(@as(u8, 128), v);
}

test "sound: square pitch from the period, 1024 Hz and 256 Hz" {
    for ([_]struct { u16, u32 }{ .{ 1920, 10240 }, .{ 1536, 2560 } }) |c| {
        var gb = fresh(&snd_a);
        gb.write8(0xFF25, 0x22); // ch2 on both sides
        gb.write8(0xFF16, 0x80); // 50% duty
        gb.write8(0xFF17, 0xF0); // volume 15, no envelope
        gb.write8(0xFF18, @truncate(c[0]));
        gb.write8(0xFF19, 0x80 | @as(u8, @intCast(c[0] >> 8)));
        _ = gb.step_frame(0);
        var total: u32 = 0;
        const n = crossings(&gb, 30, &total);
        const f = hz10(n, total);
        try expect(f + 30 >= c[1] and f <= c[1] + 30);
    }
}

test "sound: duty patterns give 1, 2, 4, 6 high steps of 8" {
    var st: apu.Sq = .{ .ctr = 10, .pos = 0 };
    for ([_]u32{ 1, 2, 4, 6 }, 0..) |high, d| {
        const pat = [4]u8{ 0x80, 0x81, 0xE1, 0x7E };
        const sp: apu.SqSpan = .{ .st = &st, .p = 10, .pat = pat[d], .vol = 3 };
        st = .{ .ctr = 10, .pos = 0 };
        // One whole cycle, then a hundred, each from a step boundary.
        try expectEqual(high * 10 * 3, sp.sum(80));
        try expectEqual(high * 10 * 3 * 100, sp.sum(8000));
        try expectEqual(@as(u3, 0), st.pos);
        try expectEqual(@as(u32, 10), st.ctr);
    }
}

test "sound: box filter gives a 131 kHz square its mean, no alias" {
    // Period 2047: 4-dot steps, far above 22 kHz. Each 95/96-dot bin is
    // half high: the span sum is the mean within one step's rounding.
    var st: apu.Sq = .{ .ctr = 1, .pos = 0 };
    const sp: apu.SqSpan = .{ .st = &st, .p = apu.sq_period(2047), .pat = 0xE1, .vol = 15 };
    for (0..1000) |i| {
        const len: u32 = if (i % 9 == 0) 96 else 95;
        const s = sp.sum(len);
        try expect(s + 4 * 15 >= len * 15 / 2 and s <= len * 15 / 2 + 4 * 15);
    }
    // Through the whole path: after the high-pass settles, flat output.
    var gb = fresh(&snd_a);
    gb.write8(0xFF25, 0x22);
    gb.write8(0xFF16, 0x80);
    gb.write8(0xFF17, 0xF0);
    gb.write8(0xFF18, 0xFF);
    gb.write8(0xFF19, 0x87);
    for (0..20) |_| gb.step_frame(0);
    const out = apu.samples(&gb);
    // The 95/96-dot bins against 4-dot steps leave +-2 of jitter (about
    // 44 dB under full scale); an alias would swing the whole range.
    for (out[1..], out[0 .. out.len - 1]) |a, b| try expect(@abs(@as(i32, a) - b) <= 3);
}

test "sound: ch1 sweep raises the pitch" {
    var gb = fresh(&snd_a);
    gb.write8(0xFF25, 0x11);
    gb.write8(0xFF10, 0x17); // sweep period 1 (128 Hz), up, shift 7
    gb.write8(0xFF11, 0x80);
    gb.write8(0xFF12, 0xF0);
    gb.write8(0xFF13, 0x00);
    gb.write8(0xFF14, 0x84); // period 1024: 128 Hz
    _ = gb.step_frame(0);
    var t1: u32 = 0;
    var t2: u32 = 0;
    const f1 = hz10(crossings(&gb, 10, &t1), t1);
    const f2 = hz10(crossings(&gb, 10, &t2), t2);
    // Period grows by period >> 7 at 128 Hz: about +1%/step, ~21 steps
    // per 10 frames, so the second window is clearly higher.
    try expect(f2 > f1 + f1 / 8);
    try expect(gb.apu.current_period > 1024 + 256);
}

test "sound: LFSR runs 32767 steps in 15-bit mode, 127 in 7-bit mode" {
    var l: u16 = 0x7FFF;
    var n: u32 = 0;
    while (true) {
        l = apu.lfsr_step(l, false);
        n += 1;
        if (l == 0x7FFF) break;
        if (n > 40000) return error.NoPeriod;
    }
    try expectEqual(@as(u32, 32767), n);
    // 7-bit mode: from the trigger value the low 7 bits settle into a
    // 127-step cycle; check the output bit sequence repeats with it.
    l = 0x7FFF;
    for (0..200) |_| l = apu.lfsr_step(l, true);
    var seq: [127]u16 = undefined;
    for (&seq) |*b| {
        b.* = l & 1;
        l = apu.lfsr_step(l, true);
    }
    for (0..127 * 3) |i| {
        try expectEqual(seq[i % 127], l & 1);
        l = apu.lfsr_step(l, true);
    }
    // And no shorter period divides it.
    var shorter = false;
    for (seq[1..], 1..) |_, p| {
        if (127 % p != 0) continue;
        if (p == 127) break;
        var same = true;
        for (0..127) |i| same = same and seq[i] == seq[(i + p) % 127];
        shorter = shorter or same;
    }
    try expect(!shorter);
    // First steps of the 15-bit sequence from 0x7FFF: bits 0 and 1 agree,
    // so zeros shift in from bit 14; the output (inverted bit 0) is low
    // for the first 14 clocks.
    l = 0x7FFF;
    for (0..14) |_| {
        l = apu.lfsr_step(l, false);
        try expectEqual(@as(u16, 1), l & 1);
    }
}

test "sound: noise plays, and its envelope steps once per 8 sequencer steps" {
    var gb = fresh(&snd_a);
    gb.write8(0xFF25, 0x88);
    gb.write8(0xFF21, 0xF1); // volume 15, down, period 1
    gb.write8(0xFF22, 0x00); // fastest clock, 15-bit
    gb.write8(0xFF23, 0x80);
    try expect(snd_a.n_on);
    try expectEqual(@as(u8, 15), snd_a.n_vol);
    gb.step_frame(0);
    gb.step_frame(0);
    var lo: u8 = 255;
    var hi: u8 = 0;
    for (apu.samples(&gb)) |v| {
        lo = @min(lo, v);
        hi = @max(hi, v);
    }
    try expect(hi - lo > 40);
    // The envelope runs at 64 Hz: 15 -> 0 in 15/64 s, about 14 frames.
    const v0 = snd_a.n_vol;
    try expect(v0 < 15 and v0 > 10);
    for (0..20) |_| gb.step_frame(0);
    try expectEqual(@as(u8, 0), snd_a.n_vol);

    // Direct: sequencer steps 0..7, envelope on step 7 only.
    gb.write8(0xFF21, 0x81); // volume 8, down, period 1
    gb.write8(0xFF23, 0x80);
    gb.apu.seq = 0;
    for (0..7) |_| apu.step_sequencer(&gb);
    try expectEqual(@as(u8, 8), snd_a.n_vol);
    apu.step_sequencer(&gb);
    try expectEqual(@as(u8, 7), snd_a.n_vol);
    gb.write8(0xFF21, 0x07); // volume 0, down: DAC off
    gb.write8(0xFF23, 0x80);
    // DAC off (upper five bits zero): the trigger leaves it silent.
    try expect(!snd_a.n_on);
}

test "sound: wave RAM plays at 65536 / (2048 - x)" {
    var gb = fresh(&snd_a);
    gb.write8(0xFF25, 0x44);
    // One cycle of a square in the 32 nibbles.
    for (0..16) |i| gb.write8(@intCast(0xFF30 + i), if (i < 8) 0xFF else 0x00);
    gb.write8(0xFF1A, 0x80); // DAC on
    gb.write8(0xFF1C, 0x20); // 100%
    gb.write8(0xFF1D, @truncate(1984));
    gb.write8(0xFF1E, 0x80 | (1984 >> 8)); // 64 below 2048: 1024 Hz
    _ = gb.step_frame(0);
    var total: u32 = 0;
    const f = hz10(crossings(&gb, 30, &total), total);
    try expect(f + 30 >= 10240 and f <= 10240 + 30);
    // Output level code 3 (25%) is quieter than code 1.
    var lo: u8 = 255;
    var hi: u8 = 0;
    for (apu.samples(&gb)) |v| {
        lo = @min(lo, v);
        hi = @max(hi, v);
    }
    gb.write8(0xFF1C, 0x60);
    for (0..10) |_| gb.step_frame(0);
    var lo2: u8 = 255;
    var hi2: u8 = 0;
    for (apu.samples(&gb)) |v| {
        lo2 = @min(lo2, v);
        hi2 = @max(hi2, v);
    }
    try expect((hi2 - lo2) * 3 < hi - lo);
    // DAC off silences it.
    gb.write8(0xFF1A, 0x00);
    for (0..20) |_| gb.step_frame(0);
    for (apu.samples(&gb)) |v| try expect(@abs(@as(i32, v) - 128) <= 1);
}

test "sound: ch2 envelope decays the amplitude" {
    var gb = fresh(&snd_a);
    gb.write8(0xFF25, 0x22);
    gb.write8(0xFF16, 0x80);
    gb.write8(0xFF17, 0xF2); // volume 15, down, every 2/64 s
    gb.write8(0xFF18, 0x00);
    gb.write8(0xFF19, 0x87);
    var amp: [3]i32 = undefined;
    for (&amp) |*a| {
        for (0..8) |_| gb.step_frame(0);
        var lo: u8 = 255;
        var hi: u8 = 0;
        for (apu.samples(&gb)) |v| {
            lo = @min(lo, v);
            hi = @max(hi, v);
        }
        a.* = hi - lo;
    }
    try expect(amp[0] > amp[1] and amp[1] > amp[2]);
}

test "sound: NR51 routing and NR50 volume scale the mix" {
    var p2p: [3]i32 = undefined;
    for ([_][2]u8{ .{ 0x77, 0x22 }, .{ 0x77, 0x02 }, .{ 0x33, 0x22 } }, &p2p) |c, *a| {
        var gb = fresh(&snd_a);
        gb.write8(0xFF24, c[0]);
        gb.write8(0xFF25, c[1]);
        gb.write8(0xFF16, 0x80);
        gb.write8(0xFF17, 0x80);
        gb.write8(0xFF18, 0x00);
        gb.write8(0xFF19, 0x86); // 512 Hz
        for (0..10) |_| gb.step_frame(0);
        var lo: u8 = 255;
        var hi: u8 = 0;
        for (apu.samples(&gb)) |v| {
            lo = @min(lo, v);
            hi = @max(hi, v);
        }
        a.* = hi - lo;
    }
    // One side is half of both; NR50 3 (x4) is half of 7 (x8).
    try expect(@abs(p2p[0] - 2 * p2p[1]) <= 3);
    try expect(@abs(p2p[0] - 2 * p2p[2]) <= 3);
}

/// Rebound (CGB, double speed, music from the start), from the repository
/// root (`zig build test`) or the cart directory.
fn load_rebound(gpa: std.mem.Allocator) ![]u8 {
    for ([_][]const u8{ "carts/snouty-boy/roms/rebound.gbc", "roms/rebound.gbc" }) |p| {
        return std.Io.Dir.cwd().readFileAlloc(std.testing.io, p, gpa, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
    }
    return error.SkipZigTest;
}

fn pads_for(i: usize) u8 {
    return switch (i % 40) {
        0...2 => Pad.start,
        10...12 => Pad.left,
        20...22 => Pad.up,
        30...32 => Pad.right,
        else => 0,
    };
}

var ram_a: [Gb.max_cart_ram]u8 = undefined;
var ram_b: [Gb.max_cart_ram]u8 = undefined;

test "sound: rendering does not change console state" {
    const gpa = std.testing.allocator;
    const rom = try load_rebound(gpa);
    defer gpa.free(rom);
    const a = try gpa.create(Gb);
    defer gpa.destroy(a);
    const b = try gpa.create(Gb);
    defer gpa.destroy(b);
    a.* = Gb.init_slice(rom, .cgb, &ram_a);
    b.* = Gb.init_slice(rom, .cgb, &ram_b);
    b.snd = &snd_b;
    apu.set_render(b, true);
    const ka = try gpa.create(Gb.Keyframe);
    defer gpa.destroy(ka);
    const kb = try gpa.create(Gb.Keyframe);
    defer gpa.destroy(kb);
    for (0..400) |i| {
        a.step_frame(pads_for(i));
        b.step_frame(pads_for(i));
    }
    a.snapshot(ka);
    b.snapshot(kb);
    try expect(std.meta.eql(ka.small, kb.small));
    try expect(std.meta.eql(ka.wram, kb.wram));
    try expect(std.meta.eql(ka.vram, kb.vram));
    try expectEqual(@as(u16, 0), a.audio_len);
    try expect(b.audio_len >= 738);
}

/// All four channels playing, set up as a game would, on `gb`.
fn play_all(gb: *Gb) void {
    gb.write8(0xFF25, 0xFF);
    gb.write8(0xFF10, 0x00);
    gb.write8(0xFF11, 0x40);
    gb.write8(0xFF12, 0xA3);
    gb.write8(0xFF13, 0x00);
    gb.write8(0xFF14, 0x86);
    gb.write8(0xFF16, 0x80);
    gb.write8(0xFF17, 0x71);
    gb.write8(0xFF18, 0x40);
    gb.write8(0xFF19, 0x85);
    for (0..16) |i| gb.write8(@intCast(0xFF30 + i), @intCast(i * 17));
    gb.write8(0xFF1A, 0x80);
    gb.write8(0xFF1C, 0x40);
    gb.write8(0xFF1D, 0x00);
    gb.write8(0xFF1E, 0x87);
    gb.write8(0xFF21, 0xF4);
    gb.write8(0xFF22, 0x31);
    gb.write8(0xFF23, 0x80);
}

test "sound: scrub round trip, a restore resets the render state" {
    // Two consoles with different histories, restored from one keyframe,
    // give the same samples from there on (the documented reset): the
    // keyframe holds the registers, so the channels play on.
    const gpa = std.testing.allocator;
    const a = try gpa.create(Gb);
    defer gpa.destroy(a);
    const b = try gpa.create(Gb);
    defer gpa.destroy(b);
    const k = try gpa.create(Gb.Keyframe);
    defer gpa.destroy(k);
    a.* = fresh(&snd_a);
    play_all(a);
    for (0..7) |_| a.step_frame(0);
    a.snapshot(k);
    b.* = fresh(&snd_b);
    for (0..13) |_| b.step_frame(0);
    play_all(b);
    b.write8(0xFF1C, 0x20);
    for (0..5) |_| b.step_frame(0);
    a.restore(k);
    b.restore(k);
    try expectEqual(@as(usize, 0), apu.samples(a).len);
    var lo: u8 = 255;
    var hi: u8 = 0;
    for (0..30) |_| {
        a.step_frame(0);
        b.step_frame(0);
        try expectEqual(a.audio_len, b.audio_len);
        try std.testing.expectEqualSlices(u8, apu.samples(a), apu.samples(b));
        for (apu.samples(a)) |v| {
            lo = @min(lo, v);
            hi = @max(hi, v);
        }
    }
    try expect(hi - lo > 60);
}
