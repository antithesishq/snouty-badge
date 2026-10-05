//! The battery save (cart/src/frontend/battery.zig) against lib/save.zig's
//! host fake, and the core's side of it: MBC2's nibble RAM, the cart RAM
//! dirty flag, `keep_cart_ram`. `tests/fixtures/saves.img` is a FAT12 drive
//! image (tools/make_romfs.py, truncated, `--fragment 3`) with these files:
//!
//!   Pocket Game.gb (336 B), Pocket Game.SAV (8192 B, byte i = i*7+3),
//!   Wrong Size.sav (100 B), Wrong Size.gb, Clock Game.sav (2048 B,
//!   byte i = i*5+1, then a 48-byte clock trailer of 0xEE),
//!   nibble.sav (512 B, byte i = i & 0x0F)
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const battery = @import("battery");
const save = battery.save_api;
const romfs = battery.romfs_api;
const Gb = core.Gb;

const saves_img = @embedFile("fixtures/saves.img");

/// A 32 KB ROM of zeros with this header.
fn make_rom(cart_type: u8, ram_code: u8, title: []const u8, checksum: u16) [0x8000]u8 {
    var rom: [0x8000]u8 = @splat(0);
    @memcpy(rom[0x134..][0..title.len], title);
    rom[0x147] = cart_type;
    rom[0x149] = ram_code;
    rom[0x14E] = @truncate(checksum >> 8);
    rom[0x14F] = @truncate(checksum);
    return rom;
}

/// The arena's shape (frontend/rewind.zig `layout`): the 16-byte header
/// slot, then the console's cart RAM.
var blob_buf: [battery.header_len + Gb.max_cart_ram]u8 align(4) = undefined;

const Rig = struct {
    rom: [0x8000]u8,
    gb: *Gb,
    blob: []u8,

    fn init(r: *Rig, cart_type: u8, ram_code: u8, title: []const u8) !void {
        r.rom = make_rom(cart_type, ram_code, title, 0xBEEF);
        const rom = core.Rom.from_slice(&r.rom);
        const len = core.mmu.cart_ram_len(&rom);
        r.blob = blob_buf[0 .. battery.header_len + len];
        @memset(r.blob, 0xAA);
        r.gb = try testing.allocator.create(Gb);
        r.gb.* = Gb.init(rom, .dmg, r.blob[battery.header_len..]);
    }

    fn deinit(r: *Rig) void {
        testing.allocator.destroy(r.gb);
    }

    fn cart(r: *const Rig) battery.Cart {
        return .from_rom(&r.gb.rom);
    }

    /// A fresh boot of the same ROM: the console reset (RAM cleared), the
    /// battery set up again; the store keeps its blobs.
    fn boot(r: *Rig, b: *battery.Battery, drive: ?battery.Drive, now: u32) void {
        r.gb.keep_cart_ram = false;
        r.gb.reset();
        b.begin(r.cart(), r.blob, save.supported(), drive, now);
        r.gb.keep_cart_ram = b.active;
    }

    /// The game writes `v` at cart RAM address `addr` (RAM enabled first).
    fn game_write(r: *Rig, addr: u16, v: u8) void {
        r.gb.write8(0x0000, 0x0A);
        r.gb.write8(addr, v);
    }
};

fn key_of(cart_type: u8, title: []const u8, checksum: u16) ![]const u8 {
    const rom = make_rom(cart_type, 2, title, checksum);
    const c: battery.Cart = .from_rom(&core.Rom.from_slice(&rom));
    const S = struct {
        var buf: [save.max_key]u8 = undefined;
    };
    return battery.make_key(&S.buf, &c);
}

test "battery: keys" {
    try testing.expectEqualStrings("boy/2048-gb    XXXX/8367", try key_of(0x03, "2048-gb    XXXX", 0x8367));
    // CGB flag at 0x143: the title is 15 bytes; it stops at the first 0.
    var t: [16]u8 = @splat(0);
    @memcpy(t[0..10], "Rex Runner");
    @memcpy(t[11..15], "RXRN");
    t[15] = 0x80;
    try testing.expectEqualStrings("boy/Rex Runner/5178", try key_of(0x1B, &t, 0x5178));
    try testing.expectEqualStrings("boy/TETRIS DX/C800", try key_of(0x03, "TETRIS DX\x00\x00\x00\x00\x00\x00\x80", 0xC800));
    // '/' and bytes outside 0x20..0x7E become '_', spaces are trimmed.
    try testing.expectEqualStrings("boy/A_B_C/0001", try key_of(0x03, "  A/B\x7FC ", 0x0001));
    try testing.expectEqualStrings("boy/untitled/FFFF", try key_of(0x03, "", 0xFFFF));
    const k = try key_of(0x03, "0123456789ABCDEF", 0x1234);
    try testing.expect(k.len <= save.max_key);
    try testing.expect(save.validKey(k));
}

test "battery: MBC2 nibble RAM, banking, dirty flag" {
    // 64 KB: four banks, bank n's first byte is n.
    var rom: [0x10000]u8 = @splat(0);
    @memcpy(rom[0..0x150], make_rom(0x06, 0, "NIBBLES", 1)[0..0x150]);
    for (1..4) |n| rom[n * 0x4000] = @intCast(n);
    const r = core.Rom.from_slice(&rom);
    try testing.expectEqual(@as(usize, 512), core.mmu.cart_ram_len(&r));
    try testing.expect(core.mmu.has_battery(0x06));
    const ram = blob_buf[0..512];
    const gb = try testing.allocator.create(Gb);
    defer testing.allocator.destroy(gb);
    gb.* = Gb.init(r, .dmg, ram);
    try testing.expectEqual(core.mmu.MbcKind.mbc2, gb.mbc.kind);
    // Reset leaves the nibbles reading 0xF0; RAM is off until enabled.
    try testing.expect(std.mem.allEqual(u8, ram, 0xF0));
    try testing.expectEqual(@as(u8, 0xFF), gb.read8(0xA000));
    // Address bit 8 set: the ROM bank register, not RAM enable.
    gb.write8(0x2100, 0x0A);
    try testing.expectEqual(@as(u8, 0xFF), gb.read8(0xA000));
    try testing.expectEqual(@as(u8, 2), gb.read8(0x4000));
    gb.write8(0x2100, 0x00); // bank 0 reads as 1
    try testing.expectEqual(@as(u8, 1), gb.read8(0x4000));
    gb.write8(0x3100, 0x13); // 4 bits
    try testing.expectEqual(@as(u8, 3), gb.read8(0x4000));
    // Bit 8 clear: RAM enable.
    try testing.expect(!gb.sram_dirty);
    gb.write8(0x0000, 0x0A);
    gb.write8(0xA000, 0x5A);
    try testing.expect(gb.sram_dirty);
    try testing.expectEqual(@as(u8, 0xFA), gb.read8(0xA000));
    try testing.expectEqual(@as(u8, 0xFA), ram[0]);
    // 512 nibbles mirrored over A000..BFFF.
    try testing.expectEqual(@as(u8, 0xFA), gb.read8(0xA200));
    gb.write8(0xBFFF, 0x03);
    try testing.expectEqual(@as(u8, 0xF3), gb.read8(0xA1FF));
    // Writes to 0x4000..0x7FFF do nothing on an MBC2.
    gb.write8(0x4000, 0x00);
    try testing.expectEqual(@as(u8, 3), gb.read8(0x4000));
    // Disabled: no write, no dirty flag.
    gb.write8(0x0000, 0x00);
    gb.sram_dirty = false;
    gb.write8(0xA001, 0x07);
    try testing.expect(!gb.sram_dirty);
    try testing.expectEqual(@as(u8, 0xF0), ram[1]);
    // `keep_cart_ram`: a reset is a power cycle with a battery.
    gb.keep_cart_ram = true;
    gb.reset();
    try testing.expectEqual(@as(u8, 0xFA), ram[0]);
    gb.keep_cart_ram = false;
    gb.reset();
    try testing.expectEqual(@as(u8, 0xF0), ram[0]);
}

test "battery: stock firmware: nothing at all" {
    save.fake.reset();
    save.fake.setSupported(false);
    var r: Rig = undefined;
    try r.init(0x03, 2, "GAME");
    defer r.deinit();
    var b: battery.Battery = .{};
    r.boot(&b, null, 0);
    try testing.expect(!b.active);
    try testing.expectEqual(battery.Status.off, b.status);
    r.game_write(0xA000, 1);
    b.note_writes(r.gb, 10);
    try testing.expect(!b.auto_due(1000));
    b.request();
    try testing.expect(!b.requested);
    b.flush(1000);
    try testing.expectEqual(@as(u32, 0), save.fake.commits());
    try testing.expect(!r.gb.keep_cart_ram);
}

test "battery: no battery, too big, no RAM" {
    save.fake.reset();
    var b: battery.Battery = .{};
    var r: Rig = undefined;
    try r.init(0x01, 2, "NOBATT"); // MBC1 + RAM, no battery
    r.boot(&b, null, 0);
    try testing.expect(!b.active);
    try testing.expectEqual(battery.Status.no_battery, b.status);
    var buf: [24]u8 = undefined;
    try testing.expectEqualStrings("No battery RAM", b.about_line(&buf));
    r.deinit();
    try r.init(0x0F, 0, "CLOCK"); // MBC3 + timer + battery, no RAM
    r.boot(&b, null, 0);
    try testing.expectEqual(battery.Status.no_battery, b.status);
    r.deinit();
    try r.init(0x1B, 4, "HUGE"); // 128 KB declared: over save.max_blob
    r.boot(&b, null, 0);
    try testing.expect(!b.active);
    try testing.expectEqual(battery.Status.too_big, b.status);
    try testing.expectEqualStrings("SRAM 128K: no save", b.about_line(&buf));
    r.deinit();
    try r.init(0x1B, 5, "SIXTYFOUR"); // 64 KB declared, 32 KB emulated: fits
    r.boot(&b, null, 0);
    try testing.expect(b.active);
    try testing.expectEqual(@as(usize, battery.header_len + 0x8000), b.blob.len);
    r.deinit();
    try testing.expectEqual(@as(u32, 0), save.fake.commits());
}

test "battery: save, load on the next boot, mismatches ignored" {
    save.fake.reset();
    var r: Rig = undefined;
    try r.init(0x03, 2, "POCKET");
    defer r.deinit();
    var b: battery.Battery = .{};
    r.boot(&b, null, 0);
    try testing.expect(b.active);
    try testing.expectEqual(battery.Status.fresh, b.status);
    try testing.expect(std.mem.allEqual(u8, b.ram(), 0));
    try testing.expectEqualStrings("boy/POCKET/BEEF", b.key());
    r.game_write(0xA123, 0x42);
    r.game_write(0xBFFF, 0x99);
    b.note_writes(r.gb, 5);
    try testing.expect(b.pending);
    try testing.expect(!r.gb.sram_dirty);
    b.flush(70);
    try testing.expectEqual(battery.Status.saved, b.status);
    try testing.expect(!b.pending);
    try testing.expectEqual(@as(u32, 1), save.fake.commits());
    // 8 KB + the 16-byte header: three 4 KB blocks plus the directory.
    try testing.expectEqual(@as(u64, 4 * 55), save.fake.flashMs());
    // The blob: header then the RAM.
    var got: [battery.header_len + 0x2000]u8 = undefined;
    const stored = save.fake.peek("boy/POCKET/BEEF", &got).?;
    try testing.expectEqual(@as(usize, battery.header_len + 0x2000), stored.len);
    try testing.expectEqualStrings("SBSV", stored[0..4]);
    try testing.expectEqual(@as(u8, 0x42), stored[battery.header_len + 0x123]);

    // Power cycle: reset clears the RAM, begin loads it back.
    save.fake.reboot();
    r.boot(&b, null, 0);
    try testing.expectEqual(battery.Status.loaded, b.status);
    try testing.expectEqual(@as(u8, 0x42), r.gb.cart_ram[0x123]);
    try testing.expectEqual(@as(u8, 0x99), r.gb.cart_ram[0x1FFF]);
    try testing.expect(!b.pending);

    // A blob of another size under this key: ignored, fresh RAM.
    save.fake.setRateLimit(false);
    try save.write("boy/POCKET/BEEF", got[0..100]);
    r.boot(&b, null, 0);
    try testing.expectEqual(battery.Status.ignored, b.status);
    try testing.expect(std.mem.allEqual(u8, b.ram(), 0));
    try testing.expectEqualStrings("SBSV", b.blob[0..4]);
    // The right size with a foreign header (another cart type): ignored.
    var foreign = got;
    foreign[5] = 0x1B;
    try save.write("boy/POCKET/BEEF", &foreign);
    r.boot(&b, null, 0);
    try testing.expectEqual(battery.Status.ignored, b.status);
    try testing.expect(std.mem.allEqual(u8, b.ram(), 0));
    // A corrupt blob (CRC failure on read): fresh RAM, flagged.
    save.fake.failNext(error.IoError);
    r.boot(&b, null, 0);
    try testing.expectEqual(battery.Status.failed, b.status);
    try testing.expect(std.mem.allEqual(u8, b.ram(), 0));
}

test "battery: automatic save after 1 s quiet, at most every 30 s" {
    save.fake.reset();
    var r: Rig = undefined;
    try r.init(0x1B, 2, "AUTO");
    defer r.deinit();
    var b: battery.Battery = .{};
    r.boot(&b, null, 0);
    try testing.expect(!b.auto_due(100));
    // The game writes at tick 100, again at 130 (a save is several writes).
    r.game_write(0xA000, 1);
    b.note_writes(r.gb, 100);
    try testing.expect(!b.auto_due(150));
    r.game_write(0xA001, 2);
    b.note_writes(r.gb, 130);
    try testing.expect(!b.auto_due(189));
    try testing.expect(b.auto_due(190));
    b.request();
    try testing.expect(b.requested);
    try testing.expect(!b.auto_due(190)); // already asked for
    b.flush(191);
    try testing.expect(!b.requested);
    try testing.expectEqual(@as(u32, 1), save.fake.commits());
    // Another write soon after: quiet for 1 s is not enough within 30 s.
    r.game_write(0xA002, 3);
    b.note_writes(r.gb, 400);
    try testing.expect(!b.auto_due(500));
    try testing.expect(!b.auto_due(191 + battery.min_gap_ticks - 1));
    try testing.expect(b.auto_due(191 + battery.min_gap_ticks));
    // A game writing all the time never gets an automatic save.
    b.flush(2000);
    var t: u32 = 2000;
    while (t < 2000 + 3 * battery.min_gap_ticks) : (t += 30) {
        r.game_write(0xA003, @truncate(t));
        b.note_writes(r.gb, t);
        try testing.expect(!b.auto_due(t));
    }
    // Menu open saves whatever is pending at once.
    b.request_if_pending();
    try testing.expect(b.requested);
    b.flush(t);
    try testing.expect(!b.pending);
    b.request_if_pending();
    try testing.expect(!b.requested);
    try testing.expectEqual(@as(u32, 3), save.fake.commits());
}

test "battery: rate limit, store full, other errors" {
    save.fake.reset();
    var r: Rig = undefined;
    try r.init(0x03, 1, "LIMITS");
    defer r.deinit();
    var b: battery.Battery = .{};
    r.boot(&b, null, 0);
    // Use up the burst of 8 commits.
    for (0..8) |i| {
        r.game_write(0xA000, @intCast(i + 1));
        b.note_writes(r.gb, 0);
        b.flush(0);
        try testing.expectEqual(battery.Status.saved, b.status);
    }
    r.game_write(0xA000, 0x77);
    b.note_writes(r.gb, 1000);
    b.flush(1100);
    try testing.expectEqual(battery.Status.waiting, b.status);
    try testing.expect(b.pending);
    try testing.expect(b.toast == null);
    // Silent retry later: not before `retry_ticks` (and the 30 s gap).
    try testing.expect(!b.auto_due(1100 + battery.min_gap_ticks - 1));
    try testing.expect(b.auto_due(1100 + battery.min_gap_ticks));
    save.fake.advanceMs(10_000);
    b.flush(1100 + battery.min_gap_ticks);
    try testing.expectEqual(battery.Status.saved, b.status);

    // Store full: fill it with other carts' 64 KB blobs (this cart's own
    // blob deleted first, so not even its one block is left).
    save.fake.setRateLimit(false);
    try save.delete("boy/LIMITS/BEEF");
    var big: [save.max_blob]u8 = @splat(1);
    var name = "other/0".*;
    var filled: u8 = 0;
    while (true) : (filled += 1) {
        name[6] = '0' + filled;
        save.write(&name, &big) catch |e| {
            try testing.expectEqual(error.NoSpace, e);
            break;
        };
    }
    // Fill the last blocks so not even a 1 KB blob fits.
    while (true) {
        name[6] +%= 1;
        save.write(&name, big[0..4096]) catch break;
    }
    r.game_write(0xA000, 0x78);
    b.note_writes(r.gb, 5000);
    b.flush(5000);
    try testing.expectEqual(battery.Status.full, b.status);
    try testing.expectEqualStrings("SAVE FULL", b.toast.?);
    try testing.expectEqualStrings("FULL", b.short_status());
    try testing.expect(!b.pending);
    b.toast = null;

    // Any other error: "SAVE ERROR" once, not on the next failure.
    save.fake.failNext(error.IoError);
    b.request();
    b.flush(6000);
    try testing.expectEqual(battery.Status.failed, b.status);
    try testing.expectEqualStrings("SAVE ERROR", b.toast.?);
    b.toast = null;
    save.fake.failNext(error.Busy);
    b.request();
    b.flush(7000);
    try testing.expectEqual(battery.Status.failed, b.status);
    try testing.expect(b.toast == null);
    try testing.expectEqualStrings("ERROR", b.short_status());
}

test "battery: exit hook saves what is pending, then exit ready" {
    save.fake.reset();
    var r: Rig = undefined;
    try r.init(0x13, 3, "EXIT"); // MBC3 + RAM + battery, 32 KB
    defer r.deinit();
    var b: battery.Battery = .{};
    try testing.expect(save.supported());
    try save.watchExit();
    r.boot(&b, null, 0);
    try testing.expect(!save.exitRequested());
    r.game_write(0xA000, 0x31);
    save.fake.setExitRequested();
    // What main.zig `save_top` does at the top of an update.
    try testing.expect(save.exitRequested());
    b.note_writes(r.gb, 50);
    b.flush_if_pending(50);
    save.exitReady();
    try testing.expectEqual(save.abi.exit_ready, save.fake.exitWord());
    try testing.expectEqual(@as(u32, 1), save.fake.commits());
    // 32 KB + the header: 9 data blocks plus the directory, 0.55 s.
    try testing.expectEqual(@as(u64, 10 * 55), save.fake.flashMs());
    // Nothing pending: the exit costs nothing.
    b.flush_if_pending(60);
    try testing.expectEqual(@as(u32, 1), save.fake.commits());
}

test "battery: rewind replays are not the game's writes" {
    save.fake.reset();
    var r: Rig = undefined;
    try r.init(0x03, 2, "REPLAY");
    defer r.deinit();
    var b: battery.Battery = .{};
    r.boot(&b, null, 0);
    // A scrub step replays frames that write cart RAM...
    r.game_write(0xA000, 5);
    // ...and the menu closing drops their flag.
    b.ignore_replays(r.gb);
    b.note_writes(r.gb, 100);
    try testing.expect(!b.pending);
    try testing.expect(!b.auto_due(10_000));
}

test "battery: delete" {
    save.fake.reset();
    var r: Rig = undefined;
    try r.init(0x03, 2, "DELETE");
    defer r.deinit();
    var b: battery.Battery = .{};
    r.boot(&b, null, 0);
    r.game_write(0xA010, 0x10);
    b.note_writes(r.gb, 1);
    b.flush(1);
    try testing.expect(b.delete());
    try testing.expectEqual(battery.Status.deleted, b.status);
    try testing.expect(std.mem.allEqual(u8, b.ram(), 0));
    var tmp: [4]u8 = undefined;
    try testing.expectError(error.NotFound, save.read("boy/DELETE/BEEF", &tmp));
    // Deleting nothing is fine too.
    try testing.expect(b.delete());
    r.boot(&b, null, 0);
    try testing.expectEqual(battery.Status.fresh, b.status);
}

test "battery: import a .sav from the drive once" {
    save.fake.reset();
    const vol = try romfs.Volume.open(.truncated_test(saves_img));
    var savs: [8]romfs.Entry = undefined;
    const ns = vol.find(&.{"sav"}, &savs);
    try testing.expectEqual(@as(usize, 4), ns);
    var r: Rig = undefined;
    try r.init(0x1B, 2, "POCKET GAME"); // MBC5 + RAM + battery, 8 KB
    defer r.deinit();
    var b: battery.Battery = .{};
    // "Pocket Game.SAV" (fragmented on the drive) for "Pocket Game.gb".
    r.boot(&b, .{ .vol = &vol, .rom_name = "Pocket Game.gb", .savs = savs[0..ns] }, 0);
    try testing.expectEqual(battery.Status.imported, b.status);
    for (b.ram(), 0..) |x, i| try testing.expectEqual(@as(u8, @truncate(i * 7 + 3)), x);
    try testing.expectEqual(@as(u32, 1), save.fake.commits());
    try testing.expect(!b.pending);
    // Next boot: the store's copy wins; the .sav is not read again.
    r.game_write(0xA000, 0xEE);
    b.note_writes(r.gb, 10);
    b.flush(10);
    r.boot(&b, .{ .vol = &vol, .rom_name = "Pocket Game.gb", .savs = savs[0..ns] }, 0);
    try testing.expectEqual(battery.Status.loaded, b.status);
    try testing.expectEqual(@as(u8, 0xEE), b.ram()[0]);
    try testing.expectEqual(@as(u32, 2), save.fake.commits());

    // The wrong size: not imported.
    save.fake.reset();
    r.boot(&b, .{ .vol = &vol, .rom_name = "Wrong Size.gb", .savs = savs[0..ns] }, 0);
    try testing.expectEqual(battery.Status.fresh, b.status);
    try testing.expect(std.mem.allEqual(u8, b.ram(), 0));
    try testing.expectEqual(@as(u32, 0), save.fake.commits());
    // No .sav at all.
    r.boot(&b, .{ .vol = &vol, .rom_name = "Missing.gbc", .savs = savs[0..ns] }, 0);
    try testing.expectEqual(battery.Status.fresh, b.status);
}

test "battery: import with an MBC3 clock trailer and MBC2 nibbles" {
    save.fake.reset();
    const vol = try romfs.Volume.open(.truncated_test(saves_img));
    var savs: [8]romfs.Entry = undefined;
    const ns = vol.find(&.{"sav"}, &savs);
    try testing.expectEqual(@as(usize, 4), ns);
    var b: battery.Battery = .{};
    {
        var r: Rig = undefined;
        try r.init(0x10, 1, "CLOCK"); // MBC3 + timer + RAM + battery, 2 KB
        defer r.deinit();
        r.boot(&b, .{ .vol = &vol, .rom_name = "Clock Game.gbc", .savs = savs[0..ns] }, 0);
        try testing.expectEqual(battery.Status.imported, b.status);
        try testing.expectEqual(@as(usize, 2048), b.ram().len);
        for (b.ram(), 0..) |x, i| try testing.expectEqual(@as(u8, @truncate(i * 5 + 1)), x);
    }
    {
        var r: Rig = undefined;
        try r.init(0x06, 0, "NIBBLE"); // MBC2 + battery
        defer r.deinit();
        r.boot(&b, .{ .vol = &vol, .rom_name = "nibble.gb", .savs = savs[0..ns] }, 0);
        try testing.expectEqual(battery.Status.imported, b.status);
        for (b.ram(), 0..) |x, i| try testing.expectEqual(@as(u8, @truncate(0xF0 | i)), x);
        var buf: [24]u8 = undefined;
        try testing.expectEqualStrings("512 B from .sav", b.about_line(&buf));
        // Stored and loaded back as nibbles.
        save.fake.reboot();
        r.boot(&b, null, 0);
        try testing.expectEqual(battery.Status.loaded, b.status);
        r.gb.write8(0x0000, 0x0A);
        try testing.expectEqual(@as(u8, 0xF5), r.gb.read8(0xA005));
    }
}
