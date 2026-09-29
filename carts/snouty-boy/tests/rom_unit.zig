//! Tests for core/rom.zig and the MMU's cached bank pointers (PLAN.md M5
//! Track A). A ROM from the badge drive may be scattered over the drive's
//! 512-byte clusters; these tests build such images on the host by storing
//! the sectors out of order and require that the console cannot tell: the
//! same reads, the same keyframes, the same CRC as the contiguous image.
const std = @import("std");
const core = @import("core");
const Gb = core.Gb;
const Rom = core.Rom;
const rom_mod = core.rom_mod;

const sector = rom_mod.sector_bytes;

/// Cart RAM for the consoles below (their images declare none, or at most
/// what `cart_ram_len` allows).
var ram_a: [Gb.max_cart_ram]u8 align(4) = undefined;
var ram_b: [Gb.max_cart_ram]u8 align(4) = undefined;

/// A scattered copy of an image: `storage` holds the sectors in a shuffled
/// order and `table` points at each sector in file order, the shape the
/// frontend builds from `romfs.Mapped.chunk`.
const Scattered = struct {
    storage: []u8,
    table: [][*]const u8,

    /// `keep(i)` true leaves sector i in place (so its bank may stay
    /// contiguous); the others are reversed among themselves, so no two
    /// neighbours in file order are neighbours in memory.
    fn init(gpa: std.mem.Allocator, img: []const u8, keep: *const fn (usize) bool) !Scattered {
        const n = (img.len + sector - 1) / sector;
        const storage = try gpa.alloc(u8, n * sector);
        errdefer gpa.free(storage);
        @memset(storage, 0xA5); // bytes past `len` in the last sector are junk
        const table = try gpa.alloc([*]const u8, n);
        errdefer gpa.free(table);
        // Sector i goes to slot[i]: itself when kept, else its mirror
        // position among the moved sectors.
        const slot = try gpa.alloc(usize, n);
        defer gpa.free(slot);
        for (slot, 0..) |*d, i| d.* = i;
        var lo: usize = 0;
        var hi: usize = n;
        while (true) {
            while (lo < n and keep(lo)) lo += 1;
            while (hi > 0 and keep(hi - 1)) hi -= 1;
            if (lo + 1 >= hi) break;
            slot[lo] = hi - 1;
            slot[hi - 1] = lo;
            lo += 1;
            hi -= 1;
        }
        for (0..n) |i| {
            const src = img[i * sector .. @min(img.len, (i + 1) * sector)];
            @memcpy(storage[slot[i] * sector ..][0..src.len], src);
            table[i] = storage[slot[i] * sector ..].ptr;
        }
        return .{ .storage = storage, .table = table };
    }

    fn deinit(s: Scattered, gpa: std.mem.Allocator) void {
        gpa.free(s.table);
        gpa.free(s.storage);
    }

    fn rom(s: Scattered, len: usize) Rom {
        return Rom.from_sectors(@intCast(len), s.table);
    }
};

fn keep_none(_: usize) bool {
    return false;
}

/// Bank 0 stays contiguous (so `Gb.rom0` is a direct pointer) and every
/// other bank is scattered (so `Gb.romn` is null): both MMU paths in one run.
fn keep_bank0(i: usize) bool {
    return i < rom_mod.bank_bytes / sector;
}

/// An MBC ROM image whose every byte names its bank and offset, so a read
/// shows which bank was mapped. Header at 0x147..0x149 set as given.
fn marked_image(gpa: std.mem.Allocator, len: usize, cart_type: u8, ram_code: u8) ![]u8 {
    const img = try gpa.alloc(u8, len);
    for (img, 0..) |*b, i| b.* = @truncate((i / rom_mod.bank_bytes) *% 0x9D +% (i % 251));
    img[0x147] = cart_type;
    img[0x148] = 0;
    img[0x149] = ram_code;
    return img;
}

/// The pre-M5 MMU read of 0x0000..0x7FFF, from `Gb.rom` as a plain slice
/// (git show d4af03c:carts/snouty-boy/core/mmu.zig). The pointer table must
/// read exactly this for every bank register value.
fn slice_read(bytes: []const u8, mbc: core.mmu.Mbc, addr: u16) u8 {
    const off: u32 = if (addr < 0x4000) mbc.rom0_offset + addr else mbc.rom_bank_offset + (addr - 0x4000);
    return if (off < bytes.len) bytes[off] else 0xFF;
}

/// Name of the first differing keyframe field, or null if equal.
fn diff(a: *const Gb.Keyframe, b: *const Gb.Keyframe) ?[]const u8 {
    inline for (@typeInfo(Gb.Keyframe).@"struct".field_names) |name| {
        if (!std.meta.eql(@field(a, name), @field(b, name))) return name;
    }
    return null;
}

test "rom: from_sectors with every bank fragmented" {
    const gpa = std.testing.allocator;
    // 64 KB plus a partial last sector, as a drive file of odd length.
    const len = 0x10000 + 0x123;
    const img = try gpa.alloc(u8, len);
    defer gpa.free(img);
    for (img, 0..) |*b, i| b.* = @truncate(i ^ (i >> 9) ^ (i >> 15));
    const s = try Scattered.init(gpa, img, &keep_none);
    defer s.deinit(gpa);
    const r = s.rom(len);

    try std.testing.expectEqual(@as(u32, len), r.len);
    for (r.banks) |b| try std.testing.expect(b == null);
    // Four full banks, all through the table; the partial fifth is not
    // counted (it can never be a direct pointer).
    try std.testing.expectEqual(@as(u32, 4), r.fragmented_banks());
    for (img, 0..) |want, i| try std.testing.expectEqual(want, r.read(@intCast(i)));
    try std.testing.expectEqual(@as(u8, 0xFF), r.read(len));
    try std.testing.expectEqual(@as(u8, 0xFF), r.read(rom_mod.max_bytes));
    try std.testing.expectEqual(std.hash.Crc32.hash(img), r.crc32());
}

test "rom: a contiguous drive file maps every bank directly" {
    const gpa = std.testing.allocator;
    const img = try marked_image(gpa, 0x10000, 0x01, 0);
    defer gpa.free(img);
    var table: [0x10000 / sector][*]const u8 = undefined;
    for (&table, 0..) |*t, i| t.* = img[i * sector ..].ptr;
    const r = Rom.from_sectors(@intCast(img.len), &table);
    try std.testing.expectEqual(@as(u32, 0), r.fragmented_banks());
    for (0..4) |b| try std.testing.expectEqual(@as(?[*]const u8, img[b * 0x4000 ..].ptr), r.bank_ptr(@intCast(b)));
    try std.testing.expectEqual(std.hash.Crc32.hash(img), r.crc32());
}

/// `Gb.step_frame` one instruction at a time, noting every switchable bank
/// mapped along the way (cpu_instrs switches banks to copy a sub-test into
/// WRAM and is back in bank 1 by the end of the frame). If this loop drifted
/// from `step_frame`, the keyframe comparison below would catch it.
fn step_frame_watching(gb: *Gb, pad: u8, banks_seen: *u64) void {
    gb.pad = pad;
    core.joypad.update(gb);
    gb.frame_dots = 0;
    gb.vblank_hit = false;
    while (!gb.vblank_hit and gb.frame_dots < core.frame_dots * 2) {
        gb.step_instruction();
        banks_seen.* |= @as(u64, 1) << @intCast(gb.mbc.rom_bank_offset / 0x4000);
        if (!core.ppu.lcd_on(gb) and gb.frame_dots >= core.frame_dots) break;
    }
    gb.sync();
    gb.frame_count +%= 1;
}

/// Run cpu_instrs.gb (64 KB MBC1: it switches banks between its sub-tests)
/// embedded and from a scattered image side by side until it reports
/// Passed, and require identical keyframes every frame.
fn cpu_instrs_both_ways(keep: *const fn (usize) bool, expect_rom0_direct: bool) !void {
    const gpa = std.testing.allocator;
    const img = @embedFile("roms/cpu_instrs.gb");
    const s = try Scattered.init(gpa, img, keep);
    defer s.deinit(gpa);
    const r = s.rom(img.len);
    try std.testing.expectEqual(std.hash.Crc32.hash(img), r.crc32());

    const a = try gpa.create(Gb);
    defer gpa.destroy(a);
    const b = try gpa.create(Gb);
    defer gpa.destroy(b);
    const ka = try gpa.create(Gb.Keyframe);
    defer gpa.destroy(ka);
    const kb = try gpa.create(Gb.Keyframe);
    defer gpa.destroy(kb);
    a.* = Gb.init_slice(img, .dmg, &ram_a);
    b.* = Gb.init(r, .dmg, &ram_b);
    try std.testing.expectEqual(core.mmu.MbcKind.mbc1, b.mbc.kind);
    try std.testing.expectEqual(expect_rom0_direct, b.rom0 != null);
    try std.testing.expect(b.romn == null);

    var banks_seen: u64 = 0; // bit per switchable bank ever mapped
    var f: u32 = 0;
    while (std.mem.indexOf(u8, a.serial.text(), "Passed") == null) : (f += 1) {
        if (f == 4000) return error.BlarggTimeout;
        a.step_frame(0);
        step_frame_watching(b, 0, &banks_seen);
        if (b.romn != null) return error.ScatteredBankMappedDirectly;
        a.snapshot(ka);
        b.snapshot(kb);
        if (diff(ka, kb)) |field| {
            std.debug.print("frame {d}: field '{s}' differs (embedded vs scattered)\n", .{ f, field });
            return error.RomPathsDiverged;
        }
    }
    // The run must have left bank 1: otherwise the MBC path was not tested.
    if (@popCount(banks_seen) < 3) {
        std.debug.print("banks mapped: {b}\n", .{banks_seen});
        return error.NoBankSwitch;
    }
    try std.testing.expectEqualStrings(a.serial.text(), b.serial.text());
}

test "rom: cpu_instrs from a fully fragmented image equals embedded" {
    try cpu_instrs_both_ways(&keep_none, false);
}

test "rom: cpu_instrs with only bank 0 contiguous equals embedded" {
    try cpu_instrs_both_ways(&keep_bank0, true);
}

test "rom: remap_rom after restoring a keyframe taken in another bank" {
    const gpa = std.testing.allocator;
    // 1 MB MBC1 so mode 1 can map bank 0x20 at 0x0000 (rom0 path) too.
    const img = try marked_image(gpa, rom_mod.max_bytes, 0x01, 0);
    defer gpa.free(img);
    const s = try Scattered.init(gpa, img, &keep_bank0);
    defer s.deinit(gpa);
    const roms = [_]Rom{ Rom.from_slice(img), s.rom(img.len) };

    for (roms) |r| {
        const gb = try gpa.create(Gb);
        defer gpa.destroy(gb);
        const k = try gpa.create(Gb.Keyframe);
        defer gpa.destroy(k);

        gb.* = Gb.init(r, .dmg, &ram_a);
        gb.write8(0x2000, 0x05); // low bank bits
        gb.write8(0x4000, 0x01); // upper bits: bank 0x25
        gb.write8(0x6000, 0x01); // mode 1: bank 0x20 at 0x0000
        try std.testing.expectEqual(img[0x25 * 0x4000 + 7], gb.read8(0x4007));
        try std.testing.expectEqual(img[0x20 * 0x4000 + 9], gb.read8(0x0009));
        gb.snapshot(k);

        // Somewhere else entirely, then back.
        gb.write8(0x6000, 0x00);
        gb.write8(0x4000, 0x00);
        gb.write8(0x2000, 0x03);
        try std.testing.expectEqual(img[3 * 0x4000 + 7], gb.read8(0x4007));
        try std.testing.expectEqual(img[9], gb.read8(0x0009));
        gb.restore(k);
        try std.testing.expectEqual(r.bank_ptr(0x25), gb.romn);
        try std.testing.expectEqual(r.bank_ptr(0x20), gb.rom0);
        try std.testing.expectEqual(img[0x25 * 0x4000 + 7], gb.read8(0x4007));
        try std.testing.expectEqual(img[0x20 * 0x4000 + 9], gb.read8(0x0009));

        // Into a console that never switched: the pointers come from the
        // keyframe's MBC, not from whatever the console had cached.
        gb.* = Gb.init(r, .dmg, &ram_a);
        try std.testing.expectEqual(img[1 * 0x4000], gb.read8(0x4000));
        gb.restore(k);
        try std.testing.expectEqual(img[0x25 * 0x4000 + 7], gb.read8(0x4007));
        try std.testing.expectEqual(img[0x20 * 0x4000 + 9], gb.read8(0x0009));

        // And through the page store, as the frontend keeps keyframes.
        const page = 512;
        const pages = core.kstore.pages_for(page, .{ @sizeOf(Gb.Small), 0x4000, 0x8000, 0 });
        const mem = try gpa.alignedAlloc(u8, .@"4", core.kstore.bytes_for(page, pages, 2, pages));
        defer gpa.free(mem);
        var store = core.kstore.Store(page).init(mem, pages, 2, pages);
        var small: Gb.Small = undefined;
        gb.* = Gb.init(r, .dmg, ram_a[0..0]);
        gb.restore(k);
        gb.save_small(&small);
        try store.put(gb.state_regions(&small));
        gb.* = Gb.init(r, .dmg, ram_a[0..0]);
        store.get(0, gb.state_regions(&small));
        gb.load_small(&small);
        try std.testing.expectEqual(img[0x25 * 0x4000 + 7], gb.read8(0x4007));
        try std.testing.expectEqual(img[0x20 * 0x4000 + 9], gb.read8(0x0009));
    }
}

/// Every ROM bank register value, both MBC1 modes, as the old slice code.
fn sweep_against_slice(bytes: []const u8, r: Rom, cart_type: u8) !void {
    const gpa = std.testing.allocator;
    const gb = try gpa.create(Gb);
    defer gpa.destroy(gb);
    gb.* = Gb.init(r, .dmg, &ram_a);
    const addrs = [_]u16{ 0x0000, 0x0150, 0x1FFF, 0x3FFF, 0x4000, 0x4001, 0x5A5A, 0x7FFF };
    const mbc5 = cart_type >= 0x19;
    for (0..2) |mode| {
        if (!mbc5) gb.write8(0x6000, @intCast(mode));
        for (0..4) |upper| {
            // MBC1: the 2-bit upper register; MBC5: bit 8 of the bank.
            if (mbc5) gb.write8(0x3000, @intCast(upper)) else gb.write8(0x4000, @intCast(upper));
            for (0..256) |low| {
                gb.write8(0x2000, @intCast(low));
                for (addrs) |a| {
                    const want = slice_read(bytes, gb.mbc, a);
                    const got = gb.read8(a);
                    if (want != got) {
                        std.debug.print("len {d} type {X:0>2} mode {d} upper {d} bank {d} addr {X:0>4}: slice {X:0>2}, rom {X:0>2}\n", .{ bytes.len, cart_type, mode, upper, low, a, want, got });
                        return error.ReadDiffers;
                    }
                }
            }
        }
    }
}

test "rom: bank reads equal the old slice code (1 MB cap, folding, open bus)" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { len: usize, cart_type: u8 }{
        .{ .len = 0x8000, .cart_type = 0x01 },
        .{ .len = 0xC000, .cart_type = 0x01 }, // 48 KB: bank 3 is past the end
        .{ .len = 0x10000, .cart_type = 0x01 },
        .{ .len = 0x10000 + 0x150, .cart_type = 0x19 }, // partial last bank
        .{ .len = rom_mod.max_bytes, .cart_type = 0x01 },
        .{ .len = rom_mod.max_bytes, .cart_type = 0x19 },
    };
    for (cases) |c| {
        const img = try marked_image(gpa, c.len, c.cart_type, 0);
        defer gpa.free(img);
        try sweep_against_slice(img, Rom.from_slice(img), c.cart_type);
        const s = try Scattered.init(gpa, img, &keep_bank0);
        defer s.deinit(gpa);
        try sweep_against_slice(img, s.rom(img.len), c.cart_type);
    }
}

test "rom: a 1 MB image folds banks; a bigger one is capped to it" {
    const gpa = std.testing.allocator;
    // 1.5 MB MBC5: the core keeps the first 1 MB (SPEC.md 11) and masks bank
    // numbers as for a 1 MB ROM, so bank 0x50 reads bank 0x10.
    const big = try marked_image(gpa, rom_mod.max_bytes + rom_mod.max_bytes / 2, 0x19, 0);
    defer gpa.free(big);
    const r = Rom.from_slice(big);
    try std.testing.expectEqual(rom_mod.max_bytes, r.len);
    const gb = try gpa.create(Gb);
    defer gpa.destroy(gb);
    gb.* = Gb.init(r, .dmg, &ram_a);
    try std.testing.expectEqual(@as(u16, 63), gb.mbc.rom_bank_mask);
    gb.write8(0x2000, 0x50);
    try std.testing.expectEqual(big[0x10 * 0x4000 + 3], gb.read8(0x4003));
    gb.write8(0x2000, 0x40); // folds to bank 0
    try std.testing.expectEqual(big[3], gb.read8(0x4003));
    gb.write8(0x3000, 0x01); // bank 0x140 folds to 0 as well
    try std.testing.expectEqual(big[3], gb.read8(0x4003));
    // The capped image behaves as the first 1 MB on its own.
    try sweep_against_slice(big[0..rom_mod.max_bytes], r, 0x19);
    try std.testing.expectEqual(std.hash.Crc32.hash(big[0..rom_mod.max_bytes]), r.crc32());

    // The same from sectors: a drive file longer than the cap.
    const s = try Scattered.init(gpa, big, &keep_bank0);
    defer s.deinit(gpa);
    const rs = s.rom(big.len);
    try std.testing.expectEqual(rom_mod.max_bytes, rs.len);
    try std.testing.expectEqual(@as(u32, 63), rs.fragmented_banks());
    try sweep_against_slice(big[0..rom_mod.max_bytes], rs, 0x19);
}

test "rom: a 48 KB image reads 0xFF in bank 3, as the slice code did" {
    const gpa = std.testing.allocator;
    const img = try marked_image(gpa, 0xC000, 0x01, 0);
    defer gpa.free(img);
    const s = try Scattered.init(gpa, img, &keep_none);
    defer s.deinit(gpa);
    for ([_]Rom{ Rom.from_slice(img), s.rom(img.len) }) |r| {
        const gb = try gpa.create(Gb);
        defer gpa.destroy(gb);
        gb.* = Gb.init(r, .dmg, &ram_a);
        // 3 banks round up to 4: mask 3, so bank 3 is not folded away.
        try std.testing.expectEqual(@as(u16, 3), gb.mbc.rom_bank_mask);
        gb.write8(0x2000, 2);
        try std.testing.expectEqual(img[2 * 0x4000 + 0x3FFF], gb.read8(0x7FFF));
        gb.write8(0x2000, 3);
        try std.testing.expect(gb.romn == null);
        try std.testing.expectEqual(@as(u8, 0xFF), gb.read8(0x4000));
        try std.testing.expectEqual(@as(u8, 0xFF), gb.read8(0x7FFF));
        gb.write8(0x2000, 7); // folds to 3
        try std.testing.expectEqual(@as(u8, 0xFF), gb.read8(0x5555));
    }
}

test "rom: crc32 of a fragmented image equals the original bytes' CRC" {
    const gpa = std.testing.allocator;
    const img = @embedFile("roms/cpu_instrs.gb");
    const want = std.hash.Crc32.hash(img);
    inline for (.{ &keep_none, &keep_bank0 }) |keep| {
        const s = try Scattered.init(gpa, img, keep);
        defer s.deinit(gpa);
        try std.testing.expectEqual(want, s.rom(img.len).crc32());
    }
    try std.testing.expectEqual(want, Rom.from_slice(img).crc32());
}

test "rom: cart_ram_len and the header read through a fragmented image" {
    const gpa = std.testing.allocator;
    for ([_]struct { code: u8, len: usize }{ .{ .code = 0, .len = 0 }, .{ .code = 1, .len = 0x800 }, .{ .code = 2, .len = 0x2000 }, .{ .code = 3, .len = 0x8000 } }) |c| {
        const img = try marked_image(gpa, 0x8000, 0x03, c.code);
        defer gpa.free(img);
        const s = try Scattered.init(gpa, img, &keep_none);
        defer s.deinit(gpa);
        const r = s.rom(img.len);
        try std.testing.expectEqual(c.len, core.mmu.cart_ram_len(&r));
        try std.testing.expectEqual(c.len, core.mmu.ram_len_for(c.code));
        const m = core.mmu.Mbc.from_header(&r);
        try std.testing.expectEqual(core.mmu.MbcKind.mbc1, m.kind);
        try std.testing.expectEqual(c.code != 0, m.has_ram);
    }
}

// Moved from core/rom.zig: tests in the core module do not run under
// tests/all.zig (only the root module's tests do).

test "rom: from_slice: full banks direct, partial tail through read" {
    var img: [0x4000 + 0x150]u8 = undefined;
    for (&img, 0..) |*b, i| b.* = @truncate(i * 7);
    const r = Rom.from_slice(&img);
    try std.testing.expectEqual(@as(u32, img.len), r.len);
    try std.testing.expect(r.banks[0] != null);
    try std.testing.expect(r.banks[1] == null);
    try std.testing.expectEqual(img[0x3FFF], r.read(0x3FFF));
    try std.testing.expectEqual(img[0x4000], r.read(0x4000));
    try std.testing.expectEqual(img[0x414F], r.read(0x414F));
    try std.testing.expectEqual(@as(u8, 0xFF), r.read(0x4150));
    try std.testing.expectEqual(@as(u8, 0xFF), r.read(0x7FFF));
    try std.testing.expectEqual(@as(u8, 0xFF), r.read(rom_mod.max_bytes));
    try std.testing.expectEqual(@as(u32, 0), r.fragmented_banks());
    try std.testing.expectEqual(std.hash.Crc32.hash(&img), r.crc32());
}

test "rom: from_sectors: contiguous banks direct, shuffled ones through the table" {
    // A 32 KB image whose second bank is stored with two sectors swapped.
    var img: [0x8000]u8 = undefined;
    for (&img, 0..) |*b, i| b.* = @truncate(i ^ (i >> 8));
    var storage: [0x8000]u8 = img;
    std.mem.swap([512]u8, storage[0x4000..][0..512], storage[0x4200..][0..512]);
    var sectors: [64][*]const u8 = undefined;
    for (&sectors, 0..) |*s, i| s.* = storage[i * 512 ..].ptr;
    std.mem.swap([*]const u8, &sectors[32], &sectors[33]);
    const r = Rom.from_sectors(img.len, &sectors);
    try std.testing.expect(r.banks[0] != null);
    try std.testing.expect(r.banks[1] == null);
    try std.testing.expectEqual(@as(u32, 1), r.fragmented_banks());
    for (img, 0..) |want, i| try std.testing.expectEqual(want, r.read(@intCast(i)));
    try std.testing.expectEqual(std.hash.Crc32.hash(&img), r.crc32());
}

test "rom: from_sectors: a table shorter than len caps the image" {
    var img: [0x4000]u8 = undefined;
    for (&img, 0..) |*b, i| b.* = @truncate(i);
    var sectors: [4][*]const u8 = undefined;
    for (&sectors, 0..) |*s, i| s.* = img[i * 512 ..].ptr;
    const r = Rom.from_sectors(img.len, &sectors);
    try std.testing.expectEqual(@as(u32, 4 * 512), r.len);
    try std.testing.expectEqual(img[4 * 512 - 1], r.read(4 * 512 - 1));
    try std.testing.expectEqual(@as(u8, 0xFF), r.read(4 * 512));
    try std.testing.expectEqual(std.hash.Crc32.hash(img[0 .. 4 * 512]), r.crc32());
}
