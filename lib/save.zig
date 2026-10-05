//! Cart saves: small named blobs (battery RAM, progress, high scores) kept
//! by the badge OS in internal flash, across cart switches, power-off and
//! OS updates. Needs the patched SYCL OS (sycl-badge branch `cart-saves`,
//! its SAVES_PLAN.md is the ABI v1 spec); on stock firmware `supported()`
//! is false and every call returns `error.Unsupported`, so a cart must hide
//! its Save entries then. docs/SAVES.md is the user guide.
//!
//! The pinned SDK (a6ce19f) has no save API, so this speaks ABI v1 itself:
//!
//! - One mailbox message, CART_SAVE_REQ 0x2C: the cart fills a 64-byte
//!   `Request` in its own RAM (4-aligned), sets `state = pending`, `dmb`,
//!   and writes `(0x2C << 24) | ((addr - 0x20000000) >> 2)` to the SIO FIFO
//!   (FIFO_WR 0xD0000054 once FIFO_ST 0xD0000050 bit 1 RDY is set, then
//!   `sev`), the way the pinned runtime sends its words
//!   (platform_cart_ram.zig; lib/stream_audio.zig's CART_START_AUDIO).
//! - The OS answers through the struct only, never through the FIFO: it
//!   sets `state = busy`, works, writes `status` and `result`, `dmb`, then
//!   `state = done`. The cart spins on `state` with `dmb`.
//! - Stock firmware ignores 0x2C (kernel.zig `handle_cart_message` drops
//!   unknown types), so the probe gives up after 250 ms with the state
//!   still `pending` and saves count as unsupported for the rest of the
//!   boot. A probe that reached `busy` keeps waiting.
//!
//! The no-flash-reads rule. While the OS erases or programs it switches
//! XIP off, so during a `write` or `delete` the cart must not touch any
//! 0x10xxxxxx address: no drive ROM reads (lib/romfs.zig pointers), no
//! code or data in flash, no interrupt handler that could run from flash.
//! The waits here run from RAM (a RAM cart's code is all in RAM), read
//! only the request, the TIMER0 and SIO registers, and mask core 1's
//! interrupts (PRIMASK) for write and delete. The cart is parked inside
//! `write()` until the OS is done, so an emulator that reads its ROM from
//! the drive by pointer is safe as long as it does not do so from another
//! context (an interrupt) during the call. XIP carts cannot use saves at
//! all: the saves OS refuses XIP UF2s.
//!
//! Cost: `write` and `delete` block. Modelled (badge-bench) and expected
//! (SAVES_PLAN.md, datasheet typical) cost is (ceil(len / 4096) + 1) x
//! 55 ms: each 4 KB data block plus one directory block; a 1 KB save is
//! ~0.1 s, 32 KB ~0.5 s, 64 KB ~0.9 s. A write whose bytes equal the
//! stored blob returns at once and costs no flash. The OS rate limits
//! commits (8 burst, 1 per 10 s: `error.RateLimited`); save on events
//! (menu open, exit request, idle after the game's own save), never per
//! frame. `read`, `stat` and `list` only read and return quickly.
//!
//! Backends, chosen from the target at build time (`backend`): `badge` on
//! the cart core (thumb freestanding), `none` for wasm (the simulator has
//! no saves: `supported()` is false), `fake` for host builds and tests: an
//! in-memory store with the OS's semantics (copy-on-write block
//! accounting, limits, unchanged-write no-op, rate limit on a virtual
//! clock) and hooks in `fake` to drive it.
//!
//! Keys: 1..32 printable ASCII bytes (0x20..0x7E); by convention
//! `<cart>/<slot>`, e.g. `boy/<title>/<checksum>` or `paperclips/game`.
//! Blobs: 1..64 KB. At most 63 keys, 248 KB of 4 KB blocks in all.
const builtin = @import("builtin");
const std = @import("std");

pub const Error = error{ Unsupported, NotFound, NoSpace, BadRequest, BadBuffer, RateLimited, TooBig, IoError, Busy };

pub const max_key = 32;
pub const max_blob = 64 * 1024;

/// What `stat()` returns (ABI v1 `SaveStat`): `region_bytes` is the whole
/// save region (64 x 4 KB), `free_bytes` the bytes of free data blocks
/// (what a new blob may use), `writes_left_now` the rate limiter's tokens.
pub const Stat = extern struct { version: u32, region_bytes: u32, free_bytes: u32, max_blob: u32, entries: u32, max_entries: u32, writes_left_now: u32, _r: u32 = 0 };

/// One row of `list()` (ABI v1 `SaveListEntry`, 40 bytes).
pub const ListEntry = extern struct {
    key_len: u32,
    key: [max_key]u8,
    size: u32,

    pub fn name(e: *const ListEntry) []const u8 {
        return e.key[0..@min(e.key_len, max_key)];
    }
};

pub const Backend = enum { badge, fake, none };

/// The Cortex-M33 cart core (RAM and XIP builds); false for wasm and hosts.
const is_badge = builtin.os.tag == .freestanding and (builtin.cpu.arch.isThumb() or builtin.cpu.arch.isArm());

pub const backend: Backend = if (is_badge) .badge else if (builtin.cpu.arch.isWasm()) .none else .fake;

// ---- ABI v1 (SAVES_PLAN.md "ABI v1", frozen) ----

pub const abi = struct {
    pub const msg_type: u32 = 0x2C;
    pub const magic: u32 = 0x31564153; // "SAV1"
    pub const version: u32 = 1;
    pub const Op = enum(u32) { probe = 1, read = 2, write = 3, delete = 4, stat = 5, list = 6, exit_watch = 7, _ };
    pub const State = enum(u32) { idle = 0, pending = 1, busy = 2, done = 3, _ };
    pub const Status = enum(u32) { ok = 0, not_found = 1, no_space = 2, bad_request = 3, bad_buffer = 4, rate_limited = 5, too_big = 6, io_error = 7, busy = 8, _ };
    pub const Request = extern struct {
        magic: u32 = magic,
        op: Op,
        state: State,
        status: Status,
        key_len: u32,
        key: [max_key]u8,
        buf: u32,
        len: u32,
        result: u32,
    };
    /// The OS writes this to the exit word when "Exit cart" is chosen; the
    /// cart answers `exit_ready` once it has saved.
    pub const exit_requested: u32 = 1;
    pub const exit_ready: u32 = 2;
    /// The FIFO word for a request at `addr` (cart RAM).
    pub fn word(addr: u32) u32 {
        return (msg_type << 24) | ((addr - 0x20000000) >> 2);
    }

    comptime {
        if (@sizeOf(Request) != 64) @compileError("SaveRequest must be 64 bytes");
        if (@sizeOf(Stat) != 32) @compileError("SaveStat must be 32 bytes");
        if (@sizeOf(ListEntry) != 40) @compileError("SaveListEntry must be 40 bytes");
    }
};

/// Map a status the OS wrote to the result of a call.
pub fn statusError(s: abi.Status) Error!void {
    return switch (s) {
        .ok => {},
        .not_found => error.NotFound,
        .no_space => error.NoSpace,
        .bad_request => error.BadRequest,
        .bad_buffer => error.BadBuffer,
        .rate_limited => error.RateLimited,
        .too_big => error.TooBig,
        .io_error => error.IoError,
        .busy => error.Busy,
        _ => error.IoError,
    };
}

/// A key the OS accepts: 1..32 bytes, each 0x20..0x7E.
pub fn validKey(key: []const u8) bool {
    if (key.len == 0 or key.len > max_key) return false;
    for (key) |c| if (c < 0x20 or c > 0x7E) return false;
    return true;
}

// ---- Public API ----

/// Whether this OS stores saves. On the badge the first call probes (at
/// most 250 ms on stock firmware) and the answer is cached for the boot.
pub fn supported() bool {
    return switch (backend) {
        .badge => badge.supported(),
        .fake => fake.supported_flag,
        .none => false,
    };
}

/// Copy up to `dst.len` bytes of `key` into `dst`. Returns the stored size,
/// which may exceed `dst.len` (only `min(size, dst.len)` bytes are copied).
/// `error.NotFound` if there is no such key; `error.IoError` for a blob
/// whose CRC no longer matches (it stays, so the cart can rewrite it).
pub fn read(key: []const u8, dst: []u8) Error!usize {
    try check_key(key);
    return switch (backend) {
        .badge => badge.read(key, dst),
        .fake => fake.read(key, dst),
        .none => unreachable,
    };
}

/// Store `src` as `key`, atomically (power loss leaves the old blob or the
/// new one). Blocks: parks the cart for ~55 ms per 4 KB plus one directory
/// block, with interrupts masked and no flash reads allowed (see the top
/// of this file). `src` must be in cart RAM (`error.BadBuffer` otherwise:
/// copy drive or flash data to RAM first). 1..`max_blob` bytes.
pub fn write(key: []const u8, src: []const u8) Error!void {
    try check_key(key);
    if (src.len == 0) return error.BadRequest;
    if (src.len > max_blob) return error.TooBig;
    return switch (backend) {
        .badge => badge.write(key, src),
        .fake => fake.write(key, src),
        .none => unreachable,
    };
}

/// Remove `key` (`error.NotFound` if absent). Blocks for one directory
/// write (~55 ms), like `write`.
pub fn delete(key: []const u8) Error!void {
    try check_key(key);
    return switch (backend) {
        .badge => badge.delete(key),
        .fake => fake.delete(key),
        .none => unreachable,
    };
}

pub fn stat() Error!Stat {
    if (!supported()) return error.Unsupported;
    return switch (backend) {
        .badge => badge.stat(),
        .fake => fake.stat(),
        .none => unreachable,
    };
}

/// Fill `out` with up to `out.len` stored keys (directory order). Returns
/// the number of keys stored, which may exceed `out.len`. (Additive to the
/// frozen interface; ABI v1 op `list`.)
pub fn list(out: []ListEntry) Error!usize {
    if (!supported()) return error.Unsupported;
    return switch (backend) {
        .badge => badge.list(out),
        .fake => fake.list(out),
        .none => unreachable,
    };
}

/// Ask the OS to warn this cart before its settings "Exit cart" stops it:
/// it then writes 1 to an exit word in cart RAM (`exitRequested()`), shows
/// "Saving..." and keeps serving requests until `exitReady()` or 3 s.
/// Check `exitRequested()` once a frame. The OS forgets the word when the
/// cart stops.
pub fn watchExit() Error!void {
    if (!supported()) return error.Unsupported;
    return switch (backend) {
        .badge => badge.watchExit(),
        .fake => fake.watch_exit(),
        .none => unreachable,
    };
}

/// True once the OS has asked this cart to exit (after `watchExit`).
pub fn exitRequested() bool {
    return switch (backend) {
        .badge => badge.exit_word_value() != 0,
        .fake => fake.exit_word != 0,
        .none => false,
    };
}

/// Tell the OS this cart has saved and may be stopped now (writes 2).
pub fn exitReady() void {
    switch (backend) {
        .badge => badge.exit_ready(),
        .fake => {
            if (fake.exit_word != 0) fake.exit_word = abi.exit_ready;
        },
        .none => {},
    }
}

fn check_key(key: []const u8) Error!void {
    if (!supported()) return error.Unsupported;
    if (!validKey(key)) return error.BadRequest;
}

// ---- Badge backend: the raw ABI over the SIO FIFO ----

const badge = struct {
    const sio_fifo_st: usize = 0xD0000050;
    const sio_fifo_wr: usize = 0xD0000054;
    const fifo_rdy: u32 = 1 << 1;
    const timer0_timehr: usize = 0x400b0008;
    const timer0_timelr: usize = 0x400b000c;

    /// Probe: give up after this long with the request still pending.
    const probe_timeout_us: u64 = 250_000;
    /// Any later request: the OS answered the probe, so a request still
    /// pending after this long was lost (the cart gets `error.Busy`). Once
    /// the OS has set `busy` the wait has no limit: it always finishes.
    const op_timeout_us: u64 = 2_000_000;

    var req: abi.Request align(4) = undefined;
    var exit_word: u32 align(4) = 0;
    var stat_buf: Stat align(4) = undefined;
    var probe_state: enum(u8) { unknown, yes, no } = .unknown;

    fn supported() bool {
        switch (probe_state) {
            .yes => return true,
            .no => return false,
            .unknown => {
                const ok = if (submit(.probe, "", 0, 0, false, probe_timeout_us)) |v| v >= 1 else |_| false;
                probe_state = if (ok) .yes else .no;
                return ok;
            },
        }
    }

    fn read(key: []const u8, dst: []u8) Error!usize {
        const r = try submit_key(.read, key, dst.ptr, dst.len, false);
        return r;
    }

    fn write(key: []const u8, src: []const u8) Error!void {
        _ = try submit_key(.write, key, src.ptr, src.len, true);
    }

    fn delete(key: []const u8) Error!void {
        _ = try submit_key(.delete, key, undefined, 0, true);
    }

    fn stat() Error!Stat {
        _ = try submit(.stat, "", @intFromPtr(&stat_buf), @sizeOf(Stat), false, op_timeout_us);
        const p: *volatile Stat = &stat_buf;
        return p.*;
    }

    fn list(out: []ListEntry) Error!usize {
        const addr = if (out.len == 0) @intFromPtr(&req) else @intFromPtr(out.ptr);
        return submit(.list, "", addr, out.len * @sizeOf(ListEntry), false, op_timeout_us);
    }

    fn watchExit() Error!void {
        const w: *volatile u32 = &exit_word;
        w.* = 0;
        _ = try submit(.exit_watch, "", @intFromPtr(&exit_word), 0, false, op_timeout_us);
    }

    fn exit_word_value() u32 {
        const w: *volatile u32 = &exit_word;
        return w.*;
    }

    fn exit_ready() void {
        const w: *volatile u32 = &exit_word;
        if (w.* == 0) return;
        w.* = abi.exit_ready;
        dmb();
    }

    fn submit_key(op: abi.Op, key: []const u8, ptr: [*]const u8, len: usize, mask: bool) Error!u32 {
        // A zero-length buffer still needs an address in cart RAM.
        const addr: usize = if (len == 0) @intFromPtr(&req) else @intFromPtr(ptr);
        return submit_masked(op, key, addr, len, mask, op_timeout_us);
    }

    fn submit(op: abi.Op, key: []const u8, addr: usize, len: usize, mask: bool, timeout_us: u64) Error!u32 {
        return submit_masked(op, key, addr, len, mask, timeout_us);
    }

    /// Fill the request, send it, wait for `done`. Runs from RAM and
    /// touches only the request, TIMER0 and the SIO FIFO.
    noinline fn submit_masked(op: abi.Op, key: []const u8, addr: usize, len: usize, mask: bool, timeout_us: u64) Error!u32 {
        const r: *volatile abi.Request = &req;
        r.magic = abi.magic;
        r.op = op;
        r.status = .ok;
        r.key_len = @intCast(key.len);
        for (0..max_key) |i| r.key[i] = if (i < key.len) key[i] else 0;
        r.buf = @truncate(addr);
        r.len = @truncate(len);
        r.result = 0;
        r.state = .pending;
        dmb();

        const primask = if (mask) irq_disable() else 0;
        defer if (mask) irq_restore(primask);

        var t0 = micros();
        if (!fifo_send(abi.word(@truncate(@intFromPtr(&req))), t0, timeout_us)) {
            r.state = .idle;
            return if (op == .probe) error.Unsupported else error.Busy;
        }
        var last: abi.State = .pending;
        while (true) {
            dmb();
            const s = r.state;
            if (s == .done) break;
            if (s != last) {
                last = s;
                t0 = micros();
            } else if (s == .pending and micros() -% t0 >= timeout_us) {
                // Never picked up: stock firmware (probe) or a lost word.
                // Spoil the magic so a late pickup touches nothing.
                r.magic = 0;
                r.state = .idle;
                dmb();
                return if (op == .probe) error.Unsupported else error.Busy;
            }
        }
        dmb();
        try statusError(r.status);
        return r.result;
    }

    /// The pinned runtime's send (platform_cart_ram.zig), with a timeout.
    inline fn fifo_send(w: u32, t0: u64, timeout_us: u64) bool {
        const st: *volatile u32 = @ptrFromInt(sio_fifo_st);
        const wr: *volatile u32 = @ptrFromInt(sio_fifo_wr);
        while (st.* & fifo_rdy == 0) {
            if (micros() -% t0 >= timeout_us) return false;
        }
        wr.* = w;
        asm volatile ("sev");
        return true;
    }

    /// platform_cart_ram.zig `micros_since_boot`: TIMELR first (it latches HR).
    inline fn micros() u64 {
        const hr_reg: *volatile u32 = @ptrFromInt(timer0_timehr);
        const lr_reg: *volatile u32 = @ptrFromInt(timer0_timelr);
        const lr = lr_reg.*;
        const hr = hr_reg.*;
        return (@as(u64, hr) << 32) | lr;
    }

    inline fn dmb() void {
        asm volatile ("dmb" ::: .{ .memory = true });
    }

    inline fn irq_disable() u32 {
        return asm volatile (
            \\mrs %[p], primask
            \\cpsid i
            : [p] "=r" (-> u32),
            :
            : .{ .memory = true });
    }

    inline fn irq_restore(p: u32) void {
        asm volatile ("msr primask, %[p]"
            :
            : [p] "r" (p),
            : .{ .memory = true });
    }
};

// ---- Host fake: the OS store's semantics in memory ----

/// The host backend and its test hooks. Semantics follow SAVES_PLAN.md
/// (and badge-bench's store): 62 data blocks of 4 KB, at most 63 keys, a
/// write needs ceil(len/4096) free blocks while the old copy still exists,
/// an unchanged write is a no-op that costs no token, commits (writes and
/// deletes that touch flash) take a token from a bucket of 8 refilled one
/// per 10 s of `advanceMs` time. State is global: call `reset()` at the
/// start of each test.
pub const fake = struct {
    pub const block_size = 4096;
    pub const region_blocks = 64;
    pub const data_blocks = 62;
    pub const max_entries = 63;
    pub const max_blocks_per_blob = max_blob / block_size;
    pub const burst = 8;
    pub const refill_ms = 10_000;
    /// Modelled flash time of one 4 KB block (erase + program).
    pub const block_ms = 55;

    const Entry = struct {
        used: bool = false,
        key_len: u8 = 0,
        key: [max_key]u8 = undefined,
        size: u32 = 0,
        nblocks: u8 = 0,
        blocks: [max_blocks_per_blob]u8 = undefined,

        fn name(e: *const Entry) []const u8 {
            return e.key[0..e.key_len];
        }
    };

    var entries: [max_entries]Entry = @splat(.{});
    var pool: [data_blocks][block_size]u8 = undefined;
    var next_fit: u8 = 0;
    var supported_flag: bool = true;
    var exit_word: u32 = 0;
    var exit_watched: bool = false;
    var rate_limit_on: bool = true;
    var tokens: u32 = burst;
    var now_ms: u64 = 0;
    var refill_from_ms: u64 = 0;
    var commit_count: u32 = 0;
    var flash_ms_total: u64 = 0;
    var fail_next: ?Error = null;

    /// Empty store, saves supported, full rate bucket, clock 0, no exit
    /// word, counters 0, no injected failure.
    pub fn reset() void {
        entries = @splat(.{});
        next_fit = 0;
        supported_flag = true;
        rate_limit_on = true;
        fail_next = null;
        commit_count = 0;
        flash_ms_total = 0;
        now_ms = 0;
        reboot();
    }

    /// A power cycle: blobs stay, the exit word and the rate bucket reset.
    pub fn reboot() void {
        exit_word = 0;
        exit_watched = false;
        tokens = burst;
        refill_from_ms = now_ms;
    }

    /// false behaves like stock firmware: every call `error.Unsupported`.
    pub fn setSupported(on: bool) void {
        supported_flag = on;
    }

    /// What the OS does on "Exit cart": write 1 to the watched exit word.
    /// No effect unless the cart called `watchExit()`.
    pub fn setExitRequested() void {
        if (exit_watched) exit_word = abi.exit_requested;
    }

    /// The exit word: 0, 1 (requested) or 2 (the cart called exitReady).
    pub fn exitWord() u32 {
        return exit_word;
    }

    pub fn exitWatched() bool {
        return exit_watched;
    }

    /// Advance the virtual clock the rate limiter refills on.
    pub fn advanceMs(ms: u64) void {
        now_ms += ms;
    }

    /// Turn the rate limiter off (true by default after `reset`).
    pub fn setRateLimit(on: bool) void {
        rate_limit_on = on;
    }

    /// The next store call (read/write/delete/stat/list) fails with `e`
    /// before doing anything (e.g. `error.IoError`, `error.Busy`).
    pub fn failNext(e: ?Error) void {
        fail_next = e;
    }

    /// Commits so far (writes and deletes that would touch flash).
    pub fn commits() u32 {
        return commit_count;
    }

    /// Modelled flash time of those commits, ms: (ceil(len/4096) + 1) x 55
    /// per write, 55 per delete.
    pub fn flashMs() u64 {
        return flash_ms_total;
    }

    /// Copy the first `out.len` stored bytes of `key` into `out` and
    /// return that part of `out`, or null if absent. Bypasses failNext.
    pub fn peek(key: []const u8, out: []u8) ?[]u8 {
        const e = find(key) orelse return null;
        const n = @min(out.len, e.size);
        copy_out(e, out[0..n]);
        return out[0..n];
    }

    // -- the store --

    fn take_fail() Error!void {
        if (fail_next) |e| {
            fail_next = null;
            return e;
        }
    }

    fn find(key: []const u8) ?*Entry {
        for (&entries) |*e| {
            if (e.used and std.mem.eql(u8, e.name(), key)) return e;
        }
        return null;
    }

    fn block_used(b: u8) bool {
        for (&entries) |*e| {
            if (!e.used) continue;
            for (e.blocks[0..e.nblocks]) |x| if (x == b) return true;
        }
        return false;
    }

    fn free_blocks() u32 {
        var n: u32 = 0;
        for (0..data_blocks) |b| {
            if (!block_used(@intCast(b))) n += 1;
        }
        return n;
    }

    fn used_entries() u32 {
        var n: u32 = 0;
        for (&entries) |*e| {
            if (e.used) n += 1;
        }
        return n;
    }

    fn copy_out(e: *const Entry, dst: []u8) void {
        var off: usize = 0;
        for (e.blocks[0..e.nblocks]) |b| {
            if (off >= dst.len) break;
            const n = @min(block_size, dst.len - off);
            @memcpy(dst[off..][0..n], pool[b][0..n]);
            off += n;
        }
    }

    fn same(e: *const Entry, src: []const u8) bool {
        if (e.size != src.len) return false;
        var off: usize = 0;
        for (e.blocks[0..e.nblocks]) |b| {
            const n = @min(block_size, src.len - off);
            if (!std.mem.eql(u8, pool[b][0..n], src[off..][0..n])) return false;
            off += n;
        }
        return true;
    }

    fn refill() void {
        if (tokens >= burst) {
            refill_from_ms = now_ms;
            return;
        }
        const add = (now_ms - refill_from_ms) / refill_ms;
        if (add == 0) return;
        tokens = @intCast(@min(burst, tokens + add));
        refill_from_ms = if (tokens >= burst) now_ms else refill_from_ms + add * refill_ms;
    }

    fn take_token() Error!void {
        if (!rate_limit_on) return;
        refill();
        if (tokens == 0) return error.RateLimited;
        tokens -= 1;
    }

    fn read(key: []const u8, dst: []u8) Error!usize {
        try take_fail();
        const e = find(key) orelse return error.NotFound;
        copy_out(e, dst[0..@min(dst.len, e.size)]);
        return e.size;
    }

    fn write(key: []const u8, src: []const u8) Error!void {
        try take_fail();
        const old = find(key);
        if (old) |e| if (same(e, src)) return;
        const need: u32 = @intCast((src.len + block_size - 1) / block_size);
        if (old == null and used_entries() >= max_entries) return error.NoSpace;
        if (free_blocks() < need) return error.NoSpace;
        try take_token();
        var nb: [max_blocks_per_blob]u8 = undefined;
        var got: u32 = 0;
        var probe: u32 = 0;
        while (got < need) : (probe += 1) {
            const b: u8 = @intCast((next_fit + probe) % data_blocks);
            if (block_used(b)) continue;
            nb[got] = b;
            got += 1;
        }
        next_fit = @intCast((@as(u32, nb[need - 1]) + 1) % data_blocks);
        for (nb[0..need], 0..) |b, i| {
            const off = i * block_size;
            const n = @min(block_size, src.len - off);
            @memcpy(pool[b][0..n], src[off..][0..n]);
        }
        const e = old orelse for (&entries) |*x| {
            if (!x.used) break x;
        } else unreachable;
        e.* = .{ .used = true, .key_len = @intCast(key.len), .size = @intCast(src.len), .nblocks = @intCast(need) };
        @memcpy(e.key[0..key.len], key);
        @memcpy(e.blocks[0..need], nb[0..need]);
        commit_count += 1;
        flash_ms_total += (need + 1) * block_ms;
    }

    fn delete(key: []const u8) Error!void {
        try take_fail();
        const e = find(key) orelse return error.NotFound;
        try take_token();
        e.* = .{};
        commit_count += 1;
        flash_ms_total += block_ms;
    }

    fn stat() Error!Stat {
        try take_fail();
        if (rate_limit_on) refill();
        return .{
            .version = abi.version,
            .region_bytes = region_blocks * block_size,
            .free_bytes = free_blocks() * block_size,
            .max_blob = max_blob,
            .entries = used_entries(),
            .max_entries = max_entries,
            .writes_left_now = if (rate_limit_on) tokens else burst,
        };
    }

    fn list(out: []ListEntry) Error!usize {
        try take_fail();
        var n: usize = 0;
        for (&entries) |*e| {
            if (!e.used) continue;
            if (n < out.len) {
                out[n] = .{ .key_len = e.key_len, .key = @splat(0), .size = e.size };
                @memcpy(out[n].key[0..e.key_len], e.name());
            }
            n += 1;
        }
        return n;
    }

    fn watch_exit() Error!void {
        exit_watched = true;
        exit_word = 0;
    }
};
