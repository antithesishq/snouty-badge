//! SPEC.md 10.2: the scrubber's promise. Run the shipped ROM (roms/2048.gb,
//! read at run time; skipped if absent) for 600 frames with a scripted pad
//! stream, keyframe every 30 frames, then restore each keyframe k into a
//! fresh console, replay the 30 logged pads and require keyframe k + 1
//! exactly. Keyframes are compared field by field (`std.meta.eql`): the
//! struct has auto layout, so its padding bytes are not comparable.
const std = @import("std");
const core = @import("core");
const Gb = core.Gb;
const Pad = core.Pad;

const rom_path = "roms/2048.gb";
const interval = 30;
const keyframes = 20;
const frames = interval * keyframes;

/// Deterministic pad script: an LCG picks a button set and a burst length,
/// so directions and A/Start are held for several frames at a time.
fn script(pads: []u8) void {
    var seed: u32 = 0x5EED_2048;
    var i: usize = 0;
    while (i < pads.len) {
        seed = seed *% 1_664_525 +% 1_013_904_223;
        const r = seed >> 8;
        const pad: u8 = switch (r % 8) {
            0 => Pad.left,
            1 => Pad.right,
            2 => Pad.up,
            3 => Pad.down,
            4 => Pad.a,
            5 => Pad.start,
            6 => Pad.up | Pad.a,
            else => 0,
        };
        const len = 2 + (r >> 4) % 12;
        var j: usize = 0;
        while (j < len and i < pads.len) : (j += 1) {
            pads[i] = pad;
            i += 1;
        }
    }
}

fn load_rom(gpa: std.mem.Allocator) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, rom_path, gpa, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
}

/// Name of the first differing field (`Small` fields by their own name),
/// or null if equal.
fn diff(a: *const Gb.Keyframe, b: *const Gb.Keyframe) ?[]const u8 {
    inline for (@typeInfo(Gb.Small).@"struct".field_names) |name| {
        if (!std.meta.eql(@field(a.small, name), @field(b.small, name))) return name;
    }
    inline for (.{ "vram", "wram", "cart_ram" }) |name| {
        if (!std.meta.eql(@field(a, name), @field(b, name))) return name;
    }
    return null;
}

/// Cart RAM buffers for the two consoles a test runs (2048-gb has 2 KB).
var ram_a: [Gb.max_cart_ram]u8 = undefined;
var ram_b: [Gb.max_cart_ram]u8 = undefined;

test "determinism: replaying logged input from each keyframe reproduces the next" {
    const gpa = std.testing.allocator;
    const rom = try load_rom(gpa);
    defer gpa.free(rom);

    const pads = try gpa.alloc(u8, frames);
    defer gpa.free(pads);
    script(pads);

    const kf = try gpa.alloc(Gb.Keyframe, keyframes + 1);
    defer gpa.free(kf);

    // The live run.
    const gb = try gpa.create(Gb);
    defer gpa.destroy(gb);
    gb.* = Gb.init(rom, .dmg, &ram_a);
    gb.snapshot(&kf[0]);
    for (pads, 1..) |p, f| {
        gb.step_frame(p);
        if (f % interval == 0) gb.snapshot(&kf[f / interval]);
    }
    // The script must actually move the game: some keyframes differ in WRAM.
    try std.testing.expect(!std.meta.eql(kf[0].wram, kf[keyframes].wram));

    // Replays into a fresh console.
    const re = try gpa.create(Gb);
    defer gpa.destroy(re);
    const got = try gpa.create(Gb.Keyframe);
    defer gpa.destroy(got);
    for (0..keyframes) |k| {
        re.* = Gb.init(rom, .dmg, &ram_b);
        re.restore(&kf[k]);
        for (pads[k * interval ..][0..interval]) |p| re.step_frame(p);
        re.snapshot(got);
        if (diff(got, &kf[k + 1])) |field| {
            std.debug.print("keyframe {d} -> {d}: field '{s}' differs after replay\n", .{ k, k + 1, field });
            return error.ReplayDiverged;
        }
    }
}

test "determinism: restore then step equals the live run frame by frame" {
    // A keyframe restored into a console that has run something else first
    // must behave as if it had never run: nothing outside the keyframe
    // leaks into emulation.
    const gpa = std.testing.allocator;
    const rom = try load_rom(gpa);
    defer gpa.free(rom);
    var pads: [90]u8 = undefined;
    script(&pads);

    const a = try gpa.create(Gb);
    defer gpa.destroy(a);
    const b = try gpa.create(Gb);
    defer gpa.destroy(b);
    const k0 = try gpa.create(Gb.Keyframe);
    defer gpa.destroy(k0);
    const ka = try gpa.create(Gb.Keyframe);
    defer gpa.destroy(ka);
    const kb = try gpa.create(Gb.Keyframe);
    defer gpa.destroy(kb);

    a.* = Gb.init(rom, .dmg, &ram_a);
    for (pads[0..30]) |p| a.step_frame(p);
    a.snapshot(k0);

    b.* = Gb.init(rom, .dmg, &ram_b);
    for (0..77) |i| b.step_frame(@truncate(i * 37)); // unrelated history
    b.restore(k0);

    for (pads[30..]) |p| {
        a.step_frame(p);
        b.step_frame(p);
        a.snapshot(ka);
        b.snapshot(kb);
        if (diff(ka, kb)) |field| {
            std.debug.print("field '{s}' differs\n", .{field});
            return error.ReplayDiverged;
        }
    }
}

test "determinism: KeyframeWith(cart_ram_len) round trip" {
    const gpa = std.testing.allocator;
    const rom = try load_rom(gpa);
    defer gpa.free(rom);
    // 2048-gb declares 2 KB of cart RAM (MBC1+RAM+battery).
    try std.testing.expectEqual(@as(usize, 0x800), core.mmu.cart_ram_len(rom));
    const Small = Gb.KeyframeWith(0x800);
    const a = try gpa.create(Gb);
    defer gpa.destroy(a);
    const k = try gpa.create(Small);
    defer gpa.destroy(k);
    const full = try gpa.create(Gb.Keyframe);
    defer gpa.destroy(full);
    const full2 = try gpa.create(Gb.Keyframe);
    defer gpa.destroy(full2);

    a.* = Gb.init(rom, .dmg, &ram_a);
    for (0..45) |i| a.step_frame(if (i % 9 < 3) Pad.left else 0);
    // The 2 KB RAM mirrors: 0xA800 is 0xA000.
    a.write8(0x0000, 0x0A);
    a.write8(0xA800, 0x5A);
    try std.testing.expectEqual(@as(u8, 0x5A), a.read8(0xA000));
    try std.testing.expect(std.mem.allEqual(u8, a.cart_ram[0x800..], 0));
    a.snapshot(k);
    a.snapshot(full);
    for (0..20) |_| a.step_frame(Pad.start);
    a.write8(0xA000, 0x11);
    a.restore(k);
    a.snapshot(full2);
    try std.testing.expectEqual(@as(?[]const u8, null), diff(full, full2));
    try std.testing.expectEqual(@sizeOf(Gb.Keyframe) - (Gb.max_cart_ram - 0x800), @sizeOf(Small));
}
