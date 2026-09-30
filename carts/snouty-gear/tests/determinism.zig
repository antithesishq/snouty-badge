//! SPEC.md section 10: the scrubber's promise. Run the shipped ROM
//! (roms/waternet.gg, read at run time from the repository root or the cart
//! directory; skipped if absent) for 600 frames with a scripted pad stream,
//! a full `Gg.Keyframe` every 30 frames, then restore each keyframe k into a
//! console with unrelated history, replay the 30 logged pads and require
//! keyframe k + 1 exactly. Keyframes are compared field by field
//! (`std.meta.eql`): the struct has auto layout, so its padding bytes are
//! not comparable. The first differing field is named (`vdp.<field>` for
//! the VDP, so VRAM and CRAM read as such).
//!
//! The same run then goes through the page store (`kstore.Store(128)`, the
//! frontend's default page size) with a pool large enough that nothing is
//! evicted: `get(age)` must reproduce every full keyframe, `matches` must
//! agree, and the restored console must replay to the next keyframe.
//! Ported from Snouty Boy's tests/determinism.zig in M3.
const std = @import("std");
const core = @import("core");
const Gg = core.Gg;
const Pad = core.Pad;
const kstore = core.kstore;

const interval = 30;
const keyframes = 20;
const frames = interval * keyframes;

/// Deterministic pad script: an LCG picks a button set and a burst length,
/// so directions and buttons are held for several frames at a time. Start
/// is pressed at 90..95 and 150..155 as in tools/scripts/m1_play.json, so
/// Waternet leaves its title screens and the rest plays the game.
fn script(pads: []u8) void {
    var seed: u32 = 0x5EED_0066;
    var i: usize = 0;
    while (i < pads.len) {
        seed = seed *% 1_664_525 +% 1_013_904_223;
        const r = seed >> 8;
        const pad: u8 = switch (r % 8) {
            0 => Pad.left,
            1 => Pad.right,
            2 => Pad.up,
            3 => Pad.down,
            4 => Pad.b1,
            5 => Pad.b2,
            6 => Pad.up | Pad.b1,
            else => 0,
        };
        const len = 2 + (r >> 4) % 12;
        var j: usize = 0;
        while (j < len and i < pads.len) : (j += 1) {
            pads[i] = pad;
            i += 1;
        }
    }
    for ([_]usize{ 90, 150 }) |at| {
        if (at + 6 <= pads.len) @memset(pads[at..][0..6], Pad.start);
    }
}

/// Tried in order (as tests/golden.zig): the test binary's working
/// directory depends on how the build runs it.
const prefixes = [_][]const u8{ "", "carts/snouty-gear/", "../", "../../" };

var rom_buf: [0x80000]u8 = undefined;

/// roms/waternet.gg, or skip the test.
fn load_rom() ![]u8 {
    for (prefixes) |pre| {
        var path_buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}roms/waternet.gg", .{pre});
        return std.Io.Dir.cwd().readFile(std.testing.io, path, &rom_buf) catch continue;
    }
    return error.SkipZigTest;
}

/// Name of the first differing field, or null if equal.
fn diff(a: *const Gg.Keyframe, b: *const Gg.Keyframe) ?[]const u8 {
    inline for (@typeInfo(Gg.Keyframe).@"struct".field_names) |name| {
        if (comptime std.mem.eql(u8, name, "vdp")) {
            inline for (@typeInfo(core.vdp.Vdp).@"struct".field_names) |v| {
                if (!std.meta.eql(@field(a.vdp, v), @field(b.vdp, v))) return "vdp." ++ v;
            }
        } else if (!std.meta.eql(@field(a, name), @field(b, name))) return name;
    }
    return null;
}

/// Put `re` through some frames of unrelated input and scribble over its
/// memory, so a restore that misses anything shows up.
fn scramble(re: *Gg, k: usize) void {
    for (0..k % 7 + 3) |i| re.step_frame(@truncate(i * 37));
    @memset(&re.cart_ram, 0xEE);
    @memset(&re.ram, 0x5A);
    @memset(&re.vdp.vram, 0xA5);
}

/// The live run: `kf[k]` after `k * interval` frames.
fn live_run(gg: *Gg, rom: []const u8, pads: []const u8, kf: []Gg.Keyframe) void {
    gg.init_in_place(core.Rom.from_slice(rom));
    gg.snapshot(&kf[0]);
    for (pads, 1..) |p, f| {
        gg.step_frame(p);
        if (f % interval == 0) gg.snapshot(&kf[f / interval]);
    }
}

test "determinism: replaying logged input from each keyframe reproduces the next" {
    const gpa = std.testing.allocator;
    const rom = try load_rom();
    var pads: [frames]u8 = undefined;
    script(&pads);

    const kf = try gpa.alloc(Gg.Keyframe, keyframes + 1);
    defer gpa.free(kf);
    const gg = try gpa.create(Gg);
    defer gpa.destroy(gg);
    live_run(gg, rom, &pads, kf);
    // The script must actually move the game: RAM and VRAM change.
    try std.testing.expect(!std.meta.eql(kf[0].ram, kf[keyframes].ram));
    try std.testing.expect(!std.meta.eql(kf[keyframes / 2].vdp.vram, kf[keyframes].vdp.vram));

    const re = try gpa.create(Gg);
    defer gpa.destroy(re);
    const got = try gpa.create(Gg.Keyframe);
    defer gpa.destroy(got);
    re.init_in_place(core.Rom.from_slice(rom));
    for (0..keyframes) |k| {
        scramble(re, k);
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
    const rom = try load_rom();
    var pads: [240]u8 = undefined;
    script(&pads);

    const a = try gpa.create(Gg);
    defer gpa.destroy(a);
    const b = try gpa.create(Gg);
    defer gpa.destroy(b);
    const k0 = try gpa.create(Gg.Keyframe);
    defer gpa.destroy(k0);
    const ka = try gpa.create(Gg.Keyframe);
    defer gpa.destroy(ka);
    const kb = try gpa.create(Gg.Keyframe);
    defer gpa.destroy(kb);

    a.init_in_place(core.Rom.from_slice(rom));
    for (pads[0..120]) |p| a.step_frame(p);
    a.snapshot(k0);

    b.init_in_place(core.Rom.from_slice(rom));
    for (0..77) |i| b.step_frame(@truncate(i * 37)); // unrelated history
    b.restore(k0);

    for (pads[120..], 120..) |p, f| {
        a.step_frame(p);
        b.step_frame(p);
        a.snapshot(ka);
        b.snapshot(kb);
        if (diff(ka, kb)) |field| {
            std.debug.print("frame {d}: field '{s}' differs\n", .{ f, field });
            return error.ReplayDiverged;
        }
    }
}

// ---- Through the page store ----

const page_size = 128;
const store_pages = kstore.pages_for(page_size, .{ @sizeOf(Gg.Small), 0x2000, 0x4000, core.cart_ram_size });
const TestStore = kstore.Store(page_size);
/// Big enough that nothing is evicted in 600 frames (21 full keyframes).
const test_pool_pages = 24 * store_pages;
const test_keyframes = 32;

test "determinism: page store (128 B pages) reproduces every keyframe and replays" {
    const gpa = std.testing.allocator;
    const rom = try load_rom();
    var pads: [frames]u8 = undefined;
    script(&pads);

    const kf = try gpa.alloc(Gg.Keyframe, keyframes + 1);
    defer gpa.free(kf);
    const mem = try gpa.alignedAlloc(u8, .@"4", kstore.bytes_for(page_size, test_pool_pages, test_keyframes, store_pages));
    defer gpa.free(mem);
    var store = TestStore.init(mem, test_pool_pages, test_keyframes, store_pages);
    var small: Gg.Small = undefined;

    const gg = try gpa.create(Gg);
    defer gpa.destroy(gg);
    gg.init_in_place(core.Rom.from_slice(rom));
    // Give cart RAM a pattern the game would not write, so the store's
    // cart RAM pages are visibly carried.
    for (&gg.cart_ram, 0..) |*b, i| b.* = @truncate(i *% 13 +% 1);
    gg.snapshot(&kf[0]);
    gg.save_small(&small);
    try store.put(gg.state_regions(&small));
    const first = store.last_copied;
    var min: usize = std.math.maxInt(usize);
    var max: usize = 0;
    var sum: usize = 0;
    for (pads, 1..) |p, f| {
        gg.step_frame(p);
        if (f % interval == 0) {
            gg.snapshot(&kf[f / interval]);
            gg.save_small(&small);
            try store.put(gg.state_regions(&small));
            min = @min(min, store.last_copied);
            max = @max(max, store.last_copied);
            sum += store.last_copied;
        }
    }
    try std.testing.expect(!std.meta.eql(kf[0].ram, kf[keyframes].ram));
    try std.testing.expectEqual(@as(usize, keyframes + 1), store.count);
    try std.testing.expectEqual(@as(usize, 0), store.last_evicted);
    try std.testing.expect(store.check());
    std.debug.print(
        "determinism: kstore waternet ({d} pages of {d} B per keyframe): first {d} pages, later min/avg/max {d}/{d}/{d} copied, pool {d} pages ({d} KB) for {d} keyframes\n",
        .{ store.n_pages, page_size, first, min, sum / keyframes, max, store.pages_in_use(), store.bytes_in_use() / 1024, store.count },
    );

    // `matches` agrees: the newest keyframe matches the live console.
    gg.save_small(&small);
    try std.testing.expect(store.matches(0, gg.state_regions(&small)));

    const re = try gpa.create(Gg);
    defer gpa.destroy(re);
    const got = try gpa.create(Gg.Keyframe);
    defer gpa.destroy(got);
    var re_small: Gg.Small = undefined;
    re.init_in_place(core.Rom.from_slice(rom));
    for (0..keyframes + 1) |k| {
        const age = keyframes - k;
        scramble(re, k);
        store.get(age, re.state_regions(&re_small));
        re.load_small(&re_small);
        re.snapshot(got);
        if (diff(got, &kf[k])) |field| {
            std.debug.print("keyframe {d}: field '{s}' differs after store restore\n", .{ k, field });
            return error.RestoreDiffers;
        }
        // The restored console matches its own age and (the state moves
        // every half second) not its neighbours'.
        re.save_small(&re_small);
        try std.testing.expect(store.matches(age, re.state_regions(&re_small)));
        if (age > 0) try std.testing.expect(!store.matches(age - 1, re.state_regions(&re_small)));
        if (age < keyframes) try std.testing.expect(!store.matches(age + 1, re.state_regions(&re_small)));
        if (k == keyframes) break;
        for (pads[k * interval ..][0..interval]) |p| re.step_frame(p);
        re.snapshot(got);
        if (diff(got, &kf[k + 1])) |field| {
            std.debug.print("keyframe {d} -> {d}: field '{s}' differs after replay\n", .{ k, k + 1, field });
            return error.ReplayDiverged;
        }
    }
    try std.testing.expect(store.check());
}

test "determinism: keyframe round trip is exact" {
    const rom: [0x8000]u8 = @splat(0);
    const gpa = std.testing.allocator;
    const a = try gpa.create(Gg);
    defer gpa.destroy(a);
    const k = try gpa.create(Gg.Keyframe);
    defer gpa.destroy(k);
    a.init_in_place(core.Rom.from_slice(&rom));
    a.snapshot(k);
    a.ram[5] = 0xAA;
    a.restore(k);
    try std.testing.expectEqual(@as(u8, 0), a.ram[5]);
}
