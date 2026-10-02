//! Where the running ROM comes from (SPEC.md section 11.1, docs/ROM_DRIVE.md
//! at the repository root), and what the About screen and the debug overlay
//! say about it.
//!
//! Badge build with `rom.source == .drive`: `scan` opens the FAT12 volume at
//! `romfs.base_addr` (the OS `romfs` flash region that the USB drive shows),
//! lists up to `max_candidates` `.gb`/`.gbc` files and checks each header;
//! `select` maps the chosen file's cluster chain and hands the core a
//! `core.Rom` built from one flash pointer per 512-byte sector, so the ROM is
//! read in place and costs no RAM. Anything that goes wrong falls back to the
//! embedded ROM (`rom.data`) and keeps the reason for the About screen.
//!
//! The wasm build (web simulator, preview.mjs) and `-Drom-source=embed` use
//! only the embedded ROM: `use_drive` is comptime false there, so none of the
//! romfs code or its tables are compiled in.
const cart = @import("cart-api");
const core = @import("core");
const rom = @import("rom");
const romfs = @import("romfs");

/// The drive path exists in this build.
pub const use_drive = !cart.is_wasm and rom.source == .drive;

pub const Source = enum(u32) { embedded = 0, drive = 1 };

/// What is running, for the About screen, the overlay and the wasm exports.
pub const Info = struct {
    source: Source = .embedded,
    name_buf: [64]u8 = undefined,
    name_len: u8 = 0,
    size: u32 = 0,
    crc: u32 = 0,
    /// 16 KB banks read through the per-sector slow path (fragmented file).
    fragmented: u32 = 0,
    /// Why the drive was tried and the embedded ROM runs instead; null when
    /// the drive ROM runs or the drive was never tried.
    fallback: ?[]const u8 = null,

    pub fn name(i: *const Info) []const u8 {
        return i.name_buf[0..i.name_len];
    }

    fn set_name(i: *Info, s: []const u8) void {
        const n = @min(s.len, i.name_buf.len);
        @memcpy(i.name_buf[0..n], s[0..n]);
        i.name_len = @intCast(n);
    }
};

pub var info: Info = .{};

/// One file on the drive with the extension we look for.
pub const Candidate = struct {
    entry: romfs.Entry = .{},
    /// Size in range and header checksum good; only these can be picked.
    playable: bool = false,
    /// Why it is not playable, or the hints for a playable one ("" if none).
    note_buf: [20]u8 = undefined,
    note_len: u8 = 0,

    pub fn note(c: *const Candidate) []const u8 {
        return c.note_buf[0..c.note_len];
    }

    fn add_note(c: *Candidate, s: []const u8) void {
        var n: usize = c.note_len;
        if (n != 0 and n < c.note_buf.len) {
            c.note_buf[n] = ' ';
            n += 1;
        }
        const k = @min(s.len, c.note_buf.len - n);
        @memcpy(c.note_buf[n..][0..k], s[0..k]);
        c.note_len = @intCast(n + k);
    }
};

/// Picker capacity (PLAN.md M5): more files than this are not listed.
pub const max_candidates = 8;

pub var candidates: [max_candidates]Candidate = @splat(.{});
pub var candidate_count: usize = 0;
/// Candidates with `playable` set.
pub var playable_count: usize = 0;
/// Why the scan found nothing to play (volume error, no file), or null.
var scan_failure: ?[]const u8 = null;

// Tables that must outlive the Rom: the file's cluster chain (5 KB) and one
// pointer per 512-byte sector of it (8 KB for 1 MB). Only compiled in when
// `use_drive` (they are referenced from nowhere else).
var clusters: [romfs.max_clusters]u16 = undefined;
var sectors: [core.rom_mod.max_sectors][*]const u8 = undefined;

/// Look at the drive. Call once from `start()`, before `choose_default` or
/// `select`. Does nothing in a build without the drive path.
pub fn scan() void {
    if (use_drive) scan_drive();
}

fn scan_drive() void {
    const vol = romfs.Volume.open_badge() catch |e| {
        scan_failure = @errorName(e);
        return;
    };
    var entries: [max_candidates]romfs.Entry = undefined;
    candidate_count = @min(vol.find(&.{ "gb", "gbc" }, &entries), max_candidates);
    if (candidate_count == 0) scan_failure = "no ROM file";
    for (entries[0..candidate_count], candidates[0..candidate_count]) |e, *c| {
        c.* = .{ .entry = e };
        check(&vol, c);
        if (c.playable) playable_count += 1;
    }
    if (candidate_count != 0 and playable_count == 0) scan_failure = "none playable";
}

/// Validate one file by its header (Pan Docs "The Cartridge Header"). Size
/// and checksum failures make it unplayable; the rest are hints only,
/// because the core runs such a ROM anyway, just not fully.
fn check(vol: *const romfs.Volume, c: *Candidate) void {
    const size = c.entry.size;
    if (size < 0x150) return c.add_note("too small");
    if (size > core.rom_mod.max_bytes) return c.add_note("over 1 MB");
    // Maps into the shared cluster table; `select` maps the chosen one again.
    const m = vol.map(c.entry, &clusters) catch |e| return c.add_note(@errorName(e));
    var sum: u8 = 0;
    var off: u32 = 0x134;
    while (off <= 0x14C) : (off += 1) sum = sum -% m.read(off) -% 1;
    if (sum != m.read(0x14D)) return c.add_note("bad checksum");
    c.playable = true;
    // Header 0x143 bit 7: the console runs it as a Game Boy Color (SPEC.md 19).
    if (m.read(0x143) & 0x80 != 0) c.add_note("Color");
    switch (m.read(0x147)) {
        0x00, 0x01, 0x02, 0x03, 0x08, 0x09, 0x11, 0x12, 0x13, 0x19...0x1E => {},
        // MBC3 with the real-time clock: the core has no RTC (SPEC.md 11).
        0x0F, 0x10 => c.add_note("no RTC"),
        else => c.add_note("mapper?"),
    }
    // Cart RAM codes 4 and 5 are 128 and 64 KB; the core keeps 32 KB
    // (SPEC.md 19.1).
    if (m.read(0x149) >= 4) c.add_note("RAM>32K");
}

/// The ROM to run when there is no choice to make: the one playable drive
/// file, or the embedded ROM. Call after `scan` when `playable_count <= 1`.
pub fn choose_default() core.Rom {
    return if (use_drive) default_drive() else embedded(null);
}

fn default_drive() core.Rom {
    if (scan_failure) |why| return embedded(why);
    for (candidates[0..candidate_count], 0..) |c, i| {
        if (c.playable) return select(i);
    }
    return embedded("none playable");
}

/// Map candidate `i` and build the core's view of it. Falls back to the
/// embedded ROM, keeping the reason, if the file cannot be mapped.
pub fn select(i: usize) core.Rom {
    return if (use_drive) select_drive(i) else embedded(null);
}

fn select_drive(i: usize) core.Rom {
    if (i >= candidate_count or !candidates[i].playable) return embedded("not playable");
    const c = &candidates[i];
    const vol = romfs.Volume.open_badge() catch |e| return embedded(@errorName(e));
    const m = vol.map(c.entry, &clusters) catch |e| return embedded(@errorName(e));
    const size: u32 = @min(m.size, core.rom_mod.max_bytes);
    const n: usize = (size + romfs.sector_size - 1) / romfs.sector_size;
    for (sectors[0..n], 0..) |*s, k| {
        const off: u32 = @intCast(k * romfs.sector_size);
        const len: u32 = @min(romfs.sector_size, size - off);
        // One sector per cluster in this FAT12 geometry, so every sector of
        // the file is one contiguous chunk; null means the map is broken.
        s.* = m.chunk(off, len) orelse return embedded("bad sector map");
    }
    const r = core.Rom.from_sectors(size, sectors[0..n]);
    info = .{
        .source = .drive,
        .size = size,
        .crc = r.crc32(),
        .fragmented = r.fragmented_banks(),
    };
    info.set_name(c.entry.slice());
    return r;
}

/// The embedded ROM. `why`: the drive was tried and this is the reason it is
/// not used (null when the drive was not asked for).
pub fn embedded(why: ?[]const u8) core.Rom {
    const r = core.Rom.from_slice(rom.data);
    info = .{
        .source = .embedded,
        .size = r.len,
        .crc = r.crc32(),
        .fallback = why,
    };
    info.set_name(rom.name);
    return r;
}
