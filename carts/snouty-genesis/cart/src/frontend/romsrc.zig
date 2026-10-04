//! Where the ROM comes from (SPEC.md section 11, docs/ROM_DRIVE.md and
//! docs/ROM_STREAMING.md at the repository root), plus the one-line report
//! the screen shows. Adapted from Snouty Gear's romsrc.zig; M2 (PLAN.md
//! Track B) splits it into the drive scan (`scan`, frontend/drive.zig does
//! the host-tested work), the choice (`select` for a drive file, `embedded`
//! otherwise) and the facts the menu shows (`file_name`, `title_name`,
//! `origin`, `crc`, `no_rom`).
//!
//! Badge build with `rom.source == .drive` (`use_drive`): `scan` opens the
//! FAT12 volume at `romfs.base_addr` and lists the root's
//! `.gen`/`.md`/`.bin` files with `core.rom.check`'s verdict (app.zig then
//! starts the one playable file, shows the picker for several or the no-ROM
//! screen, frontend/help.zig, for none). `select` maps the chosen file
//! again and builds a `core.RomSource`: the flash pointer when the file is
//! one contiguous run, else the cluster table over the volume's data area.
//! A drive build has no embedded ROM: nothing it analyzes reads `rom.data`
//! (`embedded` is a compile error there), so the bytes are not linked in.
//! The simulator (wasm) and `-Dmd-rom-source=embed` always use the embedded
//! ROM, and none of the drive code is compiled into them (`use_drive` is
//! comptime). The core never sees romfs (SPEC.md section 7).
const cart = @import("cart-api");
const core = @import("core");
const rom = @import("rom");
const romfs = @import("romfs");
const drive = @import("drive");
const debug = @import("debug.zig");
const text = @import("text.zig");

/// True when this build reads the badge drive (comptime: false in wasm and
/// with `-Dmd-rom-source=embed`). Every drive path is behind it.
pub const use_drive = !cart.is_wasm and rom.source == .drive;

/// What the ROM report line says, and `debug_rom_source`.
pub const Origin = enum(u32) {
    /// Nothing runnable: the chosen bytes have no "SEGA" header.
    none = 0,
    embedded = 1,
    drive_contiguous = 2,
    drive_fragmented = 3,
};

pub var origin: Origin = .none;
/// CRC32 of the drive file (0 for the embedded ROM, and 0 until
/// `crc_known`: `crc_tick` hashes the file a slice per update so starting a
/// ROM never stalls a frame).
pub var crc: u32 = 0;
/// True once `crc` holds the running ROM's CRC32 (always for the embedded
/// ROM, whose `crc` is 0).
pub var crc_known: bool = true;
/// File bytes `crc_tick` hashes per call (about 0.7 ms on the badge).
pub const crc_chunk: u32 = 8 * 1024;
/// The CRC in progress for the drive file `select` started.
var crc_state: romfs.Mapped.Crc = undefined;
/// Drive builds: why no drive ROM runs, for the no-ROM screen ("NoVolume",
/// "SONIC.GEN: BadChain", "no .gen/.md/.bin files"); null when the refused
/// files the screen lists say it all, and while a drive ROM runs.
pub var no_rom: ?[]const u8 = null;
var no_rom_buf: [80]u8 = undefined;

/// The last `scan` (drive builds; only `candidates[0..count]` is set).
pub var scan_result: drive.Scan = undefined;
/// `.gen`/`.md`/`.bin` files found by `scan`, and how many of them run.
/// Both 0 when the drive was not scanned or has no volume.
pub var candidate_count: u32 = 0;
pub var playable_count: u32 = 0;

/// The candidate `select` started, null for the embedded ROM.
var chosen: ?usize = null;

var report_buf: [160]u8 = undefined;
var report_len: usize = 0;

/// The report line, e.g. "ROM: embedded snouty-test.bin 16 KB" or
/// "ROM: drive contiguous SONIC.GEN 512 KB crc 1A2B3C4D".
pub fn report() []const u8 {
    return report_buf[0..report_len];
}

/// Cluster table for `romfs.Volume.map` (5 KB) and the mapped file; both
/// must outlive the RomSource, whose cluster path reads through `clusters`.
/// The RAM cart's holds 768 KB (3 KB), the largest ROM that fits on the
/// drive beside its own ~540 KB UF2, so its sound (core/sound.zig) fits; a
/// larger file is listed as not playable (TooManyClusters).
var clusters: [if (core.sound.enabled) 1536 else romfs.max_clusters]u16 = undefined;
var mapped: romfs.Mapped = undefined;

/// The drive: `romfs.size` bytes at `romfs.base_addr`.
fn drive_base() romfs.Image {
    return romfs.Image.badge();
}

/// List the drive's ROM files into `scan_result`, and set `no_rom` when
/// the volume did not open or holds no ROM file at all. Call once from
/// `start()` (a no-op in builds that do not read the drive).
pub fn scan() void {
    if (!use_drive) return;
    scan_result = drive.scan(drive_base(), &clusters);
    candidate_count = scan_result.count;
    playable_count = scan_result.playable_count;
    no_rom = if (scan_result.err) |e| @errorName(e) else if (candidate_count == 0) "no .gen/.md/.bin files" else null;
}

/// The candidates of the last `scan` (empty in builds without the drive).
pub fn candidates() []const drive.Candidate {
    if (!use_drive) return &.{};
    return scan_result.candidates[0..candidate_count];
}

/// Start drive candidate `i` (drive builds only): map it, set `origin` and
/// the report line, and start the CRC32 that `crc_tick` finishes (the
/// report reads "crc ...." until then). Null, with `no_rom` set, when `i`
/// is not a playable candidate or its chain no longer maps: app.zig then
/// shows the no-ROM screen.
pub fn select(i: usize) ?core.RomSource {
    if (!use_drive) @compileError("select: drive builds only");
    if (i >= candidate_count or !scan_result.candidates[i].playable()) return refuse(i, "not playable");
    const c = &scan_result.candidates[i];
    mapped = drive.open(drive_base(), c, &clusters) catch |err| return refuse(i, @errorName(err));
    crc_state = romfs.Mapped.Crc.init();
    crc = 0;
    crc_known = false;
    const src = drive.source_of(&mapped);
    origin = if (src.base != null) .drive_contiguous else .drive_fragmented;
    chosen = i;
    no_rom = null;
    drive_report();
    return src;
}

/// `select` could not start candidate `i`: `no_rom` = "NAME: why".
fn refuse(i: usize, why: []const u8) ?core.RomSource {
    var n: usize = 0;
    const name = if (i < candidate_count) scan_result.candidates[i].file_name() else "";
    for ([_][]const u8{ name, ": ", why }) |part| {
        const k = @min(part.len, no_rom_buf.len - n);
        @memcpy(no_rom_buf[n..][0..k], part[0..k]);
        n += k;
    }
    origin = .none;
    no_rom = no_rom_buf[0..n];
    return null;
}

/// Hash the next `crc_chunk` bytes of the running drive file; on the last
/// slice set `crc`, `crc_known` and the report line. Call once per running
/// update; a no-op once the CRC is known, for the embedded ROM and in
/// builds without the drive.
pub fn crc_tick() void {
    if (!use_drive) return;
    if (crc_known) return;
    if (!crc_state.step(&mapped, crc_chunk)) return;
    crc = crc_state.final();
    crc_known = true;
    drive_report();
}

/// The report line for the drive file `chosen`, e.g. "ROM: drive
/// contiguous SONIC.GEN 512 KB crc 1A2B3C4D (1 of 2)"; "crc ...." while
/// the CRC is pending.
fn drive_report() void {
    const i = chosen orelse return;
    const c = &scan_result.candidates[i];
    var w: Writer = .{};
    w.put(if (origin == .drive_contiguous) "ROM: drive contiguous " else "ROM: drive fragmented ");
    w.put(c.file_name());
    w.put(" ");
    w.num((mapped.size + 1023) / 1024);
    w.put(" KB crc ");
    if (crc_known) w.hex32(crc) else w.put("....");
    if (playable_count > 1) {
        w.put(" (");
        w.num(@intCast(i + 1));
        w.put(" of ");
        w.num(candidate_count);
        w.put(")");
    }
    w.done();
}

/// The embedded ROM (wasm and `-Dmd-rom-source=embed` builds only: a
/// drive build must not reference `rom.data`, or the bytes are linked in).
/// `none` when `rom.check` refuses it (a bad -Dmd-rom: no header, SMD,
/// mapper, SVP), with the reason on the report line.
pub fn embedded() core.RomSource {
    if (use_drive) @compileError("embedded: a drive build has no embedded ROM");
    const src = core.RomSource.from_slice(rom.data);
    const verdict = core.rom.check(&src);
    const ok = verdict == .ok;
    origin = if (ok) .embedded else .none;
    crc = 0;
    crc_known = true;
    chosen = null;
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
        w.put(": ");
        w.put(verdict.text());
        w.put(")");
    }
    w.done();
    return if (ok) src else .{};
}

/// The running ROM's file name: the drive file's, or the embedded one's.
pub fn file_name() []const u8 {
    if (use_drive) {
        const i = chosen orelse return "";
        return scan_result.candidates[i].file_name();
    }
    return rom.name;
}

var title_buf: [drive.name_max]u8 = undefined;

/// The running ROM's name for the menu: the header's domestic name, else
/// its overseas name (trimmed, runs of spaces collapsed), else the file
/// name.
pub fn title_name() []const u8 {
    if (use_drive) {
        const i = chosen orelse return "";
        const c = &scan_result.candidates[i];
        return if (c.name_len > 0) c.name() else c.file_name();
    }
    const src = core.RomSource.from_slice(rom.data);
    if (!core.rom.is_genesis(&src)) return rom.name;
    const n = drive.header_name(&src, &title_buf);
    return if (n > 0) title_buf[0..n] else rom.name;
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
