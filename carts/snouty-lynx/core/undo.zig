//! The time scrubber's store (SPEC.md section 10, PLAN.md "M3 Scrub:
//! contract", "Frozen for M3"): copy-on-first-write undo records, one per
//! `frames_per_record` badge frames, in one ring of 68-byte slots in an
//! arena the frontend hands over. Snouty Genesis's design
//! (carts/snouty-genesis/core/undo.zig) with two regions: the 64 KB of RAM
//! (the display and collision buffers are ordinary RAM) and the console's
//! small state (`Lynx.Small`). One tracker for one console: the state is
//! file-level so the bus write path and Suzy reach the dirty bytes without
//! a `Lynx` offset. No cart-api, no allocator, no floats. docs/SCRUB.md
//! has the design and the sizing.
//!
//! A record is a run of consecutive slots (modular in the ring): first the
//! small state (`small_slots` slots, ids `0xF000 + chunk`), then one slot
//! per 64-byte RAM block first written in the record's interval (id =
//! block, region `ram` = 0) holding the block as it was at the record's
//! opening boundary. Applying a record swaps every slot with the console's
//! bytes: the console goes back to the boundary and the record now holds
//! the newer contents, so applying it again goes forward. Left and Right
//! are the same operation, bit-exact, with no replay.
//!
//! Ages: 0 is the open record (from the newest boundary to live), 1 the
//! newest closed one, ... `cursor` counts the records applied (0 = live).
//! Left from live while the open record is empty (live exactly on a
//! boundary) applies it and the newest closed record in one step, so every
//! step moves the picture; Right mirrors it.
//!
//! Frontend protocol:
//!   init(arena) once; reset(l) after the console is (re)made
//!   (`Lynx.init_in_place`/`reset` zero RAM and run the boot past the
//!   hooks, so the history must be forgotten then); record_frame(l) after
//!   every `step_frame`; step(l, dir) while scrubbing (it ends with
//!   `l.refresh_display()` for the picture); and **`resume_here(l)` before
//!   the first `step_frame` after a scrub** when `parked()`: it drops the
//!   applied records (they hold the future) and opens a fresh record from
//!   the parked state. `record_frame` while parked (the frontend forgot
//!   `resume_here`) forgets the history (`reset`): consistent, never
//!   corrupt.
//!
//! Dirty bytes: one per block, nonzero = the block is already saved into
//! the open record (or nothing is being recorded), so a write needs no
//! copy; zero = the first write copies it (`save`, out of line). While
//! tracking is off (before `reset`, after `disable`), parked, or while the
//! history is lost, the bytes are all 1. The `.bss` state (all 0) before
//! anything ran costs one `save` call per block that sees `console ==
//! null` and sets the byte, so untracked host tests pay only the byte test
//! after the first write per block.
//!
//! The hooks do not know which console writes: a second, untracked console
//! stepped while another is tracked only makes the tracked one save blocks
//! it did not write, which is harmless (a block not yet saved still holds
//! its boundary contents).
const std = @import("std");
const lynx_mod = @import("lynx.zig");
const Lynx = lynx_mod.Lynx;

pub const block_size = 64;
pub const Slot = extern struct { id: u16, pad: u16 = 0, data: [block_size]u8 };
/// 60 badge frames (1 s) per record, not SPEC.md 10's 30: the Lynx games
/// redraw their 8 KB screen buffers every frame, so a record holds the same
/// blocks whatever its length, and 60 doubles the history per byte
/// (docs/SCRUB.md sizing; M3 integration decision, Adrian may change it).
pub const default_frames_per_record = 60;
/// A variable (read once per frame) so the unit tests can keep SPEC 10's
/// 30-frame arithmetic; the cart never changes it.
pub var frames_per_record: u32 = default_frames_per_record;
pub const max_records = 64;
pub const Region = enum(u4) { ram = 0, small = 15 };

comptime {
    if (@sizeOf(Slot) != 68 or @offsetOf(Slot, "data") != 4) @compileError("undo.Slot must be 68 bytes, data at 4");
}

/// Slots of `Lynx.Small` at the head of every record.
pub const small_slots = (@sizeOf(Lynx.Small) + block_size - 1) / block_size;
const small_id: u16 = @as(u16, @backingInt(Region.small)) << 12;

pub const ram_blocks = 0x10000 / block_size;

/// One byte per RAM block: see the header (nonzero = no copy needed).
var dirty: [ram_blocks]u8 = @splat(0);

/// The tracked console, null while tracking is off.
var console: ?*Lynx = null;
var slots: []Slot = &.{};

const Rec = struct { start: u32 = 0, len: u32 = 0 };
const rec_n = max_records + 1;
/// Closed records and the open one, a ring: age `a` at `rec_at(a)`.
var recs: [rec_n]Rec = @splat(.{});
var open_i: u32 = 0;
/// Closed records held (ages 1..closed).
var closed: u32 = 0;
/// First slot of the oldest record, and the slots all records use.
var tail: u32 = 0;
var used: u32 = 0;
/// Frames stepped into the open record.
var open_frames: u32 = 0;
/// Records applied (0 = live).
var cursor: u32 = 0;
/// The open record outgrew the ring: no history until the next boundary.
var lost: bool = false;
/// `Lynx.Small` staging for opening and applying records (a static, off
/// the badge's small stack).
var small_tmp: Lynx.Small = undefined;

/// Take `arena` (4-byte aligned) as the slot ring: `arena.len / 68`
/// slots. Tracking stays off until `reset`.
pub fn init(arena: []align(4) u8) void {
    const n = arena.len / @sizeOf(Slot);
    slots = @as([*]Slot, @ptrCast(arena.ptr))[0..n];
    disable();
}

pub fn capacity_slots() usize {
    return slots.len;
}

/// Forget the history and open record 0 from `l`'s state; tracking on.
/// Without an arena (`init` not called or empty) tracking stays off.
pub fn reset(l: *Lynx) void {
    if (slots.len == 0) return disable();
    console = l;
    forget();
    open_record(l);
}

/// Tracking off: the history is forgotten and the console runs untracked.
pub fn disable() void {
    console = null;
    forget();
    open_frames = 0;
    set_dirty(1);
}

fn forget() void {
    recs = @splat(.{});
    open_i = 0;
    closed = 0;
    tail = 0;
    used = 0;
    cursor = 0;
    lost = false;
}

/// After every stepped frame: counts the open record's frames and at the
/// boundary closes it (evicting the oldest record past `max_records`) and
/// opens the next from `l`. Rebuilds after a lost history. See the header
/// for the parked case (`resume_here`).
pub fn record_frame(l: *Lynx) void {
    if (console == null) return;
    if (cursor != 0) return reset(l);
    open_frames += 1;
    if (open_frames < frames_per_record) return;
    if (lost) {
        // Start over from here.
        forget();
        return open_record(l);
    }
    if (closed == max_records) evict_oldest();
    closed += 1;
    open_i = (open_i + 1) % rec_n;
    open_record(l);
}

/// Before the first `step_frame` after a scrub: the applied records (ages
/// 0..cursor-1, the newest in the ring) hold the future and are dropped;
/// a fresh record opens from the parked state (a boundary). No-op live.
pub fn resume_here(l: *Lynx) void {
    if (cursor == 0 or console == null) return;
    const oldest_applied = rec_at(cursor - 1);
    const n: u32 = @intCast(slots.len);
    used = (oldest_applied.start + n - tail) % n;
    open_i = (open_i + rec_n - (cursor - 1)) % rec_n;
    closed -= cursor - 1;
    cursor = 0;
    open_record(l);
}

/// The cursor a step in `dir` reaches, null at the ends.
fn target(dir: i2) ?u32 {
    if (console == null or lost) return null;
    if (dir < 0) {
        const t: u32 = if (cursor == 0 and open_frames == 0) 2 else cursor + 1;
        return if (t - 1 <= closed) t else null;
    }
    if (dir > 0) return if (cursor > 0) (if (cursor == 2 and open_frames == 0) 0 else cursor - 1) else null;
    return null;
}

pub fn can_step(dir: i2) bool {
    return target(dir) != null;
}

/// Apply one record Left (dir < 0, back in time) or Right; false (and no
/// change) at the ends. Then `l.refresh_display()`: `display` shows the
/// frame at the restored DISPADR. Parked, the dirty bytes are all 1; back
/// at live they are rebuilt from the open record's slot ids.
pub fn step(l: *Lynx, dir: i2) bool {
    const t = target(dir) orelse return false;
    while (cursor < t) : (cursor += 1) apply(l, cursor);
    while (cursor > t) {
        cursor -= 1;
        apply(l, cursor);
    }
    if (cursor == 0) rebuild_dirty() else set_dirty(1);
    l.refresh_display();
    return true;
}

pub fn parked() bool {
    return cursor != 0;
}

/// Frames behind live (0 live).
pub fn depth_frames() u32 {
    if (cursor == 0) return 0;
    return open_frames + frames_per_record * (cursor - 1);
}

/// Frames reachable back from live.
pub fn history_frames() u32 {
    if (console == null or lost) return 0;
    return open_frames + frames_per_record * closed;
}

/// Closed records held.
pub fn record_count() usize {
    return closed;
}

pub fn slots_in_use() usize {
    return used;
}

/// Slots of the open record (0 while the history is lost): for sizing.
pub fn open_record_slots() usize {
    if (console == null or lost) return 0;
    return recs[open_i].len;
}

/// The open record's RAM block numbers (address >> 6), in the order they
/// were first written, into `out`; returns how many (all of them, even
/// past `out.len`): for sizing.
pub fn open_record_blocks(out: []u16) usize {
    if (console == null or lost) return 0;
    const r = recs[open_i];
    var n: usize = 0;
    var j: u32 = 0;
    while (j < r.len) : (j += 1) {
        const id = slots[(r.start + j) % slots.len].id;
        if (id >> 12 == @backingInt(Region.small)) continue;
        if (n < out.len) out[n] = id;
        n += 1;
    }
    return n;
}

/// True while the open record has outgrown the ring (until the boundary).
pub fn lost_history() bool {
    return lost;
}

// ---- Hot hooks: called BEFORE the write ----

/// One RAM byte at `addr` is about to be written.
pub inline fn touch(addr: u16) void {
    const b = addr >> 6;
    if (dirty[b] == 0) save(b);
}

/// `bytes` RAM bytes from `addr` are about to be written (wraps at 64 KB).
pub fn touch_range(addr: u16, bytes: u32) void {
    if (bytes == 0) return;
    if (bytes >= 0x10000) {
        var b: u16 = 0;
        while (b < ram_blocks) : (b += 1) if (dirty[b] == 0) save(b);
        return;
    }
    var b: u16 = addr >> 6;
    const last: u16 = @truncate(((@as(u32, addr) + bytes - 1) & 0xFFFF) >> 6);
    while (true) {
        if (dirty[b] == 0) save(b);
        if (b == last) break;
        b = (b + 1) % ram_blocks;
    }
}

/// `touch_range` for a short run (1..128 bytes: a sprite span within one
/// 80-byte line), in line: the common case (every block already saved)
/// is three byte loads and no call. A run of at most 128 bytes covers at
/// most three blocks: first, last and the one between.
pub inline fn touch_short(addr: u16, bytes: u16) void {
    const first = addr >> 6;
    const last = (addr +% (bytes - 1)) >> 6;
    const mid = (first + (((last -% first) & (ram_blocks - 1)) >> 1)) & (ram_blocks - 1);
    if (dirty[first] & dirty[mid] & dirty[last] == 0) touch_range(addr, bytes);
}

// ---- The rest ----

/// First write to RAM `block` in the open record: copy it in.
noinline fn save(block: u16) void {
    dirty[block] = 1;
    const l = console orelse return;
    const s = alloc_slot() orelse return;
    s.id = block;
    s.pad = 0;
    const off = @as(usize, block) * block_size;
    @memcpy(&s.data, l.ram[off..][0..block_size]);
}

fn set_dirty(v: u8) void {
    @memset(&dirty, v);
}

inline fn rec_at(age: u32) *Rec {
    return &recs[(open_i + rec_n - age) % rec_n];
}

/// Open a record at the ring's head from `l`: the small state, then the
/// dirty bytes cleared (every block not yet saved).
noinline fn open_record(l: *Lynx) void {
    const n: u32 = @intCast(slots.len);
    recs[open_i] = .{ .start = (tail + used) % n, .len = 0 };
    open_frames = 0;
    set_dirty(0);
    l.save_small(&small_tmp);
    const bytes = std.mem.asBytes(&small_tmp);
    var k: u16 = 0;
    while (k < small_slots) : (k += 1) {
        const s = alloc_slot() orelse return;
        s.id = small_id + k;
        s.pad = 0;
        const off = @as(usize, k) * block_size;
        const len = @min(block_size, bytes.len - off);
        @memcpy(s.data[0..len], bytes[off..][0..len]);
        if (len < block_size) @memset(s.data[len..], 0);
    }
}

/// The next slot of the open record, evicting the oldest closed record
/// when the ring is full; null when the open record alone fills it (the
/// history is lost until the next boundary).
noinline fn alloc_slot() ?*Slot {
    const n: u32 = @intCast(slots.len);
    if (used == n) {
        if (closed == 0) {
            lose();
            return null;
        }
        evict_oldest();
    }
    const i = (tail + used) % n;
    used += 1;
    recs[open_i].len += 1;
    return &slots[i];
}

fn evict_oldest() void {
    const r = rec_at(closed);
    tail = (tail + r.len) % @as(u32, @intCast(slots.len));
    used -= r.len;
    r.* = .{};
    closed -= 1;
}

/// The open record alone outgrew the ring: drop everything, stop copying
/// (dirty bytes 1) until the next boundary starts over.
fn lose() void {
    lost = true;
    used = 0;
    tail = 0;
    recs[open_i] = .{};
    set_dirty(1);
}

/// Swap record `age` with the console (see the header).
fn apply(l: *Lynx, age: u32) void {
    const r = rec_at(age).*;
    const n = slots.len;
    l.save_small(&small_tmp);
    const bytes = std.mem.asBytes(&small_tmp);
    var j: u32 = 0;
    while (j < r.len) : (j += 1) {
        const s = &slots[(r.start + j) % n];
        const region: u4 = @truncate(s.id >> 12);
        const idx: u16 = s.id & 0xFFF;
        if (region == @backingInt(Region.small)) {
            const off = @as(usize, idx) * block_size;
            const len = @min(block_size, bytes.len - off);
            swap_bytes(s.data[0..len], bytes[off..][0..len]);
        } else {
            const off = @as(usize, idx) * block_size;
            swap_bytes(&s.data, l.ram[off..][0..block_size]);
        }
    }
    l.load_small(&small_tmp);
}

fn swap_bytes(a: []u8, b: []u8) void {
    for (a, b) |*x, *y| {
        const t = x.*;
        x.* = y.*;
        y.* = t;
    }
}

/// Back at live: the blocks the open record holds are saved (1), all
/// others are not (0).
fn rebuild_dirty() void {
    set_dirty(0);
    const r = recs[open_i];
    var j: u32 = 0;
    while (j < r.len) : (j += 1) {
        const id = slots[(r.start + j) % slots.len].id;
        if (id >> 12 == @backingInt(Region.small)) continue;
        dirty[id & 0xFFF] = 1;
    }
}
