//! SPEC.md 10.2: the scrubber's promise. Run the shipped ROM (roms/2048.gb,
//! read at run time from the cart or the repository root; skipped if absent) for 600 frames with a scripted pad
//! stream, keyframe every 30 frames, then restore each keyframe k into a
//! fresh console, replay the 30 logged pads and require keyframe k + 1
//! exactly. Keyframes are compared field by field (`std.meta.eql`): the
//! struct has auto layout, so its padding bytes are not comparable.
//!
//! The same check runs through the page store (SPEC.md 19.3,
//! core/kstore.zig) on 2048-gb and, when fetched, on the Color ROMs
//! tests/roms/rex-runner.gb and tests/roms/rebound.gbc in CGB mode, and
//! prints the keyframe sizes the memory budget depends on.
const std = @import("std");
const core = @import("core");
const Gb = core.Gb;
const Pad = core.Pad;

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
    return load_rom_at(gpa, "roms/2048.gb");
}

/// A ROM by its path in the cart directory, from the repository root
/// (`zig build test`) or the cart directory; skips the test if absent.
fn load_rom_at(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var buf: [256]u8 = undefined;
    const rooted = try std.fmt.bufPrint(&buf, "carts/snouty-boy/{s}", .{path});
    for ([_][]const u8{ rooted, path }) |p| {
        return std.Io.Dir.cwd().readFileAlloc(std.testing.io, p, gpa, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
    }
    return error.SkipZigTest;
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
    gb.* = Gb.init_slice(rom, .dmg, &ram_a);
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
        re.* = Gb.init_slice(rom, .dmg, &ram_b);
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

    a.* = Gb.init_slice(rom, .dmg, &ram_a);
    for (pads[0..30]) |p| a.step_frame(p);
    a.snapshot(k0);

    b.* = Gb.init_slice(rom, .dmg, &ram_b);
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

    a.* = Gb.init_slice(rom, .dmg, &ram_a);
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

// ---- Through the page store (SPEC.md 19.3) ----

const kstore = core.kstore;
const page_size = 512;
const store_pages = kstore.pages_for(page_size, .{ @sizeOf(Gb.Small), 0x4000, 0x8000, Gb.max_cart_ram });
const TestStore = kstore.Store(page_size);
/// Big enough that nothing is evicted in 600 frames.
const test_pool_pages = 2048;
const test_keyframes = 32;

fn new_store(gpa: std.mem.Allocator) !struct { []align(4) u8, TestStore } {
    const mem = try gpa.alignedAlloc(u8, .@"4", kstore.bytes_for(page_size, test_pool_pages, test_keyframes, store_pages));
    return .{ mem, TestStore.init(mem, test_pool_pages, test_keyframes, store_pages) };
}

/// Live run with a keyframe put into the store every 30 frames (and a
/// direct `Gb.Keyframe` alongside), then for each k: restore keyframe k from
/// the store into a console with unrelated history, require it equal to the
/// direct keyframe, replay 30 pads and require keyframe k + 1. `r` may be
/// a fragmented image (a drive file); `label` names it in the output.
fn store_determinism(r: core.Rom, label: []const u8, model: core.Model, pads: []const u8) !void {
    const gpa = std.testing.allocator;
    const ram_len = core.mmu.cart_ram_len(&r);

    const kf = try gpa.alloc(Gb.Keyframe, keyframes + 1);
    defer gpa.free(kf);
    const mem, var store = try new_store(gpa);
    defer gpa.free(mem);
    var small: Gb.Small = undefined;

    const gb = try gpa.create(Gb);
    defer gpa.destroy(gb);
    gb.* = Gb.init(r, model, ram_a[0..ram_len]);
    // Give cart RAM a pattern the game would not write, so the store's RAM
    // pages are visibly carried (with RAM enabled the game may change it).
    for (gb.cart_ram, 0..) |*b, i| b.* = @truncate(i *% 13 +% 1);
    gb.snapshot(&kf[0]);
    gb.save_small(&small);
    try store.put(gb.state_regions(&small));
    const first = store.last_copied;
    var min: usize = std.math.maxInt(usize);
    var max: usize = 0;
    var sum: usize = 0;
    var live_pages: usize = 0;
    for (pads, 1..) |p, f| {
        gb.step_frame(p);
        if (f % interval == 0) {
            gb.snapshot(&kf[f / interval]);
            gb.save_small(&small);
            try store.put(gb.state_regions(&small));
            min = @min(min, store.last_copied);
            max = @max(max, store.last_copied);
            sum += store.last_copied;
            live_pages = @max(live_pages, store.n_pages - store.last_zero);
        }
    }
    try std.testing.expect(!std.meta.eql(kf[0].wram, kf[keyframes].wram));
    try std.testing.expectEqual(@as(usize, keyframes + 1), store.count);
    try std.testing.expect(store.check());
    std.debug.print(
        "kstore {s} ({s}, cart RAM {d} B, {d} pages of {d} B per keyframe): first keyframe {d} pages ({d} KB), " ++
            "later min/avg/max {d}/{d}/{d} pages, largest non-zero keyframe {d} pages ({d} KB), " ++
            "pool {d} pages ({d} KB) for {d} keyframes\n",
        .{ label, @tagName(model), ram_len, store.n_pages, page_size, first, first * page_size / 1024, min, sum / keyframes, max, live_pages, live_pages * page_size / 1024, store.pages_in_use(), store.bytes_in_use() / 1024, store.count },
    );

    const re = try gpa.create(Gb);
    defer gpa.destroy(re);
    const got = try gpa.create(Gb.Keyframe);
    defer gpa.destroy(got);
    for (0..keyframes) |k| {
        // A console with unrelated history, cart RAM included: the restore
        // must overwrite everything the game can touch.
        re.* = Gb.init(r, model, ram_b[0..ram_len]);
        for (0..k % 7 + 3) |i| re.step_frame(@truncate(i * 37));
        @memset(re.cart_ram, 0xEE);
        store.get(keyframes - k, re.state_regions(&small));
        re.load_small(&small);
        re.snapshot(got);
        if (diff(got, &kf[k])) |field| {
            std.debug.print("{s}: keyframe {d}: field '{s}' differs after store restore\n", .{ label, k, field });
            return error.RestoreDiffers;
        }
        for (pads[k * interval ..][0..interval]) |p| re.step_frame(p);
        re.snapshot(got);
        if (diff(got, &kf[k + 1])) |field| {
            std.debug.print("{s}: keyframe {d} -> {d}: field '{s}' differs after replay\n", .{ label, k, k + 1, field });
            return error.ReplayDiverged;
        }
    }
}

fn store_determinism_file(path: []const u8, model: core.Model) !void {
    const gpa = std.testing.allocator;
    const rom = try load_rom_at(gpa, path);
    defer gpa.free(rom);
    const pads = try gpa.alloc(u8, frames);
    defer gpa.free(pads);
    script(pads);
    // CGB titles sit on their title screen without Start; press it early.
    for (pads[40..44]) |*p| p.* = Pad.start;
    try store_determinism(core.Rom.from_slice(rom), path, model, pads);
}

test "determinism: page store over 2048-gb" {
    try store_determinism_file("roms/2048.gb", .dmg);
}

test "determinism: page store over rex-runner (CGB)" {
    try store_determinism_file("roms/rex-runner.gb", .cgb);
}

test "determinism: page store over rebound (CGB)" {
    try store_determinism_file("roms/rebound.gbc", .cgb);
}

/// A drive file's shape (M5): the image's 512-byte sectors stored in reverse
/// order, so no bank is contiguous and every ROM read takes the per-sector
/// slow path of `core.Rom`.
const Scattered = struct {
    storage: []u8,
    table: [][*]const u8,

    fn init(gpa: std.mem.Allocator, img: []const u8) !Scattered {
        const sector = core.rom_mod.sector_bytes;
        const n = (img.len + sector - 1) / sector;
        const storage = try gpa.alloc(u8, n * sector);
        errdefer gpa.free(storage);
        @memset(storage, 0xA5);
        const table = try gpa.alloc([*]const u8, n);
        for (0..n) |i| {
            const at = (n - 1 - i) * sector;
            const len = @min(sector, img.len - i * sector);
            @memcpy(storage[at..][0..len], img[i * sector ..][0..len]);
            table[i] = storage[at..].ptr;
        }
        return .{ .storage = storage, .table = table };
    }

    fn deinit(s: Scattered, gpa: std.mem.Allocator) void {
        gpa.free(s.table);
        gpa.free(s.storage);
    }
};

/// 2048-gb with header byte 0x149 patched: 0 (no RAM), 1 (2 KB, the real
/// header), 2 (8 KB) or 3 (32 KB), read from a fully fragmented image,
/// through the page store: every cart RAM size the store lays out.
fn fragmented_store_replay(ram_code: u8, want_len: usize) !void {
    const gpa = std.testing.allocator;
    const rom = try load_rom(gpa);
    defer gpa.free(rom);
    rom[0x149] = ram_code;
    const s = try Scattered.init(gpa, rom);
    defer s.deinit(gpa);
    const r = core.Rom.from_sectors(@intCast(rom.len), s.table);
    try std.testing.expectEqual(@as(u32, @intCast(rom.len / 0x4000)), r.fragmented_banks());
    try std.testing.expectEqual(want_len, core.mmu.cart_ram_len(&r));
    const pads = try gpa.alloc(u8, frames);
    defer gpa.free(pads);
    script(pads);
    try store_determinism(r, "2048-gb fragmented", .dmg, pads);
}

test "determinism: fragmented image, no cart RAM, through the store" {
    try fragmented_store_replay(0, 0);
}

test "determinism: fragmented image, 2 KB cart RAM, through the store" {
    try fragmented_store_replay(1, 0x800);
}

test "determinism: fragmented image, 8 KB cart RAM, through the store" {
    try fragmented_store_replay(2, 0x2000);
}

test "determinism: fragmented image, 32 KB cart RAM, through the store" {
    try fragmented_store_replay(3, 0x8000);
}

// Moved from core/gb.zig, where it never ran (see tests/all.zig).
test "determinism: keyframe round trip is exact" {
    const rom: [0x8000]u8 = @splat(0);
    var gb = Gb.init_slice(&rom, .dmg, &.{});
    var k: Gb.Keyframe = undefined;
    gb.snapshot(&k);
    var gb2 = Gb.init_slice(&rom, .dmg, &.{});
    gb2.wram[5] = 0xAA;
    gb2.restore(&k);
    try std.testing.expectEqual(@as(u8, 0), gb2.wram[5]);
}
