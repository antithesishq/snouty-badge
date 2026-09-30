//! Where the ROM comes from (docs/ROM_DRIVE.md sections 4 and 5, SPEC.md
//! section 11), plus the report line the status strip shows.
//!
//! Badge build with `rom.source == .drive`: scan the FAT12 volume at
//! `romfs.base_addr` for `.lnx`/`.lyx` files (frontend/drive.zig), run the
//! first playable one (M0; the M2 menu lists `candidates()`), CRC it and
//! build the core's block table (flash pointers for contiguous blocks, the
//! per-cluster path for the rest). No volume, no file, or only refused
//! files: the embedded ROM, with the reason in the report. The simulator
//! (wasm) and `-Dlynx-rom-source=embed` always embed. The core never sees
//! romfs (SPEC.md section 7).
const std = @import("std");
const cart = @import("cart-api");
const core = @import("core");
const rom = @import("rom");
const romfs = @import("romfs");
const drive = @import("drive");
const debug = @import("debug.zig");

pub const Origin = enum(u32) { embedded = 0, drive = 1 };

/// True when this build reads the badge drive (false in wasm and embed builds).
pub const use_drive = !cart.is_wasm and rom.source == .drive;

pub var origin: Origin = .embedded;
/// CRC32 of the drive file (0 for the embedded ROM).
pub var crc: u32 = 0;
/// Size in bytes of the running ROM file (header included).
pub var size: u32 = 0;
/// `core.cart.parse` of the running ROM.
pub var layout: core.cart.Layout = .{};
/// The drive volume opened but holds no playable Lynx file: the screen
/// shows the how-to-add-a-ROM help (main.zig).
pub var no_rom_on_drive: bool = false;

/// Cluster table and the chosen file's source: both outlive the Cart,
/// whose fragmented blocks read through them.
var clusters: [romfs.max_clusters]u16 = undefined;
var source: drive.Source = undefined;
var scanned: drive.Scan = undefined;
var scanned_ok = false;
var chosen: usize = 0;

/// The drive's Lynx files as scanned (empty when the drive was not read).
pub fn candidates() []const drive.Candidate {
    if (!scanned_ok) return &.{};
    return scanned.candidates[0..scanned.count];
}

/// File name of the running ROM: the drive entry or the embedded ROM's.
pub fn name() []const u8 {
    return if (origin == .drive) scanned.candidates[chosen].file_name() else rom.name;
}

var report_buf: [96]u8 = undefined;
var report_len: usize = 0;

/// E.g. "drive HARD_D~1.LNX 128 KB crc 1A2B3C4D", "embedded
/// placeholder.lnx 576 B", "embedded placeholder.lnx 576 B, drive:
/// NoVolume" or "..., drive: X.LNX: rotated".
pub fn report() []const u8 {
    return report_buf[0..report_len];
}

/// The report without its first word ("drive" / "embedded"), which the
/// status strip shows on the title line instead.
pub fn detail() []const u8 {
    const r = report();
    const sp = std.mem.indexOfScalar(u8, r, ' ') orelse return r;
    return r[sp + 1 ..];
}

/// "drive" or "embedded".
pub fn origin_word() []const u8 {
    return if (origin == .drive) "drive" else "embedded";
}

/// Choose the ROM. Call once from `start()`.
pub fn select() core.Cart {
    if (!use_drive) return embedded(null, null);
    return from_drive();
}

fn from_drive() core.Cart {
    const base: [*]const u8 = @ptrFromInt(romfs.base_addr);
    scanned = drive.scan(base, &clusters);
    scanned_ok = true;
    if (scanned.err) |e| return embedded(@errorName(e), null);
    const i = scanned.first_playable() orelse {
        no_rom_on_drive = true;
        if (scanned.count > 0) return embedded(null, &scanned.candidates[0]);
        return embedded("no .lnx/.lyx file", null);
    };
    const cand = &scanned.candidates[i];
    const c = drive.open(base, cand, &clusters, &source) catch |e| return embedded(@errorName(e), null);
    chosen = i;
    origin = .drive;
    layout = cand.layout;
    size = cand.entry.size;
    crc = source.mapped.crc32();

    var w: Writer = .{};
    w.put("drive ");
    w.put(cand.file_name());
    w.put(" ");
    w.size(size);
    w.put(" crc ");
    w.hex32(crc);
    if (c.direct_blocks() < @min(core.cart.block_count, c.size / c.block_size)) w.put(" frag");
    if (!layout.headered) w.put(" raw");
    if (layout.warn_eeprom()) w.put(" no-EEPROM");
    if (scanned.count > 1) {
        w.put(" (");
        w.num(@intCast(i + 1));
        w.put(" of ");
        w.num(scanned.count);
        w.put(")");
    }
    w.done();
    return c;
}

/// The embedded ROM. `why` or `refused` say why the drive was not used
/// (both null: it was not asked).
fn embedded(why: ?[]const u8, refused: ?*const drive.Candidate) core.Cart {
    origin = .embedded;
    size = @intCast(rom.data.len);
    layout = core.cart.parse(rom.data, size);
    var w: Writer = .{};
    w.put("embedded ");
    w.put(rom.name);
    w.put(" ");
    w.size(size);
    if (layout.verdict != .ok) {
        w.put(": ");
        w.put(layout.verdict.text());
    }
    if (why) |s| {
        w.put(", drive: ");
        w.put(s);
    }
    if (refused) |c| {
        w.put(", drive: ");
        w.put(c.file_name());
        w.put(": ");
        w.put(c.note());
    }
    w.done();
    if (layout.verdict != .ok) return core.Cart.empty(&layout);
    return core.Cart.from_slice(&layout, rom.data);
}

const Writer = struct {
    n: usize = 0,

    fn put(w: *Writer, s: []const u8) void {
        w.n += debug.put(report_buf[w.n..], s);
    }

    fn num(w: *Writer, v: u32) void {
        w.n += debug.put_num(report_buf[w.n..], v);
    }

    fn size(w: *Writer, bytes: u32) void {
        if (bytes >= 1024) {
            w.num(bytes / 1024);
            w.put(" KB");
        } else {
            w.num(bytes);
            w.put(" B");
        }
    }

    fn hex32(w: *Writer, v: u32) void {
        const digits = "0123456789ABCDEF";
        var tmp: [8]u8 = undefined;
        for (&tmp, 0..) |*ch, i| ch.* = digits[(v >> @intCast(28 - 4 * i)) & 0xF];
        w.put(&tmp);
    }

    fn done(w: *Writer) void {
        report_len = w.n;
    }
};
