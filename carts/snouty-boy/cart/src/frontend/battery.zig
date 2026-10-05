//! Battery-backed cart RAM across runs (root docs/SAVES.md, lib/save.zig):
//! a cartridge whose header says its RAM has a battery
//! (`core.mmu.has_battery`) keeps that RAM in the patched OS's save store,
//! one key per game. No cart-api import, so tests/battery_unit.zig drives
//! it on the host against `save.fake`; main.zig does the drawing.
//!
//! Key: `boy/<header title>/<global checksum>`, the title sanitised to
//! 0x20..0x7E ('/' becomes '_'), trimmed, cut so the key fits 32 bytes,
//! the checksum (header 0x14E..0x14F) as 4 hex digits: two ROMs with one
//! title (revisions, hacks) never share a save.
//!
//! Blob: a 16-byte header (`Header`: magic "SBSV", format 1, cart type
//! 0x147, RAM code 0x149, MBC kind, RAM bytes) and the cart RAM, contiguous
//! in the arena (frontend/rewind.zig `layout` puts the header slot right
//! before the console's cart RAM), so a save needs no second buffer. A
//! stored blob whose size or header does not match this ROM is ignored at
//! load (fresh RAM) and overwritten by the next save. MBC2 RAM is 512
//! nibbles stored one per byte, upper nibble 1s. MBC3's clock (0x0F, 0x10)
//! is not emulated, so nothing of it is stored. RAM over `save.max_blob`
//! (header code 4, 128 KB; the core keeps 32 KB of it anyway) is not saved.
//!
//! Load: once the ROM is chosen, before the first frame and the first
//! keyframe (`begin`). No stored save: a raw SRAM dump `<rom name minus
//! extension>.sav` of the right size on the badge drive (what other
//! emulators write) is imported once and written to the store.
//!
//! When it writes (`save.write` parks the cart ~55 ms per 4 KB plus one
//! directory block): the game's cart RAM writes set `Gb.sram_dirty`
//! (`core/mmu.zig`, one store on the rare cart RAM write); the frontend
//! turns that into `pending` once per update (`note_writes`). A pending
//! save is written when the menu or the chorded rewind opens, when the OS
//! asks to exit (`save.watchExit`), on the menu's Save now, and on its own
//! once the game has not written cart RAM for `idle_ticks` (1 s), at most
//! once per `min_gap_ticks` (30 s), never while fast forwarding or linked.
//! An unchanged blob costs the store nothing, so there is no compare here.
//!
//! Rewind: the store holds what the game last wrote, as of the last save.
//! Scrubbing never saves: the frames the scrubber replays write cart RAM
//! too, so `ignore_replays` drops their dirty flag when the menu or the
//! rewind closes. Since the menu and the rewind save first, nothing is
//! normally pending while scrubbing; rewinding past a save does not unsave
//! it. The game's next own write after resuming saves the RAM as it is in
//! the resumed timeline.
const std = @import("std");
const core = @import("core");
const save = @import("save");
const romfs = @import("romfs");

/// For tests/battery_unit.zig, whose module has no `save` or `romfs` import.
pub const save_api = save;
pub const romfs_api = romfs;

pub const header_len = 16;
pub const magic = "SBSV".*;
pub const format_version: u8 = 1;

/// Updates (1/60 s) without a cart RAM write before an automatic save.
pub const idle_ticks: u32 = 60;
/// Updates between automatic saves at least.
pub const min_gap_ticks: u32 = 30 * 60;
/// Updates to wait after `error.RateLimited` (the OS refills one commit
/// per 10 s).
pub const retry_ticks: u32 = 10 * 60;

/// The blob's first 16 bytes.
pub const Header = extern struct {
    magic: [4]u8 = magic,
    version: u8 = format_version,
    /// Header byte 0x147 (cartridge type) and 0x149 (RAM size code).
    cart_type: u8,
    ram_code: u8,
    /// `core.mmu.MbcKind` as a number.
    mbc: u8,
    /// Cart RAM bytes after the header.
    ram_len: u32,
    _r: u32 = 0,

    comptime {
        if (@sizeOf(Header) != header_len) @compileError("battery.Header must be 16 bytes");
    }
};

pub const Status = enum {
    /// Saves not supported by this OS, or no ROM yet: no Save UI.
    off,
    /// The cartridge has no battery-backed RAM.
    no_battery,
    /// Its RAM is larger than a save blob may be.
    too_big,
    /// Nothing stored yet (and nothing imported).
    fresh,
    /// A stored blob did not match this ROM and was ignored.
    ignored,
    loaded,
    imported,
    saved,
    deleted,
    /// The game wrote cart RAM that is not stored yet.
    unsaved,
    /// The OS rate-limited the last save; it is tried again later.
    waiting,
    /// `error.NoSpace`.
    full,
    /// Any other error.
    failed,
};

/// Where a `.sav` file for the import may be (the badge drive).
pub const Drive = struct {
    vol: *const romfs.Volume,
    /// The ROM's file name on the drive.
    rom_name: []const u8,
    /// The `.sav` files on the drive (`vol.find(&.{"sav"}, ...)`;
    /// frontend/romsrc.zig collects them in its one directory walk).
    savs: []const romfs.Entry,
};

/// What `begin` needs to know about the cartridge, from its header.
pub const Cart = struct {
    cart_type: u8,
    ram_code: u8,
    mbc: core.mmu.MbcKind,
    title: [16]u8,
    checksum: u16,

    pub noinline fn from_rom(rom: *const core.Rom) Cart {
        var c: Cart = .{
            .cart_type = rom.read(0x147),
            .ram_code = rom.read(0x149),
            .mbc = core.mmu.kind_for(rom.read(0x147)),
            .title = undefined,
            .checksum = (@as(u16, rom.read(0x14E)) << 8) | rom.read(0x14F),
        };
        read_bytes(rom, 0x134, &c.title);
        return c;
    }

    /// The header asks for more RAM than one blob holds (code 4, 128 KB).
    fn declared_bytes(c: *const Cart) u32 {
        if (core.mmu.is_mbc2(c.cart_type)) return core.mmu.mbc2_ram_len;
        return switch (c.ram_code) {
            0 => 0,
            1 => 0x800,
            2 => 0x2000,
            3 => 0x8000,
            4 => 0x20000,
            5 => 0x10000,
            else => 0,
        };
    }
};

/// ROM bytes `off..off + dst.len` (kept out of line: the header is read once).
noinline fn read_bytes(rom: *const core.Rom, off: u32, dst: []u8) void {
    for (dst, 0..) |*b, i| b.* = rom.read(off + @as(u32, @intCast(i)));
}

/// `boy/<title>/<checksum>` into `buf`; at most `save.max_key` bytes.
pub noinline fn make_key(buf: *[save.max_key]u8, c: *const Cart) []const u8 {
    const prefix = "boy/";
    // Header 0x143 bit 7 is the CGB flag: the title is 15 bytes then.
    var end: usize = if (c.title[15] & 0x80 != 0) 15 else 16;
    for (c.title[0..end], 0..) |b, i| {
        if (b == 0) {
            end = i;
            break;
        }
    }
    var start: usize = 0;
    while (start < end and c.title[start] == ' ') start += 1;
    while (end > start and c.title[end - 1] == ' ') end -= 1;
    @memcpy(buf[0..prefix.len], prefix);
    var n: usize = prefix.len;
    if (start == end) {
        @memcpy(buf[n..][0..8], "untitled");
        n += 8;
    } else {
        // 16 bytes at most: "boy/" + 16 + "/XXXX" is 25, under 32.
        for (c.title[start..end]) |b| {
            buf[n] = if (b < 0x20 or b > 0x7E or b == '/') '_' else b;
            n += 1;
        }
    }
    buf[n] = '/';
    n += 1;
    const digits = "0123456789ABCDEF";
    var sh: u4 = 12;
    while (true) : (sh -= 4) {
        buf[n] = digits[@as(u4, @truncate(c.checksum >> sh))];
        n += 1;
        if (sh == 0) break;
    }
    return buf[0..n];
}

pub const Battery = struct {
    /// Saves are on for this ROM: the OS stores them, the cartridge has a
    /// battery and its RAM fits a blob. The Save rows show only then.
    active: bool = false,
    /// The OS supports saves at all (About shows a save line then).
    supported: bool = false,
    status: Status = .off,
    key_buf: [save.max_key]u8 = undefined,
    key_len: u8 = 0,
    /// Header slot + cart RAM (`rewind.layout`); the RAM is `blob[16..]`.
    blob: []u8 = &.{},
    cart: Cart = undefined,
    /// RAM bytes the header declares (for `too_big`).
    declared: u32 = 0,
    /// Cart RAM written by the game and not stored yet.
    pending: bool = false,
    /// Tick of the game's last cart RAM write seen (`note_writes`).
    last_write: u32 = 0,
    /// Tick of the last save attempt, null before the first.
    last_flush: ?u32 = null,
    /// No automatic save before this tick (after `error.RateLimited`).
    retry_at: u32 = 0,
    /// A save was requested (menu, Save now, automatic): main.zig draws
    /// "SAVING", presents, and calls `flush` at the top of the next update.
    requested: bool = false,
    /// A message for the game screen, once ("SAVE FULL", "SAVE ERROR");
    /// main.zig shows it for a while and clears it.
    toast: ?[]const u8 = null,
    /// "SAVE ERROR" has been shown once this run.
    error_toasted: bool = false,

    pub fn key(b: *const Battery) []const u8 {
        return b.key_buf[0..b.key_len];
    }

    pub fn ram(b: *const Battery) []u8 {
        return b.blob[header_len..];
    }

    /// Set up for a ROM just started: `blob` is the header slot and the
    /// console's freshly reset cart RAM (`Gb.cart_ram == blob[16..]`).
    /// Loads the stored save into the RAM, or imports a `.sav` from
    /// `drive`, before the first frame. `supported` is `save.supported()`.
    pub noinline fn begin(b: *Battery, c: Cart, blob: []u8, supported: bool, drive: ?Drive, now: u32) void {
        b.* = .{ .supported = supported, .cart = c, .blob = blob };
        b.key_len = @intCast(make_key(&b.key_buf, &c).len);
        b.declared = c.declared_bytes();
        if (!supported) return;
        if (!core.mmu.has_battery(c.cart_type) or blob.len <= header_len) {
            b.status = .no_battery;
            return;
        }
        if (b.declared > save.max_blob or blob.len > save.max_blob) {
            b.status = .too_big;
            return;
        }
        b.active = true;
        b.status = b.load();
        if (b.status == .fresh) {
            if (drive) |d| {
                if (b.import(d)) {
                    b.status = .imported;
                    b.pending = true;
                    b.flush(now);
                    if (b.status == .saved) b.status = .imported;
                }
            }
        }
    }

    fn header(b: *const Battery) Header {
        return .{
            .cart_type = b.cart.cart_type,
            .ram_code = b.cart.ram_code,
            .mbc = @backingInt(b.cart.mbc),
            .ram_len = @intCast(b.ram().len),
        };
    }

    fn put_header(b: *Battery) void {
        const h = b.header();
        @memcpy(b.blob[0..header_len], std.mem.asBytes(&h));
    }

    fn header_matches(b: *const Battery) bool {
        const h = b.header();
        return std.mem.eql(u8, b.blob[0..header_len], std.mem.asBytes(&h));
    }

    /// The RAM as reset left it (an MBC2's nibbles read 0xF0).
    fn clear_ram(b: *Battery) void {
        @memset(b.ram(), if (b.cart.mbc == .mbc2) 0xF0 else 0);
    }

    noinline fn load(b: *Battery) Status {
        const n = save.read(b.key(), b.blob[0..header_len]) catch |e| return switch (e) {
            error.NotFound => .fresh,
            else => .failed,
        };
        if (n != b.blob.len or !b.header_matches()) {
            b.put_header();
            return .ignored;
        }
        const m = save.read(b.key(), b.blob) catch {
            b.clear_ram();
            b.put_header();
            return .failed;
        };
        if (m != b.blob.len or !b.header_matches()) {
            b.clear_ram();
            b.put_header();
            return .ignored;
        }
        b.fix_nibbles();
        return .loaded;
    }

    fn fix_nibbles(b: *Battery) void {
        if (b.cart.mbc != .mbc2) return;
        for (b.ram()) |*x| x.* |= 0xF0;
    }

    /// A `.sav` beside the ROM sized like the RAM (MBC3 with a clock: also
    /// the RAM plus a 44 or 48-byte clock trailer, which is skipped).
    fn sav_size_ok(b: *const Battery, size: u32) bool {
        const len: u32 = @intCast(b.ram().len);
        if (size == len) return true;
        const clock = b.cart.cart_type == 0x0F or b.cart.cart_type == 0x10;
        return clock and (size == len + 44 or size == len + 48);
    }

    /// Copy the RAM from `<rom stem>.sav` on the drive; false if there is
    /// none of the right size (the RAM is untouched then).
    noinline fn import(b: *Battery, d: Drive) bool {
        const want = stem(d.rom_name);
        for (d.savs) |e| {
            if (!std.ascii.eqlIgnoreCase(stem(e.slice()), want)) continue;
            if (!b.sav_size_ok(e.size)) continue;
            var clusters: [max_sav_clusters]u16 = undefined;
            const m = d.vol.map(e, &clusters) catch continue;
            const dst = b.ram();
            var off: u32 = 0;
            while (off < dst.len) {
                const len: u32 = @intCast(@min(romfs.sector_size, dst.len - off));
                const p = m.chunk(off, len) orelse break;
                @memcpy(dst[off..][0..len], p[0..len]);
                off += len;
            }
            if (off < dst.len) {
                b.clear_ram();
                continue;
            }
            b.fix_nibbles();
            return true;
        }
        return false;
    }

    /// Clusters of the largest `.sav` imported: 32 KB plus a clock trailer.
    const max_sav_clusters = (0x8000 + 48 + romfs.sector_size - 1) / romfs.sector_size;

    /// Once per update while the game runs: turn the core's dirty flag
    /// into `pending` and note when the game last wrote.
    pub fn note_writes(b: *Battery, gb: *core.Gb, now: u32) void {
        if (!gb.sram_dirty) return;
        gb.sram_dirty = false;
        if (!b.active) return;
        b.pending = true;
        b.last_write = now;
        if (b.status != .full and b.status != .failed) b.status = .unsaved;
    }

    /// Scrub replays wrote cart RAM through the core: not the game's own
    /// writes. Call when the menu or the chorded rewind closes.
    pub fn ignore_replays(_: *Battery, gb: *core.Gb) void {
        gb.sram_dirty = false;
    }

    /// An automatic save is due: pending, the game quiet for 1 s, 30 s
    /// since the last save, past any rate-limit wait.
    pub fn auto_due(b: *const Battery, now: u32) bool {
        if (!b.active or !b.pending or b.requested) return false;
        if (now -% b.last_write < idle_ticks) return false;
        if (b.last_flush) |t| if (now -% t < min_gap_ticks) return false;
        if (@as(i32, @bitCast(now -% b.retry_at)) < 0) return false;
        return true;
    }

    /// Ask for a save of whatever is pending (menu or rewind opening).
    pub fn request_if_pending(b: *Battery) void {
        if (b.active and b.pending) b.requested = true;
    }

    /// Save now, pending or not (the menu's Save now).
    pub fn request(b: *Battery) void {
        if (b.active) b.requested = true;
    }

    /// Write the blob (blocks: see the file comment). Clears `requested`.
    pub fn flush(b: *Battery, now: u32) void {
        b.requested = false;
        if (!b.active) return;
        b.put_header();
        b.last_flush = now;
        if (save.write(b.key(), b.blob)) |_| {
            b.pending = false;
            b.status = .saved;
        } else |e| switch (e) {
            // Nothing was written: keep it pending and try again later.
            error.RateLimited => {
                b.retry_at = now +% retry_ticks;
                b.status = .waiting;
            },
            // Retried on the game's next own write or Save now.
            error.NoSpace => {
                b.pending = false;
                b.status = .full;
                b.toast = "SAVE FULL";
            },
            else => {
                b.pending = false;
                b.status = .failed;
                if (!b.error_toasted) {
                    b.error_toasted = true;
                    b.toast = "SAVE ERROR";
                }
            },
        }
    }

    /// Save if anything is pending (the OS asked to exit).
    pub fn flush_if_pending(b: *Battery, now: u32) void {
        if (b.active and b.pending) b.flush(now);
    }

    /// Remove the stored save and empty the RAM (the caller resets the
    /// console). True when the store no longer holds it.
    pub fn delete(b: *Battery) bool {
        if (!b.active) return false;
        save.delete(b.key()) catch |e| switch (e) {
            error.NotFound => {},
            error.RateLimited => {
                b.status = .waiting;
                return false;
            },
            else => {
                b.status = .failed;
                return false;
            },
        };
        b.clear_ram();
        b.pending = false;
        b.requested = false;
        b.status = .deleted;
        return true;
    }

    /// The menu's Save row value, at most 7 characters.
    pub fn short_status(b: *const Battery) []const u8 {
        return short_names[@backingInt(b.status)];
    }

    /// About's save line, at most 18 characters: "8 KB saved",
    /// "512 B loaded", "No battery RAM", "SRAM 128K: no save".
    pub noinline fn about_line(b: *const Battery, buf: *[24]u8) []const u8 {
        var w: Fmt = .{ .buf = buf };
        switch (b.status) {
            .off, .no_battery => return about_names[@backingInt(b.status)],
            .too_big => {
                w.put("SRAM ");
                w.num(b.declared / 1024);
                w.put("K: no save");
                return w.done();
            },
            else => {},
        }
        const len: u32 = @intCast(b.ram().len);
        if (len < 1024) {
            w.num(len);
            w.put(" B ");
        } else {
            w.num(len / 1024);
            w.put(" KB ");
        }
        w.put(about_names[@backingInt(b.status)]);
        return w.done();
    }
};

const status_count = @typeInfo(Status).@"enum".field_names.len;

/// `Battery.short_status` by `Status`.
const short_names = [status_count][]const u8{
    "off", "off", "off", "empty", "empty", "saved", "saved", "saved", "empty", "unsaved", "unsaved", "FULL", "ERROR",
};

/// `Battery.about_line`'s words by `Status`.
const about_names = [status_count][]const u8{
    "Saves off", "No battery RAM", "", "not saved", "old ignored", "loaded", "from .sav", "saved", "deleted", "unsaved", "retry soon", "SAVE FULL", "SAVE ERROR",
};

comptime {
    // Keep the tables in `Status` order.
    if (@backingInt(Status.failed) != status_count - 1 or @backingInt(Status.off) != 0 or @backingInt(Status.saved) != 7) @compileError("battery name tables out of order");
}

/// The cart's one battery (main.zig and the menu share it).
pub var live: Battery = .{};

/// `name` without its last extension.
fn stem(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    return name[0..dot];
}

const Fmt = struct {
    buf: *[24]u8,
    n: usize = 0,

    noinline fn put(w: *Fmt, s: []const u8) void {
        const k = @min(s.len, w.buf.len - w.n);
        @memcpy(w.buf[w.n..][0..k], s[0..k]);
        w.n += k;
    }

    noinline fn num(w: *Fmt, v: u32) void {
        var tmp: [10]u8 = undefined;
        var i: usize = tmp.len;
        var x = v;
        while (true) {
            i -= 1;
            tmp[i] = '0' + @as(u8, @intCast(x % 10));
            x /= 10;
            if (x == 0) break;
        }
        w.put(tmp[i..]);
    }

    fn done(w: *const Fmt) []const u8 {
        return w.buf[0..w.n];
    }
};
