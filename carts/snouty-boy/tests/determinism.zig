//! SPEC.md 10.2: the scrubber's promise. Run the shipped ROM (roms/2048.gb,
//! read at run time from the cart or the repository root; skipped if absent) for 600 frames with a scripted pad
//! stream, keyframe every 30 frames, then restore each keyframe k into a
//! fresh console, replay the 30 logged pads and require keyframe k + 1
//! exactly. Keyframes are compared field by field (`std.meta.eql`): the
//! struct has auto layout, so its padding bytes are not comparable.
const std = @import("std");
const core = @import("core");
const Gb = core.Gb;
const Pad = core.Pad;

/// `zig build test` runs the binary from the repository root; a test binary
/// started by hand from the cart directory finds the ROM too.
const rom_paths = [_][]const u8{ "carts/snouty-boy/roms/2048.gb", "roms/2048.gb" };
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
    for (rom_paths) |p| {
        return std.Io.Dir.cwd().readFileAlloc(std.testing.io, p, gpa, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
    }
    return error.SkipZigTest;
}

/// Name of the first differing field, or null if equal.
fn diff(a: *const Gb.Keyframe, b: *const Gb.Keyframe) ?[]const u8 {
    inline for (@typeInfo(Gb.Keyframe).@"struct".field_names) |name| {
        if (!std.meta.eql(@field(a, name), @field(b, name))) return name;
    }
    return null;
}

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
    gb.* = Gb.init(rom);
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
        re.* = Gb.init(rom);
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

    a.* = Gb.init(rom);
    for (pads[0..30]) |p| a.step_frame(p);
    a.snapshot(k0);

    b.* = Gb.init(rom);
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
    try std.testing.expectEqual(@as(usize, 0x800), core.mmu.ram_len_for(rom[0x149]));
    const Small = Gb.KeyframeWith(0x800);
    const a = try gpa.create(Gb);
    defer gpa.destroy(a);
    const k = try gpa.create(Small);
    defer gpa.destroy(k);
    const full = try gpa.create(Gb.Keyframe);
    defer gpa.destroy(full);
    const full2 = try gpa.create(Gb.Keyframe);
    defer gpa.destroy(full2);

    a.* = Gb.init(rom);
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
    try std.testing.expectEqual(@sizeOf(Gb.Keyframe) - 0x1800, @sizeOf(Small));
}

/// A keyframe pool as the frontend lays it out (cart/src/frontend/rewind.zig):
/// slots of `Gb.Fixed` followed by the ROM's cart RAM bytes, the stride
/// rounded up so every `Fixed` is aligned.
const Pool = struct {
    bytes: []align(@alignOf(Gb.Fixed)) u8,
    stride: usize,
    ram_len: usize,

    fn init(gpa: std.mem.Allocator, slots: usize, ram_len: usize) !Pool {
        const stride = std.mem.alignForward(usize, @sizeOf(Gb.Fixed) + ram_len, @alignOf(Gb.Fixed));
        const bytes = try gpa.alignedAlloc(u8, .of(Gb.Fixed), slots * stride);
        return .{ .bytes = bytes, .stride = stride, .ram_len = ram_len };
    }

    fn deinit(p: Pool, gpa: std.mem.Allocator) void {
        gpa.free(p.bytes);
    }

    fn fixed(p: Pool, i: usize) *Gb.Fixed {
        return @ptrCast(@alignCast(p.bytes[i * p.stride ..].ptr));
    }

    fn ram(p: Pool, i: usize) []u8 {
        return p.bytes[i * p.stride + @sizeOf(Gb.Fixed) ..][0..p.ram_len];
    }
};

/// 2048-gb with header byte 0x149 patched: 0 (no RAM), 1 (2 KB, the real
/// header) or 2 (8 KB), so one playable ROM covers every pool slot size.
fn pool_round_trip_and_replay(ram_code: u8, want_len: usize) !void {
    const gpa = std.testing.allocator;
    const rom = try load_rom(gpa);
    defer gpa.free(rom);
    rom[0x149] = ram_code;
    const r = core.Rom.from_slice(rom);
    const ram_len = core.mmu.cart_ram_len(&r);
    try std.testing.expectEqual(want_len, ram_len);

    const pads = try gpa.alloc(u8, frames);
    defer gpa.free(pads);
    script(pads);

    const pool = try Pool.init(gpa, keyframes + 1, ram_len);
    defer pool.deinit(gpa);
    // Full keyframes of the same instants, the reference.
    const kf = try gpa.alloc(Gb.Keyframe, keyframes + 1);
    defer gpa.free(kf);

    const gb = try gpa.create(Gb);
    defer gpa.destroy(gb);
    gb.* = Gb.init_rom(r);
    // Give cart RAM a pattern the game would not write, so the pool's RAM
    // bytes are visibly carried (with RAM enabled the game may change it).
    for (gb.cart_ram[0..ram_len], 0..) |*b, i| b.* = @truncate(i *% 13 +% ram_code);
    gb.snapshot_pool(pool.fixed(0), pool.ram(0));
    gb.snapshot(&kf[0]);
    for (pads, 1..) |p, f| {
        gb.step_frame(p);
        if (f % interval == 0) {
            gb.snapshot_pool(pool.fixed(f / interval), pool.ram(f / interval));
            gb.snapshot(&kf[f / interval]);
        }
    }
    try std.testing.expect(!std.meta.eql(kf[0].wram, kf[keyframes].wram));

    const re = try gpa.create(Gb);
    defer gpa.destroy(re);
    const got = try gpa.create(Gb.Keyframe);
    defer gpa.destroy(got);
    for (0..keyframes) |k| {
        // A console with unrelated history, cart RAM included: restore_pool
        // must overwrite everything the game can touch.
        re.* = Gb.init_rom(r);
        for (0..k % 7 + 3) |i| re.step_frame(@truncate(i * 37));
        @memset(re.cart_ram[0..ram_len], 0xEE);
        re.restore_pool(pool.fixed(k), pool.ram(k));
        re.snapshot(got);
        if (diff(got, &kf[k])) |field| {
            std.debug.print("ram {d}: keyframe {d}: field '{s}' differs after restore_pool\n", .{ ram_len, k, field });
            return error.PoolRoundTrip;
        }
        for (pads[k * interval ..][0..interval]) |p| re.step_frame(p);
        re.snapshot(got);
        if (diff(got, &kf[k + 1])) |field| {
            std.debug.print("ram {d}: keyframe {d} -> {d}: field '{s}' differs after replay\n", .{ ram_len, k, k + 1, field });
            return error.ReplayDiverged;
        }
    }
}

test "determinism: pool slots without cart RAM round-trip and replay" {
    try pool_round_trip_and_replay(0, 0);
}

test "determinism: pool slots with 2 KB cart RAM round-trip and replay" {
    try pool_round_trip_and_replay(1, 0x800);
}

test "determinism: pool slots with 8 KB cart RAM round-trip and replay" {
    try pool_round_trip_and_replay(2, 0x2000);
}

// Moved from core/gb.zig, where it never ran (see tests/all.zig).
test "determinism: keyframe round trip is exact" {
    const rom: [0x8000]u8 = @splat(0);
    var gb = Gb.init(&rom);
    var k: Gb.Keyframe = undefined;
    gb.snapshot(&k);
    var gb2 = Gb.init(&rom);
    gb2.wram[5] = 0xAA;
    gb2.restore(&k);
    try std.testing.expectEqual(@as(u8, 0), gb2.wram[5]);
}
