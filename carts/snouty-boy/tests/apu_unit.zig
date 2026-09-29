//! APU register-model tests (core/apu.zig, SPEC.md section 9). Each test
//! builds a `Gb` around a zeroed 32 KB ROM and drives the APU through
//! `gb.write8` / `gb.read8` and the frame sequencer, with no CPU involved.
const std = @import("std");
const core = @import("core");
const Gb = core.Gb;
const apu = core.apu;
const expectEqual = std.testing.expectEqual;

const zero_rom: [0x8000]u8 = @splat(0);

fn fresh() Gb {
    var gb = Gb.init(&zero_rom, .dmg, &.{});
    gb.write8(0xFF26, 0x00); // power cycle: clean registers, sequencer at 0
    gb.write8(0xFF26, 0x80);
    return gb;
}

fn nr52(gb: *Gb) u8 {
    return gb.read8(0xFF26);
}

/// Run `n` frame sequencer steps through `apu.tick` (2048 M-cycles each).
fn steps(gb: *Gb, n: u32) void {
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        var m: u32 = 0;
        while (m < apu.seq_period) : (m += 4) apu.tick(gb, 16);
    }
}

test "apu post-boot NR52 reads 0xF1" {
    var gb = Gb.init(&zero_rom, .dmg, &.{});
    try expectEqual(@as(u8, 0xF1), nr52(&gb));
    try expectEqual(@as(u8, 0), apu.pick_voice(&gb).channel);
}

test "apu ch2 length counter disables after the right number of steps" {
    var gb = fresh();
    gb.write8(0xFF17, 0xF0); // NR22: volume 15, no envelope
    gb.write8(0xFF16, 0x80 | 60); // NR21: duty 2, length 64-60 = 4
    gb.write8(0xFF18, 0x00);
    gb.write8(0xFF19, 0xC0 | 0x07); // trigger, length enable, period 0x700
    try expectEqual(@as(u8, 0xF2), nr52(&gb));
    // Length clocks on steps 0, 2, 4, 6: 4 clocks happen within 7 steps.
    steps(&gb, 6);
    try expectEqual(@as(u8, 0xF2), nr52(&gb));
    steps(&gb, 1); // step 6: fourth clock
    try expectEqual(@as(u8, 0xF0), nr52(&gb));
    try expectEqual(@as(u16, 0), gb.apu.ch[1].length);
}

test "apu length is ignored without the enable bit and reloads on trigger" {
    var gb = fresh();
    gb.write8(0xFF17, 0xF0);
    gb.write8(0xFF16, 63); // length 1
    gb.write8(0xFF19, 0x80); // trigger, no length enable
    steps(&gb, 16);
    try expectEqual(@as(u8, 0xF2), nr52(&gb));
    gb.write8(0xFF19, 0xC0); // enable: one clock kills it
    steps(&gb, 2);
    try expectEqual(@as(u8, 0xF0), nr52(&gb));
    gb.write8(0xFF19, 0xC0); // length 0 -> reloaded to 64 on trigger
    try expectEqual(@as(u16, 64), gb.apu.ch[1].length);
    try expectEqual(@as(u8, 0xF2), nr52(&gb));
}

test "apu ch3 uses a 256-step length" {
    var gb = fresh();
    gb.write8(0xFF1A, 0x80); // DAC on
    gb.write8(0xFF1C, 0x20); // full volume
    gb.write8(0xFF1B, 256 - 3); // length 3
    gb.write8(0xFF1E, 0xC0);
    try expectEqual(@as(u8, 0xF4), nr52(&gb));
    steps(&gb, 5); // clocks at steps 0, 2, 4
    try expectEqual(@as(u8, 0xF0), nr52(&gb));
    gb.write8(0xFF1E, 0x80);
    try expectEqual(@as(u16, 256), gb.apu.ch[2].length);
}

test "apu envelope steps at 64 Hz times the period" {
    var gb = fresh();
    gb.write8(0xFF12, 0xF2); // volume 15, decrease, period 2
    gb.write8(0xFF14, 0x80);
    try expectEqual(@as(u8, 15), gb.apu.ch[0].volume);
    // Envelope clocks on step 7 of every 8; period 2 -> every 16 steps.
    steps(&gb, 8);
    try expectEqual(@as(u8, 15), gb.apu.ch[0].volume);
    steps(&gb, 8);
    try expectEqual(@as(u8, 14), gb.apu.ch[0].volume);
    steps(&gb, 16 * 13);
    try expectEqual(@as(u8, 1), gb.apu.ch[0].volume);
    steps(&gb, 16 * 3);
    try expectEqual(@as(u8, 0), gb.apu.ch[0].volume);
    // Still enabled (DAC on), but silent: not a voice.
    try expectEqual(@as(u8, 0xF1), nr52(&gb));
    try expectEqual(@as(u8, 0), apu.pick_voice(&gb).channel);
}

test "apu envelope increases and period 0 freezes it" {
    var gb = fresh();
    gb.write8(0xFF17, 0x39); // volume 3, increase, period 1
    gb.write8(0xFF19, 0x80);
    steps(&gb, 8);
    try expectEqual(@as(u8, 4), gb.apu.ch[1].volume);
    steps(&gb, 8 * 20);
    try expectEqual(@as(u8, 15), gb.apu.ch[1].volume);
    gb.write8(0xFF17, 0x58); // volume 5, increase, period 0
    gb.write8(0xFF19, 0x80);
    steps(&gb, 64);
    try expectEqual(@as(u8, 5), gb.apu.ch[1].volume);
}

test "apu ch1 sweep raises the period and writes it back" {
    var gb = fresh();
    gb.write8(0xFF10, 0x11); // sweep period 1, increase, shift 1
    gb.write8(0xFF12, 0xF0);
    gb.write8(0xFF13, 0x00);
    gb.write8(0xFF14, 0x80 | 0x01); // period 0x100, trigger
    try expectEqual(@as(u16, 0x100), gb.apu.current_period);
    steps(&gb, 3); // sweep clocks on step 2
    try expectEqual(@as(u16, 0x180), gb.apu.current_period);
    try expectEqual(@as(u8, 0x80), gb.io[0x13]);
    try expectEqual(@as(u8, 0x01), gb.io[0x14] & 7);
    steps(&gb, 4); // step 6
    try expectEqual(@as(u16, 0x240), gb.apu.current_period);
    try expectEqual(@as(u16, 0x240), apu.pick_voice(&gb).period);
}

test "apu ch1 sweep decrease" {
    var gb = fresh();
    gb.write8(0xFF10, 0x1A); // period 1, decrease, shift 2
    gb.write8(0xFF12, 0xF0);
    gb.write8(0xFF13, 0x00);
    gb.write8(0xFF14, 0x84); // period 0x400
    steps(&gb, 3);
    try expectEqual(@as(u16, 0x300), gb.apu.current_period);
    try expectEqual(@as(u8, 0xF1), nr52(&gb));
}

test "apu ch1 sweep overflow disables the channel" {
    var gb = fresh();
    gb.write8(0xFF10, 0x11);
    gb.write8(0xFF12, 0xF0);
    gb.write8(0xFF13, 0x00);
    gb.write8(0xFF14, 0x80 | 0x05); // 0x500: next 0x780 fits, then 0xB40 overflows
    try expectEqual(@as(u8, 0xF1), nr52(&gb));
    steps(&gb, 3);
    // 0x500 -> 0x780 written, and the follow-up check (0xB40) overflows.
    try expectEqual(@as(u16, 0x780), gb.apu.current_period);
    try expectEqual(@as(u8, 0xF0), nr52(&gb));
}

test "apu ch1 trigger overflow check disables immediately" {
    var gb = fresh();
    gb.write8(0xFF10, 0x01); // period 0, shift 1: check still runs on trigger
    gb.write8(0xFF12, 0xF0);
    gb.write8(0xFF13, 0xFF);
    gb.write8(0xFF14, 0x87); // 0x7FF + 0x3FF > 2047
    try expectEqual(@as(u8, 0xF0), nr52(&gb));
}

test "apu DAC off disables and blocks trigger" {
    var gb = fresh();
    gb.write8(0xFF12, 0xF0);
    gb.write8(0xFF14, 0x80);
    try expectEqual(@as(u8, 0xF1), nr52(&gb));
    gb.write8(0xFF12, 0x08); // volume 0 but increase: DAC stays on
    try expectEqual(@as(u8, 0xF1), nr52(&gb));
    gb.write8(0xFF12, 0x07); // upper 5 bits zero: DAC off
    try expectEqual(@as(u8, 0xF0), nr52(&gb));
    gb.write8(0xFF14, 0x80);
    try expectEqual(@as(u8, 0xF0), nr52(&gb));
    // Ch3: NR30 bit 7.
    gb.write8(0xFF1C, 0x20);
    gb.write8(0xFF1E, 0x80);
    try expectEqual(@as(u8, 0xF0), nr52(&gb));
    gb.write8(0xFF1A, 0x80);
    gb.write8(0xFF1E, 0x80);
    try expectEqual(@as(u8, 0xF4), nr52(&gb));
    gb.write8(0xFF1A, 0x00);
    try expectEqual(@as(u8, 0xF0), nr52(&gb));
}

test "apu NR52 power off clears registers but keeps lengths" {
    var gb = fresh();
    gb.write8(0xFF11, 0x80 | 10);
    gb.write8(0xFF12, 0xF0);
    gb.write8(0xFF14, 0x80);
    gb.write8(0xFF24, 0x77);
    try expectEqual(@as(u8, 0xF1), nr52(&gb));
    gb.write8(0xFF26, 0x00);
    try expectEqual(@as(u8, 0x70), nr52(&gb));
    try expectEqual(@as(u8, 0x00), gb.read8(0xFF24));
    try expectEqual(@as(u8, 0x00), gb.read8(0xFF12));
    try expectEqual(@as(u8, 0x3F), gb.read8(0xFF11)); // duty cleared, mask
    try expectEqual(@as(u16, 54), gb.apu.ch[0].length);
    // Writes are ignored while off, except lengths (DMG) and wave RAM.
    gb.write8(0xFF12, 0xF0);
    try expectEqual(@as(u8, 0x00), gb.read8(0xFF12));
    gb.write8(0xFF16, 0xC0 | 20);
    try expectEqual(@as(u16, 44), gb.apu.ch[1].length);
    gb.write8(0xFF30, 0x5A);
    try expectEqual(@as(u8, 0x5A), gb.read8(0xFF30));
    // Sequencer is stopped while off.
    steps(&gb, 4);
    try expectEqual(@as(u8, 0), gb.apu.seq);
    gb.write8(0xFF26, 0x80);
    try expectEqual(@as(u8, 0xF0), nr52(&gb));
}

test "apu read masks" {
    var gb = fresh();
    try expectEqual(@as(u8, 0x80), gb.read8(0xFF10));
    try expectEqual(@as(u8, 0xFF), gb.read8(0xFF13)); // write-only
    try expectEqual(@as(u8, 0xFF), gb.read8(0xFF15)); // unused
    try expectEqual(@as(u8, 0xFF), gb.read8(0xFF2A));
    gb.write8(0xFF14, 0x47);
    try expectEqual(@as(u8, 0xFF), gb.read8(0xFF14));
    gb.write8(0xFF14, 0x07);
    try expectEqual(@as(u8, 0xBF), gb.read8(0xFF14));
}

fn play_square(gb: *Gb, ch: u8, vol: u8, period: u16) void {
    const base: u16 = if (ch == 1) 0xFF11 else 0xFF16;
    gb.write8(base, 0x40); // duty 1
    gb.write8(base + 1, vol << 4);
    gb.write8(base + 2, @truncate(period));
    gb.write8(base + 3, 0x80 | @as(u8, @intCast(period >> 8)));
}

fn play_wave(gb: *Gb, code: u8, period: u16) void {
    gb.write8(0xFF1A, 0x80);
    gb.write8(0xFF1C, code << 5);
    gb.write8(0xFF1D, @truncate(period));
    gb.write8(0xFF1E, 0x80 | @as(u8, @intCast(period >> 8)));
}

test "apu pick_voice picks the loudest channel" {
    var gb = fresh();
    try expectEqual(@as(u8, 0), apu.pick_voice(&gb).channel);
    play_square(&gb, 1, 5, 0x600);
    play_square(&gb, 2, 9, 0x700);
    var v = apu.pick_voice(&gb);
    try expectEqual(@as(u8, 2), v.channel);
    try expectEqual(@as(u16, 0x700), v.period);
    try expectEqual(@as(u8, 9), v.volume);
    try expectEqual(@as(u8, 1), v.duty);
    play_wave(&gb, 1, 0x500); // code 1 counts as 15
    v = apu.pick_voice(&gb);
    try expectEqual(@as(u8, 3), v.channel);
    try expectEqual(@as(u8, 15), v.volume);
    try expectEqual(@as(u8, 1), v.wave_volume_code);
    try expectEqual(@as(u16, 0x500), v.period);
    gb.write8(0xFF1C, 2 << 5); // code 2 counts as 7: ch2 (9) wins
    try expectEqual(@as(u8, 2), apu.pick_voice(&gb).channel);
    gb.write8(0xFF1C, 0); // muted
    gb.write8(0xFF17, 0x00); // ch2 DAC off
    try expectEqual(@as(u8, 1), apu.pick_voice(&gb).channel);
    gb.write8(0xFF26, 0x00);
    try expectEqual(@as(u8, 0), apu.pick_voice(&gb).channel);
}

test "apu pick_voice ties go ch1 then ch2 then ch3" {
    var gb = fresh();
    play_square(&gb, 2, 15, 0x700);
    play_wave(&gb, 1, 0x500);
    try expectEqual(@as(u8, 2), apu.pick_voice(&gb).channel);
    play_square(&gb, 1, 15, 0x600);
    try expectEqual(@as(u8, 1), apu.pick_voice(&gb).channel);
    gb.write8(0xFF12, 0x00);
    gb.write8(0xFF17, 0x00);
    try expectEqual(@as(u8, 3), apu.pick_voice(&gb).channel);
    // Equal volume 7 between ch2 and ch3 (code 2) goes to ch2.
    play_square(&gb, 2, 7, 0x700);
    gb.write8(0xFF1C, 2 << 5);
    try expectEqual(@as(u8, 2), apu.pick_voice(&gb).channel);
}

test "apu period_to_hz" {
    try expectEqual(@as(u32, 64), apu.period_to_hz(1, 0));
    try expectEqual(@as(u32, 32), apu.period_to_hz(3, 0));
    // A4 = 440 Hz is period 1750 on the squares (131072/298 = 439.8).
    try expectEqual(@as(u32, 440), apu.period_to_hz(2, 1750));
    try expectEqual(@as(u32, 1024), apu.period_to_hz(1, 1920));
    try expectEqual(@as(u32, 512), apu.period_to_hz(3, 1920));
    try expectEqual(@as(u32, 131072), apu.period_to_hz(1, 2047));
    // C6 (1046.5 Hz): 131072/(2048-1923) = 1048.6 -> 1049.
    try expectEqual(@as(u32, 1049), apu.period_to_hz(1, 1923));
}

test "apu state survives a keyframe round trip" {
    var gb = fresh();
    play_square(&gb, 1, 12, 0x6A0);
    steps(&gb, 3);
    var k: Gb.Keyframe = undefined;
    gb.snapshot(&k);
    var gb2 = Gb.init(&zero_rom, .dmg, &.{});
    gb2.restore(&k);
    try std.testing.expectEqualDeep(apu.pick_voice(&gb), apu.pick_voice(&gb2));
    try expectEqual(gb.apu.seq, gb2.apu.seq);
}

// ---- Shipped ROM sanity (roms/2048.gb, read at run time; skipped if absent) ----

var rom_buf: [0x10000]u8 = undefined;

fn load_2048() ?[]const u8 {
    const io = std.testing.io;
    const paths = [_][]const u8{ "roms/2048.gb", "../roms/2048.gb" };
    for (paths) |p| {
        const data = std.Io.Dir.cwd().readFile(io, p, &rom_buf) catch continue;
        return data;
    }
    return null;
}

// 2048-gb (M1 development ROM) writes no sound register at all: 600 idle
// frames and 3000 frames of scripted play leave 0xFF10..0xFF3F at their
// post-boot values, so there is no title music to assert on. This test only
// checks the model stays consistent under a real game.
test "apu 2048.gb 600 idle frames keep the model consistent" {
    const rom = load_2048() orelse return error.SkipZigTest;
    const gb = try std.testing.allocator.create(Gb);
    defer std.testing.allocator.destroy(gb);
    var ram: [0x800]u8 = undefined;
    gb.* = Gb.init(rom, .dmg, &ram);
    var f: u32 = 0;
    while (f < 600) : (f += 1) {
        gb.step_frame(0);
        const v = apu.pick_voice(gb);
        const status = gb.read8(0xFF26);
        if (v.channel != 0) try std.testing.expect((status >> @intCast(v.channel - 1)) & 1 == 1);
        var bits: u8 = 0;
        for (gb.apu.ch, 0..) |c, i| bits |= c.on << @intCast(i);
        try expectEqual(bits, status & 7);
    }
}
