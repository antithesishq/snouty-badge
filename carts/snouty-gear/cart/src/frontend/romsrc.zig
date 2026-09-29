//! Where the ROM comes from (docs/ROM_DRIVE.md sections 4 and 5, SPEC.md
//! section 11), plus the one-line report the screen shows.
//!
//! Badge build with `rom.source == .drive`: open the FAT12 volume at
//! `romfs.base_addr`, take the first `.gg`/`.sms` file, map its clusters,
//! CRC it and build the core's bank table: a direct flash pointer for each
//! 16 KB bank that is one contiguous run (`Mapped.chunk`), the per-cluster
//! `Mapped.read` path for the rest. Any error, or no file, falls back to the
//! embedded ROM. The simulator (wasm) and `-Dgg-rom-source=embed` always use
//! the embedded ROM. The core never sees romfs (SPEC.md section 7).
const cart = @import("cart-api");
const core = @import("core");
const rom = @import("rom");
const romfs = @import("romfs");
const debug = @import("debug.zig");

pub const Origin = enum(u32) { embedded = 0, drive = 1 };

pub var origin: Origin = .embedded;
/// ROM files found on the drive (0 when not looked or no volume).
pub var drive_matches: u32 = 0;
/// CRC32 of the drive file (0 for the embedded ROM).
pub var crc: u32 = 0;

var report_buf: [160]u8 = undefined;
var report_len: usize = 0;

/// The report line, e.g. "ROM: embedded waternet.gg 64 KB",
/// "ROM: drive sonic.gg 256 KB crc 1A2B3C4D" or
/// "ROM: embedded waternet.gg 64 KB, drive: NoVolume".
pub fn report() []const u8 {
    return report_buf[0..report_len];
}

/// Cluster table for `romfs.Volume.map` (5 KB) and the mapped file; both
/// must outlive the Rom, whose null banks read through `mapped`.
var clusters: [romfs.max_clusters]u16 = undefined;
var mapped: romfs.Mapped = undefined;
var entries: [8]romfs.Entry = undefined;

/// Choose the ROM. Call once from `start()`.
pub fn select() core.Rom {
    if (cart.is_wasm or rom.source == .embed) return embedded(null);
    return from_drive();
}

fn from_drive() core.Rom {
    const base: [*]const u8 = @ptrFromInt(romfs.base_addr);
    const vol = romfs.Volume.open(base) catch |e| return embedded(@errorName(e));
    const n = vol.find(&.{ "gg", "sms" }, &entries);
    drive_matches = @intCast(n);
    if (n == 0) return embedded("no .gg/.sms file");
    const e = entries[0];
    mapped = vol.map(e, &clusters) catch |err| return embedded(@errorName(err));
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
    origin = .drive;

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

/// The embedded ROM; `why` says why the drive was not used (null: it was
/// not asked for).
fn embedded(why: ?[]const u8) core.Rom {
    origin = .embedded;
    var w: Writer = .{};
    w.put("ROM: embedded ");
    w.put(rom.name);
    w.put(" ");
    w.num(@intCast(rom.data.len / 1024));
    w.put(" KB");
    if (why) |s| {
        w.put(", drive: ");
        w.put(s);
    }
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
        cart.text(.{
            .str = s[starts[k]..ends[k]],
            .x = 0,
            .y = y,
            .text_color = .rgb(0xFFFFFF),
            .background_color = .rgb(0x000000),
        });
    }
}
