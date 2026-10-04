//! The time scrubber's store (SPEC.md section 10, PLAN.md "M3 Scrub:
//! contract", "Frozen for M3"): copy-on-first-write undo records, one per
//! `frames_per_record` Genesis frames, in one ring of 68-byte slots in an
//! arena the frontend hands over. One tracker for one console: the state
//! is file-level so the write paths reach the need bytes without an `Md`
//! offset. No cart-api, no allocator, no floats.
//!
//! A record is a run of consecutive slots (modular in the ring): first the
//! console's small state (`Md.Small`, `small_slots` slots, ids `0xF000 +
//! chunk`), then one slot per 64-byte block first written in the record's
//! interval (id `region << 12 | block`) holding the block as it was at the
//! record's opening boundary. Applying a record swaps every slot with the
//! console's bytes: the console goes back to the boundary and the record
//! now holds the newer contents, so applying it again goes forward. Left
//! and Right are the same operation, bit-exact, with no replay.
//!
//! Ages: 0 is the open record (from the newest boundary to live), 1 the
//! newest closed one, ... `cursor` counts the records applied (0 = live).
//! Left from live while the open record is empty (live exactly on a
//! boundary) applies it and the newest closed record in one step, so every
//! step moves the picture; Right mirrors it.
//!
//! Frontend protocol:
//!   init(arena) once; reset(md) after the console is (re)made (`Md.reset`
//!   writes the memories past the hooks); record_frame(md) after every
//!   `step_frame`; step(md, dir) while scrubbing (then `Md.render_still`
//!   for the picture); and **`resume_here(md)` before the first
//!   `step_frame` after a scrub** when `parked()`: it drops the applied
//!   records (they hold the future) and opens a fresh record from the
//!   parked state. The truncation cannot happen inside `record_frame`: by
//!   then the frame has run untracked. `record_frame` while parked (the
//!   frontend forgot `resume_here`) forgets the history (`reset`), which
//!   is consistent, never corrupt.
//!
//! Need bytes: one per block, nonzero = the block has not been saved into
//! the open record yet, so the first write copies it. All zero = nothing
//! is copied: before `init`, after `disable`, while parked, and while the
//! history is lost. Zero is the `.bss` state, so the untracked host tests
//! pay only the byte test. (The encoding is the inverse of the "dirty
//! byte" of the PLAN text; the cost is the same load and branch.)
//!
//! The hooks do not know which console writes: a second, untracked
//! console stepped while another is tracked only makes the tracked one
//! save blocks it did not write, which is harmless (a block not yet saved
//! still holds its boundary contents).
const std = @import("std");
const md_mod = @import("md.zig");
const rom = @import("rom.zig");
const Md = md_mod.Md;

/// The scrubber is in this build (`build_options.scrub`: the XIP cart and
/// the simulator). Without it the hooks below compile to nothing and the
/// frontend never calls the rest (PLAN.md M5: the RAM cart).
pub const enabled: bool = @import("build_options").scrub;

pub const block_size = 64;
pub const Slot = extern struct {
    id: u16,
    pad: u16 = 0,
    /// Word aligned (offset 4, slot size 68) for the arena's 4-byte slots.
    data: [block_size]u8 align(4),
};
pub const frames_per_record = 30;
pub const max_records = 64;
pub const Region = enum(u4) { work_ram = 0, vram = 1, z80_ram = 2, sram = 3, small = 15 };

comptime {
    if (@sizeOf(Slot) != 68) @compileError("undo.Slot must be 68 bytes");
}

/// Slots of `Md.Small` at the head of every record.
pub const small_slots = (@sizeOf(Md.Small) + block_size - 1) / block_size;
const small_id: u16 = @as(u16, @backingInt(Region.small)) << 12;

const wr_blocks = 0x10000 / block_size;
const vr_blocks = 0x10000 / block_size;
const zr_blocks = md_mod.z80_ram_size / block_size;
const sr_blocks = rom.sram_max / block_size;

var need_wr: [wr_blocks]u8 = @splat(0);
var need_vr: [vr_blocks]u8 = @splat(0);
var need_zr: [zr_blocks]u8 = @splat(0);
var need_sr: [sr_blocks]u8 = @splat(0);

/// The tracked console, null while tracking is off.
var console: ?*Md = null;
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
/// `Md.Small` staging for opening and applying records (a static: 1.7 KB
/// is too much for the wasm stack's taste).
var small_tmp: Md.Small = undefined;

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

/// Forget the history and open record 0 from `md`'s state; tracking on.
/// Without an arena (`init` not called or empty) tracking stays off.
pub fn reset(md: *Md) void {
    if (slots.len == 0) return disable();
    console = md;
    recs = @splat(.{});
    open_i = 0;
    closed = 0;
    tail = 0;
    used = 0;
    cursor = 0;
    lost = false;
    open_record(md);
}

/// Tracking off: the history is forgotten and the console runs untracked.
pub fn disable() void {
    console = null;
    clear_need();
    closed = 0;
    tail = 0;
    used = 0;
    cursor = 0;
    open_frames = 0;
    lost = false;
    recs = @splat(.{});
}

/// After every stepped frame: counts the open record's frames and at the
/// boundary closes it (evicting the oldest record past `max_records`) and
/// opens the next from `md`. Rebuilds after a lost history. See the
/// header for the parked case (`resume_here`).
pub fn record_frame(md: *Md) void {
    if (console == null) return;
    if (cursor != 0) return reset(md);
    open_frames += 1;
    if (open_frames < frames_per_record) return;
    if (lost) {
        // Start over from here.
        lost = false;
        recs = @splat(.{});
        open_i = 0;
        closed = 0;
        tail = 0;
        used = 0;
        return open_record(md);
    }
    if (closed == max_records) evict_oldest();
    closed += 1;
    open_i = (open_i + 1) % rec_n;
    open_record(md);
}

/// Before the first `step_frame` after a scrub: the applied records (ages
/// 0..cursor-1, the newest in the ring) hold the future and are dropped;
/// a fresh record opens from the parked state (a boundary). No-op live.
pub fn resume_here(md: *Md) void {
    if (cursor == 0 or console == null) return;
    const oldest_applied = rec_at(cursor - 1);
    const n: u32 = @intCast(slots.len);
    used = (oldest_applied.start + n - tail) % n;
    open_i = (open_i + rec_n - (cursor - 1)) % rec_n;
    closed -= cursor - 1;
    cursor = 0;
    open_record(md);
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
/// change) at the ends. Parked, the need bytes are all zero; back at
/// live they are rebuilt from the open record's slot ids.
pub fn step(md: *Md, dir: i2) bool {
    const t = target(dir) orelse return false;
    while (cursor < t) : (cursor += 1) apply(md, cursor);
    while (cursor > t) {
        cursor -= 1;
        apply(md, cursor);
    }
    if (cursor == 0) rebuild_need() else clear_need();
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

/// The open record's block slots per region (work RAM, VRAM, Z80 RAM,
/// SRAM): for sizing.
pub fn open_record_blocks() [4]u32 {
    var c: [4]u32 = @splat(0);
    if (console == null or lost) return c;
    const r = recs[open_i];
    var j: u32 = 0;
    while (j < r.len) : (j += 1) {
        const id = slots[(r.start + j) % slots.len].id;
        if (id >> 12 < 4) c[id >> 12] += 1;
    }
    return c;
}

/// True while the open record has outgrown the ring (until the boundary).
pub fn lost_history() bool {
    return lost;
}

// ---- Hot hooks: called BEFORE the write, with the region address ----

/// Work RAM byte address (a word never straddles a block).
pub inline fn touch_wr(addr: u16) void {
    if (!enabled) return;
    const b = addr >> 6;
    if (need_wr[b] != 0) save(.work_ram, b);
}

/// VRAM byte address.
pub inline fn touch_vr(addr: u16) void {
    if (!enabled) return;
    const b = addr >> 6;
    if (need_vr[b] != 0) save(.vram, b);
}

/// A VRAM run of `bytes` from `addr`, wrapping at 64 KB (DMA).
pub fn touch_vr_range(addr: u16, bytes: u32) void {
    if (!enabled) return;
    if (bytes == 0) return;
    if (bytes >= 0x10000) {
        var b: u16 = 0;
        while (b < vr_blocks) : (b += 1) if (need_vr[b] != 0) save(.vram, b);
        return;
    }
    var b: u16 = addr >> 6;
    const last: u16 = @truncate(((@as(u32, addr) + bytes - 1) & 0xFFFF) >> 6);
    while (true) {
        if (need_vr[b] != 0) save(.vram, b);
        if (b == last) break;
        b = (b + 1) % vr_blocks;
    }
}

/// Z80 RAM address (0000-1FFF).
pub inline fn touch_zr(addr: u13) void {
    if (!enabled) return;
    const b = addr >> 6;
    if (need_zr[b] != 0) save(.z80_ram, b);
}

/// Cartridge SRAM: index into `md.sram`.
pub inline fn touch_sr(addr: u14) void {
    if (!enabled) return;
    const b = addr >> 6;
    if (need_sr[b] != 0) save(.sram, b);
}

// ---- The rest ----

/// First write to `block` of `region` in the open record: copy it in.
noinline fn save(region: Region, block: u16) void {
    const md = console orelse return clear_need();
    need(region)[block] = 0;
    const s = alloc_slot() orelse return;
    s.id = @as(u16, @backingInt(region)) << 12 | block;
    s.pad = 0;
    @memcpy(&s.data, block_bytes(md, region, block));
}

fn need(region: Region) []u8 {
    return switch (region) {
        .work_ram => &need_wr,
        .vram => &need_vr,
        .z80_ram => &need_zr,
        .sram => &need_sr,
        .small => unreachable,
    };
}

fn block_bytes(md: *Md, region: Region, block: u16) *[block_size]u8 {
    const off = @as(usize, block) * block_size;
    return switch (region) {
        .work_ram => md.work_ram[off..][0..block_size],
        .vram => md.vdp.vram[off..][0..block_size],
        .z80_ram => md.z80_ram[off..][0..block_size],
        .sram => md.sram[off..][0..block_size],
        .small => unreachable,
    };
}

fn clear_need() void {
    @memset(&need_wr, 0);
    @memset(&need_vr, 0);
    @memset(&need_zr, 0);
    @memset(&need_sr, 0);
}

inline fn rec_at(age: u32) *Rec {
    return &recs[(open_i + rec_n - age) % rec_n];
}

/// Open a record at the ring's head from `md`: the small state, then the
/// need bytes set (every block not yet saved).
fn open_record(md: *Md) void {
    const n: u32 = @intCast(slots.len);
    recs[open_i] = .{ .start = (tail + used) % n, .len = 0 };
    open_frames = 0;
    @memset(&need_wr, 1);
    @memset(&need_vr, 1);
    @memset(&need_zr, 1);
    @memset(&need_sr, 1);
    md.save_small(&small_tmp);
    const bytes = std.mem.asBytes(&small_tmp);
    var k: u16 = 0;
    while (k < small_slots) : (k += 1) {
        const s = alloc_slot() orelse return;
        s.id = small_id + k;
        s.pad = 0;
        const off = @as(usize, k) * block_size;
        const len = @min(block_size, bytes.len - off);
        @memcpy(s.data[0..len], bytes[off..][0..len]);
    }
}

/// The next slot of the open record, evicting the oldest closed record
/// when the ring is full; null when the open record alone fills it (the
/// history is lost until the next boundary).
fn alloc_slot() ?*Slot {
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

fn lose() void {
    lost = true;
    used = 0;
    tail = 0;
    recs[open_i] = .{};
    clear_need();
}

/// Swap record `age` with the console (see the header).
fn apply(md: *Md, age: u32) void {
    const r = rec_at(age).*;
    const n = slots.len;
    md.save_small(&small_tmp);
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
            swap_bytes(&s.data, block_bytes(md, @fromBackingInt(@intCast(region)), idx));
        }
    }
    md.load_small(&small_tmp);
}

fn swap_bytes(a: []u8, b: []u8) void {
    for (a, b) |*x, *y| {
        const t = x.*;
        x.* = y.*;
        y.* = t;
    }
}

/// Back at live: the blocks the open record holds are saved, all others
/// are not.
fn rebuild_need() void {
    @memset(&need_wr, 1);
    @memset(&need_vr, 1);
    @memset(&need_zr, 1);
    @memset(&need_sr, 1);
    const r = recs[open_i];
    var j: u32 = 0;
    while (j < r.len) : (j += 1) {
        const id = slots[(r.start + j) % slots.len].id;
        const region: u4 = @truncate(id >> 12);
        if (region == @backingInt(Region.small)) continue;
        need(@fromBackingInt(@intCast(region)))[id & 0xFFF] = 0;
    }
}
