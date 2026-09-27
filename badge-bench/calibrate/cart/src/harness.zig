//! Timing wrapper, per-kernel statistics, checksum and trace lines
//! (PLAN.md "Contract: trace lines").
const std = @import("std");
const cart = @import("cart-api");
const kernels = @import("kernels.zig");

/// badge-bench pokes this to 1 before start() (carts/badge-calibrate.toml)
/// so the emulator skips the 1.2 M-cycle wait for the LCD DMA. Hardware
/// never sets it. Read only through `skip_wait_set()`.
pub var skip_wait: u8 = 0;

pub fn skip_wait_set() bool {
    return @as(*volatile u8, &skip_wait).* != 0;
}

/// Core cycle counter (DWT_CYCCNT through the SDK's wrap-extending reader).
pub inline fn now() i64 {
    return cart.platform.cycles();
}

/// Cycles around one run of kernel `k` (all N iterations), raw: counter
/// read overhead included, nothing subtracted (K0 is the baseline).
/// noinline so the busy and idle runs execute the same timing code.
pub noinline fn time(k: *const kernels.Kernel) u32 {
    const t0 = now();
    k.run();
    const t1 = now();
    return @truncate(@as(u64, @bitCast(t1 - t0)));
}

/// Values kept per kernel: 5 passes x 2 idle runs, 5 passes x 1 busy run.
/// Beyond the cap the oldest value is overwritten (a ring); main.zig stops
/// after 5 passes, so it never happens.
pub const idle_cap = 10;
pub const busy_cap = 5;

pub const Series = struct {
    fn Of(comptime cap: usize) type {
        return struct {
            v: [cap]u32 = @splat(0),
            len: u32 = 0,
            next: u32 = 0,

            const Self = @This();

            pub fn add(s: *Self, x: u32) void {
                s.v[s.next] = x;
                s.next = (s.next + 1) % cap;
                if (s.len < cap) s.len += 1;
            }
            pub fn min(s: *const Self) u32 {
                var m: u32 = std.math.maxInt(u32);
                for (s.v[0..s.len]) |x| m = @min(m, x);
                return if (s.len == 0) 0 else m;
            }
            /// Lower median (element (len-1)/2 of the sorted values).
            pub fn median(s: *const Self) u32 {
                if (s.len == 0) return 0;
                var t: [cap]u32 = s.v;
                const w = t[0..s.len];
                std.mem.sort(u32, w, {}, std.sort.asc(u32));
                return w[(s.len - 1) / 2];
            }
        };
    }
};

pub const Stats = struct {
    idle: Series.Of(idle_cap) = .{},
    busy: Series.Of(busy_cap) = .{},
    /// Busy runs that ended after 4.5 ms from the frame start (outside the
    /// DMA window). Shown on the summary page.
    late: u32 = 0,
};

pub var stats: [kernels.count]Stats = @splat(.{});

pub fn reset() void {
    stats = @splat(.{});
}

/// The eight numbers of a `CAL k=` line, in line order.
pub const Row = struct {
    k: u32,
    n: u32,
    ops: u32,
    idle_min: u32,
    idle_med: u32,
    busy_min: u32,
    busy_med: u32,
    sink: u32,
};

pub fn row(id: usize) Row {
    const k = &kernels.list[id];
    const s = &stats[id];
    return .{
        .k = @intCast(id),
        .n = k.n,
        .ops = k.n * k.ops_per_iter,
        .idle_min = s.idle.min(),
        .idle_med = s.idle.median(),
        .busy_min = s.busy.min(),
        .busy_med = s.busy.median(),
        .sink = @as(*volatile u32, &kernels.sinks[id]).*,
    };
}

/// FNV-1a-32 over the eight numbers of every kernel in id order, each
/// number as 4 little-endian bytes.
pub fn checksum_of(rows: *const [kernels.count]Row) u32 {
    var h: u32 = 0x811c9dc5;
    for (rows) |r| {
        const nums = [8]u32{ r.k, r.n, r.ops, r.idle_min, r.idle_med, r.busy_min, r.busy_med, r.sink };
        for (nums) |x| {
            var b = x;
            for (0..4) |_| {
                h ^= b & 0xff;
                h *%= 0x01000193;
                b >>= 8;
            }
        }
    }
    return h;
}

/// Checksum of the live statistics (summary page).
pub fn checksum() u32 {
    var rows: [kernels.count]Row = undefined;
    for (&rows, 0..) |*r, id| r.* = row(id);
    return checksum_of(&rows);
}

pub fn format_row(buf: *[120]u8, r: Row) []const u8 {
    return std.fmt.bufPrint(buf, "CAL k={d} n={d} ops={d} idle_min={d} idle_med={d} busy_min={d} busy_med={d} sink={x:0>8}", .{
        r.k, r.n, r.ops, r.idle_min, r.idle_med, r.busy_min, r.busy_med, r.sink,
    }) catch buf[0..0];
}

pub fn format_done(buf: *[120]u8, pass: u32, sum: u32) []const u8 {
    return std.fmt.bufPrint(buf, "CAL done pass={d} sum={x:0>8}", .{ pass, sum }) catch buf[0..0];
}

// ---------------------------------------------------------------------------
// Pending trace lines.
//
// cart.trace() copies into the one shared IPC trace buffer and only waits
// for FIFO space, not for core 0 to have printed the previous line, so
// back-to-back traces overwrite each other on hardware. A completed pass is
// therefore snapshotted here and main.zig sends one line per frame: rows
// 0..19 in the 20 frames after the pass (before that frame's kernel runs),
// and the done line in the same frame as row 19 but after the kernel runs
// (8+ ms later). The queue is empty again when the next pass completes.

pub const lines_per_pass = kernels.count + 1;

pub var pending_rows: [kernels.count]Row = undefined;
pub var pending_sum: u32 = 0;
pub var pending_pass: u32 = 0;
/// Next line to send: 0..19 rows, 20 the done line, 21 nothing pending.
pub var emit_next: u32 = lines_per_pass;

/// Freeze the statistics of the pass that just completed.
pub fn snapshot(pass: u32) void {
    for (&pending_rows, 0..) |*r, id| r.* = row(id);
    pending_sum = checksum_of(&pending_rows);
    pending_pass = pass;
    emit_next = 0;
}

pub fn clear_pending() void {
    emit_next = lines_per_pass;
}
