//! SN76489 synthesis (core/psg.zig `Synth`, docs/EMU_SOUND.md): pitch from
//! the period, the constant output of periods 0 and 1, the noise shift
//! register, the attenuation table, the stereo average, the box filter,
//! and through the console (`Gg.audio_out`) the samples per frame, the
//! isolation from console state and the scrub round trip.
const std = @import("std");
const core = @import("core");
const psg = core.psg;
const Gg = core.Gg;
const Pad = core.Pad;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

fn set(p: *psg.Psg, ch: u8, period: u16, att: u8) void {
    p.write(0x80 | ch << 5 | @as(u8, @intCast(period & 0x0F)));
    p.write(@intCast(period >> 4));
    p.write(0x90 | ch << 5 | att);
}

/// The sample one channel at volume `v` with `sides` stereo sides makes.
fn level(v: i32, sides: i32) u8 {
    return @intCast(std.math.clamp(128 + ((v * sides * psg.gain + 0x8000) >> 16), 0, 255));
}

/// One second of sound from `p` into `out` (44,100 samples, give or take one).
fn second(s: *psg.Synth, p: *const psg.Psg, out: []u8) u16 {
    var len: u16 = 0;
    s.resync(p, 0);
    s.run_to(p, psg.clock, out, &len);
    return len;
}

var buf: [44_200]u8 = undefined;

test "sound: a second of console time is 44,100 samples" {
    const p: psg.Psg = .{};
    var s: psg.Synth = .{};
    const n = second(&s, &p, &buf);
    try expect(n == 44_100 or n == 44_099);
    for (buf[0..n]) |b| try expectEqual(@as(u8, 128), b);
}

test "sound: tone pitch from the period" {
    // Period 254: 3,579,545 / (32 x 254) = 440.4 Hz; period 0x3FF: 109.3 Hz.
    for ([_][2]u32{ .{ 254, 440 }, .{ 0x3FF, 109 }, .{ 100, 1118 } }) |c| {
        var p: psg.Psg = .{};
        set(&p, 1, @intCast(c[0]), 0);
        var s: psg.Synth = .{};
        const n = second(&s, &p, &buf);
        var rises: u32 = 0;
        for (1..n) |i| {
            if (buf[i - 1] < 128 and buf[i] >= 128) rises += 1;
        }
        try expect(rises + 1 >= c[1] and rises <= c[1] + 1);
        // Full swing both ways at attenuation 0.
        try expectEqual(level(32767, 2), std.mem.max(u8, buf[0..n]));
        try expectEqual(level(-32767, 2), std.mem.min(u8, buf[0..n]));
    }
}

test "sound: periods 0 and 1 are a constant +1" {
    for ([_]u16{ 0, 1 }) |per| {
        var p: psg.Psg = .{};
        set(&p, 2, per, 3);
        var s: psg.Synth = .{};
        const n = second(&s, &p, &buf);
        for (buf[0..n]) |b| try expectEqual(level(psg.volume[3], 2), b);
    }
    // Volume writes on a constant channel are the sample-playback trick:
    // each write moves the level at once.
    var p: psg.Psg = .{};
    set(&p, 0, 0, 15);
    var s: psg.Synth = .{};
    var len: u16 = 0;
    s.resync(&p, 0);
    for (0..16) |a| {
        p.write(0x90 | @as(u8, @intCast(15 - a)));
        s.after_write(&p, @intCast(a * 810));
        s.run_to(&p, @intCast((a + 1) * 810), &buf, &len);
        try expectEqual(level(psg.volume[15 - a], 2), buf[len - 2]);
    }
}

/// Bits shifted out of the noise register after each shift, from 0x8000.
fn noise_bits(white: bool, out: []bool) void {
    var p: psg.Psg = .{};
    p.write(0xF0); // noise volume 0
    p.write(if (white) 0xE4 else 0xE0); // rate 0: a shift every 512 T-states
    var s: psg.Synth = .{};
    var len: u16 = 0;
    var junk: [64]u8 = undefined;
    s.resync(&p, 0);
    // The first counter zero (256) raises the shift clock: shifts at 256 + 512k.
    for (out, 0..) |*o, k| {
        len = 0;
        s.run_to(&p, @intCast(256 + 512 * k + 1), &junk, &len);
        o.* = s.noise_bit;
    }
}

test "sound: periodic noise rotates the single bit out every 16 shifts" {
    var bits: [48]bool = undefined;
    noise_bits(false, &bits);
    for (bits, 0..) |b, k| try expectEqual(k % 16 == 15, b);
}

test "sound: white noise is the Sega 16-bit register tapped at bits 0 and 3" {
    var bits: [200]bool = undefined;
    noise_bits(true, &bits);
    // Reference written from the SMS Power description: shift right, the
    // new bit 15 is bit 0 XOR bit 3, the bit shifted out is the output.
    var r: u32 = 0x8000;
    var ones: u32 = 0;
    for (bits) |b| {
        const out = r & 1;
        r = (r >> 1) | (((r ^ (r >> 3)) & 1) << 15);
        try expectEqual(out != 0, b);
        if (b) ones += 1;
    }
    try expect(ones > 50 and ones < 150);
}

test "sound: a noise register write resets the shift register" {
    var p: psg.Psg = .{};
    p.write(0xE4);
    var s: psg.Synth = .{};
    var len: u16 = 0;
    var junk: [700]u8 = undefined;
    s.resync(&p, 0);
    s.run_to(&p, 20_000, &junk, &len);
    try expect(s.lfsr != 0x8000);
    p.write(0xE5);
    s.after_write(&p, 20_000);
    try expectEqual(@as(u16, 0x8000), s.lfsr);
    // A volume write to the noise channel does not.
    len = 0;
    s.run_to(&p, 40_000, &junk, &len);
    const before = s.lfsr;
    p.write(0xF3);
    s.after_write(&p, 40_000);
    try expectEqual(before, s.lfsr);
}

test "sound: attenuation table is 2 dB steps down to off" {
    try expectEqual(@as(i32, 0), psg.volume[15]);
    for (0..14) |i| {
        // 10^(-2/20) = 0.7943
        const ratio = @divTrunc(psg.volume[i + 1] * 10_000, psg.volume[i]);
        try expect(ratio >= 7880 and ratio <= 8000);
    }
    // Rendered: a constant channel at each attenuation.
    for (0..16) |a| {
        var p: psg.Psg = .{};
        set(&p, 0, 0, @intCast(a));
        var s: psg.Synth = .{};
        var len: u16 = 0;
        s.resync(&p, 0);
        s.run_to(&p, 1000, &buf, &len);
        try expectEqual(level(psg.volume[a], 2), buf[0]);
    }
}

test "sound: stereo port 06 averages left and right to mono" {
    const cases = [_]struct { stereo: u8, sides: i32 }{
        .{ .stereo = 0xFF, .sides = 2 },
        .{ .stereo = 0x11, .sides = 2 },
        .{ .stereo = 0x01, .sides = 1 },
        .{ .stereo = 0x10, .sides = 1 },
        .{ .stereo = 0xEE, .sides = 0 },
    };
    for (cases) |c| {
        var p: psg.Psg = .{};
        set(&p, 0, 0, 0);
        p.stereo = c.stereo;
        var s: psg.Synth = .{};
        var len: u16 = 0;
        s.resync(&p, 0);
        s.run_to(&p, 1000, &buf, &len);
        try expectEqual(level(32767, c.sides), buf[3]);
    }
    // Two constant channels sum.
    var p: psg.Psg = .{};
    set(&p, 0, 0, 2);
    set(&p, 1, 1, 2);
    var s: psg.Synth = .{};
    var len: u16 = 0;
    s.resync(&p, 0);
    s.run_to(&p, 1000, &buf, &len);
    try expectEqual(level(2 * psg.volume[2], 2), buf[3]);
}

test "sound: the box filter averages a fast square to its mean" {
    // Period 2: 56 kHz, a flip every 32 T-states, more than two per bin.
    // Point sampling would land on +-full swing; the bin mean stays within
    // the one unmatched half period (32 of 81 T-states) of zero.
    var p: psg.Psg = .{};
    set(&p, 0, 2, 0);
    var s: psg.Synth = .{};
    const n = second(&s, &p, &buf);
    const bound: i32 = ((32767 * 2 * 32 / 81) * psg.gain >> 16) + 1;
    var sum: i64 = 0;
    for (buf[0..n]) |b| {
        try expect(@abs(@as(i32, b) - 128) <= bound);
        sum += b;
    }
    const mean = @divTrunc(sum * 100, n);
    try expect(mean >= 12_750 and mean <= 12_850);

    // A 50% square at 1,118 Hz: the mean over a second is silence and the
    // bins straddling a flip carry the in-between levels.
    set(&p, 0, 100, 0);
    const n2 = second(&s, &p, &buf);
    sum = 0;
    var between: u32 = 0;
    for (buf[0..n2]) |b| {
        sum += b;
        if (b != level(32767, 2) and b != level(-32767, 2)) between += 1;
    }
    try expect(@abs(@divTrunc(sum * 100, n2) - 12_800) <= 50);
    // About one bin per flip (2,236 flips) is in between.
    try expect(between > 2000 and between < 2400);
}

// ---- Through the console ----

const prefixes = [_][]const u8{ "", "carts/snouty-gear/", "../", "../../" };
var rom_buf: [0x80000]u8 = undefined;

fn load_rom() ![]u8 {
    for (prefixes) |pre| {
        var path_buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}roms/waternet.gg", .{pre});
        return std.Io.Dir.cwd().readFile(std.testing.io, path, &rom_buf) catch continue;
    }
    return error.SkipZigTest;
}

fn pad_at(f: usize) u8 {
    if ((f >= 90 and f < 96) or (f >= 150 and f < 156)) return Pad.start;
    return if (f % 40 < 10) Pad.right else 0;
}

test "sound: Waternet renders 735 to 737 samples a frame, music included" {
    const gpa = std.testing.allocator;
    const rom = try load_rom();
    const gg = try gpa.create(Gg);
    defer gpa.destroy(gg);
    gg.init_in_place(core.Rom.from_slice(rom));
    gg.audio_render = true;
    var total: u64 = 0;
    var loud: u32 = 0;
    for (0..600) |f| {
        gg.step_frame(pad_at(f));
        // 735.95 on average; a frame that ends an instruction late runs a
        // few T-states long (the next one starts that much in).
        try expect(gg.audio_len >= 735 and gg.audio_len <= 737);
        total += gg.audio_len;
        for (gg.audio_out[0..gg.audio_len]) |b| {
            if (@abs(@as(i32, b) - 128) > 8) loud += 1;
        }
    }
    // 600 x 59,736 T-states at 44,100 / 3,579,545.
    const want: u64 = 600 * 59_736 * 44_100 / 3_579_545;
    try expect(total + 1 >= want and total <= want + 1);
    try expect(loud > 10_000);
    gg.audio_render = false;
    gg.step_frame(0);
    try expectEqual(@as(u16, 0), gg.audio_len);
}

test "sound: rendering does not change console state" {
    const gpa = std.testing.allocator;
    const rom = try load_rom();
    const a = try gpa.create(Gg);
    defer gpa.destroy(a);
    const b = try gpa.create(Gg);
    defer gpa.destroy(b);
    a.init_in_place(core.Rom.from_slice(rom));
    b.init_in_place(core.Rom.from_slice(rom));
    b.audio_render = true;
    for (0..400) |f| {
        a.step_frame(pad_at(f));
        b.step_frame(pad_at(f));
    }
    const ka = try gpa.create(Gg.Keyframe);
    defer gpa.destroy(ka);
    const kb = try gpa.create(Gg.Keyframe);
    defer gpa.destroy(kb);
    a.snapshot(ka);
    b.snapshot(kb);
    inline for (@typeInfo(Gg.Keyframe).@"struct".field_names) |name| {
        try expect(std.meta.eql(@field(ka, name), @field(kb, name)));
    }
}

test "sound: scrub round trip renders the same frames after each restore" {
    // The phase is render-only state, not in the keyframe: a restore starts
    // it clean (Synth.resync), so every replay from a keyframe sounds the
    // same, whatever ran before.
    const gpa = std.testing.allocator;
    const rom = try load_rom();
    const gg = try gpa.create(Gg);
    defer gpa.destroy(gg);
    gg.init_in_place(core.Rom.from_slice(rom));
    gg.audio_render = true;
    for (0..300) |f| gg.step_frame(pad_at(f));
    const k = try gpa.create(Gg.Keyframe);
    defer gpa.destroy(k);
    gg.snapshot(k);
    var first: [20 * psg.max_frame_samples]u8 = undefined;
    var n1: usize = 0;
    var loud: u32 = 0;
    for (0..3) |round| {
        gg.restore(k);
        var n2: usize = 0;
        for (0..20) |f| {
            gg.step_frame(pad_at(300 + f));
            const out = gg.audio_out[0..gg.audio_len];
            if (round == 0) {
                @memcpy(first[n1..][0..out.len], out);
                n1 += out.len;
                for (out) |b| {
                    if (b != 128) loud += 1;
                }
            } else {
                try expect(n2 + out.len <= n1);
                try std.testing.expectEqualSlices(u8, first[n2..][0..out.len], out);
                n2 += out.len;
            }
        }
        if (round != 0) try expectEqual(n1, n2);
        for (0..7) |f| gg.step_frame(@truncate(f * 37));
    }
    try expect(loud > 0);
}
