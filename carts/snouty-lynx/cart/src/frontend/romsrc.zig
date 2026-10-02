//! Where the ROM comes from (docs/ROM_DRIVE.md sections 4 and 5, SPEC.md
//! section 11), plus the facts the status strip and About show.
//!
//! Badge build with `rom.source == .drive`: scan the FAT12 volume at
//! `romfs.base_addr` for `.lnx`/`.lyx` files (frontend/drive.zig), run the
//! first playable one (the picker, frontend/picker.zig, offers the others
//! when there are several and `open`s the chosen one), CRC it and
//! build the core's block table (flash pointers for contiguous blocks, the
//! per-cluster path for the rest). No volume, no file, or only refused
//! files: the embedded ROM, with the reason in `fallback`. The simulator
//! (wasm) and `-Dlynx-rom-source=embed` always embed. The core never sees
//! romfs (SPEC.md section 7).
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

/// Why the drive was not used for the embedded ROM ("NoVolume", "X.LNX:
/// rotated", "skipped"); null for a drive ROM or when it was not asked.
pub var fallback: ?[]const u8 = null;
var fallback_buf: [48]u8 = undefined;
/// The drive file runs partly through the per-cluster path.
pub var fragmented: bool = false;

/// The drive's Lynx files as scanned (empty when the drive was not read).
pub fn candidates() []const drive.Candidate {
    if (!scanned_ok) return &.{};
    return scanned.candidates[0..scanned.count];
}

/// Index in `candidates()` of the running drive file, null for the
/// embedded ROM.
pub fn chosen_index() ?usize {
    return if (origin == .drive) chosen else null;
}

/// Playable drive files (0 when the drive was not read).
pub fn playable_count() u32 {
    if (!scanned_ok) return 0;
    return scanned.playable_count;
}

/// File name of the running ROM: the drive entry or the embedded ROM's.
pub fn name() []const u8 {
    return if (origin == .drive) scanned.candidates[chosen].file_name() else rom.name;
}

/// The ROM's display name: the header title when there is one, else the
/// file name (the strip and the menu band). Set with `layout`.
pub fn title_name() []const u8 {
    return title;
}
var title: []const u8 = "";

fn set_title() void {
    const t = layout.title();
    title = if (t.len > 0) t else name();
}

/// "drive" or "embedded".
pub fn origin_word() []const u8 {
    return if (origin == .drive) "drive" else "embedded";
}

/// "drive 128 KB" or "embedded 27 KB" (the strip's second line).
pub fn origin_line(buf: *[24]u8) []const u8 {
    var n = debug.put(buf, origin_word());
    n += debug.put(buf[n..], " ");
    n += put_size(buf[n..], size);
    return buf[0..n];
}

/// What happens after the splash (main.zig's state machine).
pub const Choice = enum {
    /// The cart from `select` runs (embedded, or the one playable file).
    run,
    /// Several playable drive files: the picker (the cart from `select`
    /// is the first of them, B keeps it).
    pick,
    /// A drive volume without a playable file: the help over the
    /// embedded ROM.
    help,
};

/// Choose the ROM. Call once from `start()`.
pub fn select() struct { cart: core.Cart, next: Choice } {
    if (!use_drive) return .{ .cart = embedded(null, null), .next = .run };
    const base: [*]const u8 = @ptrFromInt(romfs.base_addr);
    scanned = drive.scan(base, &clusters);
    scanned_ok = true;
    if (scanned.err) |e| return .{ .cart = embedded(@errorName(e), null), .next = .run };
    const i = scanned.first_playable() orelse {
        no_rom_on_drive = true;
        const c = if (scanned.count > 0) embedded(null, &scanned.candidates[0]) else embedded("no .lnx/.lyx file", null);
        return .{ .cart = c, .next = .help };
    };
    return .{ .cart = open(i), .next = if (scanned.playable_count > 1) .pick else .run };
}

/// Open drive candidate `i` (a playable one from `candidates()`) for the
/// picker: maps it into the shared cluster table and `Source`, recomputes
/// the CRC and the report. The caller re-`init_in_place`s the core with
/// the result before anything reads the old Cart again. A file that no
/// longer maps gives the embedded ROM with the reason.
pub noinline fn open(i: usize) core.Cart {
    const base: [*]const u8 = @ptrFromInt(romfs.base_addr);
    const cand = &scanned.candidates[i];
    const c = drive.open(base, cand, &clusters, &source) catch |e| return embedded(@errorName(e), null);
    chosen = i;
    origin = .drive;
    fallback = null;
    layout = cand.layout;
    size = cand.entry.size;
    crc = source.mapped.crc32();
    fragmented = c.direct_blocks() < @min(core.cart.block_count, c.size / c.block_size);
    set_title();
    return c;
}

/// The embedded ROM. `why` or `refused` say why the drive was not used
/// (both null: it was not asked).
pub noinline fn embedded(why: ?[]const u8, refused: ?*const drive.Candidate) core.Cart {
    origin = .embedded;
    crc = 0;
    fragmented = false;
    size = @intCast(rom.data.len);
    layout = core.cart.parse(rom.data, size);
    set_title();
    fallback = null;
    if (why) |s| {
        fallback = fallback_buf[0..debug.put(&fallback_buf, s)];
    }
    if (refused) |c| {
        var n = debug.put(&fallback_buf, c.file_name());
        n += debug.put(fallback_buf[n..], ": ");
        n += debug.put(fallback_buf[n..], c.note());
        fallback = fallback_buf[0..n];
    }
    if (layout.verdict != .ok) return core.Cart.empty(&layout);
    return core.Cart.from_slice(&layout, rom.data);
}

/// "128 KB" or "576 B".
pub noinline fn put_size(dst: []u8, bytes: u32) usize {
    if (bytes >= 1024) {
        const n = debug.put_num(dst, bytes / 1024);
        return n + debug.put(dst[n..], " KB");
    }
    const n = debug.put_num(dst, bytes);
    return n + debug.put(dst[n..], " B");
}

/// `v` as eight upper-case hex digits.
pub noinline fn hex8(buf: *[8]u8, v: u32) []const u8 {
    const digits = "0123456789ABCDEF";
    for (buf, 0..) |*ch, i| ch.* = digits[(v >> @intCast(28 - 4 * i)) & 0xF];
    return buf;
}
