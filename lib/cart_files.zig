//! Cart files: a cart creates a new file on the badge's USB drives
//! (SYCLBADGE, and SYCLEXTRA when the external chip is mounted). Needs the
//! fork firmware's `feature/cart-files` (adrian-computering/sycl-badge,
//! fork/CART_FILES.md "Cart ABI (v1)", the spec this file speaks); our carts
//! build against the pinned SDK, which predates it. First user: Snouty Beam,
//! which saves a received cart as an ordinary `.uf2`.
//!
//! - Detection: `os_flags` (u16 at 0x200350EA) bit 6 = `cart_files`, then a
//!   `probe` request (result = ABI version). Stock firmware leaves bit 6 at 0
//!   and never sees a request.
//! - A request: a 64-byte `abi.Request` in cart RAM, `state = pending`,
//!   `dmb`, the FIFO word `0x2D << 24 | (addr - 0x20000000) / 4`. The OS
//!   answers only through the struct (pending -> busy -> done, `status`,
//!   `result` and `flags` written before `done`), never the FIFO, so the
//!   wait (lib/os_mailbox.zig `wait_struct`) never reads the FIFO and the
//!   pinned runtime's FRAMEBUFFER_DONE stays queued for `present` (the
//!   hazard lib/ext_flash.zig has to handle does not arise; see
//!   lib/os_mailbox.zig).
//! - `create`, `write` and `commit` mask interrupts and spin from RAM until
//!   `done`: core 0 turns XIP off while it erases. `probe`, `stat` and
//!   `abort` touch no flash and run unmasked.
//! - A request still `pending` after 250 ms (probe) or 2 s (others) was
//!   never picked up: the magic is spoiled (`magic = 0`, which the OS
//!   ignores) and the call fails. Once the OS has moved it on, the wait has
//!   no limit: the OS always finishes.
//! - Flow for one file: `stat` the volumes, `create(volume, name, size)`
//!   (reserves space; `error.Exists` -> try another name), `write` in order
//!   (each 1..4096 bytes, `offset` = bytes so far, the buffer in cart RAM),
//!   `commit`. Any failure, or giving up: `abort` (the drive is unchanged
//!   until `commit`).
//! - `usb_host` (`abi.Flags`, on every reply, `last_flags()`): a computer
//!   has the drive mounted; `create`, `write` and `commit` then fail with
//!   `error.UsbHost` and the cart must `abort`.
//!
//! Backends: `badge` (free functions below) on the cart core; nothing in the
//! wasm simulator (`supported()` false); `Fake`, an in-memory drive pair
//! with the OS's rules and failure injection, for host tests (each test
//! badge owns one).
const std = @import("std");
const builtin = @import("builtin");
const os_mailbox = @import("os_mailbox.zig");

const is_badge = os_mailbox.is_badge;

pub const os_flags_address: usize = 0x200350EA;
pub const flag_cart_files: u16 = 1 << 6;

/// fork/CART_FILES.md "Cart ABI (v1)".
pub const abi = struct {
    pub const msg_type: u32 = 0x2D;
    pub const magic: u32 = 0x314C4946; // "FIL1"
    pub const version: u32 = 1;

    pub const Op = enum(u32) { probe = 1, stat = 2, create = 3, write = 4, commit = 5, abort = 6, _ };
    pub const State = enum(u32) { idle = 0, pending = 1, busy = 2, done = 3, _ };
    pub const Status = enum(u32) {
        ok = 0,
        exists = 1,
        no_space = 2,
        dir_full = 3,
        bad_request = 4,
        bad_buffer = 5,
        bad_name = 6,
        usb_host = 7,
        busy = 8,
        no_volume = 9,
        not_open = 10,
        io_error = 11,
        _,
    };
    pub const Flags = packed struct(u32) {
        /// A USB host has configured the device right now.
        usb_host: bool = false,
        /// Volume 1 (SYCLEXTRA) is mounted.
        ext_volume: bool = false,
        _: u30 = 0,
    };
    pub const Request = extern struct {
        magic: u32 = magic,
        op: Op,
        state: State = .idle,
        status: Status = .ok,
        /// 0 = SYCLBADGE, 1 = SYCLEXTRA.
        volume: u32 = 0,
        /// create: total file size; write: byte offset.
        offset: u32 = 0,
        buf: u32 = 0,
        len: u32 = 0,
        result: u32 = 0,
        flags: Flags = .{},
        _reserved: [6]u32 = @splat(0),
    };
    pub const FileStat = extern struct {
        free_bytes: u32,
        free_root_entries: u32,
        cluster_size: u32,
        total_bytes: u32,
    };

    comptime {
        if (@sizeOf(Request) != 64) @compileError("FileRequest must be 64 bytes");
        if (@sizeOf(FileStat) != 16) @compileError("FileStat must be 16 bytes");
    }
};

pub const Error = error{ Unsupported, Exists, NoSpace, DirFull, BadRequest, BadBuffer, BadName, UsbHost, Busy, NoVolume, NotOpen, IoError };

pub fn status_error(s: abi.Status) Error!void {
    return switch (s) {
        .ok => {},
        .exists => error.Exists,
        .no_space => error.NoSpace,
        .dir_full => error.DirFull,
        .bad_request => error.BadRequest,
        .bad_buffer => error.BadBuffer,
        .bad_name => error.BadName,
        .usb_host => error.UsbHost,
        .busy => error.Busy,
        .no_volume => error.NoVolume,
        .not_open => error.NotOpen,
        .io_error => error.IoError,
        _ => error.IoError,
    };
}

pub const volume_count = 2;
/// The drives' labels, by volume index.
pub const volume_names = [volume_count][]const u8{ "SYCLBADGE", "SYCLEXTRA" };
pub const max_name = 63;
pub const max_write = 4096;

/// What `stat` reports for a volume, plus the flags of that reply.
pub const Stat = struct {
    free_bytes: u32,
    free_root_entries: u32,
    cluster_size: u32,
    total_bytes: u32,
    flags: abi.Flags = .{},

    /// Room for a file of `size` bytes named with `name_len` bytes: whole
    /// clusters, and the root entries its long name takes.
    pub fn fits(s: Stat, size: u32, name_len: usize) bool {
        const cluster = @max(s.cluster_size, 1);
        const need = (@as(u64, size) + cluster - 1) / cluster * cluster;
        return need <= s.free_bytes and root_entries(name_len) <= s.free_root_entries;
    }
};

/// Root directory entries a name takes: one per 13 characters of long
/// name, plus the 8.3 entry (fork/CART_FILES.md "Rules").
pub fn root_entries(name_len: usize) u32 {
    return @intCast((name_len + 12) / 13 + 1);
}

// ---- names ---------------------------------------------------------------------------

fn bad_char(c: u8) bool {
    if (c < 0x20 or c > 0x7E) return true;
    return switch (c) {
        '\\', '/', ':', '*', '?', '"', '<', '>', '|' => true,
        else => false,
    };
}

/// The OS's name rules: 1..63 bytes, printable ASCII, none of
/// `\ / : * ? " < > |`, no leading or trailing space or dot.
pub fn valid_name(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name) return false;
    for (name) |c| if (bad_char(c)) return false;
    const first = name[0];
    const last = name[name.len - 1];
    return first != ' ' and first != '.' and last != ' ' and last != '.';
}

/// A name the OS accepts made from any bytes (a partner's file name):
/// forbidden characters become `_`, leading/trailing spaces and dots go,
/// at most 63 bytes keeping the extension; "cart.uf2" when nothing is left.
pub fn sanitize(name: []const u8, out: *[max_name]u8) []const u8 {
    var start: usize = 0;
    var end: usize = name.len;
    while (start < end and (name[start] == ' ' or name[start] == '.')) start += 1;
    while (end > start and (name[end - 1] == ' ' or name[end - 1] == '.')) end -= 1;
    const s = name[start..end];
    if (s.len == 0) {
        const d = "cart.uf2";
        @memcpy(out[0..d.len], d);
        return out[0..d.len];
    }
    // Over 63 bytes: keep the extension (if short) and cut the stem.
    const dot = std.mem.lastIndexOfScalar(u8, s, '.');
    const ext = if (dot) |d| (if (s.len - d <= 8) s[d..] else "") else "";
    const stem_max = max_name - ext.len;
    const stem = if (s.len <= max_name) s else s[0..stem_max];
    var n: usize = 0;
    for (stem) |c| {
        out[n] = if (bad_char(c)) '_' else c;
        n += 1;
    }
    if (s.len > max_name) for (ext) |c| {
        out[n] = if (bad_char(c)) '_' else c;
        n += 1;
    };
    // The cut may have left a trailing space or dot.
    while (n > 1 and (out[n - 1] == ' ' or out[n - 1] == '.')) n -= 1;
    return out[0..n];
}

/// `name` with "-k" before its extension (`snouty-pong-2.uf2`), the stem
/// cut so the result stays within 63 bytes. `name` must be valid.
pub fn numbered(name: []const u8, k: u32, out: *[max_name]u8) []const u8 {
    var suffix_buf: [12]u8 = undefined;
    const suffix = std.fmt.bufPrint(&suffix_buf, "-{d}", .{k}) catch unreachable;
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse name.len;
    const stem_full = name[0..dot];
    const ext = name[dot..];
    const room = max_name - suffix.len - ext.len;
    var stem = stem_full[0..@min(stem_full.len, room)];
    while (stem.len > 1 and (stem[stem.len - 1] == ' ' or stem[stem.len - 1] == '.')) stem = stem[0 .. stem.len - 1];
    var n: usize = 0;
    for ([_][]const u8{ stem, suffix, ext }) |part| {
        @memcpy(out[n..][0..part.len], part);
        n += part.len;
    }
    return out[0..n];
}

// ---- badge backend --------------------------------------------------------------------

/// Whether this firmware writes cart files: os_flags bit 6 and a probe
/// answered with ABI v1 or later (cached for the boot).
pub fn supported() bool {
    if (comptime is_badge) return badge.supported();
    return false;
}

/// The flags of the last reply (all false before any).
pub fn last_flags() abi.Flags {
    if (comptime is_badge) return badge.flags;
    return .{};
}

/// Ask again (a `probe`, no flash): refreshes `last_flags`.
pub fn refresh() Error!abi.Flags {
    if (comptime !is_badge) return error.Unsupported;
    if (!badge.supported()) return error.Unsupported;
    _ = try badge.submit(.probe, 0, 0, 0, 0, false);
    return badge.flags;
}

pub fn stat(volume: u1) Error!Stat {
    if (comptime !is_badge) return error.Unsupported;
    if (!badge.supported()) return error.Unsupported;
    _ = try badge.submit(.stat, volume, 0, @intFromPtr(&badge.stat_buf), @sizeOf(abi.FileStat), false);
    const s = @as(*volatile abi.FileStat, &badge.stat_buf).*;
    return .{ .free_bytes = s.free_bytes, .free_root_entries = s.free_root_entries, .cluster_size = s.cluster_size, .total_bytes = s.total_bytes, .flags = badge.flags };
}

/// Open a new file of `size` bytes on `volume` (`name` in cart RAM).
pub fn create(volume: u1, name: []const u8, size: u32) Error!void {
    if (comptime !is_badge) return error.Unsupported;
    if (!valid_name(name)) return error.BadName;
    _ = try badge.submit(.create, volume, size, @intFromPtr(name.ptr), name.len, true);
}

/// The next `data.len` (1..4096) bytes of the open file, at `offset` =
/// bytes written so far; `data` must be in cart RAM.
pub fn write(offset: u32, data: []const u8) Error!void {
    if (comptime !is_badge) return error.Unsupported;
    if (data.len == 0 or data.len > max_write) return error.BadRequest;
    _ = try badge.submit(.write, 0, offset, @intFromPtr(data.ptr), data.len, true);
}

/// Link the fully written file into the FAT and directory.
pub fn commit() Error!void {
    if (comptime !is_badge) return error.Unsupported;
    _ = try badge.submit(.commit, 0, 0, 0, 0, true);
}

/// Drop the open file; the drive stays as it was.
pub fn abort() void {
    if (comptime !is_badge) return;
    _ = badge.submit(.abort, 0, 0, 0, 0, false) catch {};
}

const badge = struct {
    const mailbox = os_mailbox.badge;
    const probe_timeout_us: u32 = 250_000;
    const op_timeout_us: u32 = 2_000_000;

    var req: abi.Request align(4) = .{ .op = .probe };
    var stat_buf: abi.FileStat align(4) = undefined;
    var flags: abi.Flags = .{};
    var probed: enum(u8) { unknown, yes, no } = .unknown;

    fn supported() bool {
        switch (probed) {
            .yes => return true,
            .no => return false,
            .unknown => {
                const os_flags: *const volatile u16 = @ptrFromInt(os_flags_address);
                const ok = os_flags.* & flag_cart_files != 0 and
                    if (submit(.probe, 0, 0, 0, 0, false)) |v| v >= abi.version else |_| false;
                probed = if (ok) .yes else .no;
                return ok;
            },
        }
    }

    /// Fill the request, send it, wait for `done`. Runs from RAM and
    /// touches only the request, TIMER0 and the SIO FIFO (write side).
    noinline fn submit(op: abi.Op, volume: u32, offset: u32, buf: usize, len: usize, mask: bool) Error!u32 {
        const r: *volatile abi.Request = &req;
        r.magic = abi.magic;
        r.op = op;
        r.status = .ok;
        r.volume = volume;
        r.offset = offset;
        r.buf = @truncate(buf);
        r.len = @truncate(len);
        r.result = 0;
        r.state = .pending;
        mailbox.dmb();

        const primask = if (mask) mailbox.irq_disable() else 0;
        defer if (mask) mailbox.irq_restore(primask);

        const timeout = if (op == .probe) probe_timeout_us else op_timeout_us;
        if (!mailbox.put(os_mailbox.word(abi.msg_type, @intFromPtr(&req)), timeout)) {
            r.state = .idle;
            return if (op == .probe) error.Unsupported else error.Busy;
        }
        const state: *volatile u32 = @ptrCast(&r.state);
        switch (mailbox.wait_struct(state, @backingInt(abi.State.pending), @backingInt(abi.State.done), timeout)) {
            .done => {},
            .never_picked_up => {
                // Spoil the magic so a late pickup touches nothing.
                r.magic = 0;
                r.state = .idle;
                mailbox.dmb();
                return if (op == .probe) error.Unsupported else error.Busy;
            },
        }
        flags = r.flags;
        try status_error(r.status);
        return r.result;
    }
};

// ---- host fake ------------------------------------------------------------------------

/// An in-memory pair of volumes with the OS's rules (fork/CART_FILES.md):
/// one open file, `create` reserves clusters and root entries, `write` in
/// order, `commit` makes the file visible, `abort` drops it, `usb_host`
/// refuses create/write/commit, names compare case-insensitively (FAT).
/// Failure injection: `usb_after_writes` (a host attaches after k
/// writes), `fail_write_at` (the k-th write fails with `fail_status`),
/// `fail_commit`. Bytes of every file live in `pool` (files the test
/// `preload`s take a name and space but no bytes).
pub const Fake = struct {
    pub const max_files = 48;
    pub const pool_size = 1024 * 1024;

    pub const Volume = struct {
        mounted: bool = true,
        total_bytes: u32 = 1280 * 1024,
        free_bytes: u32 = 1280 * 1024,
        free_root_entries: u32 = 32,
        cluster_size: u32 = 512,
    };

    pub const File = struct {
        volume: u1,
        name_buf: [max_name]u8,
        name_len: u8,
        /// Offset in `pool`, or null for a preloaded file with no bytes.
        at: ?u32,
        size: u32,
        pub fn name(f: *const File) []const u8 {
            return f.name_buf[0..f.name_len];
        }
    };

    const Open = struct {
        volume: u1,
        name_buf: [max_name]u8,
        name_len: u8,
        size: u32,
        written: u32,
        at: u32,
        reserved_bytes: u32,
        reserved_entries: u32,
    };

    volumes: [volume_count]Volume,
    usb_host: bool,
    usb_after_writes: ?u32,
    fail_write_at: ?u32,
    fail_status: abi.Status,
    fail_commit: ?abi.Status,
    files: [max_files]File,
    file_count: u32,
    open: ?Open,
    pool: [pool_size]u8,
    pool_used: u32,
    // Counters for the tests.
    creates: u32,
    writes: u32,
    commits: u32,
    aborts: u32,

    /// SYCLBADGE as the OS formats it (1280 KB, 32 root entries) and
    /// SYCLEXTRA (1792 KB, 128), both empty; no faults. Field by field: the
    /// struct is too big for a temporary.
    pub fn reset(f: *Fake) void {
        f.volumes[0] = .{};
        f.volumes[1] = .{ .total_bytes = 1792 * 1024, .free_bytes = 1792 * 1024, .free_root_entries = 128 };
        f.usb_host = false;
        f.usb_after_writes = null;
        f.fail_write_at = null;
        f.fail_status = .io_error;
        f.fail_commit = null;
        f.file_count = 0;
        f.open = null;
        f.pool_used = 0;
        f.creates = 0;
        f.writes = 0;
        f.commits = 0;
        f.aborts = 0;
    }

    fn eql_fold(a: []const u8, b: []const u8) bool {
        return std.ascii.eqlIgnoreCase(a, b);
    }

    pub fn find(f: *const Fake, volume: u1, name: []const u8) ?*const File {
        for (f.files[0..f.file_count]) |*file| {
            if (file.volume == volume and eql_fold(file.name(), name)) return file;
        }
        return null;
    }

    /// A committed file's bytes (null: absent, or preloaded without bytes).
    pub fn contents(f: *const Fake, volume: u1, name: []const u8) ?[]const u8 {
        const file = f.find(volume, name) orelse return null;
        const at = file.at orelse return null;
        return f.pool[at..][0..file.size];
    }

    fn add(f: *Fake, volume: u1, name: []const u8, at: ?u32, size: u32) void {
        if (f.file_count == max_files) @panic("fake drive: too many files");
        const file = &f.files[f.file_count];
        file.volume = volume;
        @memcpy(file.name_buf[0..name.len], name);
        file.name_len = @intCast(name.len);
        file.at = at;
        file.size = size;
        f.file_count += 1;
    }

    fn cluster_bytes(v: *const Volume, size: u32) u32 {
        return (size + v.cluster_size - 1) / v.cluster_size * v.cluster_size;
    }

    /// A file already on the drive (name and space only).
    pub fn preload(f: *Fake, volume: u1, name: []const u8, size: u32) void {
        const v = &f.volumes[volume];
        v.free_bytes -= cluster_bytes(v, size);
        v.free_root_entries -= root_entries(name.len);
        f.add(volume, name, null, size);
    }

    pub fn flags(f: *const Fake) abi.Flags {
        return .{ .usb_host = f.usb_host, .ext_volume = f.volumes[1].mounted };
    }

    pub fn stat(f: *const Fake, volume: u1) Error!Stat {
        const v = &f.volumes[volume];
        if (!v.mounted) return error.NoVolume;
        return .{ .free_bytes = v.free_bytes, .free_root_entries = v.free_root_entries, .cluster_size = v.cluster_size, .total_bytes = v.total_bytes, .flags = f.flags() };
    }

    pub fn create(f: *Fake, volume: u1, name: []const u8, size: u32) Error!void {
        const v = &f.volumes[volume];
        if (f.open != null) return error.BadRequest;
        if (!v.mounted) return error.NoVolume;
        if (f.usb_host) return error.UsbHost;
        if (!valid_name(name)) return error.BadName;
        if (f.find(volume, name) != null) return error.Exists;
        const bytes = cluster_bytes(v, size);
        const entries = root_entries(name.len);
        if (bytes > v.free_bytes) return error.NoSpace;
        if (entries > v.free_root_entries) return error.DirFull;
        if (f.pool_used + size > pool_size) @panic("fake drive: pool full");
        v.free_bytes -= bytes;
        v.free_root_entries -= entries;
        var o: Open = .{ .volume = volume, .name_buf = undefined, .name_len = @intCast(name.len), .size = size, .written = 0, .at = f.pool_used, .reserved_bytes = bytes, .reserved_entries = entries };
        @memcpy(o.name_buf[0..name.len], name);
        f.open = o;
        f.creates += 1;
    }

    pub fn write(f: *Fake, offset: u32, data: []const u8) Error!void {
        const o = if (f.open) |*o| o else return error.NotOpen;
        if (f.usb_host) return error.UsbHost;
        if (data.len == 0 or data.len > max_write or offset != o.written or data.len > o.size - o.written) return error.BadRequest;
        if (f.fail_write_at) |k| if (k == f.writes) {
            f.writes += 1;
            return status_error(f.fail_status);
        };
        @memcpy(f.pool[o.at + offset ..][0..data.len], data);
        o.written += @intCast(data.len);
        f.writes += 1;
        if (f.usb_after_writes) |k| if (f.writes >= k) {
            f.usb_host = true;
        };
    }

    pub fn commit(f: *Fake) Error!void {
        const o = f.open orelse return error.NotOpen;
        if (f.usb_host) return error.UsbHost;
        if (o.written != o.size) return error.BadRequest;
        if (f.fail_commit) |s| return status_error(s);
        f.add(o.volume, o.name_buf[0..o.name_len], o.at, o.size);
        f.pool_used += o.size;
        f.open = null;
        f.commits += 1;
    }

    pub fn abort(f: *Fake) void {
        const o = f.open orelse return;
        const v = &f.volumes[o.volume];
        v.free_bytes += o.reserved_bytes;
        v.free_root_entries += o.reserved_entries;
        f.open = null;
        f.aborts += 1;
    }
};

test "cart_files: names" {
    try std.testing.expect(valid_name("snouty-pong.uf2"));
    try std.testing.expect(!valid_name(""));
    try std.testing.expect(!valid_name(".hidden"));
    try std.testing.expect(!valid_name("a.uf2 "));
    try std.testing.expect(!valid_name("a?b.uf2"));
    const a64: [64]u8 = @splat('a');
    try std.testing.expect(!valid_name(&a64));
    var buf: [max_name]u8 = undefined;
    try std.testing.expectEqualStrings("a_b_c.uf2", sanitize(" a?b*c.uf2.", &buf));
    try std.testing.expectEqualStrings("cart.uf2", sanitize(" .. ", &buf));
    var long_in: [74]u8 = @splat('x');
    @memcpy(long_in[70..], ".uf2");
    const long = sanitize(&long_in, &buf);
    try std.testing.expectEqual(@as(usize, 63), long.len);
    try std.testing.expect(std.mem.endsWith(u8, long, ".uf2") and valid_name(long));
    var nb: [max_name]u8 = undefined;
    try std.testing.expectEqualStrings("snouty-pong-2.uf2", numbered("snouty-pong.uf2", 2, &nb));
    try std.testing.expectEqualStrings("README-10", numbered("README", 10, &nb));
    const ln = numbered(long, 12, &nb);
    try std.testing.expectEqual(@as(usize, 63), ln.len);
    try std.testing.expect(std.mem.endsWith(u8, ln, "-12.uf2") and valid_name(ln));
    try std.testing.expectEqual(@as(u32, 3), root_entries("snouty-pong.uf2".len));
    try std.testing.expectEqual(@as(u32, 2), root_entries(13));
}

test "cart_files: the fake drive's rules" {
    const f = try std.testing.allocator.create(Fake);
    defer std.testing.allocator.destroy(f);
    f.reset();
    const st = try f.stat(0);
    try std.testing.expect(st.fits(1000, 15));
    try std.testing.expect(!st.fits(1280 * 1024 + 1, 15));
    f.preload(0, "Pong.uf2", 1000);
    try std.testing.expectError(error.Exists, f.create(0, "pong.UF2", 10));
    try f.create(0, "b.uf2", 5000);
    try std.testing.expectError(error.BadRequest, f.create(0, "c.uf2", 1));
    try std.testing.expectError(error.BadRequest, f.write(4, "abcd"));
    const xs: [4096]u8 = @splat('x');
    try f.write(0, &xs);
    try std.testing.expectError(error.BadRequest, f.commit());
    try f.write(4096, xs[0..904]);
    try f.commit();
    try std.testing.expectEqual(@as(usize, 5000), f.contents(0, "B.UF2").?.len);
    try std.testing.expectEqual(@as(u32, 1280 * 1024 - 1024 - 5120), (try f.stat(0)).free_bytes);
    // Abort gives the reservation back and leaves no file.
    try f.create(1, "c.uf2", 100);
    f.abort();
    try std.testing.expect(f.find(1, "c.uf2") == null);
    try std.testing.expectEqual(@as(u32, 1792 * 1024), (try f.stat(1)).free_bytes);
    try std.testing.expectError(error.NotOpen, f.commit());
    // USB host.
    f.usb_host = true;
    try std.testing.expectError(error.UsbHost, f.create(0, "d.uf2", 1));
    try std.testing.expect((try f.stat(0)).flags.usb_host);
    // Root entries run out before bytes do.
    f.usb_host = false;
    f.volumes[0].free_root_entries = 2;
    try std.testing.expectError(error.DirFull, f.create(0, "a-long-name-here.uf2", 1));
    f.volumes[1].mounted = false;
    try std.testing.expectError(error.NoVolume, f.stat(1));
}
