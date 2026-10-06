//! Where the ROM comes from (docs/ROM_DRIVE.md sections 4 and 5, SPEC.md
//! section 11), plus the facts the menu's About page shows.
//!
//! Badge build with `rom.source == .drive`: scan the FAT12 volume at
//! `romfs.base_addr` for `.lnx`/`.lyx` files (frontend/drive.zig), run the
//! first playable one (the picker, frontend/picker.zig, offers the others
//! when there are several and `open`s the chosen one), CRC it and
//! build the core's block table (flash pointers for contiguous blocks, the
//! per-cluster path for the rest). No volume, no file, only refused files
//! or a file that no longer maps: no ROM (`origin == .none`, the reason in
//! `reason`), and main.zig shows the no-ROM screen. A drive build embeds no
//! ROM: every use of `rom.data` sits behind `!use_drive`, so the badge cart
//! carries none of its bytes. The simulator (wasm) and
//! `-Dlynx-rom-source=embed` always embed. The core never sees romfs
//! (SPEC.md section 7).
const cart = @import("cart-api");
const core = @import("core");
const rom = @import("rom");
const romfs = @import("romfs");
const drive = @import("drive");
const debug = @import("debug.zig");

pub const Origin = enum(u32) { embedded = 0, drive = 1, none = 2 };

/// True when this build reads the badge drive (false in wasm and embed builds).
pub const use_drive = !cart.is_wasm and rom.source == .drive;

pub var origin: Origin = .embedded;
/// CRC32 of the drive file (0 for the embedded ROM and none).
pub var crc: u32 = 0;
/// Size in bytes of the running ROM file (header included).
pub var size: u32 = 0;
/// `core.cart.parse` of the running ROM.
pub var layout: core.cart.Layout = .{};

/// Cluster table and the chosen file's source: both outlive the Cart,
/// whose fragmented blocks read through them.
var clusters: [romfs.max_clusters]u16 = undefined;
var source: drive.Source = undefined;
var scanned: drive.Scan = undefined;
var scanned_ok = false;
var chosen: usize = 0;

/// Why the drive gave no ROM ("NoVolume", "X.LNX: rotated", "no .lnx/.lyx
/// file"); null while a ROM runs. The no-ROM screen shows it.
pub var reason: ?[]const u8 = null;
var reason_buf: [48]u8 = undefined;
/// The drive file runs partly through the per-cluster path.
pub var fragmented: bool = false;

/// The drive's Lynx files as scanned (empty when the drive was not read).
pub fn candidates() []const drive.Candidate {
    if (!scanned_ok) return &.{};
    return scanned.candidates[0..scanned.count];
}

/// Index in `candidates()` of the running drive file, null for the
/// embedded ROM and none.
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
    return switch (origin) {
        .drive => scanned.candidates[chosen].file_name(),
        .embedded => rom.name,
        .none => "",
    };
}

/// The ROM's display name: the header title when there is one, else the
/// file name (the menu band, the debug overlay). Set with `layout`.
pub fn title_name() []const u8 {
    return title;
}
var title: []const u8 = "";

fn set_title() void {
    const t = layout.title();
    title = if (t.len > 0) t else name();
}

/// What happens after the splash (main.zig's state machine).
pub const Choice = enum {
    /// The cart from `select` runs (embedded, or the one playable file).
    run,
    /// Several playable drive files: the picker (the cart from `select`
    /// is the first of them, B keeps it).
    pick,
    /// No usable ROM on the drive (drive builds): the no-ROM screen, for
    /// good. The cart from `select` is an empty one, never stepped.
    help,
};

pub const Selection = struct { cart: core.Cart, next: Choice };

/// Choose the ROM. Call once from `start()`.
pub fn select() Selection {
    if (!use_drive) return .{ .cart = embedded(), .next = .run };
    scanned = drive.scan(romfs.Image.badge(), &clusters);
    // The extra drive (ext-flash firmware); stock firmware has none.
    if (romfs.Image.extra()) |extra| _ = drive.add(&scanned, extra, 1, &clusters);
    scanned_ok = true;
    // The badge drive's error matters only when the extra one had nothing.
    if (scanned.count == 0) if (scanned.err) |e| return no_rom(@errorName(e), null);
    const i = scanned.first_playable() orelse
        return if (scanned.count > 0) no_rom(null, &scanned.candidates[0]) else no_rom("no .lnx/.lyx file", null);
    const c = open(i) orelse return .{ .cart = .empty(&layout), .next = .help };
    return .{ .cart = c, .next = if (scanned.playable_count > 1) .pick else .run };
}

/// Open drive candidate `i` (a playable one from `candidates()`) for the
/// picker: maps it into the shared cluster table and `Source`, recomputes
/// the CRC and the report. The caller re-`init_in_place`s the core with
/// the result before anything reads the old Cart again. A file that no
/// longer maps gives null, no ROM with the reason: the caller shows the
/// no-ROM screen (the old Cart's cluster table may be overwritten).
pub noinline fn open(i: usize) ?core.Cart {
    const cand = &scanned.candidates[i];
    const base = romfs.Image.drive(cand.entry.drive) orelse {
        _ = no_rom("NoVolume", null);
        return null;
    };
    const c = drive.open(base, cand, &clusters, &source) catch |e| {
        _ = no_rom(@errorName(e), null);
        return null;
    };
    chosen = i;
    origin = .drive;
    reason = null;
    layout = cand.layout;
    size = cand.entry.size;
    crc = source.mapped.crc32();
    fragmented = c.direct_blocks() < @min(core.cart.block_count, c.size / c.block_size);
    set_title();
    return c;
}

/// The embedded ROM (wasm and embed builds only: a drive build must not
/// reference `rom.data`, or its bytes land in the badge cart).
noinline fn embedded() core.Cart {
    if (use_drive) @compileError("rom.data referenced in a drive build");
    origin = .embedded;
    crc = 0;
    fragmented = false;
    size = @intCast(rom.data.len);
    layout = core.cart.parse(rom.data, size);
    set_title();
    if (layout.verdict != .ok) return core.Cart.empty(&layout);
    return core.Cart.from_slice(&layout, rom.data);
}

/// No ROM (drive builds): `why` or `refused` say why the drive gave none.
/// The cart is an empty one for the core to hold; main.zig never steps it.
noinline fn no_rom(why: ?[]const u8, refused: ?*const drive.Candidate) Selection {
    origin = .none;
    crc = 0;
    size = 0;
    fragmented = false;
    layout = .{};
    set_title();
    reason = null;
    if (why) |s| {
        reason = reason_buf[0..debug.put(&reason_buf, s)];
    }
    if (refused) |c| {
        var n = debug.put(&reason_buf, c.file_name());
        n += debug.put(reason_buf[n..], ": ");
        n += debug.put(reason_buf[n..], c.note());
        reason = reason_buf[0..n];
    }
    return .{ .cart = .empty(&layout), .next = .help };
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
