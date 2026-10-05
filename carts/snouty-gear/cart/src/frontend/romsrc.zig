//! Where the ROM comes from (docs/ROM_DRIVE.md sections 4 and 5, SPEC.md
//! section 11), plus the one-line report the screen shows.
//!
//! Badge build with `rom.source == .drive`: open the FAT12 volume at
//! `romfs.base_addr`, then the extra drive when the firmware has one
//! (`romfs.Image.extra`), take the first `.gg`/`.sms` file, map its clusters,
//! CRC it and build the core's bank table: a direct flash pointer for each
//! 16 KB bank that is one contiguous run (`Mapped.chunk`), the per-cluster
//! `Mapped.read` path for the rest. Any error, or no file, means no ROM:
//! `select` returns null, `failure` says why and main.zig shows the
//! "No ROM on the badge drive" screen (frontend/splash.zig). This build
//! never references `rom.data`, so the embedded ROM's bytes are not in the
//! image (the badge drive has room for 1280 KB of UF2s, and a UF2 costs
//! twice its payload). The simulator (wasm) and `-Dgg-rom-source=embed`
//! always use the embedded ROM. The core never sees romfs (SPEC.md
//! section 7).
const cart = @import("cart-api");
const core = @import("core");
const rom = @import("rom");
const romfs = @import("romfs");
const debug = @import("debug.zig");
const text = @import("text.zig");

pub const Origin = enum(u32) { embedded = 0, drive = 1 };

/// The badge drive build: the ROM comes only from the drive and the
/// embedded one is comptime-unreachable (not linked).
pub const use_drive = !cart.is_wasm and rom.source == .drive;

pub const origin: Origin = if (use_drive) .drive else .embedded;
/// ROM files found on the drive (0 when not looked or no volume).
pub var drive_matches: u32 = 0;
/// CRC32 of the drive file (0 for the embedded ROM).
pub var crc: u32 = 0;
/// Size in bytes of the running ROM: the drive file's directory size, or
/// the embedded ROM's length (the core's `Rom.size` is capped at 256 banks).
pub var size: u32 = 0;
/// Why the drive gave no ROM (a romfs error name or "no .gg/.sms file");
/// null when the drive ROM runs or the drive was never tried (simulator,
/// `-Dgg-rom-source=embed`).
pub var failure: ?[]const u8 = null;
/// The chosen drive entry; `name` points into it. Static, as `entries`.
var drive_entry: romfs.Entry = .{};

/// File name of the running ROM for the menu and About: the drive entry
/// (long name if the host wrote one, up to 64 bytes) or the embedded
/// ROM's file name. A Game Gear header carries no title.
pub fn name() []const u8 {
    return if (comptime use_drive) drive_entry.slice() else rom.name;
}

var report_buf: [160]u8 = undefined;
var report_len: usize = 0;

/// The report line, e.g. "ROM: embedded waternet.gg 64 KB",
/// "ROM: drive sonic.gg 256 KB crc 1A2B3C4D" or "ROM: none, drive:
/// NoVolume".
pub fn report() []const u8 {
    return report_buf[0..report_len];
}

/// Cluster table for `romfs.Volume.map` (5 KB) and the mapped file; both
/// must outlive the Rom, whose null banks read through `mapped`.
var clusters: [romfs.max_clusters]u16 = undefined;
var mapped: romfs.Mapped = undefined;
var entries: [8]romfs.Entry = undefined;

/// Choose the ROM. Call once from `start()`. Null: the drive has no
/// usable ROM (`failure` says why); only the badge drive build returns it.
pub fn select() ?core.Rom {
    if (comptime !use_drive) return embedded();
    return from_drive();
}

fn from_drive() ?core.Rom {
    // The badge drive first, then the extra drive. The badge drive's error
    // is reported only when neither has a ROM.
    var badge_err: ?[]const u8 = null;
    var n: usize = 0;
    var d: u8 = 0;
    while (d < romfs.drive_count and n < entries.len) : (d += 1) {
        const v = romfs.Volume.open_drive(d) catch |err| {
            if (d == 0) badge_err = @errorName(err);
            continue;
        };
        n += v.find(&.{ "gg", "sms" }, entries[n..]);
    }
    drive_matches = @intCast(n);
    if (n == 0) return none(badge_err orelse "no .gg/.sms file");
    const e = entries[0];
    drive_entry = e;
    const vol = romfs.Volume.open_drive(e.drive) catch |err| return none(@errorName(err));
    mapped = vol.map(e, &clusters) catch |err| return none(@errorName(err));
    crc = mapped.crc32();

    var r: core.Rom = .{
        .size = @min(mapped.size, core.rom.max_banks * core.rom.bank_size),
        .read_fallback = .{ .ctx = &mapped, .func = &read_mapped },
    };
    r.bank_count = core.Rom.bank_count_for(r.size);
    var i: u32 = 0;
    while (i < r.bank_count) : (i += 1) {
        const off = i * core.rom.bank_size;
        // Only whole banks get a pointer; a partial last bank goes through
        // `read`, which stops at the end of the file.
        if (off + core.rom.bank_size <= r.size) r.banks[i] = mapped.chunk(off, core.rom.bank_size);
    }
    size = mapped.size;

    var w: Writer = .{};
    w.put("ROM: drive ");
    w.put(e.slice());
    w.put(" ");
    w.num(mapped.size / 1024);
    w.put(" KB crc ");
    w.hex32(crc);
    if (!r.all_direct()) w.put(" frag");
    if (n > 1) {
        w.put(" (1 of ");
        w.num(@intCast(n));
        w.put(")");
    }
    w.done();
    return r;
}

fn read_mapped(ctx: *const anyopaque, offset: u32) u8 {
    const m: *const romfs.Mapped = @ptrCast(@alignCast(ctx));
    return m.read(offset);
}

/// No ROM on the drive: record `why` for the no-ROM screen.
fn none(why: []const u8) ?core.Rom {
    failure = why;
    var w: Writer = .{};
    w.put("ROM: none, drive: ");
    w.put(why);
    w.done();
    return null;
}

/// The embedded ROM (simulator, `-Dgg-rom-source=embed`). Never analysed
/// in the badge drive build, so `rom.data` is not linked there.
fn embedded() core.Rom {
    size = @intCast(rom.data.len);
    var w: Writer = .{};
    w.put("ROM: embedded ");
    w.put(rom.name);
    w.put(" ");
    w.num(@intCast(rom.data.len / 1024));
    w.put(" KB");
    w.done();
    return core.Rom.from_slice(rom.data);
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
    // Split into at most 4 lines at spaces.
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
