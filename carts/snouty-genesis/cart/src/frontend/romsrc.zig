//! Where the ROM comes from (SPEC.md section 11, docs/ROM_DRIVE.md and
//! docs/ROM_STREAMING.md at the repository root), plus the one-line report
//! the screen shows. Adapted from Snouty Gear's romsrc.zig; M2 adds the
//! picker for several files and the no-ROM help screen.
//!
//! Badge build with `rom.source == .drive`: open the FAT12 volume at
//! `romfs.base_addr`, list the root's `.gen`/`.md`/`.bin` files, take the
//! first whose word at 0x100 reads "SEGA", map its clusters and build a
//! `core.RomSource`: the flash pointer when the file is one contiguous run
//! (`Mapped.contiguous`), else the cluster table over the volume's data
//! area. Any error, or no such file, falls back to the embedded ROM. The
//! simulator (wasm) and `-Dmd-rom-source=embed` always use the embedded
//! ROM. The core never sees romfs (SPEC.md section 7).
const cart = @import("cart-api");
const core = @import("core");
const rom = @import("rom");
const romfs = @import("romfs");
const debug = @import("debug.zig");
const text = @import("text.zig");

/// What the ROM report line says, and `debug_rom_source`.
pub const Origin = enum(u32) {
    /// Nothing runnable: the chosen bytes have no "SEGA" header.
    none = 0,
    embedded = 1,
    drive_contiguous = 2,
    drive_fragmented = 3,
};

pub var origin: Origin = .none;
/// ROM files found on the drive (0 when not looked or no volume).
pub var drive_matches: u32 = 0;
/// CRC32 of the drive file (0 for the embedded ROM).
pub var crc: u32 = 0;

var report_buf: [160]u8 = undefined;
var report_len: usize = 0;

/// The report line, e.g. "ROM: embedded snouty-test.bin 16 KB",
/// "ROM: drive contiguous SONIC.GEN 512 KB crc 1A2B3C4D" or
/// "ROM: embedded placeholder.bin 1 KB, drive: NoVolume".
pub fn report() []const u8 {
    return report_buf[0..report_len];
}

/// Cluster table for `romfs.Volume.map` (5 KB) and the mapped file; both
/// must outlive the RomSource, whose cluster path reads through `clusters`.
var clusters: [romfs.max_clusters]u16 = undefined;
var mapped: romfs.Mapped = undefined;
var entries: [8]romfs.Entry = undefined;

/// Choose the ROM. Call once from `start()`.
pub fn select() core.RomSource {
    if (cart.is_wasm or rom.source == .embed) return embedded(null);
    return from_drive();
}

fn from_drive() core.RomSource {
    const base: [*]const u8 = @ptrFromInt(romfs.base_addr);
    const vol = romfs.Volume.open(base) catch |e| return embedded(@errorName(e));
    const n = vol.find(&.{ "gen", "md", "bin" }, &entries);
    // First file with a Genesis header; count them all for the report.
    var pick: ?usize = null;
    var last_err: ?[]const u8 = null;
    var genesis: u32 = 0;
    for (entries[0..n], 0..) |e, i| {
        const m = vol.map(e, &clusters) catch |err| {
            last_err = @errorName(err);
            continue;
        };
        const src = source_of(&m);
        if (!core.rom.is_genesis(&src)) continue;
        genesis += 1;
        if (pick == null) pick = i;
    }
    drive_matches = genesis;
    const i = pick orelse return embedded(last_err orelse "no .gen/.md/.bin file");
    const e = entries[i];
    // Map the pick again: the loop reused `clusters` for later files.
    mapped = vol.map(e, &clusters) catch |err| return embedded(@errorName(err));
    crc = mapped.crc32();
    const src = source_of(&mapped);
    origin = if (src.base != null) .drive_contiguous else .drive_fragmented;

    var w: Writer = .{};
    w.put(if (origin == .drive_contiguous) "ROM: drive contiguous " else "ROM: drive fragmented ");
    w.put(e.slice());
    w.put(" ");
    w.num((mapped.size + 1023) / 1024);
    w.put(" KB crc ");
    w.hex32(crc);
    if (genesis > 1) {
        w.put(" (1 of ");
        w.num(genesis);
        w.put(")");
    }
    w.done();
    return src;
}

/// The RomSource for a mapped file: the base pointer when contiguous, else
/// the cluster table.
fn source_of(m: *const romfs.Mapped) core.RomSource {
    const size: u32 = @min(m.size, core.rom.max_size);
    if (m.contiguous()) |p| return .{ .size = size, .base = p };
    return .{ .size = size, .clusters = m.clusters, .data_base = m.data_base };
}

/// The embedded ROM; `why` says why the drive was not used (null: it was
/// not asked for). `none` when it has no Genesis header (a bad -Dmd-rom).
fn embedded(why: ?[]const u8) core.RomSource {
    const src = core.RomSource.from_slice(rom.data);
    const ok = core.rom.is_genesis(&src);
    origin = if (ok) .embedded else .none;
    var w: Writer = .{};
    if (ok) {
        w.put("ROM: embedded ");
        w.put(rom.name);
        w.put(" ");
        w.num(@intCast((rom.data.len + 1023) / 1024));
        w.put(" KB");
    } else {
        w.put("ROM: none (");
        w.put(rom.name);
        w.put(" has no SEGA header)");
    }
    if (why) |s| {
        w.put(", drive: ");
        w.put(s);
    }
    w.done();
    return if (ok) src else .{};
}

const Writer = struct {
    n: usize = 0,

    fn put(w: *Writer, s: []const u8) void {
        const k = @min(s.len, report_buf.len - w.n);
        w.n += debug.put(report_buf[w.n..], s[0..k]);
    }

    fn num(w: *Writer, v: u32) void {
        if (report_buf.len - w.n < 10) return;
        w.n += debug.put_num(report_buf[w.n..], v);
    }

    fn hex32(w: *Writer, v: u32) void {
        const digits = "0123456789ABCDEF";
        var tmp: [8]u8 = undefined;
        for (&tmp, 0..) |*c, i| c.* = digits[(v >> @intCast(28 - 4 * i)) & 0xF];
        w.put(&tmp);
    }

    fn done(w: *Writer) void {
        report_len = w.n;
    }
};

/// Draw the report at the bottom of the screen, word-wrapped to the 20
/// columns of the 8 px font, last line on the bottom row.
pub fn draw_report() void {
    const cols = cart.screen_width / 8;
    const s = report();
    var starts: [4]usize = undefined;
    var ends: [4]usize = undefined;
    var lines: usize = 0;
    var i: usize = 0;
    while (i < s.len and lines < starts.len) {
        while (i < s.len and s[i] == ' ') i += 1;
        const start = i;
        var end = @min(s.len, start + cols);
        if (end < s.len and s[end] != ' ') {
            var j = end;
            while (j > start and s[j - 1] != ' ') j -= 1;
            if (j > start) end = j;
        }
        var trimmed = end;
        while (trimmed > start and s[trimmed - 1] == ' ') trimmed -= 1;
        starts[lines] = start;
        ends[lines] = trimmed;
        lines += 1;
        i = end;
    }
    for (0..lines) |k| {
        const y: i32 = @intCast(cart.screen_height - 8 * (lines - k));
        text.draw(s[starts[k]..ends[k]], 0, y, .rgb(0xFFFFFF), .rgb(0x000000));
    }
}
